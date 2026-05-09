const std = @import("std");

const c = @cImport({
    @cInclude("ghostty.h");
});

pub const Contract = struct {
    terminal_engine: []const u8,
    host_platform: []const u8,
    surface_context: []const u8,
    io_mode: []const u8,
};

pub fn current() Contract {
    return .{
        .terminal_engine = "ghostty",
        .host_platform = "macos-nsview",
        .surface_context = "split",
        .io_mode = "exec",
    };
}

pub fn assertCompileTimeSurfaceContract() void {
    _ = c.GHOSTTY_PLATFORM_MACOS;
    _ = c.GHOSTTY_SURFACE_CONTEXT_SPLIT;
    _ = c.GHOSTTY_SURFACE_IO_EXEC;
    _ = c.ghostty_surface_config_s;
}

test "Ghostty C API exposes the native macOS surface contract" {
    assertCompileTimeSurfaceContract();
    var config = std.mem.zeroes(c.ghostty_surface_config_s);
    config.platform_tag = c.GHOSTTY_PLATFORM_MACOS;
    config.context = c.GHOSTTY_SURFACE_CONTEXT_SPLIT;
    config.io_mode = c.GHOSTTY_SURFACE_IO_EXEC;

    try std.testing.expectEqual(c.GHOSTTY_PLATFORM_MACOS, config.platform_tag);
    try std.testing.expectEqual(c.GHOSTTY_SURFACE_CONTEXT_SPLIT, config.context);
    try std.testing.expectEqual(c.GHOSTTY_SURFACE_IO_EXEC, config.io_mode);
}
