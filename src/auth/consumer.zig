const std = @import("std");

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

pub const Consumer = struct {
    key: []u8,
    secret: []u8,
    gpa: Allocator,

    pub fn deinit(consumer: *Consumer) void {
        assert(consumer.key.len != 0);
        assert(consumer.secret.len != 0);

        consumer.gpa.free(consumer.key);
        consumer.gpa.free(consumer.secret);
    }
};

pub const InitOptions = struct {
    key: []const u8,
    secret: []const u8,
};

pub const key_default: []const u8 = "fc3e99d2-118c-44b8-8ae3-03370dde24c0";
pub const secret_default: []const u8 = "E08WAR897WEy2knn7aFBrvegVAf0AFdWBBF";

pub const key_variable: []const u8 = "GARMIN_CONSUMER_KEY";
pub const secret_variable: []const u8 = "GARMIN_CONSUMER_SECRET";

pub const credential_len_max: u32 = 256;

comptime {
    assert(key_default.len <= credential_len_max);
    assert(secret_default.len <= credential_len_max);
}

pub fn default(gpa: Allocator) !Consumer {
    return init(gpa, .{ .key = key_default, .secret = secret_default });
}

pub fn init(gpa: Allocator, options: InitOptions) !Consumer {
    if (options.key.len == 0) return error.ConsumerKeyEmpty;
    if (options.secret.len == 0) return error.ConsumerSecretEmpty;
    if (options.key.len > credential_len_max) return error.ConsumerKeyTooLong;
    if (options.secret.len > credential_len_max) return error.ConsumerSecretTooLong;

    const key_owned = try gpa.dupe(u8, options.key);
    errdefer gpa.free(key_owned);

    const secret_owned = try gpa.dupe(u8, options.secret);

    return .{
        .key = key_owned,
        .secret = secret_owned,
        .gpa = gpa,
    };
}
