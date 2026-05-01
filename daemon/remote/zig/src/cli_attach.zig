const std = @import("std");
const cross = @import("cross.zig");
const json_rpc = @import("json_rpc.zig");
const rpc_client = @import("rpc_client.zig");
const tty_raw = @import("tty_raw.zig");

const Size = struct {
    cols: u16,
    rows: u16,
};

const default_size = Size{ .cols = 80, .rows = 24 };
// Idle wake interval. Used as a fallback to notice tty resizes while idle.
// Pure event-driven wakeups would require SIGWINCH self-pipe; this keeps CPU
// at ~0% while still picking up size changes within a few hundred ms.
const idle_poll_timeout_ms: i32 = 250;

const InputPlan = struct {
    write_len: usize,
    next_pending_len: usize,
    detach: bool,
};

const SubscribeSnapshot = struct {
    data: []u8,
    eof: bool,
};

const FrameOutcome = struct {
    eof: bool = false,
};

pub fn run(alloc: std.mem.Allocator, socket_path: []const u8, session_name: []const u8, stderr: anytype) !u8 {
    var client = rpc_client.Client.init(alloc, socket_path);
    defer client.deinit();
    const stdin_fd = std.fs.File.stdin().handle;
    const stdout_file = std.fs.File.stdout();
    var stdout_nonblocking = try NonBlockingFd.enter(stdout_file.handle);
    defer stdout_nonblocking.deinit();
    var trace = try AttachTrace.init(alloc);
    defer trace.deinit();
    const fallback_size = try statusSize(&client, session_name, stderr);
    const size = currentAttachSizeWithTrace(fallback_size, &trace);
    const attachment_id = try std.fmt.allocPrint(alloc, "cli-{d}", .{cross.c.getpid()});
    defer alloc.free(attachment_id);

    try trace.log("attach_start", .{
        .hypothesis_id = "h2",
        .session_id = session_name,
        .attachment_id = attachment_id,
        .cols = size.cols,
        .rows = size.rows,
        .detail = "initial attach size",
    });
    try attachSession(&client, session_name, attachment_id, size.cols, size.rows, stderr);

    var guard = try tty_raw.RestoreGuard.enter(stdin_fd);
    defer guard.deinit();
    defer detachSession(&client, session_name, attachment_id, stderr) catch {};

    var pending_output: std.ArrayList(u8) = .empty;
    defer pending_output.deinit(alloc);

    // Subscribe with no offset → snapshot is empty (start from current next_offset).
    const snapshot = try subscribeTerminal(alloc, &client, session_name, stderr);
    defer alloc.free(snapshot.data);
    if (snapshot.data.len > 0) {
        try pending_output.appendSlice(alloc, snapshot.data);
    }
    try flushPendingOutput(stdout_file.handle, &pending_output, &trace, session_name);
    if (snapshot.eof) return 0;

    // Take ownership of the socket fd; rpc_client.Client still owns close on
    // deinit, but we drive reads/writes directly from here on out so we can
    // multiplex with stdin via poll().
    const sock_fd = client.file.?.handle;

    var request_id: u64 = 100;
    var last_size = size;
    var pending_detach: [tty_raw.max_detach_prefix_bytes]u8 = undefined;
    var pending_detach_len: usize = 0;
    var input_buf: [4096 + tty_raw.max_detach_prefix_bytes]u8 = undefined;
    var read_accum: std.ArrayList(u8) = .empty;
    defer read_accum.deinit(alloc);
    var read_buf: [16 * 1024]u8 = undefined;

    while (true) {
        const desired_size = currentAttachSizeWithTrace(last_size, &trace);
        if (desired_size.cols != last_size.cols or desired_size.rows != last_size.rows) {
            try trace.log("resize_sent", .{
                .hypothesis_id = "h2",
                .session_id = session_name,
                .attachment_id = attachment_id,
                .cols = desired_size.cols,
                .rows = desired_size.rows,
                .detail = "client observed tty resize",
            });
            request_id += 1;
            try sendResize(alloc, sock_fd, request_id, session_name, attachment_id, desired_size.cols, desired_size.rows);
            last_size = desired_size;
        }

        try flushPendingOutput(stdout_file.handle, &pending_output, &trace, session_name);

        var poll_fds = [_]std.posix.pollfd{
            .{ .fd = stdin_fd, .events = std.posix.POLL.IN, .revents = 0 },
            .{ .fd = sock_fd, .events = std.posix.POLL.IN, .revents = 0 },
        };
        const timeout_ms: i32 = if (pending_output.items.len > 0) 0 else idle_poll_timeout_ms;
        _ = try std.posix.poll(&poll_fds, timeout_ms);

        const sock_revents = poll_fds[1].revents;
        if (sock_revents & std.posix.POLL.IN != 0) {
            const n = std.posix.read(sock_fd, &read_buf) catch |err| switch (err) {
                error.WouldBlock => 0,
                else => return err,
            };
            if (n == 0) return 0; // socket closed
            try read_accum.appendSlice(alloc, read_buf[0..n]);
            var saw_eof = false;
            while (std.mem.indexOfScalar(u8, read_accum.items, '\n')) |nl| {
                if (handleSocketLine(alloc, read_accum.items[0..nl], &pending_output, stderr)) |outcome| {
                    if (outcome.eof) saw_eof = true;
                } else |err| {
                    try stderr.print("cmux: bad daemon frame: {s}\n", .{@errorName(err)});
                    try stderr.flush();
                }
                const remaining = read_accum.items[nl + 1 ..];
                std.mem.copyForwards(u8, read_accum.items[0..remaining.len], remaining);
                read_accum.items.len = remaining.len;
            }
            try flushPendingOutput(stdout_file.handle, &pending_output, &trace, session_name);
            if (saw_eof) return 0;
        } else if ((sock_revents & (std.posix.POLL.HUP | std.posix.POLL.ERR | std.posix.POLL.NVAL)) != 0) {
            return 0;
        }

        const stdin_revents = poll_fds[0].revents;
        if (stdin_revents & std.posix.POLL.IN != 0) {
            pending_detach_len = try drainAndWriteInput(
                alloc,
                sock_fd,
                &request_id,
                session_name,
                stdin_fd,
                &input_buf,
                &pending_detach,
                pending_detach_len,
                &trace,
            ) orelse return 0;
        } else if ((stdin_revents & (std.posix.POLL.HUP | std.posix.POLL.ERR | std.posix.POLL.NVAL)) != 0) {
            return 0;
        }
    }
}

