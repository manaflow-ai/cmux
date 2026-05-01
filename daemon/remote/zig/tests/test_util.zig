//! Test helpers for end-to-end integration tests against the Zig daemon.
//!
//! These helpers stand up a real `serve_unix`-shaped listener on a temp Unix
//! socket and connect real clients to it. They reuse the production
//! `session_service.Service` + `outbound_queue.OutboundQueue` + `server_core`
//! pieces in the same composition as `serve_unix.handleClient`. The accept
//! loop and per-connection thread are hand-rolled here because production's
//! `serve_unix.serve()` installs a process-wide signal handler, calls
//! `setpgid`, and never returns, none of which is compatible with an
//! in-process test.

const std = @import("std");

const cmuxd = @import("cmuxd_src");
const connection_attachments = cmuxd.connection_attachments;
const json_rpc = cmuxd.json_rpc;
const outbound_queue = cmuxd.outbound_queue;
const server_core = cmuxd.server_core;
const session_service = cmuxd.session_service;

// ---------------------------------------------------------------------------
// Server: in-process Unix socket listener wired up like serve_unix.handleClient
// ---------------------------------------------------------------------------

pub const Server = struct {
    alloc: std.mem.Allocator,
    socket_path: []const u8,
    service: *session_service.Service,
    listener_fd: std.posix.fd_t,
    accept_thread: ?std.Thread = null,
    shutdown_flag: std.atomic.Value(bool) = .init(false),

    workers_mutex: std.Thread.Mutex = .{},
    workers: std.ArrayListUnmanaged(*Worker) = .empty,

    pub fn start(
        alloc: std.mem.Allocator,
        service: *session_service.Service,
        socket_path: []const u8,
    ) !*Server {
        const self = try alloc.create(Server);
        errdefer alloc.destroy(self);

        std.fs.deleteFileAbsolute(socket_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };

        var unix_addr = try std.net.Address.initUnix(socket_path);
        const listener_fd = try std.posix.socket(
            std.posix.AF.UNIX,
            std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC,
            0,
        );
        errdefer std.posix.close(listener_fd);
        try std.posix.bind(listener_fd, &unix_addr.any, unix_addr.getOsSockLen());
        try std.posix.listen(listener_fd, 16);

        self.* = .{
            .alloc = alloc,
            .socket_path = socket_path,
            .service = service,
            .listener_fd = listener_fd,
        };
        self.accept_thread = try std.Thread.spawn(.{}, acceptLoop, .{self});
        return self;
    }

    pub fn deinit(self: *Server) void {
        const alloc = self.alloc;
        self.shutdown_flag.store(true, .seq_cst);
        std.posix.close(self.listener_fd);

        var snapshot: std.ArrayListUnmanaged(*Worker) = .empty;
        defer snapshot.deinit(alloc);

        self.workers_mutex.lock();
        snapshot.appendSlice(alloc, self.workers.items) catch {};
        self.workers_mutex.unlock();

        for (snapshot.items) |w| {
            // Direct syscall with unchecked errno. `std.posix.shutdown`
            // panics on errnos it doesn't recognize (e.g. EBADF if the
            // worker thread's `defer close` already fired), and under
            // ReleaseSafe that panic tears the whole process down.
            // Best-effort wake-up is all we need here.
            _ = std.c.shutdown(w.client_fd, std.c.SHUT.RDWR);
        }

        if (self.accept_thread) |t| t.join();

        for (snapshot.items) |w| {
            if (w.thread) |t| t.join();
            w.deinit();
            alloc.destroy(w);
        }

        self.workers_mutex.lock();
        self.workers.deinit(alloc);
        self.workers_mutex.unlock();

        std.fs.deleteFileAbsolute(self.socket_path) catch {};
        alloc.destroy(self);
    }

    fn acceptLoop(self: *Server) void {
        while (!self.shutdown_flag.load(.seq_cst)) {
            const client_fd = std.posix.accept(self.listener_fd, null, null, std.posix.SOCK.CLOEXEC) catch {
                return;
            };
            if (self.shutdown_flag.load(.seq_cst)) {
                std.posix.close(client_fd);
                return;
            }

            const worker = self.alloc.create(Worker) catch {
                std.posix.close(client_fd);
                continue;
            };
            worker.* = .{
                .alloc = self.alloc,
                .service = self.service,
                .client_fd = client_fd,
            };

            const t = std.Thread.spawn(.{}, Worker.run, .{worker}) catch {
                worker.deinit();
                self.alloc.destroy(worker);
                continue;
            };
            worker.thread = t;

            self.workers_mutex.lock();
            self.workers.append(self.alloc, worker) catch {};
            self.workers_mutex.unlock();
        }
    }
};

