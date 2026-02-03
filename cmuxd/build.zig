const std = @import("std");

const UnicodeTables = struct {
    props_exe: *std.Build.Step.Compile,
    symbols_exe: *std.Build.Step.Compile,
    props_output: std.Build.LazyPath,
    symbols_output: std.Build.LazyPath,

    pub fn init(b: *std.Build, uucode_tables: std.Build.LazyPath) !UnicodeTables {
        const props_exe = b.addExecutable(.{
            .name = "props-unigen",
            .root_module = b.createModule(.{
                .root_source_file = b.path("../ghostty/src/unicode/props_uucode.zig"),
                .target = b.graph.host,
                .strip = false,
                .omit_frame_pointer = false,
                .unwind_tables = .sync,
            }),
            .use_llvm = true,
        });

        const symbols_exe = b.addExecutable(.{
            .name = "symbols-unigen",
            .root_module = b.createModule(.{
                .root_source_file = b.path("../ghostty/src/unicode/symbols_uucode.zig"),
                .target = b.graph.host,
                .strip = false,
                .omit_frame_pointer = false,
                .unwind_tables = .sync,
            }),
            .use_llvm = true,
        });

        if (b.lazyDependency("uucode", .{
            .target = b.graph.host,
            .tables_path = uucode_tables,
            .build_config_path = b.path("../ghostty/src/build/uucode_config.zig"),
        })) |dep| {
            inline for (&.{ props_exe, symbols_exe }) |exe| {
                exe.root_module.addImport("uucode", dep.module("uucode"));
            }
        }

        const props_run = b.addRunArtifact(props_exe);
        const symbols_run = b.addRunArtifact(symbols_exe);

        const wf = b.addWriteFiles();
        const props_output = wf.addCopyFile(props_run.captureStdOut(), "props.zig");
        const symbols_output = wf.addCopyFile(symbols_run.captureStdOut(), "symbols.zig");

        return .{
            .props_exe = props_exe,
            .symbols_exe = symbols_exe,
            .props_output = props_output,
            .symbols_output = symbols_output,
        };
    }

    pub fn addModuleImport(self: *const UnicodeTables, module: *std.Build.Module) void {
        module.addAnonymousImport("unicode_tables", .{
            .root_source_file = self.props_output,
        });
        module.addAnonymousImport("symbols_tables", .{
            .root_source_file = self.symbols_output,
        });
    }
};

const TerminalOptions = struct {
    artifact: Artifact,
    oniguruma: bool,
    simd: bool,
    slow_runtime_safety: bool,
    c_abi: bool,

    const Artifact = enum {
        ghostty,
        lib,
    };

    fn add(self: TerminalOptions, b: *std.Build, m: *std.Build.Module) void {
        const opts = b.addOptions();
        opts.addOption(Artifact, "artifact", self.artifact);
        opts.addOption(bool, "c_abi", self.c_abi);
        opts.addOption(bool, "oniguruma", self.oniguruma);
        opts.addOption(bool, "simd", self.simd);
        opts.addOption(bool, "slow_runtime_safety", self.slow_runtime_safety);
        opts.addOption(bool, "kitty_graphics", self.oniguruma);
        opts.addOption(bool, "tmux_control_mode", self.oniguruma);
        m.addOptions("terminal_options", opts);
    }
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const ghostty_mod = b.addModule("ghostty", .{
        .root_source_file = b.path("../ghostty/src/cmuxd.zig"),
        .target = target,
        .optimize = optimize,
    });

    (TerminalOptions{
        .artifact = .lib,
        .oniguruma = true,
        .simd = false,
        .slow_runtime_safety = optimize == .Debug,
        .c_abi = false,
    }).add(b, ghostty_mod);

    const uucode_dep = b.dependency("uucode", .{
        .target = target,
        .optimize = optimize,
        .build_config_path = b.path("../ghostty/src/build/uucode_config.zig"),
    });
    const uucode_tables = uucode_dep.namedLazyPath("tables.zig");
    const unicode_tables = UnicodeTables.init(b, uucode_tables) catch @panic("unicode tables");
    ghostty_mod.addImport("uucode", uucode_dep.module("uucode"));
    unicode_tables.addModuleImport(ghostty_mod);

    const onig_dep = b.dependency("oniguruma", .{});
    ghostty_mod.addImport("oniguruma", onig_dep.module("oniguruma"));

    const wuffs_dep = b.dependency("wuffs", .{});
    ghostty_mod.addImport("wuffs", wuffs_dep.module("wuffs"));

    const exe = b.addExecutable(.{
        .name = "cmuxd",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    exe.root_module.addImport("ghostty", ghostty_mod);

    b.installArtifact(exe);
}
