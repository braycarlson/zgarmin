const std = @import("std");

const http = @import("../http.zig");
const Consumer = @import("consumer.zig").Consumer;

const Allocator = std.mem.Allocator;
const HmacSha1 = std.crypto.auth.hmac.HmacSha1;
const assert = std.debug.assert;
const base64 = std.base64.standard;

pub const OAuth1Token = struct {
    oauth_token: []u8,
    oauth_token_secret: []u8,
    mfa_token: ?[]u8,
    gpa: Allocator,

    pub fn deinit(token: *OAuth1Token) void {
        token.gpa.free(token.oauth_token);
        token.gpa.free(token.oauth_token_secret);

        if (token.mfa_token) |mfa| token.gpa.free(mfa);
    }
};

pub const Param = struct {
    key: []const u8,
    value: []const u8,
};

pub const Signing = struct {
    method: []const u8,
    base_url: []const u8,
    consumer_key: []const u8,
    consumer_secret: []const u8,
    token: []const u8,
    token_secret: []const u8,
    nonce: []const u8,
    timestamp: []const u8,
};

pub const SigningBuffers = struct {
    nonce: [nonce_len]u8 = undefined,
    timestamp: [timestamp_len_max]u8 = undefined,
};

pub const SigningRequest = struct {
    method: []const u8,
    base_url: []const u8,
    consumer: *const Consumer,
    token: []const u8 = "",
    token_secret: []const u8 = "",
};

const Encoded = struct {
    key: []u8,
    value: []u8,

    fn less(_: void, a: Encoded, b: Encoded) bool {
        const order = std.mem.order(u8, a.key, b.key);

        if (order != .eq) return order == .lt;

        return std.mem.order(u8, a.value, b.value) == .lt;
    }
};

pub const params_max: u32 = 32;
pub const oauth_params_max: u32 = 6;
pub const signature_base64_len: u32 = 28;

pub const nonce_bytes: u32 = 16;
pub const nonce_len: u32 = nonce_bytes * 2;
pub const timestamp_len_max: u32 = 20;

pub const connectapi_url: []const u8 = "https://connectapi.garmin.com";

pub const preauthorization_origin: []const u8 = "https://sso.garmin.com/sso/embed";

comptime {
    assert(base64.Encoder.calcSize(HmacSha1.mac_length) == signature_base64_len);
}

pub fn get_oauth1_token(
    gpa: Allocator,
    io: std.Io,
    client: *http.Client,
    consumer: *const Consumer,
    ticket: []const u8,
) !OAuth1Token {
    assert(ticket.len != 0);
    assert(consumer.key.len != 0);

    const base_url = connectapi_url ++ "/oauth-service/oauth/preauthorized";

    const params = [_]Param{
        .{ .key = "accepts-mfa-tokens", .value = "true" },
        .{ .key = "login-url", .value = preauthorization_origin },
        .{ .key = "ticket", .value = ticket },
    };

    var buffers: SigningBuffers = .{};

    const signing = try signing_init(io, &buffers, &.{
        .method = "GET",
        .base_url = base_url,
        .consumer = consumer,
    });

    const authorization = try authorization_header(gpa, &signing, &params);
    defer gpa.free(authorization);

    const url = try url_with_query(gpa, base_url, &params);
    defer gpa.free(url);

    var response = try client.send(&.{
        .method = .GET,
        .url = url,
        .user_agent = http.user_agent_android,
        .authorization = authorization,
        .redirect = false,
    });

    defer response.deinit();

    if (response.status != 200) return error.OAuth1RequestFailed;

    return parse_oauth1(gpa, response.body);
}

pub fn signing_init(
    io: std.Io,
    buffers: *SigningBuffers,
    request: *const SigningRequest,
) !Signing {
    assert(request.method.len != 0);
    assert(request.base_url.len != 0);
    assert(request.consumer.key.len != 0);
    assert(request.consumer.secret.len != 0);

    nonce_hex(io, &buffers.nonce);

    const timestamp = try timestamp_seconds(io, &buffers.timestamp);

    assert(timestamp.len != 0);

    return .{
        .method = request.method,
        .base_url = request.base_url,
        .consumer_key = request.consumer.key,
        .consumer_secret = request.consumer.secret,
        .token = request.token,
        .token_secret = request.token_secret,
        .nonce = &buffers.nonce,
        .timestamp = timestamp,
    };
}

