const std = @import("std");
const server_core = @import("server_core.zig");
const session_service = @import("session_service.zig");

pub fn serve() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var service = session_service.Service.init(alloc);
    defer service.deinit();
    service.on_workspace_changed = &server_core.notifyWorkspaceSubscribers;
    service.ensurePumpStarted();
    service.ensureWriterStarted();

    const stdin = std.fs.File.stdin();
    var output_buf: [64 * 1024]u8 = undefined;
    var output_writer = std.fs.File.stdout().writer(&output_buf);
    const output = &output_writer.interface;

    var pending: std.ArrayList(u8) = .empty;
    defer pending.deinit(alloc);

    var read_buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = try stdin.read(&read_buf);
        if (n == 0) break;

        try pending.appendSlice(alloc, read_buf[0..n]);
        while (std.mem.indexOfScalar(u8, pending.items, '\n')) |newline_index| {
            try server_core.handleLine(&service, output, pending.items[0..newline_index]);

            const remaining = pending.items[newline_index + 1 ..];
            std.mem.copyForwards(u8, pending.items[0..remaining.len], remaining);
            pending.items.len = remaining.len;
        }
    }

    if (pending.items.len > 0) {
        try server_core.handleLine(&service, output, pending.items);
    }
}
