const std = @import("std");
const cross = @import("cross.zig");
const terminal_session = @import("terminal_session.zig");

/// Global child PID registry for signal-safe cleanup. forkpty children
/// call setsid() so they're not in the daemon's process group. The
/// signal handler iterates this array to kill them on SIGTERM.
const max_children = 512;
var child_pids: [max_children]std.posix.pid_t = .{0} ** max_children;
var child_count: usize = 0;

pub fn registerChild(pid: std.posix.pid_t) void {
    if (child_count < max_children) {
        child_pids[child_count] = pid;
        child_count += 1;
    }
}

pub fn unregisterChild(pid: std.posix.pid_t) void {
    for (0..child_count) |i| {
        if (child_pids[i] == pid) {
            child_pids[i] = child_pids[child_count - 1];
            child_count -= 1;
            return;
        }
    }
}

/// Kill all registered child processes. Safe to call from signal handlers.
pub fn killAllChildren() void {
    for (0..child_count) |i| {
        const pid = child_pids[i];
        if (pid > 0) {
            _ = std.c.kill(pid, std.posix.SIG.KILL);
        }
    }
}

pub const PtyHost = struct {
    alloc: std.mem.Allocator,
    master_fd: std.posix.fd_t,
    master_open: bool = true,
    pid: std.posix.pid_t,
    closed: bool = false,

    pub fn init(alloc: std.mem.Allocator, command: []const u8, cols: u16, rows: u16) !PtyHost {
        const command_z = try alloc.dupeZ(u8, command);
        defer alloc.free(command_z);

        var winsize = cross.c.struct_winsize{
            .ws_row = @max(@as(u16, 1), rows),
            .ws_col = @max(@as(u16, 1), cols),
            .ws_xpixel = 0,
            .ws_ypixel = 0,
        };

        var master_fd: c_int = undefined;
        const pid = cross.forkpty(&master_fd, null, null, &winsize);
        if (pid < 0) return error.ForkPtyFailed;

        if (pid == 0) {
            const shell_path: [*:0]const u8 = "/bin/sh";
            const argv = [_:null]?[*:0]const u8{
                "/bin/sh",
                "-c",
                command_z,
                null,
            };
            const err = std.posix.execveZ(shell_path, &argv, std.c.environ);
            std.log.err("execve failed: {s}", .{@errorName(err)});
            std.posix.exit(127);
            unreachable;
        }

        const flags = try std.posix.fcntl(master_fd, std.posix.F.GETFL, 0);
        _ = try std.posix.fcntl(master_fd, std.posix.F.SETFL, flags | @as(u32, @bitCast(std.posix.O{ .NONBLOCK = true })));

        registerChild(pid);

        return .{
            .alloc = alloc,
            .master_fd = master_fd,
            .pid = pid,
        };
    }

    pub fn deinit(self: *PtyHost) void {
        if (self.master_open) {
            std.posix.close(self.master_fd);
            self.master_open = false;
        }
        self.markClosed();
        std.posix.kill(-self.pid, std.posix.SIG.HUP) catch {};
        std.posix.kill(self.pid, std.posix.SIG.HUP) catch {};
        std.posix.kill(-self.pid, std.posix.SIG.KILL) catch {};
        std.posix.kill(self.pid, std.posix.SIG.KILL) catch {};
        _ = std.posix.waitpid(self.pid, 0);
        unregisterChild(self.pid);
    }

    pub fn write(self: *PtyHost, data: []const u8) !void {
        var remaining = data;
        while (remaining.len > 0) {
            const written = std.posix.write(self.master_fd, remaining) catch |err| switch (err) {
                error.WouldBlock => {
                    try self.waitWritable();
                    continue;
                },
                else => return err,
            };
            if (written == 0) return;
            remaining = remaining[written..];
        }
    }

    pub fn writeDraining(self: *PtyHost, session: *terminal_session.TerminalSession, data: []const u8) !void {
        var remaining = data;
        while (remaining.len > 0) {
            const written = std.posix.write(self.master_fd, remaining) catch |err| switch (err) {
                error.WouldBlock => {
                    try self.waitWritableOrReadable();
                    try self.pump(session);
                    continue;
                },
                else => return err,
            };
            if (written == 0) return;
            remaining = remaining[written..];
            try self.pump(session);
        }
        try self.pump(session);
    }

    pub fn resize(self: *PtyHost, cols: u16, rows: u16) !void {
        var winsize = cross.c.struct_winsize{
            .ws_row = @max(@as(u16, 1), rows),
            .ws_col = @max(@as(u16, 1), cols),
            .ws_xpixel = 0,
            .ws_ypixel = 0,
        };
        if (cross.c.ioctl(self.master_fd, cross.c.TIOCSWINSZ, &winsize) != 0) {
            return error.ResizeFailed;
        }
    }

    pub fn waitReadable(self: *PtyHost, timeout_ms: i32) !bool {
        if (self.closed) return true;

        var fds = [1]std.posix.pollfd{.{
            .fd = self.master_fd,
            .events = std.posix.POLL.IN | std.posix.POLL.ERR | std.posix.POLL.HUP,
            .revents = 0,
        }};
        const ready = try std.posix.poll(&fds, timeout_ms);
        return ready > 0;
    }

    fn waitWritable(self: *PtyHost) !void {
        var fds = [1]std.posix.pollfd{.{
            .fd = self.master_fd,
            .events = std.posix.POLL.OUT | std.posix.POLL.ERR | std.posix.POLL.HUP,
            .revents = 0,
        }};
        _ = try std.posix.poll(&fds, -1);
    }

    fn waitWritableOrReadable(self: *PtyHost) !void {
        var fds = [1]std.posix.pollfd{.{
            .fd = self.master_fd,
            .events = std.posix.POLL.OUT | std.posix.POLL.IN | std.posix.POLL.ERR | std.posix.POLL.HUP,
            .revents = 0,
        }};
        _ = try std.posix.poll(&fds, -1);
    }

    pub fn pump(self: *PtyHost, session: *terminal_session.TerminalSession) !void {
        var buf: [32 * 1024]u8 = undefined;
        while (true) {
            const read_len = std.posix.read(self.master_fd, &buf) catch |err| switch (err) {
                error.WouldBlock => break,
                error.InputOutput, error.BrokenPipe => {
                    self.markClosed();
                    break;
                },
                else => return err,
            };
            if (read_len == 0) {
                self.markClosed();
                break;
            }
            try session.feed(buf[0..read_len]);
        }
    }

    pub fn isClosed(self: *const PtyHost) bool {
        return self.closed;
    }

    fn markClosed(self: *PtyHost) void {
        self.closed = true;
    }
};