pub fn nonce_hex(io: std.Io, out: *[nonce_len]u8) void {
    const hex = "0123456789abcdef";

    var raw: [nonce_bytes]u8 = undefined;

    io.random(&raw);

    for (raw, 0..) |byte, index| {
        out[index * 2] = hex[byte >> 4];
        out[index * 2 + 1] = hex[byte & 0x0f];
    }
}

pub fn timestamp_seconds(io: std.Io, out: *[timestamp_len_max]u8) ![]const u8 {
    const seconds = std.Io.Clock.real.now(io).toSeconds();

    return std.fmt.bufPrint(out, "{d}", .{seconds});
}

pub fn authorization_header(
    gpa: Allocator,
    signing: *const Signing,
    extra_params: []const Param,
) ![]u8 {
    assert(signing.consumer_key.len != 0);
    assert(signing.nonce.len != 0);
    assert(signing.timestamp.len != 0);

    var all: [params_max]Param = undefined;

    const all_count = try authorization_header_params(&all, signing, extra_params);

    var signature: [signature_base64_len]u8 = undefined;

    try sign(gpa, signing, all[0..all_count], &signature);

    var writer: std.Io.Writer.Allocating = .init(gpa);
    errdefer writer.deinit();

    try writer.writer.writeAll("OAuth ");
    try write_header_param(&writer.writer, "oauth_consumer_key", signing.consumer_key, true);
    try write_header_param(&writer.writer, "oauth_nonce", signing.nonce, false);
    try write_header_param(&writer.writer, "oauth_signature", &signature, false);
    try write_header_param(&writer.writer, "oauth_signature_method", "HMAC-SHA1", false);
    try write_header_param(&writer.writer, "oauth_timestamp", signing.timestamp, false);

    if (signing.token.len != 0) {
        try write_header_param(&writer.writer, "oauth_token", signing.token, false);
    }

    try write_header_param(&writer.writer, "oauth_version", "1.0", false);

    return writer.toOwnedSlice();
}

fn authorization_header_params(
    out: *[params_max]Param,
    signing: *const Signing,
    extra_params: []const Param,
) !usize {
    var oauth: [oauth_params_max]Param = undefined;
    var oauth_count: usize = 0;

    oauth[oauth_count] = .{ .key = "oauth_consumer_key", .value = signing.consumer_key };
    oauth_count += 1;

    oauth[oauth_count] = .{ .key = "oauth_nonce", .value = signing.nonce };
    oauth_count += 1;

    oauth[oauth_count] = .{ .key = "oauth_signature_method", .value = "HMAC-SHA1" };
    oauth_count += 1;

    oauth[oauth_count] = .{ .key = "oauth_timestamp", .value = signing.timestamp };
    oauth_count += 1;

    if (signing.token.len != 0) {
        oauth[oauth_count] = .{ .key = "oauth_token", .value = signing.token };
        oauth_count += 1;
    }

    oauth[oauth_count] = .{ .key = "oauth_version", .value = "1.0" };
    oauth_count += 1;

    if (oauth_count + extra_params.len > params_max) return error.ParamCountExceeded;

    var all_count: usize = 0;

    for (oauth[0..oauth_count]) |param| {
        out[all_count] = param;
        all_count += 1;
    }

    for (extra_params) |param| {
        assert(all_count < params_max);

        out[all_count] = param;
        all_count += 1;
    }

    assert(all_count <= params_max);

    return all_count;
}

pub fn sign(
    gpa: Allocator,
    signing: *const Signing,
    params: []const Param,
    out_signature: *[signature_base64_len]u8,
) !void {
    assert(signing.consumer_secret.len != 0);

    const base = try signature_base_string(gpa, signing.method, signing.base_url, params);
    defer gpa.free(base);

    var key: std.Io.Writer.Allocating = .init(gpa);
    defer key.deinit();

    try percent_encode(&key.writer, signing.consumer_secret);
    try key.writer.writeByte('&');
    try percent_encode(&key.writer, signing.token_secret);

    var mac: [HmacSha1.mac_length]u8 = undefined;

    HmacSha1.create(&mac, base, key.written());

    const written = base64.Encoder.encode(out_signature, &mac);

    assert(written.len == signature_base64_len);
}

