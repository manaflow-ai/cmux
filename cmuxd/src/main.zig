const std = @import("std");
const builtin = @import("builtin");
const ghostty = @import("ghostty");
const terminal = ghostty.terminal;
const pty = ghostty.pty;

const posix = std.posix;
const base64 = std.base64;
const passwd_c = @cImport({
    @cInclude("sys/types.h");
    @cInclude("unistd.h");
    @cInclude("pwd.h");
});

const Allocator = std.mem.Allocator;

const magic_ws_guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

const server_capabilities = [_][]const u8{
    "sessions",
    "list_sessions",
    "attach_session",
    "new_session",
    "pane_scoping",
    "title_update",
    "cwd_update",
    "notify",
    "unix_socket",
    "ping",
};

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var args = std.process.args();
    _ = args.next();

    var use_stdio = false;
    var ws_addr: ?[]const u8 = null;
    var unix_path: ?[]const u8 = null;
    var cols: u16 = 80;
    var rows: u16 = 24;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--stdio")) {
            use_stdio = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--ws")) {
            const addr = args.next() orelse return usageError("--ws requires an address");
            ws_addr = addr;
            continue;
        }
        if (std.mem.eql(u8, arg, "--unix")) {
            const path = args.next() orelse return usageError("--unix requires a path");
            unix_path = path;
            continue;
        }
        if (std.mem.eql(u8, arg, "--cols")) {
            const v = args.next() orelse return usageError("--cols requires a value");
            cols = try std.fmt.parseInt(u16, v, 10);
            continue;
        }
        if (std.mem.eql(u8, arg, "--rows")) {
            const v = args.next() orelse return usageError("--rows requires a value");
            rows = try std.fmt.parseInt(u16, v, 10);
            continue;
        }
        return usageError("unknown argument");
    }

    if (!use_stdio and ws_addr == null and unix_path == null) {
        return usageError("must enable --stdio, --ws, or --unix");
    }

    var hub = try OutputHub.init(alloc);
    defer hub.deinit();

    const default_cwd = if (posix.getenv("CMUXD_DEFAULT_CWD")) |value|
        std.mem.sliceTo(value, 0)
    else
        null;
    const default_term = if (posix.getenv("CMUXD_DEFAULT_TERM")) |value|
        std.mem.sliceTo(value, 0)
    else
        null;
    var state = try ServerState.init(alloc, &hub, .{
        .cols = cols,
        .rows = rows,
        .cwd = default_cwd,
        .term = default_term,
    });
    defer state.deinit();

    var ws_thread: ?std.Thread = null;
    if (ws_addr) |addr| {
        ws_thread = try std.Thread.spawn(.{}, runWsServer, .{ alloc, state, &hub, addr });
    }
    var unix_thread: ?std.Thread = null;
    if (unix_path) |path| {
        unix_thread = try std.Thread.spawn(.{}, runUnixServer, .{ alloc, state, &hub, path });
    }

    if (use_stdio) {
        try runStdio(alloc, state, &hub);
    } else if (ws_thread) |t| {
        t.join();
    } else if (unix_thread) |t| {
        t.join();
    }
}

fn usageError(msg: []const u8) !void {
    std.debug.print("cmuxd: {s}\n\nusage: cmuxd (--stdio | --ws <addr> | --unix <path>) [--cols N] [--rows N]\n", .{msg});
    return error.InvalidArgs;
}

const OutputSink = struct {
    ctx: *anyopaque,
    send_output: *const fn (*anyopaque, SessionRef, []const u8) void,
    send_event: *const fn (*anyopaque, SessionRef, u32) void,
    send_title: *const fn (*anyopaque, SessionRef, []const u8) void,
    send_cwd: *const fn (*anyopaque, SessionRef, []const u8) void,
    send_notify: *const fn (*anyopaque, SessionRef, []const u8, []const u8) void,
};

const SessionRef = struct {
    session_id: [32]u8,
    pane_id: [32]u8,
};

const OutputHub = struct {
    alloc: Allocator,
    mutex: std.Thread.Mutex = .{},
    next_id: usize = 1,
    entries: std.ArrayList(Entry),

    const Entry = struct {
        id: usize,
        sink: OutputSink,
    };

    fn init(alloc: Allocator) !OutputHub {
        return .{
            .alloc = alloc,
            .entries = try std.ArrayList(Entry).initCapacity(alloc, 2),
        };
    }

    fn deinit(self: *OutputHub) void {
        self.entries.deinit(self.alloc);
    }

    fn add(self: *OutputHub, sink: OutputSink) !usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        const id = self.next_id;
        self.next_id += 1;
        try self.entries.append(self.alloc, .{ .id = id, .sink = sink });
        return id;
    }

    fn remove(self: *OutputHub, id: usize) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var i: usize = 0;
        while (i < self.entries.items.len) : (i += 1) {
            if (self.entries.items[i].id == id) {
                _ = self.entries.swapRemove(i);
                return;
            }
        }
    }

    fn sendOutput(self: *OutputHub, ref: SessionRef, data: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.entries.items) |entry| {
            entry.sink.send_output(entry.sink.ctx, ref, data);
        }
    }

    fn sendEvent(self: *OutputHub, ref: SessionRef, exit_code: u32) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.entries.items) |entry| {
            entry.sink.send_event(entry.sink.ctx, ref, exit_code);
        }
    }

    fn sendTitle(self: *OutputHub, ref: SessionRef, title: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.entries.items) |entry| {
            entry.sink.send_title(entry.sink.ctx, ref, title);
        }
    }

    fn sendCwd(self: *OutputHub, ref: SessionRef, cwd: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.entries.items) |entry| {
            entry.sink.send_cwd(entry.sink.ctx, ref, cwd);
        }
    }

    fn sendNotify(self: *OutputHub, ref: SessionRef, title: []const u8, body: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.entries.items) |entry| {
            entry.sink.send_notify(entry.sink.ctx, ref, title, body);
        }
    }
};

const PaneOptions = struct {
    cols: u16,
    rows: u16,
    cwd: ?[]const u8 = null,
    term: ?[]const u8 = null,
};

const ServerState = struct {
    alloc: Allocator,
    hub: *OutputHub,
    sessions_by_id: std.AutoHashMap([32]u8, *Session),
    sessions_by_pane: std.AutoHashMap([32]u8, *Session),
    default_session_id: [32]u8,
    mutex: std.Thread.Mutex = .{},

    fn init(alloc: Allocator, hub: *OutputHub, options: PaneOptions) !*ServerState {
        var state = try alloc.create(ServerState);
        errdefer alloc.destroy(state);
        state.* = .{
            .alloc = alloc,
            .hub = hub,
            .sessions_by_id = std.AutoHashMap([32]u8, *Session).init(alloc),
            .sessions_by_pane = std.AutoHashMap([32]u8, *Session).init(alloc),
            .default_session_id = undefined,
        };
        const session = try Session.create(alloc, hub, state, options);
        state.default_session_id = session.id;
        try state.sessions_by_id.put(session.id, session);
        try state.sessions_by_pane.put(session.pane_id, session);
        return state;
    }

    fn deinit(self: *ServerState) void {
        var it = self.sessions_by_id.valueIterator();
        while (it.next()) |session| {
            session.*.deinit();
        }
        self.sessions_by_id.deinit();
        self.sessions_by_pane.deinit();
        self.alloc.destroy(self);
    }

    fn getSessionByPane(self: *ServerState, pane_id: [32]u8) ?*Session {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.sessions_by_pane.get(pane_id);
    }

    fn getSessionById(self: *ServerState, session_id: [32]u8) ?*Session {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.sessions_by_id.get(session_id);
    }

    fn createPane(self: *ServerState, cols: u16, rows: u16) !*Session {
        self.mutex.lock();
        defer self.mutex.unlock();
        const session = try Session.create(self.alloc, self.hub, self, .{
            .cols = cols,
            .rows = rows,
        });
        try self.sessions_by_id.put(session.id, session);
        try self.sessions_by_pane.put(session.pane_id, session);
        return session;
    }

    fn createPaneWithOptions(self: *ServerState, options: PaneOptions) !*Session {
        self.mutex.lock();
        defer self.mutex.unlock();
        const session = try Session.create(self.alloc, self.hub, self, options);
        try self.sessions_by_id.put(session.id, session);
        try self.sessions_by_pane.put(session.pane_id, session);
        return session;
    }

    fn closePane(self: *ServerState, pane_id: [32]u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.sessions_by_pane.fetchRemove(pane_id)) |entry| {
            _ = self.sessions_by_id.fetchRemove(entry.value.id);
            entry.value.closing.store(true, .release);
            entry.value.deinit();
        }
    }

    fn queueClose(self: *ServerState, pane_id: [32]u8) void {
        const thread = std.Thread.spawn(.{}, closePaneThread, .{ self, pane_id }) catch {
            return;
        };
        thread.detach();
    }
};

