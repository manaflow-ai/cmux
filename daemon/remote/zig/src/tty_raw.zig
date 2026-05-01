const std = @import("std");
const cross = @import("cross.zig");

pub const max_detach_prefix_bytes: usize = 64;

pub const RestoreGuard = struct {
    fd: std.posix.fd_t,
    original: cross.c.struct_termios,
    active: bool,

    pub fn enter(fd: std.posix.fd_t) !RestoreGuard {
        var original: cross.c.struct_termios = undefined;
        if (cross.c.tcgetattr(fd, &original) != 0) return error.GetAttrFailed;
        var raw = original;
        cross.c.cfmakeraw(&raw);
        raw.c_cc[cross.c.VMIN] = 1;
        raw.c_cc[cross.c.VTIME] = 0;
        if (cross.c.tcsetattr(fd, cross.c.TCSAFLUSH, &raw) != 0) return error.SetAttrFailed;
        return .{
            .fd = fd,
            .original = original,
            .active = true,
        };
    }

    pub fn deinit(self: *RestoreGuard) void {
        if (!self.active or self.fd < 0) return;
        _ = cross.c.tcsetattr(self.fd, cross.c.TCSANOW, &self.original);
        self.active = false;
    }
};

pub fn currentSize(fd: std.posix.fd_t) !struct { cols: u16, rows: u16 } {
    var winsize = cross.c.struct_winsize{
        .ws_row = 0,
        .ws_col = 0,
        .ws_xpixel = 0,
        .ws_ypixel = 0,
    };
    if (cross.c.ioctl(fd, cross.c.TIOCGWINSZ, &winsize) != 0) return error.GetWindowSizeFailed;
    return .{
        .cols = @max(@as(u16, 1), winsize.ws_col),
        .rows = @max(@as(u16, 1), winsize.ws_row),
    };
}

pub fn isDetachSequence(bytes: []const u8) bool {
    return detachSequenceStart(bytes) != null;
}

pub fn detachSequenceStart(bytes: []const u8) ?usize {
    if (std.mem.indexOfScalar(u8, bytes, 0x1c)) |idx| return idx;
    return kittyCtrlBackslashStart(bytes);
}

pub fn trailingDetachPrefixLen(bytes: []const u8) usize {
    if (bytes.len == 0) return 0;

    const window_start = if (bytes.len > max_detach_prefix_bytes) bytes.len - max_detach_prefix_bytes else 0;
    var i: usize = window_start;
    while (i < bytes.len) : (i += 1) {
        if (couldBeDetachPrefix(bytes[i..])) return bytes.len - i;
    }
    return 0;
}

// Adapted from references/zmx/src/util.zig at commit
// 993b0cf6c7e7d384e8cf428e301e5e790e88c6f2.
fn kittyCtrlBackslashStart(buf: []const u8) ?usize {
    var i: usize = 0;
    while (i + 2 < buf.len) : (i += 1) {
        if (buf[i] == 0x1b and buf[i + 1] == '[') {
            if (parseKittyCtrlBackslash(buf[i + 2 ..])) return i;
        }
    }
    return null;
}

fn parseKittyCtrlBackslash(buf: []const u8) bool {
    var pos: usize = 0;

    const key_code = parseDecimal(buf, &pos) orelse return false;
    if (key_code != 92) return false;

    while (pos < buf.len and buf[pos] == ':') {
        pos += 1;
        _ = parseDecimal(buf, &pos);
    }

    if (pos >= buf.len or buf[pos] != ';') return false;
    pos += 1;

    const mod_encoded = parseDecimal(buf, &pos) orelse return false;
    if (mod_encoded < 1) return false;
    const mod_raw = mod_encoded - 1;

    const intentional_mods = mod_raw & 0b00111111;
    if (intentional_mods != 0b100) return false;

    if (pos < buf.len and buf[pos] == ':') {
        pos += 1;
        const event_type = parseDecimal(buf, &pos) orelse return false;
        if (event_type == 3) return false;
    }

    if (pos < buf.len and buf[pos] == ';') {
        pos += 1;
        while (pos < buf.len and (std.ascii.isDigit(buf[pos]) or buf[pos] == ':')) {
            pos += 1;
        }
    }

    return pos < buf.len and buf[pos] == 'u';
}