/// Mirror of serve_unix.handleClient: per-connection state + per-connection
/// outbound writer queue + RPC dispatch.
pub const Worker = struct {
    alloc: std.mem.Allocator,
    service: *session_service.Service,
    client_fd: std.posix.fd_t,
    thread: ?std.Thread = null,

    fn run(self: *Worker) void {
        defer std.posix.close(self.client_fd);

        var stream = std.net.Stream{ .handle = self.client_fd };

        var queue = outbound_queue.OutboundQueue.init(self.alloc, self.client_fd);
        queue.start() catch return;
        defer queue.shutdown();

        var workspace_subscribed = false;
        var attachments = connection_attachments.Tracker.init(self.alloc);
        defer attachments.deinit();
        defer attachments.detachAll(self.service);
        defer if (workspace_subscribed) self.service.subscriptions.remove(&stream);
        defer self.service.unsubscribeAllForStream(&stream);

        var write_mutex: std.Thread.Mutex = .{};

        var pending: std.ArrayListUnmanaged(u8) = .empty;
        defer pending.deinit(self.alloc);

        var read_buf: [64 * 1024]u8 = undefined;
        while (true) {
            if (queue.isDead()) return;
            const n = std.posix.read(self.client_fd, &read_buf) catch return;
            if (n == 0) return;

            pending.appendSlice(self.alloc, read_buf[0..n]) catch return;
            while (std.mem.indexOfScalar(u8, pending.items, '\n')) |newline_index| {
                self.handleLine(
                    &queue,
                    &stream,
                    &write_mutex,
                    &workspace_subscribed,
                    &attachments,
                    pending.items[0..newline_index],
                ) catch return;

                const remaining = pending.items[newline_index + 1 ..];
                std.mem.copyForwards(u8, pending.items[0..remaining.len], remaining);
                pending.items.len = remaining.len;
            }
        }
    }

    fn handleLine(
        self: *Worker,
        queue: *outbound_queue.OutboundQueue,
        stream: *std.net.Stream,
        write_mutex: *std.Thread.Mutex,
        workspace_subscribed: *bool,
        attachments: *connection_attachments.Tracker,
        raw_line: []const u8,
    ) !void {
        const trimmed = std.mem.trimRight(u8, raw_line, "\r");
        if (trimmed.len == 0) return;

        var req = json_rpc.decodeRequest(self.alloc, trimmed) catch {
            const resp = try json_rpc.encodeResponse(self.alloc, .{
                .ok = false,
                .@"error" = .{ .code = "invalid_request", .message = "invalid JSON request" },
            });
            return enqueueResponse(queue, self.alloc, resp);
        };
        defer req.deinit(self.alloc);

        if (std.mem.eql(u8, req.method, "terminal.subscribe")) {
            const resp = try self.handleTerminalSubscribe(queue, stream, write_mutex, &req);
            return enqueueResponse(queue, self.alloc, resp);
        }
        if (std.mem.eql(u8, req.method, "terminal.unsubscribe")) {
            const resp = try self.handleTerminalUnsubscribe(stream, &req);
            return enqueueResponse(queue, self.alloc, resp);
        }
        if (std.mem.eql(u8, req.method, "workspace.subscribe") and !workspace_subscribed.*) {
            self.service.subscriptions.addQueued(self.alloc, stream, queue) catch {};
            workspace_subscribed.* = true;
        }

        const response = try server_core.dispatch(self.service, &req);
        attachments.recordResponse(&req, response);
        return enqueueResponse(queue, self.alloc, response);
    }

    fn enqueueResponse(queue: *outbound_queue.OutboundQueue, alloc: std.mem.Allocator, payload: []u8) !void {
        const line = try alloc.alloc(u8, payload.len + 1);
        @memcpy(line[0..payload.len], payload);
        line[payload.len] = '\n';
        alloc.free(payload);
        queue.enqueueControl(line) catch |err| {
            alloc.free(line);
            return err;
        };
    }

    fn handleTerminalSubscribe(
        self: *Worker,
        queue: *outbound_queue.OutboundQueue,
        stream: *std.net.Stream,
        write_mutex: *std.Thread.Mutex,
        req: *const json_rpc.Request,
    ) ![]u8 {
        const alloc = self.alloc;
        const params_value = req.parsed.value.object.get("params") orelse {
            return errorResp(alloc, req.id, "invalid_params", "terminal.subscribe requires params");
        };
        if (params_value != .object) return errorResp(alloc, req.id, "invalid_params", "params must be object");
        const session_id_v = params_value.object.get("session_id") orelse {
            return errorResp(alloc, req.id, "invalid_params", "terminal.subscribe requires session_id");
        };
        if (session_id_v != .string) return errorResp(alloc, req.id, "invalid_params", "session_id must be string");
        const session_id = session_id_v.string;

        const requested_offset: ?u64 = blk: {
            const off_v = params_value.object.get("offset") orelse break :blk null;
            if (off_v != .integer) break :blk null;
            if (off_v.integer < 0) break :blk null;
            break :blk @intCast(off_v.integer);
        };

        const snap = self.service.subscribeTerminalQueued(stream, write_mutex, queue, session_id, requested_offset) catch |err| switch (err) {
            error.TerminalSessionNotFound => return errorResp(alloc, req.id, "not_found", "terminal session not found"),
            else => return errorResp(alloc, req.id, "internal_error", @errorName(err)),
        };
        defer alloc.free(snap.data);

        const enc_len = std.base64.standard.Encoder.calcSize(snap.data.len);
        const enc = try alloc.alloc(u8, enc_len);
        defer alloc.free(enc);
        _ = std.base64.standard.Encoder.encode(enc, snap.data);

        return try json_rpc.encodeResponse(alloc, .{
            .id = req.id,
            .ok = true,
            .result = .{
                .session_id = session_id,
                .seq = snap.seq,
                .offset = snap.offset,
                .base_offset = snap.base_offset,
                .truncated = snap.truncated,
                .eof = snap.eof,
                .data = enc,
            },
        });
    }

    fn handleTerminalUnsubscribe(
        self: *Worker,
        stream: *std.net.Stream,
        req: *const json_rpc.Request,
    ) ![]u8 {
        const alloc = self.alloc;
        const params_value = req.parsed.value.object.get("params") orelse {
            return errorResp(alloc, req.id, "invalid_params", "terminal.unsubscribe requires params");
        };
        if (params_value != .object) return errorResp(alloc, req.id, "invalid_params", "params must be object");
        const session_id_v = params_value.object.get("session_id") orelse {
            return errorResp(alloc, req.id, "invalid_params", "terminal.unsubscribe requires session_id");
        };
        if (session_id_v != .string) return errorResp(alloc, req.id, "invalid_params", "session_id must be string");

        const removed = self.service.unsubscribeTerminal(stream, session_id_v.string);
        return try json_rpc.encodeResponse(alloc, .{
            .id = req.id,
            .ok = true,
            .result = .{ .removed = removed },
        });
    }

    fn errorResp(alloc: std.mem.Allocator, id: ?std.json.Value, code: []const u8, message: []const u8) ![]u8 {
        return try json_rpc.encodeResponse(alloc, .{
            .id = id,
            .ok = false,
            .@"error" = .{ .code = code, .message = message },
        });
    }

    fn deinit(self: *Worker) void {
        _ = self;
    }
};