pub fn signature_base_string(
    gpa: Allocator,
    method: []const u8,
    base_url: []const u8,
    params: []const Param,
) ![]u8 {
    assert(method.len != 0);
    assert(base_url.len != 0);

    if (params.len > params_max) return error.ParamCountExceeded;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    const arena = arena_state.allocator();

    var encoded: [params_max]Encoded = undefined;

    for (params, 0..) |param, index| {
        encoded[index] = .{
            .key = try percent_encode_alloc(arena, param.key),
            .value = try percent_encode_alloc(arena, param.value),
        };
    }

    const slice = encoded[0..params.len];

    std.mem.sort(Encoded, slice, {}, Encoded.less);

    var param_string: std.Io.Writer.Allocating = .init(arena);

    for (slice, 0..) |entry, index| {
        if (index != 0) try param_string.writer.writeByte('&');

        try param_string.writer.writeAll(entry.key);
        try param_string.writer.writeByte('=');
        try param_string.writer.writeAll(entry.value);
    }

    var base: std.Io.Writer.Allocating = .init(gpa);
    errdefer base.deinit();

    try base.writer.writeAll(method);
    try base.writer.writeByte('&');
    try percent_encode(&base.writer, base_url);
    try base.writer.writeByte('&');
    try percent_encode(&base.writer, param_string.written());

    return base.toOwnedSlice();
}

fn percent_encode_alloc(gpa: Allocator, input: []const u8) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(gpa);
    errdefer writer.deinit();

    try percent_encode(&writer.writer, input);
    return writer.toOwnedSlice();
}

fn write_header_param(out: *std.Io.Writer, key: []const u8, value: []const u8, first: bool) !void {
    if (!first) try out.writeAll(", ");

    try out.writeAll(key);
    try out.writeAll("=\"");
    try percent_encode(out, value);
    try out.writeByte('"');
}

fn url_with_query(gpa: Allocator, base_url: []const u8, params: []const Param) ![]u8 {
    assert(base_url.len != 0);
    assert(params.len != 0);
    assert(params.len <= params_max);

    var writer: std.Io.Writer.Allocating = .init(gpa);
    errdefer writer.deinit();

    try writer.writer.writeAll(base_url);

    for (params, 0..) |param, index| {
        try writer.writer.writeByte(if (index == 0) '?' else '&');
        try writer.writer.writeAll(param.key);
        try writer.writer.writeByte('=');
        try percent_encode(&writer.writer, param.value);
    }

    return writer.toOwnedSlice();
}

fn parse_oauth1(gpa: Allocator, body: []const u8) !OAuth1Token {
    var oauth_token: ?[]u8 = null;
    errdefer if (oauth_token) |value| gpa.free(value);

    var oauth_token_secret: ?[]u8 = null;
    errdefer if (oauth_token_secret) |value| gpa.free(value);

    var mfa_token: ?[]u8 = null;
    errdefer if (mfa_token) |value| gpa.free(value);

    var pairs = std.mem.splitScalar(u8, body, '&');

    while (pairs.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        const key = pair[0..eq];
        const value = pair[eq + 1 ..];

        if (std.mem.eql(u8, key, "oauth_token")) {
            const decoded = try query_decode(gpa, value);

            if (oauth_token) |previous| gpa.free(previous);
            oauth_token = decoded;
        } else if (std.mem.eql(u8, key, "oauth_token_secret")) {
            const decoded = try query_decode(gpa, value);

            if (oauth_token_secret) |previous| gpa.free(previous);
            oauth_token_secret = decoded;
        } else if (std.mem.eql(u8, key, "mfa_token")) {
            const decoded = try query_decode(gpa, value);

            if (mfa_token) |previous| gpa.free(previous);
            mfa_token = decoded;
        }
    }

    const token = oauth_token orelse return error.OAuth1ResponseInvalid;
    const secret = oauth_token_secret orelse return error.OAuth1ResponseInvalid;

    if (token.len == 0) return error.OAuth1ResponseInvalid;
    if (secret.len == 0) return error.OAuth1ResponseInvalid;

    return .{
        .oauth_token = token,
        .oauth_token_secret = secret,
        .mfa_token = mfa_token,
        .gpa = gpa,
    };
}