fn handleSocketLine(
    alloc: std.mem.Allocator,
    line: []const u8,
    pending_output: *std.ArrayList(u8),
    stderr: anytype,
) !FrameOutcome {
    if (line.len == 0) return .{};
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, line, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidResponse;
    const obj = parsed.value.object;

    if (obj.get("event")) |event_val| {
        if (event_val == .string and std.mem.eql(u8, event_val.string, "terminal.output")) {
            const data_val = obj.get("data") orelse return .{};
            if (data_val != .string) return error.InvalidResponse;
            const encoded = data_val.string;
            const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(encoded) catch return error.InvalidResponse;
            if (decoded_len > 0) {
                const decoded = try alloc.alloc(u8, decoded_len);
                defer alloc.free(decoded);
                std.base64.standard.Decoder.decode(decoded, encoded) catch return error.InvalidResponse;
                try pending_output.appendSlice(alloc, decoded);
            }
            const eof = if (obj.get("eof")) |v| (v == .bool and v.bool) else false;
            return .{ .eof = eof };
        }
        // Unknown event — ignore. Notifications field intentionally not surfaced
        // by the CLI.
        return .{};
    }

    // Response to one of our async writes (terminal.write / session.resize).
    if (obj.get("ok")) |ok_val| {
        if (ok_val == .bool and !ok_val.bool) {
            if (obj.get("error")) |err_obj| {
                if (err_obj == .object) {
                    if (err_obj.object.get("message")) |m| {
                        if (m == .string) {
                            try stderr.print("cmux: {s}\n", .{m.string});
                            try stderr.flush();
                        }
                    }
                }
            }
        }
    }
    return .{};
}