// ---------------------------------------------------------------------------
// Client: blocking line-delimited JSON-RPC client over a Unix socket
// ---------------------------------------------------------------------------

pub const Client = struct {
    alloc: std.mem.Allocator,
    fd: std.posix.fd_t,
    pending: std.ArrayListUnmanaged(u8) = .empty,
    /// Lines that were read from the socket but not consumed by the caller
    /// (e.g. non-matching frames that `awaitResponse` had to skip past to
    /// find its response). `readLine` drains this queue before splitting
    /// more bytes out of `pending`, so subsequent `readFrame` calls see
    /// those intermediate frames in the original wire order. Lines are
    /// allocator-owned slices taking the same form as `readLine`'s return.
    queued_lines: std.ArrayListUnmanaged([]u8) = .empty,
    next_id: u64 = 1,

    pub fn connect(alloc: std.mem.Allocator, socket_path: []const u8) !Client {
        var unix_addr = try std.net.Address.initUnix(socket_path);
        const fd = try std.posix.socket(
            std.posix.AF.UNIX,
            std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC,
            0,
        );
        errdefer std.posix.close(fd);
        try std.posix.connect(fd, &unix_addr.any, unix_addr.getOsSockLen());
        // Mark the fd non-blocking so `posix.read` cannot block past the
        // `waitReadable` poll deadline. Without this, a stale poll wakeup
        // (or a poll-timeout that the caller failed to check) would cause
        // readLine to hang forever instead of returning error.Timeout.
        const flags = try std.posix.fcntl(fd, std.posix.F.GETFL, 0);
        _ = try std.posix.fcntl(fd, std.posix.F.SETFL, flags | @as(u32, @bitCast(std.posix.O{ .NONBLOCK = true })));
        return .{ .alloc = alloc, .fd = fd };
    }

    pub fn deinit(self: *Client) void {
        std.posix.close(self.fd);
        self.pending.deinit(self.alloc);
        for (self.queued_lines.items) |line| self.alloc.free(line);
        self.queued_lines.deinit(self.alloc);
    }

    pub fn allocId(self: *Client) u64 {
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }

    pub fn sendLine(self: *Client, line: []const u8) !void {
        try self.writeAll(line);
        try self.writeAll("\n");
    }

    fn writeAll(self: *Client, data: []const u8) !void {
        var written: usize = 0;
        while (written < data.len) {
            const n = std.posix.write(self.fd, data[written..]) catch |err| switch (err) {
                error.WouldBlock => {
                    try waitWritable(self.fd, 2000);
                    continue;
                },
                else => return err,
            };
            if (n == 0) return error.ConnectionClosed;
            written += n;
        }
    }

    pub fn sendRequest(self: *Client, id: u64, method: []const u8, params: anytype) !void {
        const Wrap = struct {
            id: u64,
            method: []const u8,
            params: @TypeOf(params),
        };
        const wrapped: Wrap = .{ .id = id, .method = method, .params = params };
        var out: std.io.Writer.Allocating = .init(self.alloc);
        defer out.deinit();
        try std.json.Stringify.value(wrapped, .{}, &out.writer);
        try self.sendLine(out.written());
    }

    pub fn readLine(self: *Client, deadline_ms: i64) ![]u8 {
        if (self.queued_lines.items.len > 0) {
            return self.queued_lines.orderedRemove(0);
        }
        while (true) {
            if (std.mem.indexOfScalar(u8, self.pending.items, '\n')) |idx| {
                const line = try self.alloc.alloc(u8, idx);
                @memcpy(line, self.pending.items[0..idx]);
                const remaining = self.pending.items[idx + 1 ..];
                std.mem.copyForwards(u8, self.pending.items[0..remaining.len], remaining);
                self.pending.items.len = remaining.len;
                return line;
            }
            const remaining_ms = deadline_ms - std.time.milliTimestamp();
            if (remaining_ms <= 0) return error.Timeout;
            try waitReadable(self.fd, @intCast(@min(remaining_ms, 1000)));

            var buf: [16 * 1024]u8 = undefined;
            const n = std.posix.read(self.fd, &buf) catch |err| switch (err) {
                error.WouldBlock => continue,
                else => return err,
            };
            if (n == 0) return error.ConnectionClosed;
            try self.pending.appendSlice(self.alloc, buf[0..n]);
        }
    }

    pub fn readFrame(self: *Client, deadline_ms: i64) !std.json.Parsed(std.json.Value) {
        const line = try self.readLine(deadline_ms);
        defer self.alloc.free(line);
        return std.json.parseFromSlice(std.json.Value, self.alloc, line, .{});
    }

    /// Read frames until one matches `expected_id`. Any non-matching frames
    /// encountered along the way (typically `terminal.output` pushes that
    /// the daemon wrote between the request and its response) are preserved
    /// in the client's line queue in original wire order, so subsequent
    /// `readFrame` / `awaitResponse` calls still observe them.
    pub fn awaitResponse(
        self: *Client,
        expected_id: u64,
        deadline_ms: i64,
    ) !std.json.Parsed(std.json.Value) {
        var skipped: std.ArrayListUnmanaged([]u8) = .empty;
        // On any early exit, put skipped lines back at the head of the
        // queue so the caller still sees them.
        errdefer {
            for (skipped.items) |line| self.alloc.free(line);
            skipped.deinit(self.alloc);
        }
        while (true) {
            const line = try self.readLine(deadline_ms);
            var free_line = true;
            defer if (free_line) self.alloc.free(line);

            var parsed = std.json.parseFromSlice(std.json.Value, self.alloc, line, .{}) catch {
                try skipped.append(self.alloc, line);
                free_line = false;
                continue;
            };
            var keep_parsed = false;
            defer if (!keep_parsed) parsed.deinit();

            const matches = parsed.value == .object and blk: {
                const id_val = parsed.value.object.get("id") orelse break :blk false;
                break :blk idEquals(id_val, expected_id);
            };

            if (matches) {
                // Reinsert any skipped lines at the front of the queue,
                // preserving their relative order.
                if (skipped.items.len > 0) {
                    self.queued_lines.insertSlice(self.alloc, 0, skipped.items) catch |err| {
                        // On OOM, free the skipped lines so we don't leak.
                        for (skipped.items) |l| self.alloc.free(l);
                        skipped.deinit(self.alloc);
                        return err;
                    };
                    skipped.deinit(self.alloc);
                }
                keep_parsed = true;
                return parsed;
            }

            try skipped.append(self.alloc, line);
            free_line = false;
        }
    }
};