fn closePaneThread(state: *ServerState, pane_id: [32]u8) void {
    state.closePane(pane_id);
}

const SessionStreamHandler = struct {
    readonly: terminal.ReadonlyHandler,
    session: *Session,

    pub fn init(session: *Session) SessionStreamHandler {
        return .{
            .readonly = terminal.ReadonlyHandler.init(&session.term),
            .session = session,
        };
    }

    pub fn deinit(self: *SessionStreamHandler) void {
        self.readonly.deinit();
    }

    pub fn vt(
        self: *SessionStreamHandler,
        comptime action: terminal.StreamAction.Tag,
        value: terminal.StreamAction.Value(action),
    ) !void {
        switch (action) {
            .window_title => self.session.updateTitle(value.title),
            .report_pwd => self.session.updateCwd(value.url),
            .show_desktop_notification => self.session.emitNotify(value.title, value.body),
            .color_operation => self.session.applyColorOperation(value.op, &value.requests),
            .full_reset => {
                self.session.resetDynamicColors();
                self.session.cursor_style_default = true;
            },
            .cursor_style => self.session.cursor_style_default = (value == .default),
            else => {},
        }
        try self.readonly.vt(action, value);
    }
};

const SessionStream = terminal.Stream(SessionStreamHandler);

const Session = struct {
    alloc: Allocator,
    state: *ServerState,
    id: [32]u8,
    pane_id: [32]u8,
    pty_handle: pty.Pty,
    pid: posix.pid_t,
    term: terminal.Terminal,
    stream: SessionStream,
    term_mutex: std.Thread.Mutex = .{},
    cols: u16,
    rows: u16,
    cwd: ?[]u8,
    title: ?[]u8,
    term_name: []u8,
    dynamic_fg: ?terminal.color.RGB = null,
    dynamic_bg: ?terminal.color.RGB = null,
    cursor_style_default: bool = true,
    closing: std.atomic.Value(bool),
    hub: *OutputHub,
    reader: std.Thread,

    fn create(alloc: Allocator, hub: *OutputHub, state: *ServerState, options: PaneOptions) !*Session {
        const id = randomId();
        const pane_id = randomId();

        const win = pty.winsize{
            .ws_row = options.rows,
            .ws_col = options.cols,
            .ws_xpixel = 0,
            .ws_ypixel = 0,
        };

        var handle = try pty.Pty.open(win);
        errdefer handle.deinit();

        const term_name = try alloc.dupe(u8, options.term orelse "xterm-ghostty");
        errdefer alloc.free(term_name);
        const cwd = if (options.cwd) |path| try alloc.dupe(u8, path) else null;
        errdefer if (cwd) |dir| alloc.free(dir);

        const pid = try spawnShell(&handle, cwd, term_name);
        posix.close(handle.slave);
        handle.slave = -1;

        const session = try alloc.create(Session);
        errdefer alloc.destroy(session);
        session.* = .{
            .alloc = alloc,
            .state = state,
            .id = id,
            .pane_id = pane_id,
            .pty_handle = handle,
            .pid = pid,
            .term = undefined,
            .stream = undefined,
            .cols = options.cols,
            .rows = options.rows,
            .cwd = cwd,
            .title = null,
            .term_name = term_name,
            .closing = std.atomic.Value(bool).init(false),
            .hub = hub,
            .reader = undefined,
        };

        session.term = try terminal.Terminal.init(alloc, .{
            .cols = options.cols,
            .rows = options.rows,
            .max_scrollback = 10_000,
        });
        errdefer session.term.deinit(alloc);

        session.stream = SessionStream.initAlloc(alloc, SessionStreamHandler.init(session));
        errdefer session.stream.deinit();

        session.reader = try std.Thread.spawn(.{}, readerThread, .{session});
        return session;
    }

    fn deinit(self: *Session) void {
        posix.close(self.pty_handle.master);
        self.reader.join();
        self.stream.deinit();
        self.term.deinit(self.alloc);
        if (self.cwd) |dir| {
            self.alloc.free(dir);
        }
        if (self.title) |value| {
            self.alloc.free(value);
        }
        self.alloc.free(self.term_name);
        self.alloc.destroy(self);
    }

    fn ref(self: *Session) SessionRef {
        return .{
            .session_id = self.id,
            .pane_id = self.pane_id,
        };
    }

    fn snapshot(self: *Session, alloc: Allocator) ![]u8 {
        self.term_mutex.lock();
        defer self.term_mutex.unlock();

        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();

        try out.writer.writeAll("\x1bc");

        const palette = &self.term.colors.palette;
        if (palette.mask.count() != 0) {
            var it = palette.mask.iterator(.{});
            while (it.next()) |idx| {
                const rgb = palette.current[idx];
                try out.writer.print(
                    "\x1b]4;{d};rgb:{x:0>2}/{x:0>2}/{x:0>2}\x1b\\",
                    .{ idx, rgb.r, rgb.g, rgb.b },
                );
            }
        }

        var opts: terminal.formatter.Options = .{
            .emit = .vt,
            .unwrap = false,
            .trim = false,
        };
        if (self.dynamic_fg) |fg| {
            opts.foreground = fg;
        }
        if (self.dynamic_bg) |bg| {
            opts.background = bg;
        }
        var formatter = terminal.formatter.TerminalFormatter.init(&self.term, opts);
        formatter.extra = .all;
        formatter.extra.palette = false;
        formatter.extra.tabstops = false;
        formatter.content = .{ .selection = null };
        try formatter.format(&out.writer);

        // Preserve the cursor shape so reconnects don't revert to block until next prompt.
        if (self.cursor_style_default) {
            try out.writer.writeAll("\x1b[0 q");
        } else {
            const blink = self.term.modes.get(.cursor_blinking);
            const cursor_style: u8 = switch (self.term.screens.active.cursor.cursor_style) {
                .block => if (blink) 1 else 2,
                .underline => if (blink) 3 else 4,
                .bar => if (blink) 5 else 6,
                // Map styles not representable by DECSCUSR to block.
                .block_hollow => if (blink) 1 else 2,
            };
            try out.writer.print("\x1b[{d} q", .{cursor_style});
        }

        return try out.toOwnedSlice();
    }

    fn resize(self: *Session, cols: u16, rows: u16) void {
        self.cols = cols;
        self.rows = rows;
        _ = self.pty_handle.setSize(.{ .ws_row = rows, .ws_col = cols, .ws_xpixel = 0, .ws_ypixel = 0 }) catch {};
        self.term_mutex.lock();
        _ = self.term.resize(self.alloc, cols, rows) catch {};
        self.term_mutex.unlock();
    }

    fn writeInput(self: *Session, data: []const u8) void {
        _ = posix.write(self.pty_handle.master, data) catch {};
    }

    fn processOutput(self: *Session, data: []const u8) void {
        self.term_mutex.lock();
        defer self.term_mutex.unlock();
        _ = self.stream.nextSlice(data) catch {};
    }

    fn applyColorOperation(
        self: *Session,
        op: terminal.osc.color.Operation,
        requests: *const terminal.osc.color.List,
    ) void {
        _ = op;
        if (requests.count() == 0) return;
        var it = requests.constIterator(0);
        while (it.next()) |req| {
            switch (req.*) {
                .set => |set| switch (set.target) {
                    .dynamic => |dynamic| switch (dynamic) {
                        .foreground => self.dynamic_fg = set.color,
                        .background => self.dynamic_bg = set.color,
                        else => {},
                    },
                    else => {},
                },
                .reset => |target| switch (target) {
                    .dynamic => |dynamic| switch (dynamic) {
                        .foreground => self.dynamic_fg = null,
                        .background => self.dynamic_bg = null,
                        else => {},
                    },
                    else => {},
                },
                else => {},
            }
        }
    }

    fn resetDynamicColors(self: *Session) void {
        self.dynamic_fg = null;
        self.dynamic_bg = null;
    }

    fn updateTitle(self: *Session, title: []const u8) void {
        if (self.closing.load(.acquire)) return;
        var copy: []u8 = undefined;
        self.state.mutex.lock();
        if (self.title) |old| {
            if (std.mem.eql(u8, old, title)) {
                self.state.mutex.unlock();
                return;
            }
            self.alloc.free(old);
        }
        copy = self.alloc.dupe(u8, title) catch {
            self.state.mutex.unlock();
            return;
        };
        self.title = copy;
        self.state.mutex.unlock();
        self.hub.sendTitle(self.ref(), copy);
    }

    fn updateCwd(self: *Session, cwd: []const u8) void {
        if (self.closing.load(.acquire)) return;
        var copy: []u8 = undefined;
        self.state.mutex.lock();
        if (self.cwd) |old| {
            if (std.mem.eql(u8, old, cwd)) {
                self.state.mutex.unlock();
                return;
            }
            self.alloc.free(old);
        }
        copy = self.alloc.dupe(u8, cwd) catch {
            self.state.mutex.unlock();
            return;
        };
        self.cwd = copy;
        self.state.mutex.unlock();
        self.hub.sendCwd(self.ref(), copy);
    }

    fn emitNotify(self: *Session, title: []const u8, body: []const u8) void {
        if (self.closing.load(.acquire)) return;
        self.hub.sendNotify(self.ref(), title, body);
    }
};

