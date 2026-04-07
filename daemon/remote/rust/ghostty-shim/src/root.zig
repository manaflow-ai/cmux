const std = @import("std");
const ghostty_vt = @import("ghostty-vt");
const testing = std.testing;

const Allocator = std.mem.Allocator;

const Handle = struct {
    alloc: Allocator,
    terminal: ghostty_vt.Terminal,
    stream: ghostty_vt.ReadonlyStream,

    fn init(self: *Handle, alloc: Allocator, cols: u16, rows: u16, max_scrollback: usize) !void {
        self.alloc = alloc;
        self.terminal = try ghostty_vt.Terminal.init(alloc, .{
            .cols = @max(@as(u16, 2), cols),
            .rows = @max(@as(u16, 1), rows),
            .max_scrollback = max_scrollback,
        });

        // The readonly stream stores a pointer to the terminal, so it must be
        // created from the terminal in its final storage location.
        self.stream = self.terminal.vtStream();
    }

    fn deinit(self: *Handle) void {
        self.stream.deinit();
        self.terminal.deinit(self.alloc);
    }
};

pub const CaptureBuffer = extern struct {
    ptr: [*c]u8,
    len: usize,
};

const CapturePayload = struct {
    cols: u16,
    rows: u16,
    cursor_x: u16,
    cursor_y: u16,
    history: []const u8,
    visible: []const u8,
};

export fn cmux_ghostty_new(cols: u16, rows: u16, max_scrollback: usize) ?*Handle {
    const alloc = std.heap.c_allocator;
    const handle = alloc.create(Handle) catch return null;
    handle.init(alloc, cols, rows, max_scrollback) catch {
        alloc.destroy(handle);
        return null;
    };
    return handle;
}

export fn cmux_ghostty_free(handle: ?*Handle) void {
    const ptr = handle orelse return;
    ptr.deinit();
    std.heap.c_allocator.destroy(ptr);
}

export fn cmux_ghostty_feed(handle: *Handle, data_ptr: [*]const u8, data_len: usize) bool {
    handle.stream.nextSlice(data_ptr[0..data_len]) catch return false;
    return true;
}

export fn cmux_ghostty_resize(handle: *Handle, cols: u16, rows: u16) bool {
    handle.terminal.resize(
        handle.alloc,
        @max(@as(u16, 2), cols),
        @max(@as(u16, 1), rows),
    ) catch return false;
    return true;
}

export fn cmux_ghostty_capture_json(
    handle: *Handle,
    include_history: bool,
    out: *CaptureBuffer,
) bool {
    const alloc = std.heap.c_allocator;
    const screen = handle.terminal.screens.active;

    const visible = dumpOrEmpty(screen, alloc, .{ .active = .{} }) catch return false;
    defer alloc.free(visible);

    const history = if (include_history)
        dumpOrEmpty(screen, alloc, .{ .history = .{} }) catch return false
    else
        alloc.dupe(u8, "") catch return false;
    defer alloc.free(history);

    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    std.json.Stringify.value(CapturePayload{
        .cols = @intCast(handle.terminal.cols),
        .rows = @intCast(handle.terminal.rows),
        .cursor_x = @intCast(handle.terminal.screens.active.cursor.x),
        .cursor_y = @intCast(handle.terminal.screens.active.cursor.y),
        .history = history,
        .visible = visible,
    }, .{}, &builder.writer) catch return false;

    const encoded = builder.writer.buffered();
    const owned = alloc.dupe(u8, encoded) catch return false;
    out.* = .{
        .ptr = if (owned.len == 0) null else owned.ptr,
        .len = owned.len,
    };
    return true;
}

export fn cmux_ghostty_buffer_free(ptr: [*c]u8, len: usize) void {
    if (ptr == null or len == 0) return;
    std.heap.c_allocator.free(ptr[0..len]);
}

fn dumpOrEmpty(screen: *const ghostty_vt.Screen, alloc: Allocator, point: ghostty_vt.Point) ![]const u8 {
    return screen.dumpStringAllocUnwrapped(alloc, point) catch |err| switch (err) {
        error.UnknownPoint => alloc.dupe(u8, ""),
        else => err,
    };
}

test "Handle.init keeps vt stream bound to stored terminal" {
    const handle = try testing.allocator.create(Handle);
    defer testing.allocator.destroy(handle);
    try handle.init(testing.allocator, 80, 24, 1_000);
    defer handle.deinit();

    try testing.expectEqual(@intFromPtr(&handle.terminal), @intFromPtr(handle.stream.handler.terminal));
}
