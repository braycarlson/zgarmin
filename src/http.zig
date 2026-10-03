const std = @import("std");

const Allocating = std.Io.Writer.Allocating;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

pub const Error = error{
    CookieCountExceeded,
    CookieLengthExceeded,
    HeaderCountExceeded,
    OutOfMemory,
    RedirectCountExceeded,
    RedirectLocationExceeded,
    RedirectLocationMissing,
    RedirectLocationUnsupported,
    RequestFailed,
    RetriesExceeded,
    UnsupportedContentEncoding,
};

pub const Client = struct {
    inner: std.http.Client,
    jar: CookieJar,
    gpa: Allocator,
    last_status: u16 = 0,

    pub fn init(gpa: Allocator, io: std.Io) Client {
        return .{
            .inner = .{ .allocator = gpa, .io = io },
            .jar = CookieJar.init(gpa),
            .gpa = gpa,
        };
    }

    pub fn deinit(client: *Client) void {
        client.jar.deinit();
        client.inner.deinit();
    }

    pub fn get(client: *Client, url: []const u8, user_agent: []const u8) Error!Response {
        return client.send(&.{
            .method = .GET,
            .url = url,
            .user_agent = user_agent,
            .retries = retries_get,
        });
    }

    pub fn send(client: *Client, request: *const Request) Error!Response {
        assert(request.url.len != 0);

        if (request.retries > retries_max) return Error.RetriesExceeded;
        if (request.extra_headers.len > extra_headers_max) return Error.HeaderCountExceeded;
        if (request.method != .GET) assert(request.retries == 0);

        const uri = std.Uri.parse(request.url) catch {
            return Error.RequestFailed;
        };

        const attempts_max: u32 = if (request.method == .GET) request.retries + 1 else 1;

        assert(attempts_max <= retries_max + 1);

        var attempt: u32 = 0;

        while (attempt < attempts_max) : (attempt += 1) {
            if (attempt != 0) {
                const delay = std.Io.Duration.fromMilliseconds(retry_delay_ms);

                std.Io.sleep(client.inner.io, delay, .awake) catch {
                    return Error.RequestFailed;
                };
            }

            return client.send_redirected(request, uri) catch |err| {
                const mapped = to_error(err);

                switch (mapped) {
                    Error.OutOfMemory,
                    Error.UnsupportedContentEncoding,
                    Error.RedirectCountExceeded,
                    Error.RedirectLocationMissing,
                    Error.RedirectLocationExceeded,
                    Error.RedirectLocationUnsupported,
                    => return mapped,
                    else => {
                        if (attempt + 1 == attempts_max) return mapped;

                        continue;
                    },
                }
            };
        }

        unreachable;
    }

    fn send_redirected(client: *Client, request: *const Request, uri_initial: std.Uri) !Response {
        var url_owned: ?[]u8 = null;
        defer if (url_owned) |value| client.gpa.free(value);

        const host_first = uri_host(uri_initial);

        var hop: Hop = .{
            .method = request.method,
            .uri = uri_initial,
            .authorization = request.authorization,
            .referer = request.referer,
            .content_type = request.content_type,
            .payload = request.payload,
        };

        var hop_index: u32 = 0;

        while (hop_index <= redirect_max) : (hop_index += 1) {
            var exchange = try client.send_once(request, &hop);

            if (!request.redirect or !status_is_redirect(exchange.response.status)) {
                if (exchange.location) |value| client.gpa.free(value);

                return exchange.response;
            }

            const status = exchange.response.status;

            exchange.response.deinit();

            const location = exchange.location orelse return error.RedirectLocationMissing;
            defer client.gpa.free(location);

            const url_next = try url_from_location(client.gpa, hop.uri, location);

            if (url_owned) |value| client.gpa.free(value);
            url_owned = url_next;

            hop.uri = try std.Uri.parse(url_next);

            if (redirect_rewrites_to_get(status, hop.method)) {
                hop.method = .GET;
                hop.content_type = null;
                hop.payload = null;
            }

            const same_host = std.ascii.eqlIgnoreCase(uri_host(hop.uri), host_first);

            if (!same_host) {
                hop.authorization = null;
                hop.referer = null;
            }
        }

        return error.RedirectCountExceeded;
    }

    fn send_once(client: *Client, request: *const Request, hop: *const Hop) !Exchange {
        assert(request.extra_headers.len <= extra_headers_max);

        var headers: std.http.Client.Request.Headers = .{
            .user_agent = .{ .override = request.user_agent },
        };

        if (hop.content_type) |value| headers.content_type = .{ .override = value };
        if (hop.authorization) |value| headers.authorization = .{ .override = value };

        const cookie_header = try client.jar.header();
        defer if (cookie_header) |value| client.gpa.free(value);

        var header_buffer: [extra_headers_max + headers_internal_max]std.http.Header = undefined;
        const header_count = send_once_headers(request, hop, cookie_header, &header_buffer);

        var inner = try client.inner.request(hop.method, hop.uri, .{
            .redirect_behavior = .unhandled,
            .headers = headers,
            .extra_headers = header_buffer[0..header_count],
        });

        defer inner.deinit();

        if (hop.payload) |payload| {
            inner.transfer_encoding = .{ .content_length = payload.len };

            var body = try inner.sendBodyUnflushed(&.{});

            try body.writer.writeAll(payload);
            try body.end();
            try inner.connection.?.flush();
        } else {
            try inner.sendBodiless();
        }

        return client.send_once_body(&inner, host_is_garmin(hop.uri));
    }

    fn send_once_headers(
        request: *const Request,
        hop: *const Hop,
        cookie_header: ?[]const u8,
        buffer: *[extra_headers_max + headers_internal_max]std.http.Header,
    ) usize {
        var count: usize = 0;

        if (host_is_garmin(hop.uri)) {
            if (cookie_header) |value| {
                buffer[count] = .{ .name = "cookie", .value = value };
                count += 1;
            }
        }

        if (hop.referer) |value| {
            buffer[count] = .{ .name = "referer", .value = value };
            count += 1;
        }

        for (request.extra_headers) |extra| {
            assert(count < extra_headers_max + headers_internal_max);

            buffer[count] = extra;
            count += 1;
        }

        assert(count <= extra_headers_max + headers_internal_max);

        return count;
    }

    fn send_once_body(
        client: *Client,
        inner: *std.http.Client.Request,
        host_trusted: bool,
    ) !Exchange {
        var redirect_buffer: [redirect_buffer_len]u8 = undefined;
        var response = try inner.receiveHead(&redirect_buffer);

        if (host_trusted) {
            var iterator = response.head.iterateHeaders();

            while (iterator.next()) |field| {
                if (std.ascii.eqlIgnoreCase(field.name, "set-cookie")) {
                    try client.jar.store_set_cookie(field.value);
                }
            }
        }

        const status = @backingInt(response.head.status);

        client.last_status = status;

        var location: ?[]u8 = null;
        errdefer if (location) |value| client.gpa.free(value);

        if (status_is_redirect(status)) {
            if (response.head.location) |value| {
                if (value.len > location_len_max) return error.RedirectLocationExceeded;
                if (value.len != 0) location = try client.gpa.dupe(u8, value);
            }
        }

        const decompress_buffer: []u8 = switch (response.head.content_encoding) {
            .identity => &.{},
            .gzip, .deflate => try client.gpa.alloc(u8, std.compress.flate.max_window_len),
            .zstd => try client.gpa.alloc(u8, std.compress.zstd.default_window_len),
            .compress => return error.UnsupportedContentEncoding,
        };

        defer if (decompress_buffer.len != 0) client.gpa.free(decompress_buffer);

        var transfer_buffer: [transfer_buffer_len]u8 = undefined;
        var decompress: std.http.Decompress = undefined;

        const reader = response.readerDecompressing(
            &transfer_buffer,
            &decompress,
            decompress_buffer,
        );

        const body = try reader.allocRemaining(client.gpa, .limited(body_len_max));

        return .{
            .response = .{
                .status = status,
                .body = body,
                .gpa = client.gpa,
            },
            .location = location,
        };
    }
};

