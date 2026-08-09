const std = @import("std");

const fuzz = @import("../testing/fuzz.zig");
const oauth1 = @import("oauth1.zig");

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const input_len_max: u32 = 256;
const escape_alphabet = "%+0123456789abcdefzZ =&";

comptime {
    assert(input_len_max > 0);
    assert(escape_alphabet.len > 0);
}

fn check_roundtrip(gpa: Allocator, input: []const u8) !void {
    var encoded: std.Io.Writer.Allocating = .init(gpa);
    defer encoded.deinit();

    try oauth1.percent_encode(&encoded.writer, input);

    const decoded = try oauth1.query_decode(gpa, encoded.written());
    defer gpa.free(decoded);

    assert(std.mem.eql(u8, input, decoded));
}

fn check_malformed(gpa: Allocator, input: []const u8) !void {
    const decoded = try oauth1.query_decode(gpa, input);
    defer gpa.free(decoded);

    assert(decoded.len <= input.len);
}

pub fn main(gpa: Allocator, args: fuzz.FuzzArgs) !void {
    assert(args.events_max >= 1);

    var prng = std.Random.DefaultPrng.init(args.seed);
    const random = prng.random();

    var buffer: [input_len_max]u8 = undefined;
    var event: u32 = 0;

    while (event < args.events_max) : (event += 1) {
        const length = random.uintAtMost(usize, input_len_max);
        const input = buffer[0..length];

        random.bytes(input);

        try check_roundtrip(gpa, input);

        for (input) |*byte| {
            byte.* = escape_alphabet[random.uintLessThan(usize, escape_alphabet.len)];
        }

        try check_malformed(gpa, input);
    }

    assert(event == args.events_max);
}

const testing = std.testing;

test "fuzz: percent encode then query decode roundtrips arbitrary bytes" {
    try main(testing.allocator, .{ .seed = 0x5eed_0a41_7b1d_92c3, .events_max = 500 });
}

test "fuzz: query decode survives malformed escapes without growing" {
    try main(testing.allocator, .{ .seed = 0x5eed_0a41_7b1d_92c4, .events_max = 500 });
}