fn readerThread(session: *Session) void {
    var pollfds: [1]posix.pollfd = .{
        .{ .fd = session.pty_handle.master, .events = posix.POLL.IN, .revents = undefined },
    };
    var buf: [8192]u8 = undefined;
    var exit_code: ?u32 = null;
    while (true) {
        _ = posix.poll(&pollfds, 100) catch {
            exit_code = 0;
            break;
        };
        if (pollfds[0].revents & posix.POLL.IN != 0) {
            var n: usize = 0;
            if (posix.read(session.pty_handle.master, &buf)) |value| {
                n = value;
            } else |err| {
                switch (err) {
                    error.WouldBlock => continue,
                    error.InputOutput,
                    error.NotOpenForReading,
                    => {
                        const wait = posix.waitpid(session.pid, std.c.W.NOHANG);
                        if (wait.pid != 0) {
                            exit_code = if (posix.W.IFEXITED(wait.status))
                                posix.W.EXITSTATUS(wait.status)
                            else if (posix.W.IFSIGNALED(wait.status))
                                128 + posix.W.TERMSIG(wait.status)
                            else
                                wait.status;
                            break;
                        }
                        continue;
                    },
                    else => {
                        exit_code = 0;
                        break;
                    },
                }
            }
            if (exit_code != null) break;
            if (n == 0) {
                exit_code = 0;
                break;
            }
            const slice = buf[0..n];
            session.processOutput(slice);
            session.hub.sendOutput(session.ref(), slice);
        }

        const wait = posix.waitpid(session.pid, std.c.W.NOHANG);
        if (wait.pid != 0) {
            exit_code = if (posix.W.IFEXITED(wait.status))
                posix.W.EXITSTATUS(wait.status)
            else if (posix.W.IFSIGNALED(wait.status))
                128 + posix.W.TERMSIG(wait.status)
            else
                wait.status;
            break;
        }

        if (exit_code != null) break;

        if (pollfds[0].revents & posix.POLL.HUP != 0) {
            const result = posix.waitpid(session.pid, 0);
            exit_code = if (posix.W.IFEXITED(result.status))
                posix.W.EXITSTATUS(result.status)
            else if (posix.W.IFSIGNALED(result.status))
                128 + posix.W.TERMSIG(result.status)
            else
                result.status;
            break;
        }
    }

    if (exit_code) |code| {
        if (!session.closing.load(.acquire)) {
            session.hub.sendEvent(session.ref(), code);
            session.state.queueClose(session.pane_id);
        }
    }
}

const PasswdEntry = struct {
    name: ?[:0]const u8 = null,
    shell: ?[:0]const u8 = null,
    home: ?[:0]const u8 = null,
};

fn dirExists(path: []const u8) bool {
    if (std.fs.openDirAbsolute(path, .{})) |dir| {
        var mutable = dir;
        mutable.close();
        return true;
    } else |_| {
        return false;
    }
}

fn getPasswdEntry(alloc: Allocator) PasswdEntry {
    var buf: [1024]u8 = undefined;
    var pw: passwd_c.struct_passwd = undefined;
    var pw_ptr: ?*passwd_c.struct_passwd = null;
    const res = passwd_c.getpwuid_r(passwd_c.getuid(), &pw, &buf, buf.len, &pw_ptr);
    if (res != 0 or pw_ptr == null) return .{};
    var entry: PasswdEntry = .{};
    if (pw.pw_name) |ptr| {
        const value = std.mem.sliceTo(ptr, 0);
        entry.name = alloc.dupeZ(u8, value) catch null;
    }
    if (pw.pw_shell) |ptr| {
        const value = std.mem.sliceTo(ptr, 0);
        entry.shell = alloc.dupeZ(u8, value) catch null;
    }
    if (pw.pw_dir) |ptr| {
        const value = std.mem.sliceTo(ptr, 0);
        entry.home = alloc.dupeZ(u8, value) catch null;
    }
    return entry;
}

fn spawnShell(handle: *pty.Pty, cwd: ?[]const u8, term_name: []const u8) !posix.pid_t {
    const pid = try posix.fork();
    if (pid == 0) {
        _ = posix.dup2(handle.slave, posix.STDIN_FILENO) catch {};
        _ = posix.dup2(handle.slave, posix.STDOUT_FILENO) catch {};
        _ = posix.dup2(handle.slave, posix.STDERR_FILENO) catch {};

        const cwd_env = cwd;
        if (cwd) |dir| {
            _ = posix.chdir(dir) catch {};
        }

        var arena_allocator = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        defer arena_allocator.deinit();
        const arena = arena_allocator.allocator();

        var envmap = std.process.getEnvMap(arena) catch {
            posix.exit(1);
        };
        defer envmap.deinit();

        const passwd = getPasswdEntry(arena);
        const env_shell = posix.getenv("SHELL");
        const shell = env_shell orelse passwd.shell orelse "/bin/sh";
        if (envmap.get("SHELL") == null) {
            _ = envmap.put("SHELL", shell) catch {};
        }

        const shell_basename = std.fs.path.basename(shell);

        const username = posix.getenv("USER") orelse posix.getenv("LOGNAME") orelse passwd.name;
        if (username) |name| {
            if (envmap.get("USER") == null) {
                _ = envmap.put("USER", name) catch {};
            }
            if (envmap.get("LOGNAME") == null) {
                _ = envmap.put("LOGNAME", name) catch {};
            }
        }
        if (envmap.get("HOME") == null) {
            if (passwd.home) |home| {
                _ = envmap.put("HOME", home) catch {};
            }
        }
        if (cwd_env) |dir| {
            _ = envmap.put("PWD", dir) catch {};
        }

        _ = envmap.put("TERM", term_name) catch {};
        if (envmap.get("COLORTERM") == null) {
            _ = envmap.put("COLORTERM", "truecolor") catch {};
        }
        if (envmap.get("TERMINFO") == null) {
            if (posix.getenv("GHOSTTY_RESOURCES_DIR")) |dir| {
                const base = std.mem.sliceTo(dir, 0);
                var terminfo: ?[]const u8 = null;
                const direct = std.fmt.allocPrint(arena, "{s}/terminfo", .{base}) catch null;
                if (direct) |path| {
                    if (dirExists(path)) {
                        terminfo = path;
                    }
                }
                if (terminfo == null) {
                    if (std.fs.path.dirname(base)) |parent| {
                        const sibling = std.fmt.allocPrint(arena, "{s}/terminfo", .{parent}) catch null;
                        if (sibling) |path| {
                            if (dirExists(path)) {
                                terminfo = path;
                            }
                        }
                    }
                }
                if (terminfo) |path| {
                    _ = envmap.put("TERMINFO", path) catch {};
                }
            }
        }
        if (envmap.get("TERM_PROGRAM") == null) {
            _ = envmap.put("TERM_PROGRAM", "ghostty") catch {};
        }
        if (envmap.get("TERM_PROGRAM_VERSION") == null) {
            if (posix.getenv("TERM_PROGRAM_VERSION")) |value| {
                _ = envmap.put("TERM_PROGRAM_VERSION", std.mem.sliceTo(value, 0)) catch {};
            }
        }

        // Setup Ghostty shell integration env for cmuxd-launched shells.
        if (envmap.get("GHOSTTY_SHELL_FEATURES") == null) {
            _ = envmap.put("GHOSTTY_SHELL_FEATURES", "cursor,title,path") catch {};
        }
        if (posix.getenv("GHOSTTY_RESOURCES_DIR")) |dir| {
            const base = std.mem.sliceTo(dir, 0);
            const integ_path = std.fmt.allocPrint(arena, "{s}/shell-integration", .{base}) catch null;
            if (integ_path) |path| {
                if (dirExists(path)) {
                    if (envmap.get("GHOSTTY_SHELL_INTEGRATION_XDG_DIR") == null) {
                        _ = envmap.put("GHOSTTY_SHELL_INTEGRATION_XDG_DIR", path) catch {};
                    }
                    const existing = envmap.get("XDG_DATA_DIRS") orelse "/usr/local/share:/usr/share";
                    if (std.mem.indexOf(u8, existing, path) == null) {
                        const merged = std.fmt.allocPrint(arena, "{s}:{s}", .{ path, existing }) catch null;
                        if (merged) |value| {
                            _ = envmap.put("XDG_DATA_DIRS", value) catch {};
                        }
                    }
                }
            }

            if (std.mem.eql(u8, shell_basename, "zsh")) {
                const zsh_integ = std.fmt.allocPrint(arena, "{s}/shell-integration/zsh", .{base}) catch null;
                if (zsh_integ) |path| {
                    if (dirExists(path)) {
                        if (envmap.get("ZDOTDIR")) |old| {
                            _ = envmap.put("GHOSTTY_ZSH_ZDOTDIR", old) catch {};
                        }
                        _ = envmap.put("ZDOTDIR", path) catch {};
                    }
                }
            }
        }

        _ = envmap.put("CMUXD", "1") catch {};
        if (cwd) |dir| {
            _ = envmap.put("PWD", dir) catch {};
        }

        handle.childPreExec() catch {};

        const envp = (std.process.createNullDelimitedEnvMap(arena, &envmap) catch {
            posix.exit(1);
        }).ptr;
        if (builtin.os.tag.isDarwin()) {
            if (username != null) {
                const shell_slice = shell[0..shell.len];
                const exec_cmd = std.fmt.allocPrintSentinel(arena, "exec -l {s}", .{shell_slice}, 0) catch {
                    posix.exit(1);
                };
                const argv = [_:null]?[*:0]const u8{
                    "/usr/bin/login",
                    "-flp",
                    username.?,
                    "/bin/bash",
                    "--noprofile",
                    "--norc",
                    "-c",
                    exec_cmd,
                    null,
                };
                _ = posix.execvpeZ("/usr/bin/login", argv[0..], envp) catch {};
                posix.exit(1);
            }
        }

        const argv = [_:null]?[*:0]const u8{ shell, null };
        _ = posix.execvpeZ(shell, argv[0..], envp) catch {};
        posix.exit(1);
    }
    return pid;
}