const Cookie = struct {
    name: []u8,
    value: []u8,
};

pub const CookieJar = struct {
    cookies: [cookies_max]Cookie,
    count: u32,
    gpa: Allocator,

    pub fn init(gpa: Allocator) CookieJar {
        return .{
            .cookies = undefined,
            .count = 0,
            .gpa = gpa,
        };
    }

    pub fn deinit(jar: *CookieJar) void {
        assert(jar.count <= cookies_max);

        for (jar.cookies[0..jar.count]) |cookie| {
            jar.gpa.free(cookie.name);
            jar.gpa.free(cookie.value);
        }
    }

    pub fn store_set_cookie(jar: *CookieJar, raw: []const u8) Error!void {
        const end = std.mem.findScalar(u8, raw, ';') orelse raw.len;
        const pair = std.mem.trim(u8, raw[0..end], " ");

        const equals = std.mem.findScalar(u8, pair, '=') orelse return;
        const name = std.mem.trim(u8, pair[0..equals], " ");
        const value = std.mem.trim(u8, pair[equals + 1 ..], " ");

        if (name.len == 0) return;

        try jar.set(name, value);
    }

    pub fn set(jar: *CookieJar, name: []const u8, value: []const u8) Error!void {
        assert(name.len != 0);
        defer assert(jar.count <= cookies_max);

        if (name.len > cookie_len_max) return Error.CookieLengthExceeded;
        if (value.len > cookie_len_max) return Error.CookieLengthExceeded;

        for (jar.cookies[0..jar.count]) |*cookie| {
            if (std.mem.eql(u8, cookie.name, name)) {
                const replacement = try jar.gpa.dupe(u8, value);

                jar.gpa.free(cookie.value);
                cookie.value = replacement;

                return;
            }
        }

        if (jar.count >= cookies_max) return Error.CookieCountExceeded;

        const name_owned = try jar.gpa.dupe(u8, name);
        errdefer jar.gpa.free(name_owned);

        const value_owned = try jar.gpa.dupe(u8, value);

        jar.cookies[jar.count] = .{ .name = name_owned, .value = value_owned };
        jar.count += 1;
    }

    pub fn header(jar: *CookieJar) Error!?[]u8 {
        assert(jar.count <= cookies_max);

        if (jar.count == 0) return null;

        var writer: Allocating = .init(jar.gpa);
        errdefer writer.deinit();

        for (jar.cookies[0..jar.count], 0..) |cookie, index| {
            append(&writer, cookie.name, cookie.value, index != 0) catch {
                return Error.OutOfMemory;
            };
        }

        return writer.toOwnedSlice() catch {
            return Error.OutOfMemory;
        };
    }
};

