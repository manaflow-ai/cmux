const std = @import("std");
const ghostty_vt = @import("ghostty-vt");
const serialize = @import("serialize.zig");

const max_raw_buffer_bytes = 1 << 20;
const max_osc_bytes = 4096;

pub const Options = struct {
    cols: u16,
    rows: u16,
    max_scrollback: usize,
};

pub const OscParserState = enum { ground, esc, osc, osc_esc, osc_discard, osc_discard_esc };

pub const Notification = struct {
    title: ?[]u8 = null,
    body: ?[]u8 = null,

    pub fn deinit(self: *Notification, alloc: std.mem.Allocator) void {
        if (self.title) |t| alloc.free(t);
        if (self.body) |b| alloc.free(b);
        self.* = .{};
    }
};

pub const RawReadResult = struct {
    data: []u8,
    offset: u64,
    base_offset: u64,
    truncated: bool,
};

pub const OffsetWindow = struct {
    base_offset: u64,
    next_offset: u64,
};

pub const TerminalSession = struct {
    alloc: std.mem.Allocator,
    terminal: *ghostty_vt.Terminal,
    stream: ghostty_vt.TerminalStream,
    raw_buffer: std.ArrayList(u8),
    base_offset: u64 = 0,
    next_offset: u64 = 0,
    /// Last window title extracted from OSC 0/2 sequences in the PTY output.
    last_title: ?[]u8 = null,
    /// Last working directory extracted from OSC 7 sequences.
    last_directory: ?[]u8 = null,
    /// Number of BEL (0x07) bytes seen in the ground state.
    bell_count: u64 = 0,
    /// Last exit code parsed from OSC 133;D;<code> ST/BEL.
    last_command_exit_code: ?i32 = null,
    /// Set true whenever an OSC 133;D sequence is parsed.
    command_finished: bool = false,
    /// Bumped every time an OSC 133;D sequence is parsed; subscribers compare
    /// their last-seen value to detect a new command-finished event.
    command_seq: u64 = 0,
    /// Last OSC 99 notification parsed (key=value;key=value form).
    last_notification: ?Notification = null,
    /// Bumped every time a new OSC 99 notification is parsed.
    notification_seq: u64 = 0,
    /// Incremental OSC parser state.
    osc_state: OscParserState = .ground,
    /// In-progress OSC payload buffer. Capped at max_osc_bytes.
    osc_buffer: std.ArrayList(u8) = .empty,

    pub fn init(alloc: std.mem.Allocator, opts: Options) !TerminalSession {
        const terminal = try alloc.create(ghostty_vt.Terminal);
        errdefer alloc.destroy(terminal);

        terminal.* = try ghostty_vt.Terminal.init(alloc, .{
            .cols = opts.cols,
            .rows = opts.rows,
            .max_scrollback = opts.max_scrollback,
        });
        errdefer terminal.deinit(alloc);

        var raw_buffer: std.ArrayList(u8) = .empty;
        try raw_buffer.ensureTotalCapacity(alloc, 4096);

        var session: TerminalSession = .{
            .alloc = alloc,
            .terminal = terminal,
            .stream = undefined,
            .raw_buffer = raw_buffer,
        };
        session.stream = terminal.vtStream();
        return session;
    }

    pub fn deinit(self: *TerminalSession) void {
        self.stream.deinit();
        self.terminal.deinit(self.alloc);
        self.alloc.destroy(self.terminal);
        self.raw_buffer.deinit(self.alloc);
        self.osc_buffer.deinit(self.alloc);
        if (self.last_title) |t| self.alloc.free(t);
        if (self.last_directory) |d| self.alloc.free(d);
        if (self.last_notification) |*n| n.deinit(self.alloc);
    }

    pub fn feed(self: *TerminalSession, data: []const u8) !void {
        if (data.len == 0) return;

        self.stream.nextSlice(data);
        try self.raw_buffer.appendSlice(self.alloc, data);
        self.next_offset += data.len;

        self.feedOscParser(data);

        if (self.raw_buffer.items.len > max_raw_buffer_bytes) {
            const overflow = self.raw_buffer.items.len - max_raw_buffer_bytes;
            const remaining = self.raw_buffer.items[overflow..];
            std.mem.copyForwards(u8, self.raw_buffer.items[0..remaining.len], remaining);
            self.raw_buffer.items.len = remaining.len;
            self.base_offset += overflow;
        }
    }

    fn feedOscParser(self: *TerminalSession, data: []const u8) void {
        for (data) |b| self.feedOscByte(b);
    }

    fn feedOscByte(self: *TerminalSession, b: u8) void {
        switch (self.osc_state) {
            .ground => switch (b) {
                0x07 => self.bell_count += 1,
                0x1b => self.osc_state = .esc,
                else => {},
            },
            .esc => switch (b) {
                ']' => {
                    self.osc_buffer.clearRetainingCapacity();
                    self.osc_state = .osc;
                },
                0x1b => {}, // stay in esc
                else => self.osc_state = .ground,
            },
            .osc => switch (b) {
                0x07 => {
                    self.handleOscPayload();
                    self.osc_state = .ground;
                },
                0x1b => self.osc_state = .osc_esc,
                else => self.appendOscByte(b),
            },
            .osc_esc => switch (b) {
                '\\' => {
                    self.handleOscPayload();
                    self.osc_state = .ground;
                },
                0x07 => {
                    self.handleOscPayload();
                    self.osc_state = .ground;
                },
                0x1b => {}, // stay in osc_esc
                else => {
                    // Spurious ESC inside OSC; treat as part of payload, return to osc state.
                    self.appendOscByte(0x1b);
                    self.appendOscByte(b);
                    self.osc_state = .osc;
                },
            },
            .osc_discard => switch (b) {
                0x07 => self.osc_state = .ground,
                0x1b => self.osc_state = .osc_discard_esc,
                else => {},
            },
            .osc_discard_esc => switch (b) {
                '\\' => self.osc_state = .ground,
                0x07 => self.osc_state = .ground,
                0x1b => {},
                else => self.osc_state = .osc_discard,
            },
        }
    }

    fn appendOscByte(self: *TerminalSession, b: u8) void {
        if (self.osc_buffer.items.len >= max_osc_bytes) {
            // Overflow: discard accumulated payload and consume bytes until terminator.
            self.osc_buffer.clearRetainingCapacity();
            self.osc_state = .osc_discard;
            return;
        }
        self.osc_buffer.append(self.alloc, b) catch {
            self.osc_buffer.clearRetainingCapacity();
            self.osc_state = .osc_discard;
        };
    }

    fn handleOscPayload(self: *TerminalSession) void {
        const body = self.osc_buffer.items;
        defer self.osc_buffer.clearRetainingCapacity();
        if (body.len < 2) return;

        // Split prefix "Ps;" off.
        const semi = std.mem.indexOfScalar(u8, body, ';') orelse return;
        const ps = body[0..semi];
        const rest = body[semi + 1 ..];

        if (std.mem.eql(u8, ps, "0") or std.mem.eql(u8, ps, "2")) {
            if (rest.len == 0) return;
            const dup = self.alloc.dupe(u8, rest) catch return;
            if (self.last_title) |old| self.alloc.free(old);
            self.last_title = dup;
        } else if (std.mem.eql(u8, ps, "7")) {
            // file://host/path → /path
            if (std.mem.indexOf(u8, rest, "//")) |slash2| {
                const after_scheme = rest[slash2 + 2 ..];
                if (std.mem.indexOfScalar(u8, after_scheme, '/')) |path_start| {
                    const path = after_scheme[path_start..];
                    const dup = self.alloc.dupe(u8, path) catch return;
                    if (self.last_directory) |old| self.alloc.free(old);
                    self.last_directory = dup;
                }
            }
        } else if (std.mem.eql(u8, ps, "133")) {
            // 133;D[;code]
            if (rest.len == 0) return;
            const sub_end = std.mem.indexOfScalar(u8, rest, ';') orelse rest.len;
            const sub = rest[0..sub_end];
            if (sub.len == 1 and sub[0] == 'D') {
                self.command_finished = true;
                self.command_seq += 1;
                if (sub_end < rest.len) {
                    const code_str = rest[sub_end + 1 ..];
                    self.last_command_exit_code = std.fmt.parseInt(i32, code_str, 10) catch null;
                } else {
                    self.last_command_exit_code = null;
                }
            }
        } else if (std.mem.eql(u8, ps, "99")) {
            self.parseNotification(rest);
        }
    }

    fn parseNotification(self: *TerminalSession, payload: []const u8) void {
        var notif: Notification = .{};
        var it = std.mem.splitScalar(u8, payload, ';');
        while (it.next()) |pair| {
            const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
            const key = pair[0..eq];
            const value = pair[eq + 1 ..];
            if (std.mem.eql(u8, key, "title")) {
                if (notif.title) |t| self.alloc.free(t);
                notif.title = self.alloc.dupe(u8, value) catch null;
            } else if (std.mem.eql(u8, key, "body")) {
                if (notif.body) |b| self.alloc.free(b);
                notif.body = self.alloc.dupe(u8, value) catch null;
            }
        }
        if (notif.title == null and notif.body == null) return;
        if (self.last_notification) |*old| old.deinit(self.alloc);
        self.last_notification = notif;
        self.notification_seq += 1;
    }

    pub fn resize(self: *TerminalSession, cols: u16, rows: u16) !void {
        try self.terminal.resize(self.alloc, cols, rows);
    }

    pub fn snapshot(self: *TerminalSession, alloc: std.mem.Allocator, format: serialize.HistoryFormat) ![]u8 {
        return serialize.serializeTerminal(alloc, self.terminal, format) orelse error.SerializeFailed;
    }

    pub fn history(self: *TerminalSession, alloc: std.mem.Allocator, format: serialize.HistoryFormat) ![]u8 {
        return serialize.serializeTerminal(alloc, self.terminal, format) orelse error.SerializeFailed;
    }

    pub fn offsetWindow(self: *const TerminalSession) OffsetWindow {
        return .{
            .base_offset = self.base_offset,
            .next_offset = self.next_offset,
        };
    }

    pub fn readRaw(self: *TerminalSession, alloc: std.mem.Allocator, offset: u64, max_bytes: usize) !RawReadResult {
        var effective_offset = offset;
        var truncated = false;
        if (effective_offset < self.base_offset) {
            effective_offset = self.base_offset;
            truncated = true;
        }
        if (effective_offset > self.next_offset) {
            effective_offset = self.next_offset;
        }

        const start: usize = @intCast(effective_offset - self.base_offset);
        var end = self.raw_buffer.items.len;
        if (max_bytes > 0 and end > start + max_bytes) {
            end = start + max_bytes;
        }

        return .{
            .data = try alloc.dupe(u8, self.raw_buffer.items[start..end]),
            .offset = effective_offset + (end - start),
            .base_offset = self.base_offset,
            .truncated = truncated,
        };
    }
};