pub fn idEquals(value: std.json.Value, expected: u64) bool {
    return switch (value) {
        .integer => |i| i >= 0 and @as(u64, @intCast(i)) == expected,
        .number_string => |s| (std.fmt.parseInt(u64, s, 10) catch return false) == expected,
        else => false,
    };
}

fn waitReadable(fd: std.posix.fd_t, timeout_ms: i32) !void {
    var pfd = [_]std.posix.pollfd{.{
        .fd = fd,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    _ = try std.posix.poll(&pfd, timeout_ms);
}

fn waitWritable(fd: std.posix.fd_t, timeout_ms: i32) !void {
    var pfd = [_]std.posix.pollfd{.{
        .fd = fd,
        .events = std.posix.POLL.OUT,
        .revents = 0,
    }};
    _ = try std.posix.poll(&pfd, timeout_ms);
}

pub fn uniqueSocketPath(alloc: std.mem.Allocator, label: []const u8) ![]u8 {
    const ts: u64 = @intCast(std.time.nanoTimestamp());
    return std.fmt.allocPrint(alloc, "/tmp/cmuxd-itest-{s}-{x}.sock", .{ label, ts });
}

pub fn base64Encode(alloc: std.mem.Allocator, data: []const u8) ![]u8 {
    const len = std.base64.standard.Encoder.calcSize(data.len);
    const out = try alloc.alloc(u8, len);
    _ = std.base64.standard.Encoder.encode(out, data);
    return out;
}

pub fn base64Decode(alloc: std.mem.Allocator, encoded: []const u8) ![]u8 {
    const len = std.base64.standard.Decoder.calcSizeForSlice(encoded) catch return error.InvalidBase64;
    const out = try alloc.alloc(u8, len);
    std.base64.standard.Decoder.decode(out, encoded) catch {
        alloc.free(out);
        return error.InvalidBase64;
    };
    return out;
}
