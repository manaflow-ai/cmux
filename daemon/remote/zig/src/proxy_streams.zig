const std = @import("std");

pub const ReadResult = struct {
    data: []u8,
    eof: bool,
};

pub const Manager = struct {
    alloc: std.mem.Allocator,
    next_stream_id: u64 = 1,
    streams: std.StringHashMap(std.net.Stream),

    pub fn init(alloc: std.mem.Allocator) Manager {
        return .{
            .alloc = alloc,
            .streams = std.StringHashMap(std.net.Stream).init(alloc),
        };
    }

    pub fn deinit(self: *Manager) void {
        var iter = self.streams.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.close();
            self.alloc.free(entry.key_ptr.*);
        }
        self.streams.deinit();
    }

    pub fn open(self: *Manager, host: []const u8, port: u16) ![]const u8 {
        const stream = try std.net.tcpConnectToHost(self.alloc, host, port);
        errdefer stream.close();

        const stream_id = try std.fmt.allocPrint(self.alloc, "s-{d}", .{self.next_stream_id});
        errdefer self.alloc.free(stream_id);
        self.next_stream_id += 1;

        try self.streams.put(stream_id, stream);
        return stream_id;
    }

    pub fn close(self: *Manager, stream_id: []const u8) !void {
        const removed = self.streams.fetchRemove(stream_id) orelse return error.StreamNotFound;
        removed.value.close();
        self.alloc.free(removed.key);
    }

    pub fn write(self: *Manager, stream_id: []const u8, payload: []const u8) !usize {
        const stream = self.streams.get(stream_id) orelse return error.StreamNotFound;
        try stream.writeAll(payload);
        return payload.len;
    }

    pub fn read(self: *Manager, alloc: std.mem.Allocator, stream_id: []const u8, max_bytes: usize, timeout_ms: i32) !ReadResult {
        const stream = self.streams.get(stream_id) orelse return error.StreamNotFound;

        var poll_fds = [1]std.posix.pollfd{.{
            .fd = stream.handle,
            .events = std.posix.POLL.IN | std.posix.POLL.ERR | std.posix.POLL.HUP,
            .revents = 0,
        }};
        const ready = try std.posix.poll(&poll_fds, timeout_ms);
        if (ready == 0) {
            return .{
                .data = try alloc.dupe(u8, ""),
                .eof = false,
            };
        }

        const buffer = try alloc.alloc(u8, max_bytes);
        errdefer alloc.free(buffer);

        const read_len = stream.read(buffer) catch |err| switch (err) {
            error.WouldBlock => {
                alloc.free(buffer);
                return .{
                    .data = try alloc.dupe(u8, ""),
                    .eof = false,
                };
            },
            else => return err,
        };
        if (read_len == 0) {
            alloc.free(buffer);
            try self.close(stream_id);
            return .{
                .data = try alloc.dupe(u8, ""),
                .eof = true,
            };
        }

        const data = try alloc.dupe(u8, buffer[0..read_len]);
        alloc.free(buffer);
        return .{
            .data = data,
            .eof = false,
        };
    }
};
