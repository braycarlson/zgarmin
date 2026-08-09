const std = @import("std");

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

pub const Env = struct {
    map: std.StringHashMapUnmanaged([]const u8),
    arena: std.heap.ArenaAllocator,

    pub fn deinit(env: *Env) void {
        env.arena.deinit();
    }

    pub fn get(env: *const Env, key: []const u8) ?[]const u8 {
        assert(key.len != 0);

        return env.map.get(key);
    }

    pub fn lookup(
        env: *const Env,
        process: *const std.process.Environ.Map,
        key: []const u8,
    ) ?[]const u8 {
        assert(key.len != 0);

        if (process.get(key)) |value| return value;
        return env.map.get(key);
    }
};

pub const path_default: []const u8 = ".env";
pub const file_len_max: u32 = 64 * 1024;

pub fn load(gpa: Allocator, io: std.Io, path: []const u8) !Env {
    assert(path.len != 0);

    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();

    const scratch = arena.allocator();

    var map: std.StringHashMapUnmanaged([]const u8) = .empty;

    const limit: std.Io.Limit = .limited(file_len_max);

    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, scratch, limit) catch |err| {
        switch (err) {
            error.FileNotFound => return .{ .map = map, .arena = arena },
            else => return err,
        }
    };

    try parse(scratch, bytes, &map);

    return .{
        .map = map,
        .arena = arena,
    };
}

pub fn parse(
    gpa: Allocator,
    bytes: []const u8,
    map: *std.StringHashMapUnmanaged([]const u8),
) !void {
    assert(bytes.len <= file_len_max);

    var lines = std.mem.splitScalar(u8, bytes, '\n');

    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");

        if (line.len == 0) continue;
        if (line[0] == '#') continue;

        const stripped = if (std.mem.startsWith(u8, line, "export "))
            line["export ".len..]
        else
            line;

        const eq = std.mem.indexOfScalar(u8, stripped, '=') orelse continue;
        const key = std.mem.trim(u8, stripped[0..eq], " \t");

        if (key.len == 0) continue;

        const value = strip_quotes(std.mem.trim(u8, stripped[eq + 1 ..], " \t"));

        try map.put(gpa, key, value);
    }
}

fn strip_quotes(value: []const u8) []const u8 {
    if (value.len < 2) return value;

    const first = value[0];
    const last = value[value.len - 1];

    if ((first == '"' and last == '"') or (first == '\'' and last == '\'')) {
        return value[1 .. value.len - 1];
    }

    return value;
}

test "parse reads keys, ignores blanks and comments, strips quotes and export" {
    const gpa = std.testing.allocator;

    const bytes =
        \\# comment line
        \\
        \\GARMIN_EMAIL=you@example.com
        \\  export GARMIN_PASSWORD = "p@ss word=1&2"
        \\EMPTY_VALUE=
        \\=novalue
        \\SINGLE='quoted'
    ;

    var map: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer map.deinit(gpa);

    try parse(gpa, bytes, &map);

    try std.testing.expectEqualStrings("you@example.com", map.get("GARMIN_EMAIL").?);
    try std.testing.expectEqualStrings("p@ss word=1&2", map.get("GARMIN_PASSWORD").?);
    try std.testing.expectEqualStrings("", map.get("EMPTY_VALUE").?);
    try std.testing.expectEqualStrings("quoted", map.get("SINGLE").?);
    try std.testing.expect(map.get("novalue") == null);
}

test "parse keeps mismatched quotes and treats export without a space as a key prefix" {
    const gpa = std.testing.allocator;

    const bytes =
        \\MISMATCH="abc'
        \\exportGARMIN=value
    ;

    var map: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer map.deinit(gpa);

    try parse(gpa, bytes, &map);

    try std.testing.expectEqualStrings("\"abc'", map.get("MISMATCH").?);
    try std.testing.expectEqualStrings("value", map.get("exportGARMIN").?);
    try std.testing.expect(map.get("GARMIN") == null);
}
