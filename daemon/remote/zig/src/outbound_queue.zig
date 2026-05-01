const std = @import("std");

/// Per-connection bounded outbound writer with a dedicated writer thread.
///
/// Two queues feed one fd:
///   - terminal: high-volume PTY push frames
///   - control:  RPC responses and workspace.changed pushes
///
/// Fairness rule: under sustained terminal output, at least one queued
/// control frame is delivered every `fairness_interval_ms` (default 100ms).
///
/// Backpressure: if an enqueue would push the combined queue above
/// `max_bytes` (default 4 MiB), the queue marks itself dead and shuts down
/// the underlying socket. The owner's reader thread will see EOF/EBADF on
/// its next read, run its disconnect cleanup, and then call `shutdown`
/// here to join the writer.
///
/// Ownership: enqueueX takes ownership of the slice on success (and frees
/// it once written). On failure (overflow / dead) the caller still owns
/// the slice and must free it.
pub const OutboundQueue = struct {
    alloc: std.mem.Allocator,
    fd: std.posix.fd_t,

    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},

    terminal_q: std.ArrayListUnmanaged([]u8) = .empty,
    control_q: std.ArrayListUnmanaged([]u8) = .empty,
    total_bytes: usize = 0,
    max_bytes: usize = 4 * 1024 * 1024,
    fairness_interval_ms: i64 = 100,
    last_control_ms: i64 = 0,

    closed: bool = false,
    dead: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

    pub fn init(alloc: std.mem.Allocator, fd: std.posix.fd_t) OutboundQueue {
        return .{
            .alloc = alloc,
            .fd = fd,
            .last_control_ms = std.time.milliTimestamp(),
        };
    }

    pub fn start(self: *OutboundQueue) !void {
        if (self.thread != null) return;
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    /// Drains the writer thread, frees any buffered payloads, and clears
    /// state. Does NOT close the fd (owner does that). Idempotent.
    pub fn shutdown(self: *OutboundQueue) void {
        self.mutex.lock();
        self.closed = true;
        self.cond.broadcast();
        self.mutex.unlock();

        if (self.thread) |t| t.join();
        self.thread = null;

        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.terminal_q.items) |item| self.alloc.free(item);
        for (self.control_q.items) |item| self.alloc.free(item);
        self.terminal_q.deinit(self.alloc);
        self.control_q.deinit(self.alloc);
        self.total_bytes = 0;
    }

    pub fn isDead(self: *OutboundQueue) bool {
        return self.dead.load(.seq_cst);
    }

    pub fn enqueueTerminal(self: *OutboundQueue, payload: []u8) !void {
        return self.enqueueLocked(payload, .terminal);
    }

    pub fn enqueueControl(self: *OutboundQueue, payload: []u8) !void {
        return self.enqueueLocked(payload, .control);
    }

    const Kind = enum { terminal, control };

    fn enqueueLocked(self: *OutboundQueue, payload: []u8, kind: Kind) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.dead.load(.seq_cst) or self.closed) return error.QueueClosed;
        if (self.total_bytes + payload.len > self.max_bytes) {
            // Backpressure: client too slow. Mark dead, shut down the socket
            // so the owner's reader unblocks and runs its cleanup.
            self.markDeadLocked();
            return error.QueueOverflow;
        }

        const list = switch (kind) {
            .terminal => &self.terminal_q,
            .control => &self.control_q,
        };
        try list.append(self.alloc, payload);
        self.total_bytes += payload.len;
        self.cond.signal();
    }

    fn markDeadLocked(self: *OutboundQueue) void {
        if (self.dead.swap(true, .seq_cst)) return;
        // Force the reader thread out of its blocking read so it can
        // tear down the connection.
        std.posix.shutdown(self.fd, .both) catch {};
        self.cond.broadcast();
    }

    fn run(self: *OutboundQueue) void {
        while (true) {
            self.mutex.lock();
            while (!self.dead.load(.seq_cst) and !self.closed and
                self.terminal_q.items.len == 0 and self.control_q.items.len == 0)
            {
                self.cond.wait(&self.mutex);
            }
            if (self.dead.load(.seq_cst) or self.closed) {
                self.mutex.unlock();
                return;
            }

            const now = std.time.milliTimestamp();
            const have_control = self.control_q.items.len > 0;
            const have_terminal = self.terminal_q.items.len > 0;
            const pick_control = have_control and (!have_terminal or
                (now - self.last_control_ms) >= self.fairness_interval_ms);

            var item: []u8 = undefined;
            if (pick_control) {
                item = self.control_q.orderedRemove(0);
                self.last_control_ms = now;
            } else if (have_terminal) {
                item = self.terminal_q.orderedRemove(0);
            } else {
                self.mutex.unlock();
                continue;
            }
            self.total_bytes -= item.len;
            self.mutex.unlock();

            writeAll(self.fd, item) catch |err| {
                // Socket dead. Mark ourselves dead so further enqueues fail
                // and the reader unblocks.
                std.log.warn("outbound queue write failed fd={d} bytes={d}: {s}", .{ self.fd, item.len, @errorName(err) });
                self.alloc.free(item);
                self.mutex.lock();
                self.markDeadLocked();
                self.mutex.unlock();
                return;
            };
            self.alloc.free(item);
        }
    }

    fn writeAll(fd: std.posix.fd_t, data: []const u8) !void {
        var written: usize = 0;
        while (written < data.len) {
            const n = try std.posix.write(fd, data[written..]);
            if (n == 0) return error.ConnectionClosed;
            written += n;
        }
    }
};

