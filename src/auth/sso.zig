const std = @import("std");

const html = @import("html.zig");
const http = @import("../http.zig");
const oauth1 = @import("oauth1.zig");
const oauth2 = @import("oauth2.zig");
const Consumer = @import("consumer.zig").Consumer;

const Allocating = std.Io.Writer.Allocating;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

pub const Field = struct {
    name: []const u8,
    value: []const u8,
};

pub const Credentials = struct {
    email: []const u8,
    password: []const u8,
};

pub const MfaProvider = struct {
    context: ?*anyopaque = null,
    get_code: *const fn (context: ?*anyopaque, buffer: []u8) anyerror![]const u8,
};

pub const Tokens = struct {
    oauth1: oauth1.OAuth1Token,
    oauth2: oauth2.OAuth2Token,

    pub fn deinit(tokens: *Tokens) void {
        tokens.oauth1.deinit();
        tokens.oauth2.deinit();
    }
};

pub const Outcome = union(enum) {
    granted: []const u8,
    challenged,
    refused,
};

pub const service_root: []const u8 = "https://sso.garmin.com/sso";
pub const widget_root: []const u8 = service_root ++ "/embed";

pub const form_media_type: []const u8 = "application/x-www-form-urlencoded";
pub const code_len_max: u32 = 64;
pub const form_fields_max: u32 = 8;

pub const field_code: []const u8 = "mfa-code";
pub const field_csrf: []const u8 = "_csrf";
pub const field_password: []const u8 = "password";
pub const field_username: []const u8 = "username";

const widget_fields = [_]Field{
    .{ .name = "embedWidget", .value = "true" },
    .{ .name = "gauthHost", .value = service_root },
    .{ .name = "id", .value = "gauth-widget" },
};

const signin_fields = [_]Field{
    .{ .name = "service", .value = widget_root },
    .{ .name = "source", .value = widget_root },
    .{ .name = "gauthHost", .value = widget_root },
    .{ .name = "redirectAfterAccountCreationUrl", .value = widget_root },
    .{ .name = "redirectAfterAccountLoginUrl", .value = widget_root },
    .{ .name = "embedWidget", .value = "true" },
    .{ .name = "id", .value = "gauth-widget" },
};

pub const widget_url: []const u8 = widget_root ++ "?" ++ query_of(&widget_fields);
pub const signin_url: []const u8 = service_root ++ "/signin?" ++ query_of(&signin_fields);
pub const verify_url: []const u8 =
    service_root ++ "/verifyMFA/loginEnterMfaCode?" ++ query_of(&signin_fields);

comptime {
    assert(signin_fields.len <= form_fields_max);
}

pub fn login(
    gpa: Allocator,
    io: std.Io,
    client: *http.Client,
    consumer: *const Consumer,
    credentials: *const Credentials,
    mfa: ?MfaProvider,
) !Tokens {
    if (credentials.email.len == 0) return error.CredentialsInvalid;
    if (credentials.password.len == 0) return error.CredentialsInvalid;

    assert(consumer.key.len != 0);
    assert(consumer.secret.len != 0);

    const ticket = try obtain_ticket(client, gpa, credentials, mfa);
    defer gpa.free(ticket);

    assert(ticket.len != 0);

    var token_oauth1 = try oauth1.get_oauth1_token(gpa, io, client, consumer, ticket);
    errdefer token_oauth1.deinit();

    const token_oauth2 = try oauth2.exchange(gpa, io, client, consumer, &token_oauth1);

    return .{
        .oauth1 = token_oauth1,
        .oauth2 = token_oauth2,
    };
}

fn obtain_ticket(
    client: *http.Client,
    gpa: Allocator,
    credentials: *const Credentials,
    mfa: ?MfaProvider,
) ![]u8 {
    try open_widget(client);

    var signin = try open_signin(client);
    defer signin.deinit();

    const csrf = html.field_value(signin.body, field_csrf) orelse return error.CsrfTokenMissing;

    var submitted = try post_form(client, gpa, signin_url, &.{
        .{ .name = field_csrf, .value = csrf },
        .{ .name = "embed", .value = "true" },
        .{ .name = field_username, .value = credentials.email },
        .{ .name = field_password, .value = credentials.password },
    });

    defer submitted.deinit();

    if (submitted.status != 200) return error.LoginFailed;

    return switch (classify(submitted.body)) {
        .granted => |ticket| gpa.dupe(u8, ticket),
        .challenged => answer_challenge(client, gpa, submitted.body, mfa),
        .refused => error.LoginRejected,
    };
}

fn answer_challenge(
    client: *http.Client,
    gpa: Allocator,
    challenge: []const u8,
    mfa: ?MfaProvider,
) ![]u8 {
    const provider = mfa orelse return error.MfaRequired;
    const csrf = html.field_value(challenge, field_csrf) orelse return error.CsrfTokenMissing;

    var buffer: [code_len_max]u8 = undefined;
    const code = try read_code(provider, &buffer);

    var verified = try post_form(client, gpa, verify_url, &.{
        .{ .name = field_csrf, .value = csrf },
        .{ .name = "fromPage", .value = "setupEnterMfaCode" },
        .{ .name = "embed", .value = "true" },
        .{ .name = field_code, .value = code },
    });

    defer verified.deinit();

    if (verified.status != 200) return error.MfaVerifyFailed;

    return switch (classify(verified.body)) {
        .granted => |ticket| gpa.dupe(u8, ticket),
        .challenged => error.MfaCodeRejected,
        .refused => error.LoginRejected,
    };
}