pub const Response = struct {
    status: u16,
    body: []u8,
    gpa: Allocator,

    pub fn deinit(response: *Response) void {
        response.gpa.free(response.body);
    }
};

pub const Request = struct {
    method: std.http.Method = .GET,
    url: []const u8,
    user_agent: []const u8,
    content_type: ?[]const u8 = null,
    authorization: ?[]const u8 = null,
    referer: ?[]const u8 = null,
    payload: ?[]const u8 = null,
    extra_headers: []const std.http.Header = &.{},
    redirect: bool = true,
    retries: u32 = 0,
};

const Hop = struct {
    method: std.http.Method,
    uri: std.Uri,
    authorization: ?[]const u8,
    referer: ?[]const u8,
    content_type: ?[]const u8,
    payload: ?[]const u8,
};

const Exchange = struct {
    response: Response,
    location: ?[]u8,
};

pub const user_agent_android: []const u8 = "com.garmin.android.apps.connectmobile";
pub const user_agent_browser: []const u8 =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 " ++
    "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

pub const body_len_max: u32 = 8 * 1024 * 1024;
pub const cookies_max: u32 = 64;
pub const cookie_len_max: u32 = 4096;
pub const extra_headers_max: u32 = 16;
pub const headers_internal_max: u32 = 2;
pub const location_len_max: u32 = 2048;
pub const redirect_max: u32 = 5;
pub const redirect_buffer_len: u32 = 16 * 1024;
pub const transfer_buffer_len: u32 = 4096;
pub const retries_get: u32 = 2;
pub const retries_max: u32 = 8;
pub const retry_delay_ms: i64 = 250;

