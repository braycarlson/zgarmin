const Connect = @This();

const std = @import("std");

const http = @import("../http.zig");
const oauth1 = @import("../auth/oauth1.zig");
const oauth2 = @import("../auth/oauth2.zig");
const Consumer = @import("../auth/consumer.zig").Consumer;
const Endpoint = @import("endpoints.zig").Endpoint;

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

gpa: Allocator,
io: std.Io,
http_client: *http.Client,
consumer: Consumer,
token_oauth1: oauth1.OAuth1Token,
token_oauth2: oauth2.OAuth2Token,
token_refreshed: bool = false,

pub const RequestOptions = struct {
    query: ?[]const u8 = null,
    content_type: ?[]const u8 = null,
    payload: ?[]const u8 = null,
};

pub const RequestError = http.Error || error{
    EndpointArgumentsInvalid,
    TokenRefreshFailed,
};

pub fn init(
    gpa: Allocator,
    io: std.Io,
    http_client: *http.Client,
    consumer: Consumer,
    token_oauth1: oauth1.OAuth1Token,
    token_oauth2: oauth2.OAuth2Token,
) Connect {
    assert(consumer.key.len != 0);
    assert(token_oauth1.oauth_token.len != 0);

    return .{
        .gpa = gpa,
        .io = io,
        .http_client = http_client,
        .consumer = consumer,
        .token_oauth1 = token_oauth1,
        .token_oauth2 = token_oauth2,
    };
}

pub fn deinit(connect: *Connect) void {
    connect.consumer.deinit();
    connect.token_oauth1.deinit();
    connect.token_oauth2.deinit();
}

pub fn get_endpoint(
    connect: *Connect,
    comptime endpoint: Endpoint,
    arguments: anytype,
    query: ?[]const u8,
) !http.Response {
    if (query) |value| assert(value.len != 0);

    const path = try endpoint.build(connect.gpa, arguments);
    defer connect.gpa.free(path);

    return connect.get(path, query);
}

pub fn get(connect: *Connect, path: []const u8, query: ?[]const u8) RequestError!http.Response {
    return connect.request(.GET, path, &.{ .query = query });
}

pub fn post_json(
    connect: *Connect,
    path: []const u8,
    query: ?[]const u8,
    json: []const u8,
) !http.Response {
    return connect.request(.POST, path, &.{
        .query = query,
        .content_type = "application/json",
        .payload = json,
    });
}

pub fn put_json(
    connect: *Connect,
    path: []const u8,
    query: ?[]const u8,
    json: []const u8,
) !http.Response {
    return connect.request(.PUT, path, &.{
        .query = query,
        .content_type = "application/json",
        .payload = json,
    });
}

pub fn delete(connect: *Connect, path: []const u8, query: ?[]const u8) RequestError!http.Response {
    return connect.request(.DELETE, path, &.{ .query = query });
}

pub fn request(
    connect: *Connect,
    method: std.http.Method,
    path: []const u8,
    options: *const RequestOptions,
) RequestError!http.Response {
    assert(path.len != 0);
    assert(path[0] == '/');

    const base = oauth1.connectapi_url;

    const url = build_url(connect.gpa, base, path, options.query) catch {
        return RequestError.OutOfMemory;
    };

    defer connect.gpa.free(url);

    return connect.authorized_request(method, url, options);
}

fn authorized_request(
    connect: *Connect,
    method: std.http.Method,
    url: []const u8,
    options: *const RequestOptions,
) RequestError!http.Response {
    var response = try connect.send_authorized(method, url, options);

    if (response.status != 401) return response;

    response.deinit();

    connect.refresh_token() catch {
        return RequestError.TokenRefreshFailed;
    };

    return connect.send_authorized(method, url, options);
}

fn send_authorized(
    connect: *Connect,
    method: std.http.Method,
    url: []const u8,
    options: *const RequestOptions,
) RequestError!http.Response {
    const authorization = connect.token_oauth2.authorization(connect.gpa) catch {
        return RequestError.OutOfMemory;
    };

    defer connect.gpa.free(authorization);

    return connect.http_client.send(&.{
        .method = method,
        .url = url,
        .user_agent = http.user_agent_android,
        .authorization = authorization,
        .content_type = options.content_type,
        .payload = options.payload,
        .retries = if (method == .GET) http.retries_get else 0,
        .redirect = method == .GET,
    });
}

fn build_url(
    gpa: std.mem.Allocator,
    base: []const u8,
    path: []const u8,
    query: ?[]const u8,
) ![]u8 {
    const value = query orelse {
        return std.fmt.allocPrint(gpa, "{s}{s}", .{ base, path });
    };

    return std.fmt.allocPrint(gpa, "{s}{s}?{s}", .{ base, path, value });
}

pub fn refresh_token(connect: *Connect) !void {
    const next = try oauth2.exchange(
        connect.gpa,
        connect.io,
        connect.http_client,
        &connect.consumer,
        &connect.token_oauth1,
    );

    connect.token_oauth2.deinit();
    connect.token_oauth2 = next;
    connect.token_refreshed = true;
}