fn sendRequestLine(alloc: std.mem.Allocator, fd: std.posix.fd_t, request: anytype) !void {
    const json = try json_rpc.encodeResponse(alloc, request);
    defer alloc.free(json);
    var iov = [_]std.posix.iovec_const{
        .{ .base = json.ptr, .len = json.len },
        .{ .base = "\n", .len = 1 },
    };
    var off: usize = 0;
    const total = json.len + 1;
    while (off < total) {
        const n = try std.posix.writev(fd, iov[0..]);
        if (n == 0) return error.BrokenPipe;
        off += n;
        // Adjust iov for partial writes.
        var consumed = n;
        var i: usize = 0;
        while (consumed > 0 and i < iov.len) {
            if (iov[i].len <= consumed) {
                consumed -= iov[i].len;
                iov[i].len = 0;
                i += 1;
            } else {
                iov[i].base = iov[i].base + consumed;
                iov[i].len -= consumed;
                consumed = 0;
            }
        }
        if (off >= total) break;
    }
}

fn sendWrite(alloc: std.mem.Allocator, fd: std.posix.fd_t, id: u64, session_name: []const u8, data: []const u8) !void {
    const enc_len = std.base64.standard.Encoder.calcSize(data.len);
    const enc = try alloc.alloc(u8, enc_len);
    defer alloc.free(enc);
    _ = std.base64.standard.Encoder.encode(enc, data);
    try sendRequestLine(alloc, fd, .{
        .id = id,
        .method = "terminal.write",
        .params = .{
            .session_id = session_name,
            .data = enc,
        },
    });
}

fn sendResize(alloc: std.mem.Allocator, fd: std.posix.fd_t, id: u64, session_name: []const u8, attachment_id: []const u8, cols: u16, rows: u16) !void {
    try sendRequestLine(alloc, fd, .{
        .id = id,
        .method = "session.resize",
        .params = .{
            .session_id = session_name,
            .attachment_id = attachment_id,
            .cols = cols,
            .rows = rows,
        },
    });
}

const NonBlockingFd = struct {
    fd: std.posix.fd_t,
    original_flags: usize,
    active: bool = false,

    fn enter(fd: std.posix.fd_t) !NonBlockingFd {
        const original_flags = try std.posix.fcntl(fd, std.posix.F.GETFL, 0);
        _ = try std.posix.fcntl(fd, std.posix.F.SETFL, original_flags | @as(u32, @bitCast(std.posix.O{ .NONBLOCK = true })));
        return .{
            .fd = fd,
            .original_flags = original_flags,
            .active = true,
        };
    }

    fn deinit(self: *NonBlockingFd) void {
        if (!self.active) return;
        _ = std.posix.fcntl(self.fd, std.posix.F.SETFL, self.original_flags) catch {};
        self.active = false;
    }
};

const TraceEvent = struct {
    hypothesis_id: []const u8,
    session_id: ?[]const u8 = null,
    attachment_id: ?[]const u8 = null,
    probe: ?[]const u8 = null,
    detail: ?[]const u8 = null,
    cols: ?u16 = null,
    rows: ?u16 = null,
    payload_len: ?usize = null,
    elapsed_ms: ?i64 = null,
};

const AttachTrace = struct {
    file: ?std.fs.File = null,
    path: ?[]u8 = null,
    seq: u64 = 0,
    alloc: std.mem.Allocator,

    fn init(alloc: std.mem.Allocator) !AttachTrace {
        const path = std.process.getEnvVarOwned(alloc, "CMUXD_ATTACH_TRACE_PATH") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => return .{ .alloc = alloc },
            else => return err,
        };
        errdefer alloc.free(path);

        var file = try std.fs.createFileAbsolute(path, .{ .truncate = true });
        try file.writeAll("");
        return .{
            .file = file,
            .path = path,
            .alloc = alloc,
        };
    }

    fn deinit(self: *AttachTrace) void {
        if (self.file) |*file| file.close();
        if (self.path) |path| self.alloc.free(path);
        self.* = .{ .alloc = self.alloc };
    }

    fn log(self: *AttachTrace, name: []const u8, event: TraceEvent) !void {
        if (self.file == null) return;
        self.seq += 1;
        const file = &self.file.?;
        var output_buf: [1024]u8 = undefined;
        var output_writer = file.writer(&output_buf);
        const writer = &output_writer.interface;
        try writer.print(
            "{{\"seq\":{d},\"name\":\"{s}\",\"mono_ms\":{d},\"hypothesis_id\":\"{s}\"",
            .{ self.seq, name, std.time.milliTimestamp(), event.hypothesis_id },
        );
        if (event.session_id) |value| try writer.print(",\"session_id\":\"{s}\"", .{value});
        if (event.attachment_id) |value| try writer.print(",\"attachment_id\":\"{s}\"", .{value});
        if (event.probe) |value| try writer.print(",\"probe\":\"{s}\"", .{value});
        if (event.detail) |value| try writer.print(",\"detail\":\"{s}\"", .{value});
        if (event.cols) |value| try writer.print(",\"cols\":{d}", .{value});
        if (event.rows) |value| try writer.print(",\"rows\":{d}", .{value});
        if (event.payload_len) |value| try writer.print(",\"payload_len\":{d}", .{value});
        if (event.elapsed_ms) |value| try writer.print(",\"elapsed_ms\":{d}", .{value});
        try writer.writeAll("}\n");
        try writer.flush();
        try file.sync();
    }
};

