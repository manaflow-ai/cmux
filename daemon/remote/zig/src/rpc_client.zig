const std = @import("std");

pub const Client = struct {
    alloc: std.mem.Allocator,
    socket_path: []const u8,
    file: ?std.fs.File = null,

    pub fn init(alloc: std.mem.Allocator, socket_path: []const u8) Client {
        return .{
            .alloc = alloc,
            .socket_path = socket_path,
        };
    }

    pub fn deinit(self: *Client) void {
        if (self.file) |*file| file.close();
        self.file = null;
    }

    pub fn call(self: *Client, request_json: []const u8) !std.json.Parsed(std.json.Value) {
        try self.ensureConnected();
        var file = &self.file.?;
        try file.writeAll(request_json);
        try file.writeAll("\n");

        const line = try readLine(self.alloc, file, 4 * 1024 * 1024);
        defer self.alloc.free(line);

        return std.json.parseFromSlice(std.json.Value, self.alloc, line, .{});
    }

    fn ensureConnected(self: *Client) !void {
        if (self.file != null) return;

        var unix_addr = try std.net.Address.initUnix(self.socket_path);
        const fd = try std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC, 0);
        errdefer std.posix.close(fd);
        try std.posix.connect(fd, &unix_addr.any, unix_addr.getOsSockLen());
        self.file = std.fs.File{ .handle = fd };
    }
};

fn readLine(alloc: std.mem.Allocator, file: *std.fs.File, max_bytes: usize) ![]u8 {
    var line = std.ArrayList(u8).empty;
    defer line.deinit(alloc);

    var byte: [1]u8 = undefined;
    while (line.items.len < max_bytes) {
        const n = try file.read(&byte);
        if (n == 0) break;
        try line.append(alloc, byte[0]);
        if (byte[0] == '\n') break;
    }

    return line.toOwnedSlice(alloc);
}

test "client reuses a single unix socket connection across calls" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const socket_path = try std.fmt.allocPrint(
        alloc,
        "/tmp/cmuxd-rpc-client-{d}.sock",
        .{std.time.nanoTimestamp()},
    );
    defer alloc.free(socket_path);

    var server = try SingleConnectionFixture.start(socket_path);
    defer server.deinit();

    var client = Client.init(alloc, socket_path);
    defer client.deinit();

    const req1 = "{\"id\":\"1\",\"method\":\"ping\",\"params\":{}}";
    var res1 = try client.call(req1);
    defer res1.deinit();
    try testing.expectEqualStrings("pong-1", res1.value.object.get("result").?.object.get("token").?.string);

    const req2 = "{\"id\":\"2\",\"method\":\"ping\",\"params\":{}}";
    var res2 = try client.call(req2);
    defer res2.deinit();
    try testing.expectEqualStrings("pong-2", res2.value.object.get("result").?.object.get("token").?.string);
}

const SingleConnectionFixture = struct {
    socket_path: []const u8,
    thread: std.Thread,

    fn start(socket_path: []const u8) !SingleConnectionFixture {
        try deleteIfPresent(socket_path);

        var unix_addr = try std.net.Address.initUnix(socket_path);
        const listener_fd = try std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC, 0);
        errdefer std.posix.close(listener_fd);
        errdefer deleteIfPresent(socket_path) catch {};
        try std.posix.bind(listener_fd, &unix_addr.any, unix_addr.getOsSockLen());
        try std.posix.listen(listener_fd, 1);

        const thread = try std.Thread.spawn(.{}, serve, .{listener_fd});
        errdefer thread.join();

        return .{
            .socket_path = socket_path,
            .thread = thread,
        };
    }

    fn deinit(self: *SingleConnectionFixture) void {
        self.thread.join();
        deleteIfPresent(self.socket_path) catch {};
    }

    fn serve(listener_fd: std.posix.fd_t) !void {
        defer std.posix.close(listener_fd);

        const client_fd = try std.posix.accept(listener_fd, null, null, std.posix.SOCK.CLOEXEC);
        defer std.posix.close(client_fd);

        var file = std.fs.File{ .handle = client_fd };

        const line1 = try readLine(std.heap.page_allocator, &file, 1024);
        defer std.heap.page_allocator.free(line1);
        try file.writeAll("{\"ok\":true,\"result\":{\"token\":\"pong-1\"}}\n");

        const line2 = try readLine(std.heap.page_allocator, &file, 1024);
        defer std.heap.page_allocator.free(line2);
        try file.writeAll("{\"ok\":true,\"result\":{\"token\":\"pong-2\"}}\n");
    }

    fn deleteIfPresent(path: []const u8) !void {
        std.fs.deleteFileAbsolute(path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }
};