pub fn host_is_garmin(uri: std.Uri) bool {
    const host = uri_host(uri);

    if (std.mem.eql(u8, host, "garmin.com")) return true;
    return std.mem.endsWith(u8, host, ".garmin.com");
}

pub fn status_is_redirect(status: u16) bool {
    return switch (status) {
        301, 302, 303, 307, 308 => true,
        else => false,
    };
}

pub fn redirect_rewrites_to_get(status: u16, method: std.http.Method) bool {
    return switch (status) {
        303 => method != .HEAD,
        301, 302 => method == .POST,
        else => false,
    };
}

pub fn url_from_location(gpa: Allocator, uri: std.Uri, location: []const u8) Error![]u8 {
    assert(location.len != 0);
    assert(location.len <= location_len_max);

    if (std.mem.startsWith(u8, location, "https://")) return gpa.dupe(u8, location);
    if (std.mem.startsWith(u8, location, "http://")) return gpa.dupe(u8, location);

    if (std.mem.startsWith(u8, location, "//")) {
        return gpa.print("{s}:{s}", .{ uri.scheme, location });
    }

    if (location[0] == '/') {
        const host = uri_host(uri);

        assert(host.len != 0);

        return gpa.print("{s}://{s}{s}", .{ uri.scheme, host, location });
    }

    return Error.RedirectLocationUnsupported;
}

fn append(
    writer: *Allocating,
    name: []const u8,
    value: []const u8,
    separate: bool,
) std.Io.Writer.Error!void {
    if (separate) try writer.writer.writeAll("; ");

    try writer.writer.writeAll(name);
    try writer.writer.writeByte('=');
    try writer.writer.writeAll(value);
}

fn to_error(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => Error.OutOfMemory,
        error.RedirectCountExceeded => Error.RedirectCountExceeded,
        error.RedirectLocationExceeded => Error.RedirectLocationExceeded,
        error.RedirectLocationMissing => Error.RedirectLocationMissing,
        error.RedirectLocationUnsupported => Error.RedirectLocationUnsupported,
        error.UnsupportedContentEncoding => Error.UnsupportedContentEncoding,
        else => Error.RequestFailed,
    };
}

fn uri_host(uri: std.Uri) []const u8 {
    const component = uri.host orelse return "";

    return switch (component) {
        .raw => |raw| raw,
        .percent_encoded => |encoded| encoded,
    };
}

test "CookieJar.set replaces an existing cookie without leaking" {
    const gpa = std.testing.allocator;

    var jar = CookieJar.init(gpa);
    defer jar.deinit();

    try jar.set("session", "one");
    try jar.set("session", "two");

    const header = try jar.header();
    defer if (header) |value| gpa.free(value);

    try std.testing.expectEqualStrings("session=two", header.?);
}

test "CookieJar.set returns CookieCountExceeded past the cap" {
    const gpa = std.testing.allocator;

    var jar = CookieJar.init(gpa);
    defer jar.deinit();

    var buffer: [32]u8 = undefined;
    var index: u32 = 0;

    while (index < cookies_max) : (index += 1) {
        const name = try std.mem.print(&buffer, "cookie{d}", .{index});

        try jar.set(name, "value");
    }

    try std.testing.expectError(error.CookieCountExceeded, jar.set("overflow", "value"));

    try jar.set("cookie0", "updated");
}

test "CookieJar.set rejects oversized name or value" {
    const gpa = std.testing.allocator;

    var jar = CookieJar.init(gpa);
    defer jar.deinit();

    const big = try gpa.alloc(u8, cookie_len_max + 1);
    defer gpa.free(big);

    @memset(big, 'x');

    try std.testing.expectError(error.CookieLengthExceeded, jar.set("name", big));
    try std.testing.expectError(error.CookieLengthExceeded, jar.set(big, "value"));
}