fn randomId() [32]u8 {
    var bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&bytes);
    var out: [32]u8 = undefined;
    _ = std.fmt.bufPrint(out[0..], "{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{
        bytes[0], bytes[1], bytes[2], bytes[3],
        bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11],
        bytes[12], bytes[13], bytes[14], bytes[15],
    }) catch unreachable;
    return out;
}

const StdioSinkContext = struct {
    writer: *std.Io.Writer,
    mutex: *std.Thread.Mutex,
    ready: *std.atomic.Value(bool),
};

const ConnectionContext = struct {
    attached_session_id: [32]u8,
};

fn runStdio(alloc: Allocator, state: *ServerState, hub: *OutputHub) !void {
    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_writer.interface;
    var stdout_mutex = std.Thread.Mutex{};
    var ready = std.atomic.Value(bool).init(false);
    var conn_ctx = ConnectionContext{ .attached_session_id = state.default_session_id };

    var sink_ctx = StdioSinkContext{
        .writer = stdout,
        .mutex = &stdout_mutex,
        .ready = &ready,
    };
    const sink_id = try hub.add(.{
        .ctx = &sink_ctx,
        .send_output = sendStdioOutput,
        .send_event = sendStdioEvent,
        .send_title = sendStdioTitle,
        .send_cwd = sendStdioCwd,
        .send_notify = sendStdioNotify,
    });
    defer hub.remove(sink_id);

    var stdin_buf: [65536]u8 = undefined;
    var stdin_reader = std.fs.File.stdin().reader(&stdin_buf);
    const stdin = &stdin_reader.interface;

    while (true) {
        const line = (stdin.takeDelimiter('\n') catch |err| switch (err) {
            else => return err,
        }) orelse break;
        const trimmed = std.mem.trimRight(u8, line, "\r\n");
        if (trimmed.len == 0) continue;
        try handleMessage(alloc, state, &conn_ctx, stdout, &stdout_mutex, trimmed, &ready);
    }
}

fn writeJsonString(writer: anytype, value: []const u8) !void {
    try writer.writeByte('"');
    for (value) |c| {
        switch (c) {
            '\\' => try writer.writeAll("\\\\"),
            '"' => try writer.writeAll("\\\""),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0x08 => try writer.writeAll("\\b"),
            0x0C => try writer.writeAll("\\f"),
            else => {
                if (c < 0x20) {
                    try writer.print("\\u00{x:0>2}", .{c});
                } else {
                    try writer.writeByte(c);
                }
            },
        }
    }
    try writer.writeByte('"');
}

fn writeCapabilities(writer: anytype) !void {
    try writer.writeByte('[');
    for (server_capabilities, 0..) |cap, idx| {
        if (idx != 0) try writer.writeByte(',');
        try writeJsonString(writer, cap);
    }
    try writer.writeByte(']');
}

fn sendStdioOutput(ctx: *anyopaque, ref: SessionRef, data: []const u8) void {
    const c: *const StdioSinkContext = @ptrCast(@alignCast(ctx));
    if (!c.ready.load(.acquire)) return;
    c.mutex.lock();
    defer c.mutex.unlock();
    const b64 = encodeBase64(std.heap.c_allocator, data) catch return;
    defer std.heap.c_allocator.free(b64);
    _ = c.writer.print(
        "{{\"type\":\"output\",\"session_id\":\"{s}\",\"pane_id\":\"{s}\",\"data\":\"{s}\"}}\n",
        .{ ref.session_id, ref.pane_id, b64 },
    ) catch {};
    _ = c.writer.flush() catch {};
}

fn sendStdioEvent(ctx: *anyopaque, ref: SessionRef, exit_code: u32) void {
    const c: *const StdioSinkContext = @ptrCast(@alignCast(ctx));
    if (!c.ready.load(.acquire)) return;
    c.mutex.lock();
    defer c.mutex.unlock();
    _ = c.writer.print(
        "{{\"type\":\"pane_exited\",\"session_id\":\"{s}\",\"pane_id\":\"{s}\",\"exit_code\":{d}}}\n",
        .{ ref.session_id, ref.pane_id, exit_code },
    ) catch {};
    _ = c.writer.flush() catch {};
}

fn sendStdioTitle(ctx: *anyopaque, ref: SessionRef, title: []const u8) void {
    const c: *const StdioSinkContext = @ptrCast(@alignCast(ctx));
    if (!c.ready.load(.acquire)) return;
    c.mutex.lock();
    defer c.mutex.unlock();
    _ = c.writer.writeAll("{\"type\":\"title_update\",\"session_id\":\"") catch {};
    _ = c.writer.writeAll(ref.session_id[0..]) catch {};
    _ = c.writer.writeAll("\",\"pane_id\":\"") catch {};
    _ = c.writer.writeAll(ref.pane_id[0..]) catch {};
    _ = c.writer.writeAll("\",\"title\":") catch {};
    _ = writeJsonString(c.writer, title) catch {};
    _ = c.writer.writeAll("}\n") catch {};
    _ = c.writer.flush() catch {};
}

fn sendStdioCwd(ctx: *anyopaque, ref: SessionRef, cwd: []const u8) void {
    const c: *const StdioSinkContext = @ptrCast(@alignCast(ctx));
    if (!c.ready.load(.acquire)) return;
    c.mutex.lock();
    defer c.mutex.unlock();
    _ = c.writer.writeAll("{\"type\":\"cwd_update\",\"session_id\":\"") catch {};
    _ = c.writer.writeAll(ref.session_id[0..]) catch {};
    _ = c.writer.writeAll("\",\"pane_id\":\"") catch {};
    _ = c.writer.writeAll(ref.pane_id[0..]) catch {};
    _ = c.writer.writeAll("\",\"cwd\":") catch {};
    _ = writeJsonString(c.writer, cwd) catch {};
    _ = c.writer.writeAll("}\n") catch {};
    _ = c.writer.flush() catch {};
}

fn sendStdioNotify(ctx: *anyopaque, ref: SessionRef, title: []const u8, body: []const u8) void {
    const c: *const StdioSinkContext = @ptrCast(@alignCast(ctx));
    if (!c.ready.load(.acquire)) return;
    c.mutex.lock();
    defer c.mutex.unlock();
    _ = c.writer.writeAll("{\"type\":\"notify\",\"session_id\":\"") catch {};
    _ = c.writer.writeAll(ref.session_id[0..]) catch {};
    _ = c.writer.writeAll("\",\"pane_id\":\"") catch {};
    _ = c.writer.writeAll(ref.pane_id[0..]) catch {};
    _ = c.writer.writeAll("\",\"title\":") catch {};
    _ = writeJsonString(c.writer, title) catch {};
    _ = c.writer.writeAll(",\"body\":") catch {};
    _ = writeJsonString(c.writer, body) catch {};
    _ = c.writer.writeAll("}\n") catch {};
    _ = c.writer.flush() catch {};
}

