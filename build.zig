const std = @import("std");

const assert = std.debug.assert;

const Steps = struct {
    check: *std.Build.Step,
    ci: *std.Build.Step,
    fuzz: *std.Build.Step,
    fuzz_build: *std.Build.Step,
    fuzz_smoke: *std.Build.Step,
    run: *std.Build.Step,
    test_all: *std.Build.Step,
    test_fmt: *std.Build.Step,
    test_unit: *std.Build.Step,
};

const format_paths = [_][]const u8{ "build.zig", "src" };

comptime {
    assert(format_paths.len > 0);
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const filters = b.option(
        []const []const u8,
        "test-filter",
        "Skip tests that do not match any filter",
    ) orelse &.{};

    const steps = Steps{
        .check = b.step("check", "Compile every artifact without running it"),
        .ci = b.step("ci", "Run formatting, compilation, unit tests, and fuzzer smoke"),
        .fuzz = b.step("fuzz", "Run a fuzzer: -- <fuzzer> [seed] [events]"),
        .fuzz_build = b.step("fuzz:build", "Compile the fuzzer without running it"),
        .fuzz_smoke = b.step("fuzz:smoke", "Run every fuzzer briefly with a fixed seed"),
        .run = b.step("run", "Run the Garmin Connect CLI"),
        .test_all = b.step("test", "Run every test suite and the formatting check"),
        .test_fmt = b.step("test:fmt", "Check that every source file is formatted"),
        .test_unit = b.step("test:unit", "Run the colocated unit tests and the tidy law"),
    };

    const module = b.addModule("zgarmin", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    add_format(b, &steps);
    add_cli(b, &steps, module, target, optimize);
    add_unit_tests(b, &steps, target, optimize, filters);
    add_fuzz(b, &steps, target, optimize);

    steps.ci.dependOn(steps.test_fmt);
    steps.ci.dependOn(steps.check);
    steps.ci.dependOn(steps.test_unit);
    steps.ci.dependOn(steps.fuzz_smoke);

    b.default_step.dependOn(steps.check);
}

fn add_format(b: *std.Build, steps: *const Steps) void {
    const fmt = b.addFmt(.{
        .paths = b.pathList(&format_paths),
        .check = true,
    });

    steps.test_fmt.dependOn(&fmt.step);
    steps.test_all.dependOn(&fmt.step);
}

fn add_cli(
    b: *std.Build,
    steps: *const Steps,
    module: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
) void {
    const exe = b.addExecutable(.{
        .name = "zgarmin",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zgarmin", .module = module }},
        }),
    });

    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);

    run.step.dependOn(b.getInstallStep());
    run.addPassthruArgs();

    steps.run.dependOn(&run.step);
    steps.check.dependOn(&exe.step);
}

fn add_unit_tests(
    b: *std.Build,
    steps: *const Steps,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    filters: []const []const u8,
) void {
    const unit = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/unit_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .filters = filters,
    });

    const run = b.addRunArtifact(unit);

    steps.test_unit.dependOn(&run.step);
    steps.test_all.dependOn(&run.step);
    steps.check.dependOn(&unit.step);
}

fn add_fuzz(
    b: *std.Build,
    steps: *const Steps,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
) void {
    const exe = b.addExecutable(.{
        .name = "fuzz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/fuzz_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run = b.addRunArtifact(exe);

    run.addPassthruArgs();

    const smoke = b.addRunArtifact(exe);

    smoke.addArg("smoke");

    steps.fuzz.dependOn(&run.step);
    steps.fuzz_build.dependOn(&exe.step);
    steps.fuzz_smoke.dependOn(&smoke.step);
    steps.check.dependOn(&exe.step);
}
