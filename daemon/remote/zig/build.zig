const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "optimization mode") orelse .ReleaseFast;
    const version = b.option([]const u8, "version", "daemon version string") orelse "dev";

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", version);

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addOptions("build_options", build_options);

    const disable_ghostty_simd =
        !builtin.os.tag.isDarwin() and target.result.os.tag.isDarwin();

    if (b.lazyDependency("ghostty", .{
        .target = target,
        .optimize = optimize,
        .simd = !disable_ghostty_simd,
    })) |dep| {
        mod.addImport("ghostty-vt", dep.module("ghostty-vt"));
    }
    if (b.lazyDependency("tls", .{
        .target = target,
        .optimize = optimize,
    })) |dep| {
        mod.addImport("tls", dep.module("tls"));
    }

    const exe = b.addExecutable(.{
        .name = "cmuxd-remote",
        .root_module = mod,
    });
    exe.linkLibC();
    b.installArtifact(exe);

    const unit_tests = b.addTest(.{
        .root_module = mod,
    });
    unit_tests.linkLibC();
    const run_unit_tests = b.addRunArtifact(unit_tests);
    b.step("test", "Run unit tests").dependOn(&run_unit_tests.step);
}