fn handleMessage(
    alloc: Allocator,
    state: *ServerState,
    conn_ctx: *ConnectionContext,
    writer: *std.Io.Writer,
    mutex: *std.Thread.Mutex,
    line: []const u8,
    ready: ?*std.atomic.Value(bool),
) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, line, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    const type_val = obj.get("type") orelse return;
    const type_str = type_val.string;

    if (std.mem.eql(u8, type_str, "hello")) {
        const session = resolveSessionForConnection(state, conn_ctx, obj) orelse return;
        mutex.lock();
        defer mutex.unlock();
        try writer.print("{{\"type\":\"welcome\",\"version\":1,\"session_id\":\"{s}\",\"pane_id\":\"{s}\",\"capabilities\":", .{
            session.id,
            session.pane_id,
        });
        try writeCapabilities(writer);
        try writer.writeAll("}\n");
        try writer.flush();
        if (ready) |flag| {
            flag.store(true, .release);
        }
        return;
    }

    if (std.mem.eql(u8, type_str, "capabilities")) {
        mutex.lock();
        defer mutex.unlock();
        try writer.writeAll("{\"type\":\"capabilities\",\"capabilities\":");
        try writeCapabilities(writer);
        try writer.writeAll("}\n");
        try writer.flush();
        return;
    }

    if (std.mem.eql(u8, type_str, "list_sessions")) {
        mutex.lock();
        defer mutex.unlock();
        state.mutex.lock();
        defer state.mutex.unlock();
        try writer.writeAll("{\"type\":\"sessions\",\"sessions\":[");
        var first = true;
        var it = state.sessions_by_id.valueIterator();
        while (it.next()) |session| {
            if (!first) try writer.writeAll(",");
            first = false;
            try writer.writeAll("{\"session_id\":\"");
            try writer.writeAll(session.*.id[0..]);
            try writer.writeAll("\",\"pane_id\":\"");
            try writer.writeAll(session.*.pane_id[0..]);
            try writer.writeAll("\",\"title\":");
            if (session.*.title) |title| {
                try writeJsonString(writer, title);
            } else {
                try writeJsonString(writer, "");
            }
            try writer.writeAll(",\"cwd\":");
            if (session.*.cwd) |cwd| {
                try writeJsonString(writer, cwd);
            } else {
                try writeJsonString(writer, "");
            }
            try writer.writeAll("}");
        }
        try writer.writeAll("]}\n");
        try writer.flush();
        return;
    }

    if (std.mem.eql(u8, type_str, "attach_session")) {
        const session_id = sessionIdFromMessage(obj) orelse {
            mutex.lock();
            defer mutex.unlock();
            try writer.writeAll("{\"type\":\"error\",\"request\":\"attach_session\",\"message\":\"missing session_id\"}\n");
            try writer.flush();
            return;
        };
        if (state.getSessionById(session_id)) |session| {
            conn_ctx.attached_session_id = session_id;
            mutex.lock();
            defer mutex.unlock();
            try writer.print(
                "{{\"type\":\"session_attached\",\"session_id\":\"{s}\",\"pane_id\":\"{s}\"}}\n",
                .{ session.id, session.pane_id },
            );
            try writer.flush();
        } else {
            mutex.lock();
            defer mutex.unlock();
            try writer.writeAll("{\"type\":\"error\",\"request\":\"attach_session\",\"message\":\"unknown session\"}\n");
            try writer.flush();
        }
        return;
    }

    if (std.mem.eql(u8, type_str, "new_session")) {
        var cols: u16 = 80;
        var rows: u16 = 24;
        if (resolveSessionForConnection(state, conn_ctx, obj)) |current| {
            cols = current.cols;
            rows = current.rows;
        }
        if (obj.get("cols")) |cols_val| {
            cols = @intCast(cols_val.integer);
        }
        if (obj.get("rows")) |rows_val| {
            rows = @intCast(rows_val.integer);
        }
        var cwd: ?[]const u8 = null;
        if (obj.get("cwd")) |cwd_val| {
            cwd = cwd_val.string;
        } else if (obj.get("working_directory")) |cwd_val| {
            cwd = cwd_val.string;
        }
        const term = if (obj.get("term")) |term_val| term_val.string else null;
        const new_session = try state.createPaneWithOptions(.{
            .cols = cols,
            .rows = rows,
            .cwd = cwd,
            .term = term,
        });
        conn_ctx.attached_session_id = new_session.id;
        mutex.lock();
        defer mutex.unlock();
        try writer.print(
            "{{\"type\":\"session_created\",\"session_id\":\"{s}\",\"pane_id\":\"{s}\"}}\n",
            .{ new_session.id, new_session.pane_id },
        );
        try writer.flush();
        return;
    }

    const session = resolveSessionForConnection(state, conn_ctx, obj) orelse return;

    if (std.mem.eql(u8, type_str, "snapshot_request")) {
        const snap = try session.snapshot(alloc);
        defer alloc.free(snap);
        const b64 = try encodeBase64(alloc, snap);
        defer alloc.free(b64);
        mutex.lock();
        defer mutex.unlock();
        try writer.print(
            "{{\"type\":\"snapshot\",\"session_id\":\"{s}\",\"pane_id\":\"{s}\",\"cols\":{d},\"rows\":{d},\"data\":\"{s}\"}}\n",
            .{ session.id, session.pane_id, session.cols, session.rows, b64 },
        );
        try writer.flush();
        return;
    }

    if (std.mem.eql(u8, type_str, "input")) {
        const data_val = obj.get("data") orelse return;
        const decoded = try decodeBase64(alloc, data_val.string);
        defer alloc.free(decoded);
        session.writeInput(decoded);
        return;
    }

    if (std.mem.eql(u8, type_str, "resize")) {
        const cols_val = obj.get("cols") orelse return;
        const rows_val = obj.get("rows") orelse return;
        session.resize(@intCast(cols_val.integer), @intCast(rows_val.integer));
        return;
    }

    if (std.mem.eql(u8, type_str, "ping")) {
        mutex.lock();
        defer mutex.unlock();
        try writer.writeAll("{\"type\":\"pong\"}\n");
        try writer.flush();
        return;
    }

    if (std.mem.eql(u8, type_str, "new_pane")) {
        var cols = session.cols;
        var rows = session.rows;
        if (obj.get("cols")) |cols_val| {
            cols = @intCast(cols_val.integer);
        }
        if (obj.get("rows")) |rows_val| {
            rows = @intCast(rows_val.integer);
        }
        var cwd: ?[]const u8 = null;
        if (obj.get("cwd")) |cwd_val| {
            cwd = cwd_val.string;
        } else if (obj.get("working_directory")) |cwd_val| {
            cwd = cwd_val.string;
        }
        const term = if (obj.get("term")) |term_val| term_val.string else null;
        const new_session = try state.createPaneWithOptions(.{
            .cols = cols,
            .rows = rows,
            .cwd = cwd,
            .term = term,
        });
        conn_ctx.attached_session_id = new_session.id;
        mutex.lock();
        defer mutex.unlock();
        try writer.print(
            "{{\"type\":\"pane_created\",\"session_id\":\"{s}\",\"pane_id\":\"{s}\"}}\n",
            .{ new_session.id, new_session.pane_id },
        );
        try writer.flush();
        return;
    }

    if (std.mem.eql(u8, type_str, "close_pane")) {
        state.closePane(session.pane_id);
        return;
    }

    if (std.mem.eql(u8, type_str, "list_panes")) {
        const target_session = sessionIdFromMessage(obj);
        if (target_session) |session_id| {
            if (state.getSessionById(session_id)) |target| {
                mutex.lock();
                defer mutex.unlock();
                try writer.writeAll("{\"type\":\"panes\",\"panes\":[");
                try writer.print("{{\"session_id\":\"{s}\",\"pane_id\":\"{s}\"}}", .{ target.id, target.pane_id });
                try writer.writeAll("]}\n");
                try writer.flush();
            } else {
                mutex.lock();
                defer mutex.unlock();
                try writer.writeAll("{\"type\":\"panes\",\"panes\":[]}\n");
                try writer.flush();
            }
            return;
        }
        mutex.lock();
        defer mutex.unlock();
        state.mutex.lock();
        defer state.mutex.unlock();
        try writer.writeAll("{\"type\":\"panes\",\"panes\":[");
        var first = true;
        var it = state.sessions_by_id.valueIterator();
        while (it.next()) |session_entry| {
            if (!first) try writer.writeAll(",");
            first = false;
            try writer.print(
                "{{\"session_id\":\"{s}\",\"pane_id\":\"{s}\"}}",
                .{ session_entry.*.id, session_entry.*.pane_id },
            );
        }
        try writer.writeAll("]}\n");
        try writer.flush();
        return;
    }

    if (std.mem.eql(u8, type_str, "list_session_panes")) {
        const session_id = sessionIdFromMessage(obj) orelse return;
        if (state.getSessionById(session_id)) |target| {
            mutex.lock();
            defer mutex.unlock();
            try writer.writeAll("{\"type\":\"panes\",\"panes\":[");
            try writer.print("{{\"session_id\":\"{s}\",\"pane_id\":\"{s}\"}}", .{ target.id, target.pane_id });
            try writer.writeAll("]}\n");
            try writer.flush();
        }
        return;
    }
}

