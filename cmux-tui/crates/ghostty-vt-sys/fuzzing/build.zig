//! libghostty-vt for coverage-guided fuzzing. build.rs uses this build, not
//! ghostty-next's own, when cargo builds with `--cfg fuzzing` (cargo fuzz).
//! It copies this file into OUT_DIR and writes a build.zig.zon beside it that
//! names the ghostty-next tree as the `ghostty` path dependency.
//!
//! Chromium instruments the code under test in every fuzzing build
//! (build/config/sanitizers/BUILD.gn, use_fuzzing_engine): libFuzzer needs
//! the parser's edges, not only the Rust wrapper's. Two changes from the
//! product build:
//!   - ReleaseSafe, not ReleaseFast: Zig's bounds, overflow and unreachable
//!     checks stay on, so a parser fault panics (abort, a libFuzzer crash)
//!     instead of being silent undefined behavior.
//!   - `fuzz = true` (zig -ffuzz) on the libghostty-vt module:
//!     SanitizerCoverage inline 8-bit counters and trace-cmp. libFuzzer's
//!     runtime in the fuzz binary provides the `__sanitizer_cov_*` callbacks;
//!     build.rs moves the counters to libFuzzer's extra-counters section
//!     (move_coverage_to_extra_counters).
//!
//! As a dependency, ghostty's build does not merge the vendored SIMD
//! libraries (simdutf, highway) into the archive, so this build installs
//! each static library libghostty-vt links beside it and build.rs links them
//! all. They keep the product's SIMD paths and are not instrumented.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const version_string = b.option(
        []const u8,
        "version-string",
        "Forwarded to the ghostty build (skips its git version detection)",
    );

    const ghostty = b.dependency("ghostty", .{
        .target = target,
        .optimize = std.builtin.OptimizeMode.ReleaseSafe,
        .@"emit-lib-vt" = true,
        .@"emit-xcframework" = false,
        .@"emit-themes" = false,
        .@"version-string" = version_string,
    });
    const lib = ghostty.artifact("ghostty-vt-static");
    lib.root_module.fuzz = true;
    installArchive(b, lib, "ghostty-vt");

    for (lib.root_module.link_objects.items) |object| switch (object) {
        .other_step => |linked| if (linked.kind == .lib and linked.linkage == .static) {
            installArchive(b, linked, linked.name);
        },
        else => {},
    };
}

fn installArchive(b: *std.Build, lib: *std.Build.Step.Compile, name: []const u8) void {
    const file = b.addInstallLibFile(lib.getEmittedBin(), b.fmt("lib{s}.a", .{name}));
    b.getInstallStep().dependOn(&file.step);
}