pub fn query_decode(gpa: Allocator, input: []const u8) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(gpa);
    errdefer writer.deinit();

    var index: usize = 0;

    while (index < input.len) {
        const c = input[index];

        if (c == '+') {
            try writer.writer.writeByte(' ');
            index += 1;
        } else if (c == '%' and index + 2 < input.len) {
            const high = std.fmt.charToDigit(input[index + 1], 16) catch {
                try writer.writer.writeByte(c);
                index += 1;
                continue;
            };

            const low = std.fmt.charToDigit(input[index + 2], 16) catch {
                try writer.writer.writeByte(c);
                index += 1;
                continue;
            };

            try writer.writer.writeByte(high * 16 + low);
            index += 3;
        } else {
            try writer.writer.writeByte(c);
            index += 1;
        }
    }

    return writer.toOwnedSlice();
}

pub fn percent_encode(out: *std.Io.Writer, input: []const u8) !void {
    const hex = "0123456789ABCDEF";

    for (input) |c| {
        if (is_unreserved(c)) {
            try out.writeByte(c);
        } else {
            try out.writeByte('%');
            try out.writeByte(hex[c >> 4]);
            try out.writeByte(hex[c & 0x0f]);
        }
    }
}

fn is_unreserved(c: u8) bool {
    return switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~' => true,
        else => false,
    };
}

test {
    _ = @import("oauth1_fuzz.zig");
}

test "preauthorized signature matches oracle" {
    const gpa = std.testing.allocator;

    const params = [_]Param{
        .{ .key = "login-url", .value = "https://mobile.integration.garmin.com/gcm/android" },
        .{ .key = "accepts-mfa-tokens", .value = "true" },
        .{ .key = "ticket", .value = "ST-0123-abcXYZ-cas" },
        .{ .key = "oauth_consumer_key", .value = "fc3e99d2-118c-44b8-8ae3-03370dde24c0" },
        .{ .key = "oauth_nonce", .value = "0123456789abcdef0123456789abcdef" },
        .{ .key = "oauth_signature_method", .value = "HMAC-SHA1" },
        .{ .key = "oauth_timestamp", .value = "1700000000" },
        .{ .key = "oauth_version", .value = "1.0" },
    };

    var signature: [signature_base64_len]u8 = undefined;

    try sign(gpa, &.{
        .method = "GET",
        .base_url = "https://connectapi.garmin.com/oauth-service/oauth/preauthorized",
        .consumer_key = "",
        .consumer_secret = "E08WAR897WEy2knn7aFBrvegVAf0AFdWBBF",
        .token = "",
        .token_secret = "",
        .nonce = "",
        .timestamp = "",
    }, &params, &signature);

    try std.testing.expectEqualStrings("npjfRCOcKNSbw7+G+Y3OSQBKfXU=", &signature);
}

test "exchange signature matches oracle" {
    const gpa = std.testing.allocator;

    const params = [_]Param{
        .{ .key = "oauth_consumer_key", .value = "fc3e99d2-118c-44b8-8ae3-03370dde24c0" },
        .{ .key = "oauth_nonce", .value = "abcdef0123456789abcdef0123456789" },
        .{ .key = "oauth_signature_method", .value = "HMAC-SHA1" },
        .{ .key = "oauth_timestamp", .value = "1700000001" },
        .{ .key = "oauth_token", .value = "b1b2c3d4-e5f6-7890-abcd-ef0123456789" },
        .{ .key = "oauth_version", .value = "1.0" },
    };

    var signature: [signature_base64_len]u8 = undefined;

    try sign(gpa, &.{
        .method = "POST",
        .base_url = "https://connectapi.garmin.com/oauth-service/oauth/exchange/user/2.0",
        .consumer_key = "",
        .consumer_secret = "E08WAR897WEy2knn7aFBrvegVAf0AFdWBBF",
        .token = "",
        .token_secret = "tokensecret-9f8e7d6c5b4a",
        .nonce = "",
        .timestamp = "",
    }, &params, &signature);

    try std.testing.expectEqualStrings("r4bFcuf2noDddQZtQxlMIHgcUOU=", &signature);
}