fn encodeBase64(alloc: Allocator, data: []const u8) ![]u8 {
    const size = base64.standard.Encoder.calcSize(data.len);
    const buf = try alloc.alloc(u8, size);
    _ = base64.standard.Encoder.encode(buf, data);
    return buf;
}

fn decodeBase64(alloc: Allocator, data: []const u8) ![]u8 {
    const size = try base64.standard.Decoder.calcSizeForSlice(data);
    const buf = try alloc.alloc(u8, size);
    try base64.standard.Decoder.decode(buf, data);
    return buf;
}

const WsSinkContext = struct {
    alloc: Allocator,
    writer: *std.Io.Writer,
    mutex: *std.Thread.Mutex,
    ready: *std.atomic.Value(bool),
};

fn runWsServer(alloc: Allocator, state: *ServerState, hub: *OutputHub, addr: []const u8) !void {
    const address = try parseListenAddress(addr);
    var server = try address.listen(.{ .reuse_address = true });
    defer server.deinit();

    while (true) {
        const conn = try server.accept();
        _ = std.Thread.spawn(.{}, handleWsConnectionThread, .{ state, hub, conn }) catch {
            _ = handleWsConnection(alloc, state, hub, conn) catch {};
        };
    }
}

fn runUnixServer(alloc: Allocator, state: *ServerState, hub: *OutputHub, path: []const u8) !void {
    removeUnixSocket(path);
    const address = try std.net.Address.initUnix(path);
    var server = try address.listen(.{});
    defer server.deinit();

    while (true) {
        const conn = try server.accept();
        _ = std.Thread.spawn(.{}, handleUnixConnectionThread, .{ state, hub, conn }) catch {
            _ = handleUnixConnection(alloc, state, hub, conn) catch {};
        };
    }
}

fn removeUnixSocket(path: []const u8) void {
    if (std.fs.path.isAbsolute(path)) {
        std.fs.deleteFileAbsolute(path) catch {};
    } else {
        std.fs.cwd().deleteFile(path) catch {};
    }
}

fn handleUnixConnectionThread(
    state: *ServerState,
    hub: *OutputHub,
    conn: std.net.Server.Connection,
) void {
    _ = handleUnixConnection(std.heap.c_allocator, state, hub, conn) catch {};
}

fn handleUnixConnection(
    alloc: Allocator,
    state: *ServerState,
    hub: *OutputHub,
    conn: std.net.Server.Connection,
) !void {
    defer conn.stream.close();

    var writer_buf: [4096]u8 = undefined;
    var writer = conn.stream.writer(&writer_buf);
    const writer_iface = &writer.interface;
    var writer_mutex = std.Thread.Mutex{};
    var ready = std.atomic.Value(bool).init(false);
    var conn_ctx = ConnectionContext{ .attached_session_id = state.default_session_id };
    var sink_ctx = StdioSinkContext{
        .writer = writer_iface,
        .mutex = &writer_mutex,
        .ready = &ready,
    };
    const sink_id = try hub.add(.{
        .ctx = &sink_ctx,
        .send_output = sendStdioOutput,
        .send_event = sendStdioEvent,
        .send_title = sendStdioTitle,
        .send_cwd = sendStdioCwd,
        .send_notify = sendStdioNotify,
    });
    defer hub.remove(sink_id);

    var reader_buf: [65536]u8 = undefined;
    var reader = conn.stream.reader(&reader_buf);
    const reader_iface = reader.interface();

    while (true) {
        const line = (reader_iface.takeDelimiter('\n') catch |err| switch (err) {
            else => return err,
        }) orelse break;
        const trimmed = std.mem.trimRight(u8, line, "\r\n");
        if (trimmed.len == 0) continue;
        try handleMessage(alloc, state, &conn_ctx, writer_iface, &writer_mutex, trimmed, &ready);
    }
}

fn handleWsConnectionThread(
    state: *ServerState,
    hub: *OutputHub,
    conn: std.net.Server.Connection,
) void {
    _ = handleWsConnection(std.heap.c_allocator, state, hub, conn) catch {};
}

fn parseListenAddress(addr: []const u8) !std.net.Address {
    var it = std.mem.splitScalar(u8, addr, ':');
    const host = it.next() orelse return error.InvalidAddress;
    const port_str = it.next() orelse return error.InvalidAddress;
    const port = try std.fmt.parseInt(u16, port_str, 10);
    return std.net.Address.parseIp(host, port);
}

fn handleWsConnection(
    alloc: Allocator,
    state: *ServerState,
    hub: *OutputHub,
    conn: std.net.Server.Connection,
) !void {
    defer conn.stream.close();

    const request = try readHttpRequest(alloc, conn.stream);
    defer alloc.free(request);

    const key = try parseWebSocketKey(request);
    var accept_buf: [28]u8 = undefined;
    const accept = computeWebSocketAccept(&accept_buf, key);

    var writer_buf: [4096]u8 = undefined;
    var writer = conn.stream.writer(&writer_buf);
    const writer_iface = &writer.interface;
    try writer_iface.print(
        "HTTP/1.1 101 Switching Protocols\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Accept: {s}\r\n\r\n",
        .{accept},
    );
    try writer_iface.flush();
    var writer_mutex = std.Thread.Mutex{};
    var ready = std.atomic.Value(bool).init(false);
    var conn_ctx = ConnectionContext{ .attached_session_id = state.default_session_id };
    var sink_ctx = WsSinkContext{
        .alloc = std.heap.c_allocator,
        .writer = writer_iface,
        .mutex = &writer_mutex,
        .ready = &ready,
    };
    const sink_id = try hub.add(.{
        .ctx = &sink_ctx,
        .send_output = sendWsOutput,
        .send_event = sendWsEvent,
        .send_title = sendWsTitle,
        .send_cwd = sendWsCwd,
        .send_notify = sendWsNotify,
    });
    defer hub.remove(sink_id);

    while (true) {
        const frame = try readWsFrame(alloc, conn.stream);
        defer alloc.free(frame.payload);
        switch (frame.opcode) {
            0x1 => try handleWsMessage(alloc, state, &conn_ctx, writer_iface, &writer_mutex, frame.payload, &ready),
            0x8 => return error.WebSocketClosed,
            0x9 => {
                // Ping: respond with pong and keep reading.
                writer_mutex.lock();
                defer writer_mutex.unlock();
                try sendWsFrame(writer_iface, 0xA, frame.payload);
            },
            0xA => {}, // Pong: ignore.
            else => return error.UnsupportedOpcode,
        }
    }
}

fn sendWsOutput(ctx: *anyopaque, ref: SessionRef, data: []const u8) void {
    const c: *const WsSinkContext = @ptrCast(@alignCast(ctx));
    if (!c.ready.load(.acquire)) return;
    c.mutex.lock();
    defer c.mutex.unlock();
    const b64 = encodeBase64(c.alloc, data) catch return;
    defer c.alloc.free(b64);
    const msg = std.fmt.allocPrint(
        c.alloc,
        "{{\"type\":\"output\",\"session_id\":\"{s}\",\"pane_id\":\"{s}\",\"data\":\"{s}\"}}",
        .{ ref.session_id, ref.pane_id, b64 },
    ) catch return;
    defer c.alloc.free(msg);
    _ = sendWsText(c.writer, msg) catch {};
}

fn sendWsEvent(ctx: *anyopaque, ref: SessionRef, exit_code: u32) void {
    const c: *const WsSinkContext = @ptrCast(@alignCast(ctx));
    if (!c.ready.load(.acquire)) return;
    c.mutex.lock();
    defer c.mutex.unlock();
    const msg = std.fmt.allocPrint(
        c.alloc,
        "{{\"type\":\"pane_exited\",\"session_id\":\"{s}\",\"pane_id\":\"{s}\",\"exit_code\":{d}}}",
        .{ ref.session_id, ref.pane_id, exit_code },
    ) catch return;
    defer c.alloc.free(msg);
    _ = sendWsText(c.writer, msg) catch {};
}

fn sendWsTitle(ctx: *anyopaque, ref: SessionRef, title: []const u8) void {
    const c: *const WsSinkContext = @ptrCast(@alignCast(ctx));
    if (!c.ready.load(.acquire)) return;
    c.mutex.lock();
    defer c.mutex.unlock();
    var list = std.ArrayList(u8).empty;
    defer list.deinit(c.alloc);
    list.appendSlice(c.alloc, "{\"type\":\"title_update\",\"session_id\":\"") catch return;
    list.appendSlice(c.alloc, ref.session_id[0..]) catch return;
    list.appendSlice(c.alloc, "\",\"pane_id\":\"") catch return;
    list.appendSlice(c.alloc, ref.pane_id[0..]) catch return;
    list.appendSlice(c.alloc, "\",\"title\":") catch return;
    writeJsonString(list.writer(c.alloc), title) catch return;
    list.appendSlice(c.alloc, "}") catch return;
    _ = sendWsText(c.writer, list.items) catch {};
}

