const std = @import("std");

const PlatformOption = enum {
    auto,
    null,
    macos,
};

const WebEngineOption = enum {
    system,
    chromium,
};

const default_zero_native_path = "third_party/zero-native";
const app_exe_name = "zero-cmux";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const platform_option = b.option(PlatformOption, "platform", "Desktop backend: auto, null, macos") orelse .auto;
    const requested_web_engine = b.option(WebEngineOption, "web-engine", "Web engine: system, chromium") orelse appWebEngine();
    const cef_dir = b.option([]const u8, "cef-dir", "Path to the CEF runtime") orelse "third_party/cef/macos";
    const cef_auto_install = b.option(bool, "cef-auto-install", "Install CEF through zero-native when missing") orelse false;
    const zero_native_path = b.option([]const u8, "zero-native-path", "Path to the zero-native checkout") orelse default_zero_native_path;

    const selected_platform: PlatformOption = switch (platform_option) {
        .auto => if (target.result.os.tag == .macos) .macos else .null,
        else => platform_option,
    };
    if (selected_platform == .macos and target.result.os.tag != .macos) {
        @panic("-Dplatform=macos requires a macOS target");
    }
    const web_engine: WebEngineOption = if (selected_platform == .null) .system else requested_web_engine;

    const zero_native_mod = zeroNativeModule(b, target, optimize, zero_native_path);
    const options = b.addOptions();
    options.addOption([]const u8, "platform", switch (selected_platform) {
        .auto => unreachable,
        .null => "null",
        .macos => "macos",
    });
    options.addOption([]const u8, "web_engine", @tagName(web_engine));
    const options_mod = options.createModule();

    const runner_mod = localModule(b, target, optimize, "src/runner.zig");
    runner_mod.addImport("zero-native", zero_native_mod);
    runner_mod.addImport("build_options", options_mod);

    const ghostty_contract_mod = localModule(b, target, optimize, "src/ghostty_contract.zig");
    ghostty_contract_mod.addIncludePath(b.path("../../ghostty/include"));

    const app_mod = localModule(b, target, optimize, "src/main.zig");
    app_mod.addImport("zero-native", zero_native_mod);
    app_mod.addImport("runner", runner_mod);
    app_mod.addImport("ghostty-contract", ghostty_contract_mod);
    app_mod.addIncludePath(b.path("../../ghostty/include"));

    const exe = b.addExecutable(.{
        .name = app_exe_name,
        .root_module = app_mod,
    });
    linkPlatform(b, target, app_mod, exe, selected_platform, web_engine, zero_native_path, cef_dir, cef_auto_install);
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    addCefRuntimeRunFiles(b, target, run, exe, web_engine, cef_dir);
    const run_step = b.step("run", "Run the prototype");
    run_step.dependOn(&run.step);

    const tests = b.addTest(.{ .root_module = app_mod });
    const test_step = b.step("test", "Run prototype tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}

fn localModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, path: []const u8) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path(path),
        .target = target,
        .optimize = optimize,
    });
}

fn zeroNativePath(b: *std.Build, zero_native_path: []const u8, sub_path: []const u8) std.Build.LazyPath {
    return .{ .cwd_relative = b.pathJoin(&.{ zero_native_path, sub_path }) };
}

fn externalModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, zero_native_path: []const u8, path: []const u8) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = zeroNativePath(b, zero_native_path, path),
        .target = target,
        .optimize = optimize,
    });
}

fn zeroNativeModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, zero_native_path: []const u8) *std.Build.Module {
    const geometry_mod = externalModule(b, target, optimize, zero_native_path, "src/primitives/geometry/root.zig");
    const assets_mod = externalModule(b, target, optimize, zero_native_path, "src/primitives/assets/root.zig");
    const app_dirs_mod = externalModule(b, target, optimize, zero_native_path, "src/primitives/app_dirs/root.zig");
    const trace_mod = externalModule(b, target, optimize, zero_native_path, "src/primitives/trace/root.zig");
    const app_manifest_mod = externalModule(b, target, optimize, zero_native_path, "src/primitives/app_manifest/root.zig");
    const diagnostics_mod = externalModule(b, target, optimize, zero_native_path, "src/primitives/diagnostics/root.zig");
    const platform_info_mod = externalModule(b, target, optimize, zero_native_path, "src/primitives/platform_info/root.zig");
    const json_mod = externalModule(b, target, optimize, zero_native_path, "src/primitives/json/root.zig");
    const debug_mod = externalModule(b, target, optimize, zero_native_path, "src/debug/root.zig");
    debug_mod.addImport("app_dirs", app_dirs_mod);
    debug_mod.addImport("trace", trace_mod);

    const zero_native_mod = externalModule(b, target, optimize, zero_native_path, "src/root.zig");
    zero_native_mod.addImport("geometry", geometry_mod);
    zero_native_mod.addImport("assets", assets_mod);
    zero_native_mod.addImport("app_dirs", app_dirs_mod);
    zero_native_mod.addImport("trace", trace_mod);
    zero_native_mod.addImport("app_manifest", app_manifest_mod);
    zero_native_mod.addImport("diagnostics", diagnostics_mod);
    zero_native_mod.addImport("platform_info", platform_info_mod);
    zero_native_mod.addImport("json", json_mod);
    zero_native_mod.addImport("debug", debug_mod);
    return zero_native_mod;
}