test "signature base string double encodes reserved characters" {
    const gpa = std.testing.allocator;

    const params = [_]Param{
        .{ .key = "login-url", .value = "https://mobile.integration.garmin.com/gcm/android" },
        .{ .key = "accepts-mfa-tokens", .value = "true" },
        .{ .key = "ticket", .value = "ST-0123-abcXYZ-cas" },
        .{ .key = "oauth_consumer_key", .value = "fc3e99d2-118c-44b8-8ae3-03370dde24c0" },
        .{ .key = "oauth_nonce", .value = "0123456789abcdef0123456789abcdef" },
        .{ .key = "oauth_signature_method", .value = "HMAC-SHA1" },
        .{ .key = "oauth_timestamp", .value = "1700000000" },
        .{ .key = "oauth_version", .value = "1.0" },
    };

    const base = try signature_base_string(
        gpa,
        "GET",
        "https://connectapi.garmin.com/oauth-service/oauth/preauthorized",
        &params,
    );

    defer gpa.free(base);

    const expected =
        "GET&https%3A%2F%2Fconnectapi.garmin.com%2Foauth-service%2Foauth%2Fpreauthorized" ++
        "&accepts-mfa-tokens%3Dtrue" ++
        "%26login-url%3Dhttps%253A%252F%252Fmobile.integration.garmin.com%252Fgcm%252Fandroid" ++
        "%26oauth_consumer_key%3Dfc3e99d2-118c-44b8-8ae3-03370dde24c0" ++
        "%26oauth_nonce%3D0123456789abcdef0123456789abcdef" ++
        "%26oauth_signature_method%3DHMAC-SHA1" ++
        "%26oauth_timestamp%3D1700000000" ++
        "%26oauth_version%3D1.0" ++
        "%26ticket%3DST-0123-abcXYZ-cas";

    try std.testing.expectEqualStrings(expected, base);
}

test "signature base string rejects too many params" {
    const gpa = std.testing.allocator;

    var params: [params_max + 1]Param = undefined;

    for (&params) |*param| param.* = .{ .key = "k", .value = "v" };

    try std.testing.expectError(error.ParamCountExceeded, signature_base_string(
        gpa,
        "GET",
        "https://connectapi.garmin.com/oauth-service/oauth/preauthorized",
        &params,
    ));
}

test "authorization header embeds oracle signature" {
    const gpa = std.testing.allocator;

    const params = [_]Param{
        .{ .key = "ticket", .value = "ST-0123-abcXYZ-cas" },
        .{ .key = "login-url", .value = "https://mobile.integration.garmin.com/gcm/android" },
        .{ .key = "accepts-mfa-tokens", .value = "true" },
    };

    const header = try authorization_header(gpa, &.{
        .method = "GET",
        .base_url = "https://connectapi.garmin.com/oauth-service/oauth/preauthorized",
        .consumer_key = "fc3e99d2-118c-44b8-8ae3-03370dde24c0",
        .consumer_secret = "E08WAR897WEy2knn7aFBrvegVAf0AFdWBBF",
        .token = "",
        .token_secret = "",
        .nonce = "0123456789abcdef0123456789abcdef",
        .timestamp = "1700000000",
    }, &params);

    defer gpa.free(header);

    const signature_param = "oauth_signature=\"npjfRCOcKNSbw7%2BG%2BY3OSQBKfXU%3D\"";

    try std.testing.expect(std.mem.startsWith(u8, header, "OAuth "));
    try std.testing.expect(std.mem.indexOf(u8, header, signature_param) != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "oauth_token=") == null);
}

test "query decode handles escapes and malformed input" {
    const gpa = std.testing.allocator;

    const cases = [_]struct { input: []const u8, expected: []const u8 }{
        .{ .input = "a%3Db", .expected = "a=b" },
        .{ .input = "a+b", .expected = "a b" },
        .{ .input = "%4", .expected = "%4" },
        .{ .input = "%", .expected = "%" },
        .{ .input = "%zz", .expected = "%zz" },
    };

    for (cases) |case| {
        const decoded = try query_decode(gpa, case.input);
        defer gpa.free(decoded);

        try std.testing.expectEqualStrings(case.expected, decoded);
    }
}