fn attachSession(client: *rpc_client.Client, session_name: []const u8, attachment_id: []const u8, cols: u16, rows: u16, stderr: anytype) !void {
    var response = try call(client, .{
        .id = "1",
        .method = "session.attach",
        .params = .{
            .session_id = session_name,
            .attachment_id = attachment_id,
            .cols = cols,
            .rows = rows,
        },
    }, stderr);
    response.deinit();
}

fn detachSession(client: *rpc_client.Client, session_name: []const u8, attachment_id: []const u8, stderr: anytype) !void {
    var response = try call(client, .{
        .id = "1",
        .method = "session.detach",
        .params = .{
            .session_id = session_name,
            .attachment_id = attachment_id,
        },
    }, stderr);
    response.deinit();
}

fn subscribeTerminal(alloc: std.mem.Allocator, client: *rpc_client.Client, session_name: []const u8, stderr: anytype) !SubscribeSnapshot {
    var response = try call(client, .{
        .id = "1",
        .method = "terminal.subscribe",
        .params = .{ .session_id = session_name },
    }, stderr);
    defer response.deinit();
    const result = response.value.object.get("result") orelse return error.InvalidResponse;
    if (result != .object) return error.InvalidResponse;
    const data_val = result.object.get("data") orelse return error.InvalidResponse;
    if (data_val != .string) return error.InvalidResponse;
    const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(data_val.string) catch return error.InvalidResponse;
    const decoded = try alloc.alloc(u8, decoded_len);
    errdefer alloc.free(decoded);
    std.base64.standard.Decoder.decode(decoded, data_val.string) catch return error.InvalidResponse;
    const eof_val = result.object.get("eof");
    const eof = if (eof_val) |v| (v == .bool and v.bool) else false;
    return .{ .data = decoded, .eof = eof };
}

fn statusSize(client: *rpc_client.Client, session_name: []const u8, stderr: anytype) !Size {
    var response = try call(client, .{
        .id = "1",
        .method = "session.status",
        .params = .{ .session_id = session_name },
    }, stderr);
    defer response.deinit();

    const result = response.value.object.get("result").?.object;
    return preferredAttachSize(.{
        .cols = try u16FromValue(result.get("effective_cols").?),
        .rows = try u16FromValue(result.get("effective_rows").?),
    }, default_size);
}

pub fn currentAttachSize(fallback: Size) Size {
    return currentAttachSizeWithTrace(fallback, null);
}

fn currentAttachSizeWithTrace(fallback: Size, maybe_trace: ?*AttachTrace) Size {
    if (observedLocalSize(maybe_trace)) |observed| {
        return preferredAttachSize(observed, fallback);
    }
    if (isUsableLocalSize(fallback)) return fallback;
    return default_size;
}

fn observedLocalSize(maybe_trace: ?*AttachTrace) ?Size {
    const stdin_fd = std.fs.File.stdin().handle;
    if (probeSize("stdin", stdin_fd, maybe_trace)) |size| return size;

    const stdout_fd = std.fs.File.stdout().handle;
    if (stdout_fd != stdin_fd) {
        if (probeSize("stdout", stdout_fd, maybe_trace)) |size| return size;
    }

    const stderr_fd = std.fs.File.stderr().handle;
    if (stderr_fd != stdin_fd and stderr_fd != stdout_fd) {
        if (probeSize("stderr", stderr_fd, maybe_trace)) |size| return size;
    }

    if (std.fs.openFileAbsolute("/dev/tty", .{ .mode = .read_write })) |tty| {
        defer tty.close();
        if (probeSize("tty", tty.handle, maybe_trace)) |size| return size;
    } else |_| {}

    return null;
}