fn sendWsCwd(ctx: *anyopaque, ref: SessionRef, cwd: []const u8) void {
    const c: *const WsSinkContext = @ptrCast(@alignCast(ctx));
    if (!c.ready.load(.acquire)) return;
    c.mutex.lock();
    defer c.mutex.unlock();
    var list = std.ArrayList(u8).empty;
    defer list.deinit(c.alloc);
    list.appendSlice(c.alloc, "{\"type\":\"cwd_update\",\"session_id\":\"") catch return;
    list.appendSlice(c.alloc, ref.session_id[0..]) catch return;
    list.appendSlice(c.alloc, "\",\"pane_id\":\"") catch return;
    list.appendSlice(c.alloc, ref.pane_id[0..]) catch return;
    list.appendSlice(c.alloc, "\",\"cwd\":") catch return;
    writeJsonString(list.writer(c.alloc), cwd) catch return;
    list.appendSlice(c.alloc, "}") catch return;
    _ = sendWsText(c.writer, list.items) catch {};
}

fn sendWsNotify(ctx: *anyopaque, ref: SessionRef, title: []const u8, body: []const u8) void {
    const c: *const WsSinkContext = @ptrCast(@alignCast(ctx));
    if (!c.ready.load(.acquire)) return;
    c.mutex.lock();
    defer c.mutex.unlock();
    var list = std.ArrayList(u8).empty;
    defer list.deinit(c.alloc);
    list.appendSlice(c.alloc, "{\"type\":\"notify\",\"session_id\":\"") catch return;
    list.appendSlice(c.alloc, ref.session_id[0..]) catch return;
    list.appendSlice(c.alloc, "\",\"pane_id\":\"") catch return;
    list.appendSlice(c.alloc, ref.pane_id[0..]) catch return;
    list.appendSlice(c.alloc, "\",\"title\":") catch return;
    writeJsonString(list.writer(c.alloc), title) catch return;
    list.appendSlice(c.alloc, ",\"body\":") catch return;
    writeJsonString(list.writer(c.alloc), body) catch return;
    list.appendSlice(c.alloc, "}") catch return;
    _ = sendWsText(c.writer, list.items) catch {};
}

fn handleWsMessage(
    alloc: Allocator,
    state: *ServerState,
    conn_ctx: *ConnectionContext,
    writer: *std.Io.Writer,
    mutex: *std.Thread.Mutex,
    line: []const u8,
    ready: *std.atomic.Value(bool),
) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, line, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    const type_val = obj.get("type") orelse return;
    const type_str = type_val.string;

    if (std.mem.eql(u8, type_str, "hello")) {
        const session = resolveSessionForConnection(state, conn_ctx, obj) orelse return;
        mutex.lock();
        defer mutex.unlock();
        var list = std.ArrayList(u8).empty;
        defer list.deinit(alloc);
        try list.appendSlice(alloc, "{\"type\":\"welcome\",\"version\":1,\"session_id\":\"");
        try list.appendSlice(alloc, &session.id);
        try list.appendSlice(alloc, "\",\"pane_id\":\"");
        try list.appendSlice(alloc, &session.pane_id);
        try list.appendSlice(alloc, "\",\"capabilities\":");
        try writeCapabilities(list.writer(alloc));
        try list.appendSlice(alloc, "}");
        try sendWsText(writer, list.items);
        ready.store(true, .release);
        return;
    }

    if (std.mem.eql(u8, type_str, "capabilities")) {
        mutex.lock();
        defer mutex.unlock();
        var list = std.ArrayList(u8).empty;
        defer list.deinit(alloc);
        try list.appendSlice(alloc, "{\"type\":\"capabilities\",\"capabilities\":");
        try writeCapabilities(list.writer(alloc));
        try list.appendSlice(alloc, "}");
        try sendWsText(writer, list.items);
        return;
    }

    if (std.mem.eql(u8, type_str, "list_sessions")) {
        mutex.lock();
        defer mutex.unlock();
        state.mutex.lock();
        defer state.mutex.unlock();
        var list = std.ArrayList(u8).empty;
        defer list.deinit(alloc);
        try list.appendSlice(alloc, "{\"type\":\"sessions\",\"sessions\":[");
        var first = true;
        var it = state.sessions_by_id.valueIterator();
        while (it.next()) |session| {
            if (!first) try list.appendSlice(alloc, ",");
            first = false;
            try list.appendSlice(alloc, "{\"session_id\":\"");
            try list.appendSlice(alloc, session.*.id[0..]);
            try list.appendSlice(alloc, "\",\"pane_id\":\"");
            try list.appendSlice(alloc, session.*.pane_id[0..]);
            try list.appendSlice(alloc, "\",\"title\":");
            if (session.*.title) |title| {
                try writeJsonString(list.writer(alloc), title);
            } else {
                try writeJsonString(list.writer(alloc), "");
            }
            try list.appendSlice(alloc, ",\"cwd\":");
            if (session.*.cwd) |cwd| {
                try writeJsonString(list.writer(alloc), cwd);
            } else {
                try writeJsonString(list.writer(alloc), "");
            }
            try list.appendSlice(alloc, "}");
        }
        try list.appendSlice(alloc, "]}");
        try sendWsText(writer, list.items);
        return;
    }

    if (std.mem.eql(u8, type_str, "attach_session")) {
        const session_id = sessionIdFromMessage(obj) orelse {
            mutex.lock();
            defer mutex.unlock();
            try sendWsText(writer, "{\"type\":\"error\",\"request\":\"attach_session\",\"message\":\"missing session_id\"}");
            return;
        };
        if (state.getSessionById(session_id)) |session| {
            conn_ctx.attached_session_id = session_id;
            mutex.lock();
            defer mutex.unlock();
            const msg = try std.fmt.allocPrint(alloc,
                "{{\"type\":\"session_attached\",\"session_id\":\"{s}\",\"pane_id\":\"{s}\"}}",
                .{ session.id, session.pane_id },
            );
            defer alloc.free(msg);
            try sendWsText(writer, msg);
        } else {
            mutex.lock();
            defer mutex.unlock();
            try sendWsText(writer, "{\"type\":\"error\",\"request\":\"attach_session\",\"message\":\"unknown session\"}");
        }
        return;
    }

    if (std.mem.eql(u8, type_str, "new_session")) {
        var cols: u16 = 80;
        var rows: u16 = 24;
        if (resolveSessionForConnection(state, conn_ctx, obj)) |current| {
            cols = current.cols;
            rows = current.rows;
        }
        if (obj.get("cols")) |cols_val| {
            cols = @intCast(cols_val.integer);
        }
        if (obj.get("rows")) |rows_val| {
            rows = @intCast(rows_val.integer);
        }
        var cwd: ?[]const u8 = null;
        if (obj.get("cwd")) |cwd_val| {
            cwd = cwd_val.string;
        } else if (obj.get("working_directory")) |cwd_val| {
            cwd = cwd_val.string;
        }
        const term = if (obj.get("term")) |term_val| term_val.string else null;
        const new_session = try state.createPaneWithOptions(.{
            .cols = cols,
            .rows = rows,
            .cwd = cwd,
            .term = term,
        });
        conn_ctx.attached_session_id = new_session.id;
        mutex.lock();
        defer mutex.unlock();
        const msg = try std.fmt.allocPrint(alloc,
            "{{\"type\":\"session_created\",\"session_id\":\"{s}\",\"pane_id\":\"{s}\"}}",
            .{ new_session.id, new_session.pane_id },
        );
        defer alloc.free(msg);
        try sendWsText(writer, msg);
        return;
    }

    const session = resolveSessionForConnection(state, conn_ctx, obj) orelse return;

    if (std.mem.eql(u8, type_str, "snapshot_request")) {
        const snap = try session.snapshot(alloc);
        defer alloc.free(snap);
        const b64 = try encodeBase64(alloc, snap);
        defer alloc.free(b64);
        const msg = try std.fmt.allocPrint(alloc,
            "{{\"type\":\"snapshot\",\"session_id\":\"{s}\",\"pane_id\":\"{s}\",\"cols\":{d},\"rows\":{d},\"data\":\"{s}\"}}",
            .{ session.id, session.pane_id, session.cols, session.rows, b64 },
        );
        defer alloc.free(msg);
        mutex.lock();
        defer mutex.unlock();
        try sendWsText(writer, msg);
        return;
    }

    if (std.mem.eql(u8, type_str, "input")) {
        const data_val = obj.get("data") orelse return;
        const decoded = try decodeBase64(alloc, data_val.string);
        defer alloc.free(decoded);
        session.writeInput(decoded);
        return;
    }

    if (std.mem.eql(u8, type_str, "resize")) {
        const cols_val = obj.get("cols") orelse return;
        const rows_val = obj.get("rows") orelse return;
        session.resize(@intCast(cols_val.integer), @intCast(rows_val.integer));
        return;
    }

    if (std.mem.eql(u8, type_str, "ping")) {
        mutex.lock();
        defer mutex.unlock();
        try sendWsText(writer, "{\"type\":\"pong\"}");
        return;
    }

    if (std.mem.eql(u8, type_str, "new_pane")) {
        var cols = session.cols;
        var rows = session.rows;
        if (obj.get("cols")) |cols_val| {
            cols = @intCast(cols_val.integer);
        }
        if (obj.get("rows")) |rows_val| {
            rows = @intCast(rows_val.integer);
        }
        var cwd: ?[]const u8 = null;
        if (obj.get("cwd")) |cwd_val| {
            cwd = cwd_val.string;
        } else if (obj.get("working_directory")) |cwd_val| {
            cwd = cwd_val.string;
        }
        const term = if (obj.get("term")) |term_val| term_val.string else null;
        const new_session = try state.createPaneWithOptions(.{
            .cols = cols,
            .rows = rows,
            .cwd = cwd,
            .term = term,
        });
        conn_ctx.attached_session_id = new_session.id;
        const msg = try std.fmt.allocPrint(alloc,
            "{{\"type\":\"pane_created\",\"session_id\":\"{s}\",\"pane_id\":\"{s}\"}}",
            .{ new_session.id, new_session.pane_id },
        );
        defer alloc.free(msg);
        mutex.lock();
        defer mutex.unlock();
        try sendWsText(writer, msg);
        return;
    }

    if (std.mem.eql(u8, type_str, "close_pane")) {
        state.closePane(session.pane_id);
        return;
    }

    if (std.mem.eql(u8, type_str, "list_panes")) {
        const target_session = sessionIdFromMessage(obj);
        if (target_session) |session_id| {
            if (state.getSessionById(session_id)) |target| {
                mutex.lock();
                defer mutex.unlock();
                const msg = try std.fmt.allocPrint(alloc,
                    "{{\"type\":\"panes\",\"panes\":[{{\"session_id\":\"{s}\",\"pane_id\":\"{s}\"}}]}}",
                    .{ target.id, target.pane_id },
                );
                defer alloc.free(msg);
                try sendWsText(writer, msg);
            } else {
                mutex.lock();
                defer mutex.unlock();
                try sendWsText(writer, "{\"type\":\"panes\",\"panes\":[]}");
            }
            return;
        }
        mutex.lock();
        defer mutex.unlock();
        state.mutex.lock();
        defer state.mutex.unlock();
        var list = std.ArrayList(u8).empty;
        defer list.deinit(alloc);
        try list.appendSlice(alloc, "{\"type\":\"panes\",\"panes\":[");
        var first = true;
        var it = state.sessions_by_id.valueIterator();
        while (it.next()) |session_entry| {
            if (!first) try list.appendSlice(alloc, ",");
            first = false;
            const chunk = try std.fmt.allocPrint(
                alloc,
                "{{\"session_id\":\"{s}\",\"pane_id\":\"{s}\"}}",
                .{ session_entry.*.id, session_entry.*.pane_id },
            );
            defer alloc.free(chunk);
            try list.appendSlice(alloc, chunk);
        }
        try list.appendSlice(alloc, "]}");
        try sendWsText(writer, list.items);
        return;
    }

    if (std.mem.eql(u8, type_str, "list_session_panes")) {
        const session_id = sessionIdFromMessage(obj) orelse return;
        if (state.getSessionById(session_id)) |target| {
            mutex.lock();
            defer mutex.unlock();
            const msg = try std.fmt.allocPrint(alloc,
                "{{\"type\":\"panes\",\"panes\":[{{\"session_id\":\"{s}\",\"pane_id\":\"{s}\"}}]}}",
                .{ target.id, target.pane_id },
            );
            defer alloc.free(msg);
            try sendWsText(writer, msg);
        }
        return;
    }
}

