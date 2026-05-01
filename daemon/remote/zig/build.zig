const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // Default to ReleaseSafe. ReleaseFast strips every safety check —
    // null derefs, bounds, integer overflow, tagged-union panics,
    // `unreachable` — so real bugs land as opaque SIGSEGVs instead of
    // panics with a stack trace. The daemon is PTY-throughput bound,
    // not compute-bound; the ~10-15% cost is not visible in practice
    // and the reliability improvement is large (every crash we hit
    // this session would have landed as a named panic).
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "optimization mode") orelse .ReleaseSafe;
    const version = b.option([]const u8, "version", "daemon version string") orelse "dev";
    const test_filter = b.option([]const u8, "test-filter", "only run tests matching this filter");
    const test_filters: []const []const u8 = if (test_filter) |filter| &.{filter} else &.{};

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", version);

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addOptions("build_options", build_options);

    if (b.lazyDependency("ghostty", .{
        .target = target,
        .optimize = optimize,
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
    exe.linkSystemLibrary("sqlite3");
    b.installArtifact(exe);

    const unit_tests = b.addTest(.{
        .root_module = mod,
        .filters = test_filters,
    });
    unit_tests.linkLibC();
    unit_tests.linkSystemLibrary("sqlite3");
    const run_unit_tests = b.addRunArtifact(unit_tests);

    // Integration tests: real `serve_unix`-shaped listener on a temp Unix
    // socket, driven via line-delimited JSON-RPC. See tests/integration.zig.
    const integration_src_mod = b.createModule(.{
        .root_source_file = b.path("src/integration_test_exports.zig"),
        .target = target,
        .optimize = optimize,
    });
    integration_src_mod.addOptions("build_options", build_options);
    if (b.lazyDependency("ghostty", .{
        .target = target,
        .optimize = optimize,
    })) |dep| {
        integration_src_mod.addImport("ghostty-vt", dep.module("ghostty-vt"));
    }
    if (b.lazyDependency("tls", .{
        .target = target,
        .optimize = optimize,
    })) |dep| {
        integration_src_mod.addImport("tls", dep.module("tls"));
    }

    const integration_mod = b.createModule(.{
        .root_source_file = b.path("tests/integration.zig"),
        .target = target,
        .optimize = optimize,
    });
    integration_mod.addImport("cmuxd_src", integration_src_mod);

    const integration_tests = b.addTest(.{
        .root_module = integration_mod,
        .filters = test_filters,
    });
    integration_tests.linkLibC();
    integration_tests.linkSystemLibrary("sqlite3");
    const run_integration_tests = b.addRunArtifact(integration_tests);

    const test_step = b.step("test", "Run unit + integration tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_integration_tests.step);

    // Separate test step with ThreadSanitizer enabled. Catches data
    // races at test time that the default build misses. Opt-in because
    // TSan is 5-15x slower and incompatible with some targets; CI can
    // run it on a schedule, devs can invoke `zig build test-tsan`
    // locally before merging concurrency-adjacent changes.
    //
    // Wires against a fresh set of modules rather than re-using the
    // ones above — `sanitize_thread` has to be set at module creation
    // in zig 0.15 and the production-build modules should stay clean.
    const tsan_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = .Debug,
        .sanitize_thread = true,
    });
    tsan_mod.addOptions("build_options", build_options);
    if (b.lazyDependency("ghostty", .{
        .target = target,
        .optimize = .Debug,
    })) |dep| {
        tsan_mod.addImport("ghostty-vt", dep.module("ghostty-vt"));
    }
    if (b.lazyDependency("tls", .{
        .target = target,
        .optimize = .Debug,
    })) |dep| {
        tsan_mod.addImport("tls", dep.module("tls"));
    }
    const tsan_unit_tests = b.addTest(.{ .root_module = tsan_mod, .filters = test_filters });
    tsan_unit_tests.linkLibC();
    tsan_unit_tests.linkSystemLibrary("sqlite3");
    const run_tsan_unit_tests = b.addRunArtifact(tsan_unit_tests);

    const tsan_src_mod = b.createModule(.{
        .root_source_file = b.path("src/integration_test_exports.zig"),
        .target = target,
        .optimize = .Debug,
        .sanitize_thread = true,
    });
    tsan_src_mod.addOptions("build_options", build_options);
    if (b.lazyDependency("ghostty", .{
        .target = target,
        .optimize = .Debug,
    })) |dep| {
        tsan_src_mod.addImport("ghostty-vt", dep.module("ghostty-vt"));
    }
    if (b.lazyDependency("tls", .{
        .target = target,
        .optimize = .Debug,
    })) |dep| {
        tsan_src_mod.addImport("tls", dep.module("tls"));
    }
    const tsan_integration_mod = b.createModule(.{
        .root_source_file = b.path("tests/integration.zig"),
        .target = target,
        .optimize = .Debug,
        .sanitize_thread = true,
    });
    tsan_integration_mod.addImport("cmuxd_src", tsan_src_mod);
    const tsan_integration_tests = b.addTest(.{ .root_module = tsan_integration_mod, .filters = test_filters });
    tsan_integration_tests.linkLibC();
    tsan_integration_tests.linkSystemLibrary("sqlite3");
    const run_tsan_integration_tests = b.addRunArtifact(tsan_integration_tests);

    const tsan_step = b.step("test-tsan", "Run tests with ThreadSanitizer");
    tsan_step.dependOn(&run_tsan_unit_tests.step);
    tsan_step.dependOn(&run_tsan_integration_tests.step);
}