fn probeSize(probe_name: []const u8, fd: std.posix.fd_t, maybe_trace: ?*AttachTrace) ?Size {
    const observed = tty_raw.currentSize(fd) catch |err| {
        if (maybe_trace) |trace| {
            trace.log("tty_probe", .{
                .hypothesis_id = "h2",
                .probe = probe_name,
                .detail = @errorName(err),
            }) catch {};
        }
        return null;
    };

    const size = Size{ .cols = observed.cols, .rows = observed.rows };
    if (maybe_trace) |trace| {
        trace.log("tty_probe", .{
            .hypothesis_id = "h2",
            .probe = probe_name,
            .cols = size.cols,
            .rows = size.rows,
            .detail = if (isUsableLocalSize(size)) "usable" else "too_small",
        }) catch {};
    }
    if (!isUsableLocalSize(size)) return null;
    return size;
}

fn flushPendingOutput(fd: std.posix.fd_t, pending_output: *std.ArrayList(u8), trace: *AttachTrace, session_name: []const u8) !void {
    while (pending_output.items.len > 0) {
        const written = std.posix.write(fd, pending_output.items) catch |err| switch (err) {
            error.WouldBlock => {
                try trace.log("stdout_backpressure", .{
                    .hypothesis_id = "h2",
                    .session_id = session_name,
                    .payload_len = pending_output.items.len,
                    .detail = "stdout_not_ready",
                });
                return;
            },
            else => return err,
        };
        if (written == 0) return;
        const remaining = pending_output.items[written..];
        std.mem.copyForwards(u8, pending_output.items[0..remaining.len], remaining);
        pending_output.items.len = remaining.len;
    }
}

fn drainAndWriteInput(
    alloc: std.mem.Allocator,
    sock_fd: std.posix.fd_t,
    request_id: *u64,
    session_name: []const u8,
    stdin_fd: std.posix.fd_t,
    input_buf: *[4096 + tty_raw.max_detach_prefix_bytes]u8,
    pending_detach: *[tty_raw.max_detach_prefix_bytes]u8,
    pending_detach_len: usize,
    trace: *AttachTrace,
) !?usize {
    if (pending_detach_len > 0) {
        @memcpy(input_buf[0..pending_detach_len], pending_detach[0..pending_detach_len]);
    }

    const read_len = try drainTTYInput(stdin_fd, input_buf[pending_detach_len..]);
    if (read_len == 0) {
        if (pending_detach_len > 0) {
            const write_started_ms = std.time.milliTimestamp();
            request_id.* += 1;
            try sendWrite(alloc, sock_fd, request_id.*, session_name, pending_detach[0..pending_detach_len]);
            try trace.log("write_result", .{
                .hypothesis_id = "h1",
                .session_id = session_name,
                .payload_len = pending_detach_len,
                .elapsed_ms = std.time.milliTimestamp() - write_started_ms,
                .detail = "flush_pending_on_eof",
            });
        }
        return null;
    }

    const total_len = pending_detach_len + read_len;
    const plan = planInput(input_buf[0..total_len]);
    if (plan.detach) {
        if (plan.write_len > 0) {
            const write_started_ms = std.time.milliTimestamp();
            request_id.* += 1;
            try sendWrite(alloc, sock_fd, request_id.*, session_name, input_buf[0..plan.write_len]);
            try trace.log("write_result", .{
                .hypothesis_id = "h1",
                .session_id = session_name,
                .payload_len = plan.write_len,
                .elapsed_ms = std.time.milliTimestamp() - write_started_ms,
                .detail = "flush_before_detach",
            });
        }
        return null;
    }

    if (plan.write_len > 0) {
        const write_started_ms = std.time.milliTimestamp();
        request_id.* += 1;
        try sendWrite(alloc, sock_fd, request_id.*, session_name, input_buf[0..plan.write_len]);
        try trace.log("write_result", .{
            .hypothesis_id = "h1",
            .session_id = session_name,
            .payload_len = plan.write_len,
            .elapsed_ms = std.time.milliTimestamp() - write_started_ms,
            .detail = "stdin_ready",
        });
    }

    if (plan.next_pending_len > 0) {
        @memcpy(pending_detach[0..plan.next_pending_len], input_buf[plan.write_len..total_len]);
    }
    return plan.next_pending_len;
}