fn linkPlatform(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    app_mod: *std.Build.Module,
    exe: *std.Build.Step.Compile,
    platform: PlatformOption,
    web_engine: WebEngineOption,
    zero_native_path: []const u8,
    cef_dir: []const u8,
    cef_auto_install: bool,
) void {
    _ = target;
    if (platform != .macos) return;

    switch (web_engine) {
        .system => {
            app_mod.addCSourceFile(.{ .file = zeroNativePath(b, zero_native_path, "src/platform/macos/appkit_host.m"), .flags = &.{ "-fobjc-arc", "-ObjC" } });
            app_mod.linkFramework("WebKit", .{});
        },
        .chromium => {
            const cef_check = addCefCheck(b, cef_dir);
            if (cef_auto_install) {
                const cef_auto = b.addSystemCommand(&.{ "zero-native", "cef", "install", "--dir", cef_dir });
                cef_check.step.dependOn(&cef_auto.step);
            }
            exe.step.dependOn(&cef_check.step);
            const include_arg = b.fmt("-I{s}", .{cef_dir});
            const define_arg = b.fmt("-DZERO_NATIVE_CEF_DIR=\"{s}\"", .{cef_dir});
            app_mod.addCSourceFile(.{ .file = zeroNativePath(b, zero_native_path, "src/platform/macos/cef_host.mm"), .flags = &.{ "-fobjc-arc", "-ObjC++", "-std=c++17", "-stdlib=libc++", include_arg, define_arg } });
            app_mod.addObjectFile(b.path(b.fmt("{s}/libcef_dll_wrapper/libcef_dll_wrapper.a", .{cef_dir})));
            app_mod.addFrameworkPath(b.path(b.fmt("{s}/Release", .{cef_dir})));
            app_mod.linkFramework("Chromium Embedded Framework", .{});
            app_mod.linkSystemLibrary("c++", .{});
            app_mod.addRPath(.{ .cwd_relative = "@executable_path/Frameworks" });
        },
    }

    app_mod.linkFramework("AppKit", .{});
    app_mod.linkFramework("Foundation", .{});
    app_mod.linkFramework("UniformTypeIdentifiers", .{});
    app_mod.linkSystemLibrary("c", .{});
}

fn addCefRuntimeRunFiles(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    run: *std.Build.Step.Run,
    exe: *std.Build.Step.Compile,
    web_engine: WebEngineOption,
    cef_dir: []const u8,
) void {
    if (web_engine != .chromium) return;
    if (target.result.os.tag != .macos) return;
    const copy = b.addSystemCommand(&.{
        "sh", "-c",
        b.fmt(
            \\set -e
            \\exe="$0"
            \\exe_dir="$(dirname "$exe")"
            \\rm -rf "zig-out/Frameworks/Chromium Embedded Framework.framework" "zig-out/bin/Frameworks/Chromium Embedded Framework.framework" ".zig-cache/o/Frameworks/Chromium Embedded Framework.framework"
            \\mkdir -p "zig-out/Frameworks" "zig-out/bin/Frameworks" ".zig-cache/o/Frameworks" "$exe_dir"
            \\cp -R "{s}/Release/Chromium Embedded Framework.framework" "zig-out/Frameworks/"
            \\cp -R "{s}/Release/Chromium Embedded Framework.framework" "zig-out/bin/Frameworks/"
            \\cp -R "{s}/Release/Chromium Embedded Framework.framework" ".zig-cache/o/Frameworks/"
            \\cp "{s}/Release/Chromium Embedded Framework.framework/Libraries/libEGL.dylib" "$exe_dir/"
            \\cp "{s}/Release/Chromium Embedded Framework.framework/Libraries/libGLESv2.dylib" "$exe_dir/"
            \\cp "{s}/Release/Chromium Embedded Framework.framework/Libraries/libvk_swiftshader.dylib" "$exe_dir/"
            \\cp "{s}/Release/Chromium Embedded Framework.framework/Libraries/vk_swiftshader_icd.json" "$exe_dir/"
        , .{ cef_dir, cef_dir, cef_dir, cef_dir, cef_dir, cef_dir, cef_dir }),
    });
    copy.addFileArg(exe.getEmittedBin());
    run.step.dependOn(&copy.step);
}

fn addCefCheck(b: *std.Build, cef_dir: []const u8) *std.Build.Step.Run {
    return b.addSystemCommand(&.{
        "sh", "-c",
        b.fmt(
            \\test -f "{s}/include/cef_app.h" &&
            \\test -d "{s}/Release/Chromium Embedded Framework.framework" &&
            \\test -f "{s}/libcef_dll_wrapper/libcef_dll_wrapper.a" || {{
            \\  echo "missing CEF dependency for -Dweb-engine=chromium" >&2
            \\  echo "Fix with: zero-native cef install --dir {s}" >&2
            \\  echo "Or rerun with: -Dcef-auto-install=true" >&2
            \\  exit 1
            \\}}
        , .{ cef_dir, cef_dir, cef_dir, cef_dir }),
    });
}

fn appWebEngine() WebEngineOption {
    const source = @embedFile("app.zon");
    if (stringField(source, ".web_engine")) |value| {
        if (std.mem.eql(u8, value, "system")) return .system;
        if (std.mem.eql(u8, value, "chromium")) return .chromium;
    }
    return .chromium;
}

fn stringField(source: []const u8, field: []const u8) ?[]const u8 {
    const field_index = std.mem.indexOf(u8, source, field) orelse return null;
    const equals = std.mem.indexOfScalarPos(u8, source, field_index, '=') orelse return null;
    const start_quote = std.mem.indexOfScalarPos(u8, source, equals, '"') orelse return null;
    const end_quote = std.mem.indexOfScalarPos(u8, source, start_quote + 1, '"') orelse return null;
    return source[start_quote + 1 .. end_quote];
}
