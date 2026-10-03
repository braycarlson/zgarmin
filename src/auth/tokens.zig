const std = @import("std");

const oauth1 = @import("oauth1.zig");
const oauth2 = @import("oauth2.zig");
const Consumer = @import("consumer.zig").Consumer;

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const ConsumerRecord = struct {
    key: []const u8,
    secret: []const u8,
};

const OAuth1Record = struct {
    token: []const u8,
    secret: []const u8,
    mfa: ?[]const u8 = null,
};

const OAuth2Record = struct {
    access: []const u8,
    refresh: []const u8,
    obtained_at: i64,
    lifetime_seconds: i64,
    refresh_lifetime_seconds: i64,
};

const ProfileRecord = struct {
    display_name: []const u8,
};

const Document = struct {
    format: u32,
    consumer: ConsumerRecord,
    oauth1: OAuth1Record,
    oauth2: OAuth2Record,
    profile: ProfileRecord,
};

pub const Stored = struct {
    consumer: *const Consumer,
    oauth1_token: *const oauth1.OAuth1Token,
    oauth2_token: *const oauth2.OAuth2Token,
    display_name: []const u8,
};

pub const Loaded = struct {
    consumer: Consumer,
    oauth1_token: oauth1.OAuth1Token,
    oauth2_token: oauth2.OAuth2Token,
    display_name: []u8,
    gpa: Allocator,

    pub fn deinit(loaded: *Loaded) void {
        loaded.consumer.deinit();
        loaded.oauth1_token.deinit();
        loaded.oauth2_token.deinit();
        loaded.gpa.free(loaded.display_name);
    }
};

pub const TokenError = error{
    OutOfMemory,
    ReadFailed,
    TokenFileInvalid,
    TokenFileVersionUnknown,
    WriteFailed,
};

pub const file_len_max: u32 = 64 * 1024;
pub const format_version: u32 = 2;
pub const suffix_partial: []const u8 = ".partial";

const obtained_at_fixture: i64 = 1_700_000_000;

pub fn save(
    gpa: Allocator,
    io: std.Io,
    directory: std.Io.Dir,
    path: []const u8,
    stored: *const Stored,
) TokenError!void {
    assert(path.len != 0);
    assert(stored.consumer.key.len != 0);
    assert(stored.oauth1_token.oauth_token.len != 0);
    assert(stored.oauth2_token.access_token.len != 0);
    assert(stored.oauth2_token.obtained_at > 0);
    assert(stored.display_name.len != 0);

    const document = document_of(stored);

    const json = std.json.Stringify.valueAlloc(gpa, document, .{}) catch {
        return TokenError.OutOfMemory;
    };

    defer gpa.free(json);

    const path_partial = gpa.print("{s}{s}", .{ path, suffix_partial }) catch {
        return TokenError.OutOfMemory;
    };

    defer gpa.free(path_partial);

    directory.writeFile(io, .{ .sub_path = path_partial, .data = json }) catch {
        return TokenError.WriteFailed;
    };

    directory.rename(path_partial, directory, path, io) catch {
        return TokenError.WriteFailed;
    };
}

fn document_of(stored: *const Stored) Document {
    return .{
        .format = format_version,
        .consumer = .{
            .key = stored.consumer.key,
            .secret = stored.consumer.secret,
        },
        .oauth1 = .{
            .token = stored.oauth1_token.oauth_token,
            .secret = stored.oauth1_token.oauth_token_secret,
            .mfa = stored.oauth1_token.mfa_token,
        },
        .oauth2 = .{
            .access = stored.oauth2_token.access_token,
            .refresh = stored.oauth2_token.refresh_token,
            .obtained_at = stored.oauth2_token.obtained_at,
            .lifetime_seconds = stored.oauth2_token.lifetime_seconds,
            .refresh_lifetime_seconds = stored.oauth2_token.refresh_lifetime_seconds,
        },
        .profile = .{ .display_name = stored.display_name },
    };
}