fn planInput(input: []const u8) InputPlan {
    if (tty_raw.detachSequenceStart(input)) |detach_idx| {
        return .{
            .write_len = detach_idx,
            .next_pending_len = 0,
            .detach = true,
        };
    }

    const prefix_len = tty_raw.trailingDetachPrefixLen(input);
    return .{
        .write_len = input.len - prefix_len,
        .next_pending_len = prefix_len,
        .detach = false,
    };
}

fn drainTTYInput(fd: std.posix.fd_t, buf: []u8) !usize {
    if (buf.len == 0) return 0;

    var total = try std.posix.read(fd, buf);
    while (total > 0 and total < buf.len) {
        var poll_fds = [1]std.posix.pollfd{.{
            .fd = fd,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const ready = try std.posix.poll(&poll_fds, 0);
        if (ready == 0) break;

        const next = try std.posix.read(fd, buf[total..]);
        if (next == 0) break;
        total += next;
    }

    return total;
}

fn preferredAttachSize(observed: Size, fallback: Size) Size {
    if (isUsableLocalSize(observed)) return observed;
    if (isUsableLocalSize(fallback)) return fallback;
    return default_size;
}

fn isUsableLocalSize(size: Size) bool {
    return size.cols >= 4 and size.rows >= 2;
}

fn call(client: *rpc_client.Client, request: anytype, stderr: anytype) !std.json.Parsed(std.json.Value) {
    const request_json = try json_rpc.encodeResponse(client.alloc, request);
    defer client.alloc.free(request_json);

    var response = try client.call(request_json);
    const root = response.value;
    if (root != .object) return error.InvalidResponse;
    if ((root.object.get("ok") orelse return error.InvalidResponse) != .bool) return error.InvalidResponse;
    if (root.object.get("ok").?.bool) return response;

    const err_obj = root.object.get("error") orelse return error.InvalidResponse;
    if (err_obj != .object) return error.InvalidResponse;
    const message = err_obj.object.get("message") orelse return error.InvalidResponse;
    if (message != .string) return error.InvalidResponse;

    try stderr.print("{s}\n", .{message.string});
    try stderr.flush();
    response.deinit();
    return error.RemoteError;
}

fn u64FromValue(value: std.json.Value) !u64 {
    return switch (value) {
        .integer => |int| if (int >= 0) @intCast(int) else error.InvalidResponse,
        .float => |float| if (float >= 0 and @floor(float) == float) @as(u64, @intFromFloat(float)) else error.InvalidResponse,
        .number_string => |raw| std.fmt.parseInt(u64, raw, 10) catch error.InvalidResponse,
        else => error.InvalidResponse,
    };
}

fn u16FromValue(value: std.json.Value) !u16 {
    const raw = try u64FromValue(value);
    if (raw > std.math.maxInt(u16)) return error.InvalidResponse;
    return @intCast(raw);
}

test "preferred attach size uses local tty when sane" {
    const size = preferredAttachSize(.{ .cols = 120, .rows = 40 }, .{ .cols = 80, .rows = 24 });
    try std.testing.expectEqual(@as(u16, 120), size.cols);
    try std.testing.expectEqual(@as(u16, 40), size.rows);
}

test "preferred attach size falls back for tiny tty" {
    const size = preferredAttachSize(.{ .cols = 1, .rows = 1 }, .{ .cols = 80, .rows = 24 });
    try std.testing.expectEqual(@as(u16, 80), size.cols);
    try std.testing.expectEqual(@as(u16, 24), size.rows);
}

test "plan input buffers fragmented kitty ctrl backslash until detach" {
    var pending: [tty_raw.max_detach_prefix_bytes + 1]u8 = undefined;
    var pending_len: usize = 0;

    const sequence = "\x1b[92;5u";
    for (sequence, 0..) |byte, index| {
        pending[pending_len] = byte;
        const total_len = pending_len + 1;
        const plan = planInput(pending[0..total_len]);

        if (index + 1 < sequence.len) {
            try std.testing.expect(!plan.detach);
            try std.testing.expectEqual(@as(usize, 0), plan.write_len);
            try std.testing.expectEqual(total_len, plan.next_pending_len);
            pending_len = plan.next_pending_len;
            continue;
        }

        try std.testing.expect(plan.detach);
        try std.testing.expectEqual(@as(usize, 0), plan.write_len);
        try std.testing.expectEqual(@as(usize, 0), plan.next_pending_len);
    }
}