// --- Tests ---

test "fairness: control delivered while terminal floods" {
    var fds: [2]std.c.fd_t = undefined;
    if (std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &fds) != 0) {
        return error.SocketPairFailed;
    }
    defer std.posix.close(fds[1]);

    var q = OutboundQueue.init(std.testing.allocator, fds[0]);
    q.fairness_interval_ms = 50;
    try q.start();
    defer {
        q.shutdown();
        std.posix.close(fds[0]);
    }

    // Enqueue a flood of terminal frames + a few control frames mixed in.
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        const t = try std.fmt.allocPrint(std.testing.allocator, "T{d}\n", .{i});
        q.enqueueTerminal(t) catch std.testing.allocator.free(t);
        if (i % 40 == 0) {
            const c = try std.fmt.allocPrint(std.testing.allocator, "C{d}\n", .{i});
            q.enqueueControl(c) catch std.testing.allocator.free(c);
        }
        // tiny pacing so writer thread can interleave
        if (i % 20 == 0) std.Thread.sleep(2 * std.time.ns_per_ms);
    }

    // Drain the read side until both control markers seen.
    var buf: [8192]u8 = undefined;
    var accum: std.ArrayListUnmanaged(u8) = .empty;
    defer accum.deinit(std.testing.allocator);
    const deadline = std.time.milliTimestamp() + 3000;
    while (std.time.milliTimestamp() < deadline) {
        const n = std.posix.read(fds[1], &buf) catch break;
        if (n == 0) break;
        try accum.appendSlice(std.testing.allocator, buf[0..n]);
        if (std.mem.indexOf(u8, accum.items, "C0\n") != null and
            std.mem.indexOf(u8, accum.items, "C40\n") != null) break;
    }
    try std.testing.expect(std.mem.indexOf(u8, accum.items, "C0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, accum.items, "C40\n") != null);
}

test "backpressure: overflow marks queue dead and shuts socket" {
    var fds: [2]std.c.fd_t = undefined;
    if (std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &fds) != 0) {
        return error.SocketPairFailed;
    }
    defer std.posix.close(fds[0]);
    defer std.posix.close(fds[1]);

    var q = OutboundQueue.init(std.testing.allocator, fds[0]);
    q.max_bytes = 4096;
    // Don't start the writer so nothing drains.
    defer q.shutdown();

    // Fill the queue until enqueue overflows.
    var overflowed = false;
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        const buf = try std.testing.allocator.alloc(u8, 1024);
        @memset(buf, 'x');
        q.enqueueTerminal(buf) catch |err| {
            std.testing.allocator.free(buf);
            try std.testing.expectEqual(@as(anyerror, error.QueueOverflow), err);
            overflowed = true;
            break;
        };
    }
    try std.testing.expect(overflowed);
    try std.testing.expect(q.isDead());
}