test "feed plain text then snapshot plain returns visible screen" {
    var session = try TerminalSession.init(std.testing.allocator, .{
        .cols = 10,
        .rows = 4,
        .max_scrollback = 1024,
    });
    defer session.deinit();

    try session.feed("hello\r\nworld\r\n");
    const snapshot = try session.snapshot(std.testing.allocator, .plain);
    defer std.testing.allocator.free(snapshot);

    try std.testing.expect(std.mem.indexOf(u8, snapshot, "hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "world") != null);
}

test "resize reflows tracked screen state" {
    var session = try TerminalSession.init(std.testing.allocator, .{
        .cols = 12,
        .rows = 4,
        .max_scrollback = 1024,
    });
    defer session.deinit();

    try session.feed("hello world\r\n");
    try session.resize(5, 4);

    const snapshot = try session.snapshot(std.testing.allocator, .plain);
    defer std.testing.allocator.free(snapshot);

    try std.testing.expect(std.mem.indexOf(u8, snapshot, "hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "world") != null);
}

test "history plain includes prior scrollback lines" {
    var session = try TerminalSession.init(std.testing.allocator, .{
        .cols = 8,
        .rows = 2,
        .max_scrollback = 1024,
    });
    defer session.deinit();

    try session.feed("line1\r\nline2\r\nline3\r\n");
    const history = try session.history(std.testing.allocator, .plain);
    defer std.testing.allocator.free(history);

    try std.testing.expect(std.mem.indexOf(u8, history, "line1") != null);
    try std.testing.expect(std.mem.indexOf(u8, history, "line3") != null);
}

test "fragmented utf8 feed preserves visible content" {
    var session = try TerminalSession.init(std.testing.allocator, .{
        .cols = 16,
        .rows = 4,
        .max_scrollback = 1024,
    });
    defer session.deinit();

    const smile = "\xF0\x9F\x98\x80";
    try session.feed("hi ");
    try session.feed(smile[0..2]);
    try session.feed(smile[2..]);
    try session.feed("\r\n");

    const snapshot = try session.snapshot(std.testing.allocator, .plain);
    defer std.testing.allocator.free(snapshot);

    try std.testing.expect(std.mem.indexOf(u8, snapshot, "hi ") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, smile) != null);
}

test "fragmented ansi escape feed preserves visible content" {
    var session = try TerminalSession.init(std.testing.allocator, .{
        .cols = 16,
        .rows = 4,
        .max_scrollback = 1024,
    });
    defer session.deinit();

    try session.feed("\x1b[31");
    try session.feed("mred");
    try session.feed("\x1b[0m\r\n");

    const snapshot = try session.snapshot(std.testing.allocator, .plain);
    defer std.testing.allocator.free(snapshot);

    try std.testing.expect(std.mem.indexOf(u8, snapshot, "red") != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, snapshot, 0x1b) == null);
}

test "raw ring truncates and advances base offset" {
    var session = try TerminalSession.init(std.testing.allocator, .{
        .cols = 8,
        .rows = 2,
        .max_scrollback = 1024,
    });
    defer session.deinit();

    const chunk = "1234567890";
    var index: usize = 0;
    while (index < max_raw_buffer_bytes + 100) : (index += chunk.len) {
        try session.feed(chunk);
    }

    try std.testing.expect(session.base_offset > 0);
    const read = try session.readRaw(std.testing.allocator, 0, 32);
    defer std.testing.allocator.free(read.data);

    try std.testing.expect(read.truncated);
    try std.testing.expectEqual(session.base_offset, read.base_offset);
}

test "readRaw from midpoint returns exact bytes and offsets" {
    var session = try TerminalSession.init(std.testing.allocator, .{
        .cols = 16,
        .rows = 4,
        .max_scrollback = 1024,
    });
    defer session.deinit();

    try session.feed("hello\nworld\n");

    const read = try session.readRaw(std.testing.allocator, 6, 5);
    defer std.testing.allocator.free(read.data);

    try std.testing.expectEqualStrings("world", read.data);
    try std.testing.expectEqual(@as(u64, 11), read.offset);
    try std.testing.expectEqual(@as(u64, 0), read.base_offset);
    try std.testing.expect(!read.truncated);
}

test "readRaw after truncation returns the retained prefix and updated offsets" {
    var session = try TerminalSession.init(std.testing.allocator, .{
        .cols = 16,
        .rows = 4,
        .max_scrollback = 1024,
    });
    defer session.deinit();

    const chunk = "abcdefghijklmnopqrstuvwxyz012345";
    var index: usize = 0;
    while (index < max_raw_buffer_bytes + chunk.len) : (index += chunk.len) {
        try session.feed(chunk);
    }

    const read = try session.readRaw(std.testing.allocator, 0, 32);
    defer std.testing.allocator.free(read.data);

    try std.testing.expect(read.truncated);
    try std.testing.expectEqual(session.base_offset, read.base_offset);
    try std.testing.expectEqualStrings(session.raw_buffer.items[0..32], read.data);
    try std.testing.expectEqual(session.base_offset + 32, read.offset);
}

// Adapted from references/zmx/src/util.zig at commit
// 993b0cf6c7e7d384e8cf428e301e5e790e88c6f2.
test "serializeTerminalState excludes synchronized output replay" {
    var term = try ghostty_vt.Terminal.init(std.testing.allocator, .{
        .cols = 80,
        .rows = 24,
    });
    defer term.deinit(std.testing.allocator);

    var stream = term.vtStream();
    defer stream.deinit();

    stream.nextSlice("\x1b[?2004h");
    stream.nextSlice("\x1b[?2026h");
    stream.nextSlice("hello");

    try std.testing.expect(term.modes.get(.bracketed_paste));
    try std.testing.expect(term.modes.get(.synchronized_output));

    const output = serialize.serializeTerminalState(std.testing.allocator, &term) orelse return error.TestUnexpectedNull;
    defer std.testing.allocator.free(output);

    try std.testing.expect(term.modes.get(.synchronized_output));

    var restored = try ghostty_vt.Terminal.init(std.testing.allocator, .{
        .cols = 80,
        .rows = 24,
    });
    defer restored.deinit(std.testing.allocator);

    var restored_stream = restored.vtStream();
    defer restored_stream.deinit();
    restored_stream.nextSlice(output);

    try std.testing.expect(restored.modes.get(.bracketed_paste));
    try std.testing.expect(!restored.modes.get(.synchronized_output));
}

test "serializeTerminalState round trips visible content" {
    var term = try ghostty_vt.Terminal.init(std.testing.allocator, .{
        .cols = 80,
        .rows = 24,
    });
    defer term.deinit(std.testing.allocator);

    var stream = term.vtStream();
    defer stream.deinit();

    stream.nextSlice("\x1b[?2004h");
    stream.nextSlice("hello\r\nworld\r\n");

    const output = serialize.serializeTerminalState(std.testing.allocator, &term) orelse return error.TestUnexpectedNull;
    defer std.testing.allocator.free(output);

    var restored = try ghostty_vt.Terminal.init(std.testing.allocator, .{
        .cols = 80,
        .rows = 24,
    });
    defer restored.deinit(std.testing.allocator);

    var restored_stream = restored.vtStream();
    defer restored_stream.deinit();
    restored_stream.nextSlice(output);

    try std.testing.expect(restored.modes.get(.bracketed_paste));

    const restored_plain = serialize.serializeTerminal(std.testing.allocator, &restored, .plain) orelse return error.TestUnexpectedNull;
    defer std.testing.allocator.free(restored_plain);

    try std.testing.expect(std.mem.indexOf(u8, restored_plain, "hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, restored_plain, "world") != null);
}

test "OSC 133;D;0 in single chunk records exit code" {
    var session = try TerminalSession.init(std.testing.allocator, .{
        .cols = 16,
        .rows = 4,
        .max_scrollback = 1024,
    });
    defer session.deinit();

    try session.feed("\x1b]133;D;0\x07");
    try std.testing.expect(session.command_finished);
    try std.testing.expectEqual(@as(?i32, 0), session.last_command_exit_code);
}

test "OSC 133;D;42 split across chunks with ST terminator" {
    var session = try TerminalSession.init(std.testing.allocator, .{
        .cols = 16,
        .rows = 4,
        .max_scrollback = 1024,
    });
    defer session.deinit();

    try session.feed("\x1b]13");
    try session.feed("3;D;42\x1b\\");
    try std.testing.expect(session.command_finished);
    try std.testing.expectEqual(@as(?i32, 42), session.last_command_exit_code);
}

test "BEL in ground state increments bell_count" {
    var session = try TerminalSession.init(std.testing.allocator, .{
        .cols = 16,
        .rows = 4,
        .max_scrollback = 1024,
    });
    defer session.deinit();

    try session.feed("hello\x07world");
    try std.testing.expectEqual(@as(u64, 1), session.bell_count);
    try std.testing.expectEqualStrings("hello\x07world", session.raw_buffer.items);
}

test "OSC 99 stores notification title and body" {
    var session = try TerminalSession.init(std.testing.allocator, .{
        .cols = 16,
        .rows = 4,
        .max_scrollback = 1024,
    });
    defer session.deinit();

    try session.feed("\x1b]99;title=Build done;body=exit 0\x07");
    try std.testing.expect(session.last_notification != null);
    const n = session.last_notification.?;
    try std.testing.expectEqualStrings("Build done", n.title.?);
    try std.testing.expectEqualStrings("exit 0", n.body.?);
}

test "OSC overflow returns to ground without crashing" {
    var session = try TerminalSession.init(std.testing.allocator, .{
        .cols = 16,
        .rows = 4,
        .max_scrollback = 1024,
    });
    defer session.deinit();

    try session.feed("\x1b]0;");
    var i: usize = 0;
    const big = "a" ** 1024;
    while (i < 10) : (i += 1) {
        try session.feed(big);
    }
    // No terminator yet; parser should be in osc_discard, no crash, no leak.
    try std.testing.expect(session.osc_state == .osc_discard or session.osc_state == .osc_discard_esc);
    // Sending a terminator returns us to ground.
    try session.feed("\x07");
    try std.testing.expect(session.osc_state == .ground);
}

test "OSC 0 title parses (regression for existing behavior)" {
    var session = try TerminalSession.init(std.testing.allocator, .{
        .cols = 16,
        .rows = 4,
        .max_scrollback = 1024,
    });
    defer session.deinit();

    try session.feed("\x1b]0;my title\x07");
    try std.testing.expectEqualStrings("my title", session.last_title.?);
}

test "OSC 7 cwd parses (regression for existing behavior)" {
    var session = try TerminalSession.init(std.testing.allocator, .{
        .cols = 16,
        .rows = 4,
        .max_scrollback = 1024,
    });
    defer session.deinit();

    try session.feed("\x1b]7;file://host/Users/me/proj\x1b\\");
    try std.testing.expectEqualStrings("/Users/me/proj", session.last_directory.?);
}