fn sessionIdFromMessage(obj: std.json.ObjectMap) ?[32]u8 {
    const session_val = obj.get("session_id") orelse return null;
    if (session_val != .string) return null;
    const s = session_val.string;
    if (s.len != 32) return null;
    var out: [32]u8 = undefined;
    @memcpy(out[0..], s[0..32]);
    return out;
}

fn resolveSessionForConnection(
    state: *ServerState,
    conn_ctx: *ConnectionContext,
    obj: std.json.ObjectMap,
) ?*Session {
    if (paneIdFromMessage(obj)) |pane_id| {
        if (state.getSessionByPane(pane_id)) |session| return session;
    }
    if (sessionIdFromMessage(obj)) |session_id| {
        if (state.getSessionById(session_id)) |session| return session;
    }
    if (state.getSessionById(conn_ctx.attached_session_id)) |session| return session;
    return state.getSessionById(state.default_session_id);
}

fn paneIdFromMessage(obj: std.json.ObjectMap) ?[32]u8 {
    const pane_val = obj.get("pane_id") orelse return null;
    if (pane_val != .string) return null;
    const s = pane_val.string;
    if (s.len != 32) return null;
    var out: [32]u8 = undefined;
    @memcpy(out[0..], s[0..32]);
    return out;
}

fn readHttpRequest(alloc: Allocator, stream: std.net.Stream) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(alloc);

    var tmp: [512]u8 = undefined;
    while (true) {
        const n = try stream.read(&tmp);
        if (n == 0) break;
        try buf.appendSlice(alloc, tmp[0..n]);
        if (std.mem.indexOf(u8, buf.items, "\r\n\r\n") != null) break;
    }
    return buf.toOwnedSlice(alloc);
}

fn parseWebSocketKey(req: []const u8) ![]const u8 {
    var it = std.mem.splitSequence(u8, req, "\r\n");
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "Sec-WebSocket-Key:")) {
            const value = std.mem.trim(u8, line[18..], " \t");
            return value;
        }
    }
    return error.MissingWebSocketKey;
}

fn computeWebSocketAccept(buf: *[28]u8, key: []const u8) []const u8 {
    var sha1 = std.crypto.hash.Sha1.init(.{});
    sha1.update(key);
    sha1.update(magic_ws_guid);
    var digest: [20]u8 = undefined;
    sha1.final(&digest);
    _ = base64.standard.Encoder.encode(buf, &digest);
    return buf;
}

fn readStreamNoEof(stream: std.net.Stream, buf: []u8) !void {
    var offset: usize = 0;
    while (offset < buf.len) {
        const n = try stream.read(buf[offset..]);
        if (n == 0) return error.EndOfStream;
        offset += n;
    }
}

const WsFrame = struct {
    opcode: u8,
    payload: []u8,
};

fn readWsFrame(alloc: Allocator, stream: std.net.Stream) !WsFrame {
    var header: [2]u8 = undefined;
    try readStreamNoEof(stream, &header);
    const fin = (header[0] & 0x80) != 0;
    const opcode = header[0] & 0x0F;
    if (!fin) return error.UnsupportedOpcode;

    const masked = (header[1] & 0x80) != 0;
    var len: usize = header[1] & 0x7F;
    if (len == 126) {
        var ext: [2]u8 = undefined;
        try readStreamNoEof(stream, &ext);
        len = std.mem.readInt(u16, &ext, .big);
    } else if (len == 127) {
        var ext: [8]u8 = undefined;
        try readStreamNoEof(stream, &ext);
        len = @intCast(std.mem.readInt(u64, &ext, .big));
    }

    var mask: [4]u8 = .{0, 0, 0, 0};
    if (masked) {
        try readStreamNoEof(stream, &mask);
    }

    const payload = try alloc.alloc(u8, len);
    try readStreamNoEof(stream, payload);

    if (masked) {
        for (payload, 0..) |*b, i| {
            b.* ^= mask[i % 4];
        }
    }

    return .{ .opcode = opcode, .payload = payload };
}

fn sendWsFrame(writer: *std.Io.Writer, opcode: u8, payload: []const u8) !void {
    var header: [10]u8 = undefined;
    var header_len: usize = 0;
    header[0] = 0x80 | (opcode & 0x0F);
    if (payload.len < 126) {
        header[1] = @intCast(payload.len);
        header_len = 2;
    } else if (payload.len < 65536) {
        header[1] = 126;
        std.mem.writeInt(u16, header[2..4], @intCast(payload.len), .big);
        header_len = 4;
    } else {
        header[1] = 127;
        std.mem.writeInt(u64, header[2..10], @intCast(payload.len), .big);
        header_len = 10;
    }

    try writer.writeAll(header[0..header_len]);
    try writer.writeAll(payload);
    try writer.flush();
}

fn sendWsText(writer: *std.Io.Writer, payload: []const u8) !void {
    try sendWsFrame(writer, 0x1, payload);
}