test "CookieJar.store_set_cookie parses attributes and rejects malformed pairs" {
    const gpa = std.testing.allocator;

    var jar = CookieJar.init(gpa);
    defer jar.deinit();

    try jar.store_set_cookie("a=b; Path=/; HttpOnly");
    try jar.store_set_cookie("a=");
    try jar.store_set_cookie("=b");
    try jar.store_set_cookie("junk");

    const header = try jar.header();
    defer if (header) |value| gpa.free(value);

    try std.testing.expectEqualStrings("a=", header.?);
}

test "CookieJar.header orders insertions and returns null when empty" {
    const gpa = std.testing.allocator;

    var jar = CookieJar.init(gpa);
    defer jar.deinit();

    try std.testing.expect((try jar.header()) == null);

    try jar.set("first", "1");
    try jar.set("second", "2");
    try jar.set("third", "3");

    const header = try jar.header();
    defer if (header) |value| gpa.free(value);

    try std.testing.expectEqualStrings("first=1; second=2; third=3", header.?);
}

test "status_is_redirect matches the redirect status set" {
    const redirects = [_]u16{ 301, 302, 303, 307, 308 };
    const passthroughs = [_]u16{ 200, 204, 304, 400, 401, 404, 500 };

    for (redirects) |status| try std.testing.expect(status_is_redirect(status));
    for (passthroughs) |status| try std.testing.expect(!status_is_redirect(status));
}

test "redirect_rewrites_to_get downgrades 303 and legacy 301/302 posts" {
    try std.testing.expect(redirect_rewrites_to_get(303, .POST));
    try std.testing.expect(redirect_rewrites_to_get(303, .GET));
    try std.testing.expect(!redirect_rewrites_to_get(303, .HEAD));
    try std.testing.expect(redirect_rewrites_to_get(301, .POST));
    try std.testing.expect(redirect_rewrites_to_get(302, .POST));
    try std.testing.expect(!redirect_rewrites_to_get(301, .GET));
    try std.testing.expect(!redirect_rewrites_to_get(307, .POST));
    try std.testing.expect(!redirect_rewrites_to_get(308, .POST));
}

test "url_from_location resolves absolute, path, and scheme-relative targets" {
    const gpa = std.testing.allocator;
    const uri = try std.Uri.parse("https://sso.garmin.com/sso/signin");

    const cases = [_]struct { location: []const u8, expected: []const u8 }{
        .{
            .location = "https://other.example/next",
            .expected = "https://other.example/next",
        },
        .{
            .location = "http://other.example/next",
            .expected = "http://other.example/next",
        },
        .{
            .location = "/sso/verify",
            .expected = "https://sso.garmin.com/sso/verify",
        },
        .{
            .location = "//connect.garmin.com/modern",
            .expected = "https://connect.garmin.com/modern",
        },
    };

    for (cases) |case| {
        const url = try url_from_location(gpa, uri, case.location);
        defer gpa.free(url);

        try std.testing.expectEqualStrings(case.expected, url);
    }
}

test "url_from_location rejects a relative path" {
    const gpa = std.testing.allocator;
    const uri = try std.Uri.parse("https://sso.garmin.com/sso/signin");

    try std.testing.expectError(
        error.RedirectLocationUnsupported,
        url_from_location(gpa, uri, "verify"),
    );
}

test "host_is_garmin accepts garmin.com and its subdomains only" {
    const garmin = [_][]const u8{
        "https://garmin.com/",
        "https://sso.garmin.com/sso",
        "https://connectapi.garmin.com/x",
    };

    const foreign = [_][]const u8{
        "https://example.com/",
        "https://notgarmin.com/",
        "https://garmin.com.evil.example/",
    };

    for (garmin) |url| try std.testing.expect(host_is_garmin(try std.Uri.parse(url)));
    for (foreign) |url| try std.testing.expect(!host_is_garmin(try std.Uri.parse(url)));
}