fn open_widget(client: *http.Client) !void {
    var response = try client.send(&.{
        .method = .GET,
        .url = widget_url,
        .user_agent = http.user_agent_browser,
        .retries = http.retries_get,
    });

    defer response.deinit();

    if (response.status != 200) return error.WidgetUnavailable;
}

fn open_signin(client: *http.Client) !http.Response {
    var response = try client.send(&.{
        .method = .GET,
        .url = signin_url,
        .user_agent = http.user_agent_browser,
        .referer = widget_root,
        .retries = http.retries_get,
    });

    errdefer response.deinit();

    if (response.status != 200) return error.SigninPageUnavailable;

    return response;
}

fn post_form(
    client: *http.Client,
    gpa: Allocator,
    url: []const u8,
    fields: []const Field,
) !http.Response {
    assert(url.len != 0);
    assert(fields.len != 0);

    var body: Allocating = .init(gpa);
    defer body.deinit();

    try write_form(&body.writer, fields);

    return client.send(&.{
        .method = .POST,
        .url = url,
        .user_agent = http.user_agent_browser,
        .content_type = form_media_type,
        .referer = signin_url,
        .payload = body.written(),
    });
}

fn write_form(out: *std.Io.Writer, fields: []const Field) !void {
    assert(fields.len != 0);
    assert(fields.len <= form_fields_max);

    for (fields, 0..) |field, index| {
        assert(field.name.len != 0);

        if (index != 0) try out.writeByte('&');

        try out.writeAll(field.name);
        try out.writeByte('=');
        try oauth1.percent_encode(out, field.value);
    }
}

fn read_code(provider: MfaProvider, buffer: *[code_len_max]u8) ![]const u8 {
    const supplied = try provider.get_code(provider.context, buffer);
    const code = std.mem.trim(u8, supplied, " \t\r\n");

    if (code.len == 0) return error.MfaCodeEmpty;
    if (code.len > code_len_max) return error.MfaCodeTooLong;

    return code;
}

pub fn classify(document: []const u8) Outcome {
    if (html.service_ticket(document)) |ticket| {
        assert(ticket.len != 0);

        return .{ .granted = ticket };
    }

    if (html.field_present(document, field_code)) return .challenged;

    return .refused;
}

fn query_of(comptime fields: []const Field) []const u8 {
    comptime {
        var query: []const u8 = "";

        for (fields, 0..) |field, index| {
            if (index != 0) query = query ++ "&";

            query = query ++ field.name ++ "=" ++ field.value;
        }

        return query;
    }
}

test "classify treats a ticket as the success signal" {
    const document =
        \\<html><head><title>Anything At All</title></head><body>
        \\<script>response_url = "https://sso.garmin.com/sso/embed?ticket=ST-42-abc";</script>
        \\</body></html>
    ;

    switch (classify(document)) {
        .granted => |ticket| try std.testing.expectEqualStrings("ST-42-abc", ticket),
        .challenged, .refused => return error.TestUnexpectedOutcome,
    }
}

test "classify detects the mfa form" {
    const document =
        \\<form action="/sso/verifyMFA/loginEnterMfaCode" method="post">
        \\  <input type="hidden" name="_csrf" value="csrf-value">
        \\  <input type="text" name="mfa-code" maxlength="6">
        \\</form>
    ;

    try std.testing.expectEqual(.challenged, std.meta.activeTag(classify(document)));
}

test "classify refuses a page with neither ticket nor challenge" {
    const document = "<html><body><p>Invalid username or password.</p></body></html>";

    try std.testing.expectEqual(.refused, std.meta.activeTag(classify(document)));
}

test "classify prefers the ticket over a lingering mfa form" {
    const document =
        \\<input name="mfa-code">
        \\<script>response_url = "https://sso.garmin.com/sso/embed?ticket=ST-7-zzz";</script>
    ;

    switch (classify(document)) {
        .granted => |ticket| try std.testing.expectEqualStrings("ST-7-zzz", ticket),
        .challenged, .refused => return error.TestUnexpectedOutcome,
    }
}

test "sso urls carry the parameters garmin requires" {
    const required = [_][]const u8{
        "embedWidget=true",
        "gauthHost=",
        "id=gauth-widget",
        "service=",
        "source=",
        "redirectAfterAccountLoginUrl=",
        "redirectAfterAccountCreationUrl=",
    };

    for (required) |parameter| {
        try std.testing.expect(std.mem.indexOf(u8, signin_url, parameter) != null);
    }

    try std.testing.expect(std.mem.startsWith(u8, signin_url, service_root));
    try std.testing.expect(std.mem.startsWith(u8, widget_url, widget_root));
    try std.testing.expect(std.mem.indexOf(u8, verify_url, "loginEnterMfaCode") != null);
}
