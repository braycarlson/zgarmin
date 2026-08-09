const std = @import("std");

const fuzz = @import("../testing/fuzz.zig");
const html = @import("html.zig");

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const alphabet = "<>=\"'/ \n\tnamevalue?ticket&-_";
const document_len_max: u32 = 512;

comptime {
    assert(alphabet.len > 0);
    assert(document_len_max > 0);
}

fn check_subslice(outer: []const u8, inner: []const u8) void {
    const outer_address = @intFromPtr(outer.ptr);
    const inner_address = @intFromPtr(inner.ptr);

    assert(inner_address >= outer_address);
    assert(inner_address + inner.len <= outer_address + outer.len);
}

pub fn main(gpa: Allocator, args: fuzz.FuzzArgs) !void {
    _ = gpa;

    assert(args.events_max >= 1);

    var prng = std.Random.DefaultPrng.init(args.seed);
    const random = prng.random();

    var buffer: [document_len_max]u8 = undefined;
    var event: u32 = 0;

    while (event < args.events_max) : (event += 1) {
        const length = random.uintAtMost(usize, document_len_max);
        const document = buffer[0..length];

        for (document) |*byte| {
            byte.* = alphabet[random.uintLessThan(usize, alphabet.len)];
        }

        if (html.field_value(document, "name")) |value| {
            check_subslice(document, value);
        }

        _ = html.field_present(document, "value");

        if (html.service_ticket(document)) |ticket| {
            check_subslice(document, ticket);

            assert(ticket.len != 0);
        }
    }

    assert(event == args.events_max);
}

const testing = std.testing;

test "fuzz: html scanners survive arbitrary documents and return subslices" {
    try main(testing.allocator, .{ .seed = 0x7a3d_11d7_5eed_2a17, .events_max = 2000 });
}

test "fuzz: html scanners are deterministic per seed" {
    try main(testing.allocator, .{ .seed = 11, .events_max = 128 });
    try main(testing.allocator, .{ .seed = 11, .events_max = 128 });
}