fn parseDecimal(buf: []const u8, pos: *usize) ?u32 {
    const start = pos.*;
    var value: u32 = 0;
    while (pos.* < buf.len and std.ascii.isDigit(buf[pos.*])) {
        value = value *% 10 +% (buf[pos.*] - '0');
        pos.* += 1;
    }
    if (pos.* == start) return null;
    return value;
}

fn couldBeDetachPrefix(bytes: []const u8) bool {
    if (bytes.len == 0 or bytes[0] != 0x1b) return false;
    if (bytes.len == 1) return true;
    if (bytes[1] != '[') return false;
    if (bytes.len == 2) return true;

    var i: usize = 2;
    while (i < bytes.len) : (i += 1) {
        const ch = bytes[i];
        if (ch == 'u') return false;
        if (!std.ascii.isDigit(ch) and ch != ':' and ch != ';') return false;
    }
    return true;
}

test "ctrl backslash requests detach" {
    try std.testing.expect(isDetachSequence("\x1c"));
}

// Adapted from references/zmx/src/util.zig at commit
// 993b0cf6c7e7d384e8cf428e301e5e790e88c6f2.
test "kitty ctrl backslash requests detach" {
    const expect = std.testing.expect;

    try expect(isDetachSequence("\x1b[92;5u"));
    try expect(isDetachSequence("\x1b[92;5:1u"));
    try expect(isDetachSequence("\x1b[92;5:2u"));
    try expect(!isDetachSequence("\x1b[92;5:3u"));

    try expect(isDetachSequence("\x1b[92;69u"));
    try expect(isDetachSequence("\x1b[92;69:1u"));
    try expect(!isDetachSequence("\x1b[92;69:3u"));

    try expect(isDetachSequence("\x1b[92;133u"));
    try expect(isDetachSequence("\x1b[92;197u"));

    try expect(!isDetachSequence("\x1b[92;6u"));
    try expect(!isDetachSequence("\x1b[92;7u"));
    try expect(!isDetachSequence("\x1b[92;13u"));
    try expect(!isDetachSequence("\x1b[92;70u"));
    try expect(!isDetachSequence("\x1b[92;134u"));

    try expect(!isDetachSequence("\x1b[92;1u"));
    try expect(!isDetachSequence("\x1b[92;2u"));

    try expect(isDetachSequence("\x1b[92:124;5u"));
    try expect(isDetachSequence("\x1b[92::92;5u"));
    try expect(isDetachSequence("\x1b[92:124:92;5u"));
    try expect(isDetachSequence("\x1b[92:124;69:1u"));
    try expect(!isDetachSequence("\x1b[92:124;69:3u"));

    try expect(isDetachSequence("\x1b[92;5;28u"));
    try expect(isDetachSequence("\x1b[92;5;28:92u"));

    try expect(!isDetachSequence("\x1b[91;5u"));
    try expect(!isDetachSequence("\x1b[93;5u"));
    try expect(!isDetachSequence("\x1b[9;5u"));
    try expect(!isDetachSequence("\x1b[920;5u"));

    try expect(isDetachSequence("abc\x1b[92;5u"));
    try expect(isDetachSequence("\x1b[A\x1b[92;5u"));

    try expect(!isDetachSequence("garbage"));
    try expect(!isDetachSequence(""));
    try expect(!isDetachSequence("\x1b["));
    try expect(!isDetachSequence("\x1b[92"));
    try expect(!isDetachSequence("\x1b[92;"));
    try expect(!isDetachSequence("\x1b[92;u"));
    try expect(!isDetachSequence("\x1b[;5u"));
    try expect(!isDetachSequence("\x1b[65;92u"));
}

test "raw mode restore guard is idempotent" {
    var guard = RestoreGuard{
        .fd = -1,
        .original = undefined,
        .active = false,
    };
    guard.deinit();
    guard.deinit();
}

test "trailing detach prefix keeps incomplete kitty sequence" {
    try std.testing.expectEqual(@as(usize, 5), trailingDetachPrefixLen("abc\x1b[92"));
    try std.testing.expectEqual(@as(usize, 1), trailingDetachPrefixLen("\x1b"));
    try std.testing.expectEqual(@as(usize, 0), trailingDetachPrefixLen("\x1b[A"));
    try std.testing.expectEqual(@as(usize, 0), trailingDetachPrefixLen("\x1b[92;5u"));
}
