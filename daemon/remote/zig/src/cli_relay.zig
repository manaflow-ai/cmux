const std = @import("std");

pub fn run(args: []const []const u8, stderr: anytype) !u8 {
    if (args.len == 0) {
        try usage(stderr);
        return 2;
    }

    const command = args[0];
    if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        try usage(stderr);
        return 0;
    }

    try stderr.print("cmux: CLI relay not implemented in Zig yet\n", .{});
    try stderr.flush();
    return 1;
}

pub fn usage(stderr: anytype) !void {
    try stderr.print("Usage: cmux [--socket <path>] [--json] <command> [args...]\n", .{});
    try stderr.print("\n", .{});
    try stderr.print("Commands:\n", .{});
    try stderr.print("  ping                     Check connectivity\n", .{});
    try stderr.print("  capabilities              List server capabilities\n", .{});
    try stderr.print("  list-workspaces           List all workspaces\n", .{});
    try stderr.print("  new-window                Create a new window\n", .{});
    try stderr.print("  new-workspace             Create a new workspace\n", .{});
    try stderr.print("  new-surface               Create a new surface\n", .{});
    try stderr.print("  new-split                 Split an existing surface\n", .{});
    try stderr.print("  close-surface             Close a surface\n", .{});
    try stderr.print("  close-workspace           Close a workspace\n", .{});
    try stderr.print("  select-workspace          Select a workspace\n", .{});
    try stderr.print("  send                      Send text to a surface\n", .{});
    try stderr.print("  send-key                  Send a key to a surface\n", .{});
    try stderr.print("  notify                    Create a notification\n", .{});
    try stderr.print("  browser <sub>             Browser commands (open, navigate, back, forward, reload, get-url)\n", .{});
    try stderr.print("  rpc <method> [json-params] Send arbitrary JSON-RPC\n", .{});
    try stderr.flush();
}