pub fn load(
    gpa: Allocator,
    io: std.Io,
    directory: std.Io.Dir,
    path: []const u8,
) TokenError!?Loaded {
    assert(path.len != 0);

    const limit: std.Io.Limit = .limited(file_len_max);

    const bytes = directory.readFileAlloc(io, path, gpa, limit) catch |err| switch (err) {
        error.FileNotFound => return null,
        error.OutOfMemory => return TokenError.OutOfMemory,
        else => return TokenError.ReadFailed,
    };

    defer gpa.free(bytes);

    const parsed = std.json.parseFromSlice(Document, gpa, bytes, .{
        .ignore_unknown_fields = true,
    }) catch |err| switch (err) {
        error.OutOfMemory => return TokenError.OutOfMemory,
        else => return TokenError.TokenFileInvalid,
    };

    defer parsed.deinit();

    try check_document(&parsed.value);

    return try adopt_document(gpa, &parsed.value);
}

fn check_document(document: *const Document) TokenError!void {
    if (document.format != format_version) return TokenError.TokenFileVersionUnknown;
    if (document.oauth2.obtained_at <= 0) return TokenError.TokenFileInvalid;
    if (document.oauth2.lifetime_seconds <= 0) return TokenError.TokenFileInvalid;
    if (document.oauth2.refresh_lifetime_seconds < 0) return TokenError.TokenFileInvalid;

    if (document.oauth2.lifetime_seconds > oauth2.lifetime_seconds_max) {
        return TokenError.TokenFileInvalid;
    }
}

fn adopt_document(gpa: Allocator, document: *const Document) TokenError!Loaded {
    const consumer_key = try adopt_text(gpa, document.consumer.key);
    errdefer gpa.free(consumer_key);

    const consumer_secret = try adopt_text(gpa, document.consumer.secret);
    errdefer gpa.free(consumer_secret);

    const oauth1_token = try adopt_text(gpa, document.oauth1.token);
    errdefer gpa.free(oauth1_token);

    const oauth1_secret = try adopt_text(gpa, document.oauth1.secret);
    errdefer gpa.free(oauth1_secret);

    const mfa_token: ?[]u8 = if (document.oauth1.mfa) |mfa|
        if (mfa.len != 0) gpa.dupe(u8, mfa) catch return TokenError.OutOfMemory else null
    else
        null;

    errdefer if (mfa_token) |value| gpa.free(value);

    const access_token = try adopt_text(gpa, document.oauth2.access);
    errdefer gpa.free(access_token);

    const refresh_token = try adopt_text(gpa, document.oauth2.refresh);
    errdefer gpa.free(refresh_token);

    const display_name = try adopt_text(gpa, document.profile.display_name);

    return .{
        .consumer = .{
            .key = consumer_key,
            .secret = consumer_secret,
            .gpa = gpa,
        },
        .oauth1_token = .{
            .oauth_token = oauth1_token,
            .oauth_token_secret = oauth1_secret,
            .mfa_token = mfa_token,
            .gpa = gpa,
        },
        .oauth2_token = .{
            .access_token = access_token,
            .refresh_token = refresh_token,
            .obtained_at = document.oauth2.obtained_at,
            .lifetime_seconds = document.oauth2.lifetime_seconds,
            .refresh_lifetime_seconds = document.oauth2.refresh_lifetime_seconds,
            .gpa = gpa,
        },
        .display_name = display_name,
        .gpa = gpa,
    };
}

fn adopt_text(gpa: Allocator, value: []const u8) TokenError![]u8 {
    if (value.len == 0) return TokenError.TokenFileInvalid;

    return gpa.dupe(u8, value) catch {
        return TokenError.OutOfMemory;
    };
}

fn stored_fixture(gpa: Allocator) !Loaded {
    return .{
        .consumer = .{
            .key = try gpa.dupe(u8, "consumer-key"),
            .secret = try gpa.dupe(u8, "consumer-secret"),
            .gpa = gpa,
        },
        .oauth1_token = .{
            .oauth_token = try gpa.dupe(u8, "oauth-token"),
            .oauth_token_secret = try gpa.dupe(u8, "oauth-token-secret"),
            .mfa_token = try gpa.dupe(u8, "mfa-token"),
            .gpa = gpa,
        },
        .oauth2_token = .{
            .access_token = try gpa.dupe(u8, "access-token"),
            .refresh_token = try gpa.dupe(u8, "refresh-token"),
            .obtained_at = obtained_at_fixture,
            .lifetime_seconds = 3600,
            .refresh_lifetime_seconds = 7200,
            .gpa = gpa,
        },
        .display_name = try gpa.dupe(u8, "athlete"),
        .gpa = gpa,
    };
}

fn write_document(io: std.Io, directory: std.Io.Dir, bytes: []const u8) !void {
    try directory.writeFile(io, .{ .sub_path = "tokens.json", .data = bytes });
}

