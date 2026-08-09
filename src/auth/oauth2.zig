const std = @import("std");

const http = @import("../http.zig");
const oauth1 = @import("oauth1.zig");
const Consumer = @import("consumer.zig").Consumer;

const Allocating = std.Io.Writer.Allocating;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

pub const OAuth2Token = struct {
    access_token: []u8,
    refresh_token: []u8,
    obtained_at: i64,
    lifetime_seconds: i64,
    refresh_lifetime_seconds: i64,
    gpa: Allocator,

    pub fn deinit(token: *OAuth2Token) void {
        assert(token.access_token.len != 0);

        token.gpa.free(token.access_token);
        token.gpa.free(token.refresh_token);
    }

    pub fn expires_at(token: *const OAuth2Token) i64 {
        assert(token.obtained_at > 0);
        assert(token.lifetime_seconds > 0);

        return token.obtained_at + token.lifetime_seconds;
    }

    pub fn refresh_expires_at(token: *const OAuth2Token) i64 {
        assert(token.obtained_at > 0);
        assert(token.refresh_lifetime_seconds >= 0);

        return token.obtained_at + token.refresh_lifetime_seconds;
    }

    pub fn expired(token: *const OAuth2Token, io: std.Io) bool {
        const now = std.Io.Clock.real.now(io).toSeconds();

        assert(now > 0);

        return now + renewal_margin_seconds >= token.expires_at();
    }

    pub fn refresh_expired(token: *const OAuth2Token, io: std.Io) bool {
        const now = std.Io.Clock.real.now(io).toSeconds();

        assert(now > 0);

        return now >= token.refresh_expires_at();
    }

    pub fn authorization(token: *const OAuth2Token, gpa: Allocator) ![]u8 {
        assert(token.access_token.len != 0);

        return std.fmt.allocPrint(gpa, "{s} {s}", .{ scheme, token.access_token });
    }
};

const Granted = struct {
    token_type: []const u8,
    access_token: []const u8,
    refresh_token: []const u8,
    expires_in: i64,
    refresh_token_expires_in: i64,
};

pub const renewal_margin_seconds: i64 = 60;
pub const lifetime_seconds_max: i64 = 10 * 365 * 24 * 60 * 60;
pub const scheme: []const u8 = "Bearer";

const exchange_path: []const u8 = "/oauth-service/oauth/exchange/user/2.0";

comptime {
    assert(renewal_margin_seconds > 0);
    assert(renewal_margin_seconds < lifetime_seconds_max);
}

pub fn exchange(
    gpa: Allocator,
    io: std.Io,
    client: *http.Client,
    consumer: *const Consumer,
    token_oauth1: *const oauth1.OAuth1Token,
) !OAuth2Token {
    assert(consumer.key.len != 0);
    assert(token_oauth1.oauth_token.len != 0);

    const url = oauth1.connectapi_url ++ exchange_path;

    var params_buffer: [1]oauth1.Param = undefined;
    var params_count: usize = 0;

    if (token_oauth1.mfa_token) |mfa| {
        params_buffer[params_count] = .{ .key = "mfa_token", .value = mfa };
        params_count += 1;
    }

    const params = params_buffer[0..params_count];

    var buffers: oauth1.SigningBuffers = .{};

    const signing = try oauth1.signing_init(io, &buffers, &.{
        .method = "POST",
        .base_url = url,
        .consumer = consumer,
        .token = token_oauth1.oauth_token,
        .token_secret = token_oauth1.oauth_token_secret,
    });

    const authorization = try oauth1.authorization_header(gpa, &signing, params);
    defer gpa.free(authorization);

    const payload = try signed_body(gpa, params);
    defer gpa.free(payload);

    var response = try client.send(&.{
        .method = .POST,
        .url = url,
        .user_agent = http.user_agent_android,
        .content_type = "application/x-www-form-urlencoded",
        .authorization = authorization,
        .payload = payload,
        .redirect = false,
    });

    defer response.deinit();

    if (response.status != 200) return error.OAuth2ExchangeFailed;

    return parse_granted(gpa, io, response.body);
}

fn signed_body(
    gpa: Allocator,
    params: []const oauth1.Param,
) ![]u8 {
    var body: Allocating = .init(gpa);
    errdefer body.deinit();

    for (params, 0..) |param, index| {
        assert(param.key.len != 0);

        if (index != 0) try body.writer.writeByte('&');

        try body.writer.writeAll(param.key);
        try body.writer.writeByte('=');
        try oauth1.percent_encode(&body.writer, param.value);
    }

    return body.toOwnedSlice();
}

fn parse_granted(gpa: Allocator, io: std.Io, body: []const u8) !OAuth2Token {
    const parsed = try std.json.parseFromSlice(Granted, gpa, body, .{
        .ignore_unknown_fields = true,
    });

    defer parsed.deinit();

    const granted = parsed.value;

    if (!std.ascii.eqlIgnoreCase(granted.token_type, scheme)) return error.OAuth2SchemeUnsupported;
    if (granted.access_token.len == 0) return error.OAuth2ResponseInvalid;
    if (granted.refresh_token.len == 0) return error.OAuth2ResponseInvalid;

    try check_lifetime(granted.expires_in, 1);
    try check_lifetime(granted.refresh_token_expires_in, 0);

    const obtained_at = std.Io.Clock.real.now(io).toSeconds();

    const token = try adopt(gpa, &granted, obtained_at);

    assert(token.expires_at() > obtained_at);

    return token;
}

fn check_lifetime(seconds: i64, floor: i64) !void {
    assert(floor >= 0);

    if (seconds < floor) return error.OAuth2ResponseInvalid;
    if (seconds > lifetime_seconds_max) return error.OAuth2ResponseInvalid;
}

fn adopt(gpa: Allocator, granted: *const Granted, obtained_at: i64) !OAuth2Token {
    assert(obtained_at > 0);
    assert(granted.access_token.len != 0);

    const access_token = try gpa.dupe(u8, granted.access_token);
    errdefer gpa.free(access_token);

    const refresh_token = try gpa.dupe(u8, granted.refresh_token);

    return .{
        .access_token = access_token,
        .refresh_token = refresh_token,
        .obtained_at = obtained_at,
        .lifetime_seconds = granted.expires_in,
        .refresh_lifetime_seconds = granted.refresh_token_expires_in,
        .gpa = gpa,
    };
}
