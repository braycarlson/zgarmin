test {
    _ = @import("auth/html.zig");
    _ = @import("auth/html_fuzz.zig");
    _ = @import("auth/oauth1.zig");
    _ = @import("auth/oauth1_fuzz.zig");
    _ = @import("auth/sso.zig");
    _ = @import("auth/tokens.zig");
    _ = @import("connect/endpoints.zig");
    _ = @import("env.zig");
    _ = @import("fuzz_tests.zig");
    _ = @import("http.zig");
    _ = @import("testing/fuzz.zig");
    _ = @import("tidy.zig");
}