test "tokens save and load roundtrip" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var fixture = try stored_fixture(gpa);
    defer fixture.deinit();

    try save(gpa, io, tmp.dir, "tokens.json", &.{
        .consumer = &fixture.consumer,
        .oauth1_token = &fixture.oauth1_token,
        .oauth2_token = &fixture.oauth2_token,
        .display_name = fixture.display_name,
    });

    var loaded = (try load(gpa, io, tmp.dir, "tokens.json")) orelse
        return error.TestTokenFileMissing;
    defer loaded.deinit();

    const oauth1_token = loaded.oauth1_token;
    const oauth2_token = loaded.oauth2_token;

    try std.testing.expectEqualStrings("consumer-key", loaded.consumer.key);
    try std.testing.expectEqualStrings("consumer-secret", loaded.consumer.secret);
    try std.testing.expectEqualStrings("oauth-token", oauth1_token.oauth_token);
    try std.testing.expectEqualStrings("oauth-token-secret", oauth1_token.oauth_token_secret);
    try std.testing.expectEqualStrings("mfa-token", oauth1_token.mfa_token.?);
    try std.testing.expectEqualStrings("access-token", oauth2_token.access_token);
    try std.testing.expectEqualStrings("refresh-token", oauth2_token.refresh_token);
    try std.testing.expectEqual(obtained_at_fixture, oauth2_token.obtained_at);
    try std.testing.expectEqual(@as(i64, 3600), oauth2_token.lifetime_seconds);
    try std.testing.expectEqualStrings("athlete", loaded.display_name);
}

test "deadlines derive from the recorded instant" {
    const gpa = std.testing.allocator;

    var fixture = try stored_fixture(gpa);
    defer fixture.deinit();

    const token = &fixture.oauth2_token;

    try std.testing.expectEqual(obtained_at_fixture + 3600, token.expires_at());
    try std.testing.expectEqual(obtained_at_fixture + 7200, token.refresh_expires_at());

    const authorization = try token.authorization(gpa);
    defer gpa.free(authorization);

    try std.testing.expectEqualStrings("Bearer access-token", authorization);
}

test "load returns null when the file is missing" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const loaded = try load(gpa, io, tmp.dir, "absent.json");

    try std.testing.expect(loaded == null);
}

test "load rejects an unknown format version" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const bytes =
        \\{"format":999,
        \\"consumer":{"key":"k","secret":"s"},
        \\"oauth1":{"token":"t","secret":"ts","mfa":null},
        \\"oauth2":{"access":"a","refresh":"r","obtained_at":1,
        \\"lifetime_seconds":1,"refresh_lifetime_seconds":1},
        \\"profile":{"display_name":"d"}}
    ;

    try write_document(io, tmp.dir, bytes);

    try std.testing.expectError(
        error.TokenFileVersionUnknown,
        load(gpa, io, tmp.dir, "tokens.json"),
    );
}

test "load rejects empty required fields" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const bytes =
        \\{"format":2,
        \\"consumer":{"key":"","secret":"s"},
        \\"oauth1":{"token":"t","secret":"ts","mfa":null},
        \\"oauth2":{"access":"a","refresh":"r","obtained_at":1,
        \\"lifetime_seconds":1,"refresh_lifetime_seconds":1},
        \\"profile":{"display_name":"d"}}
    ;

    try write_document(io, tmp.dir, bytes);

    try std.testing.expectError(
        error.TokenFileInvalid,
        load(gpa, io, tmp.dir, "tokens.json"),
    );
}

test "load rejects a non-positive lifetime" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const bytes =
        \\{"format":2,
        \\"consumer":{"key":"k","secret":"s"},
        \\"oauth1":{"token":"t","secret":"ts","mfa":null},
        \\"oauth2":{"access":"a","refresh":"r","obtained_at":1,
        \\"lifetime_seconds":0,"refresh_lifetime_seconds":1},
        \\"profile":{"display_name":"d"}}
    ;

    try write_document(io, tmp.dir, bytes);

    try std.testing.expectError(
        error.TokenFileInvalid,
        load(gpa, io, tmp.dir, "tokens.json"),
    );
}

test "load rejects a malformed document" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try write_document(io, tmp.dir, "{ not json");

    try std.testing.expectError(
        error.TokenFileInvalid,
        load(gpa, io, tmp.dir, "tokens.json"),
    );
}
