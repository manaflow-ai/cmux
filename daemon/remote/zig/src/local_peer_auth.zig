const std = @import("std");
const builtin = @import("builtin");

const c = @cImport({
    @cInclude("sys/types.h");
    @cInclude("sys/socket.h");
    @cInclude("unistd.h");
});

pub fn authorizeClient(fd: std.posix.fd_t) !void {
    if (std.posix.getenv("CMUX_REMOTE_UNIX_SKIP_PEER_AUTH")) |value| {
        if (std.mem.eql(u8, value, "1")) return;
    }

    switch (builtin.os.tag) {
        .macos, .ios, .freebsd, .netbsd, .openbsd, .dragonfly => try authorizeWithGetPeerEid(fd),
        .linux => try authorizeWithPeerCred(fd),
        else => return error.UnsupportedPeerCredentials,
    }
}

fn authorizeWithGetPeerEid(fd: std.posix.fd_t) !void {
    var peer_uid: c.uid_t = 0;
    var peer_gid: c.gid_t = 0;
    if (c.getpeereid(fd, &peer_uid, &peer_gid) != 0) return error.PeerAuthFailed;
    if (peer_uid != c.geteuid()) return error.UnauthorizedPeer;
}

fn authorizeWithPeerCred(fd: std.posix.fd_t) !void {
    const LinuxUCred = extern struct {
        pid: c.pid_t,
        uid: c.uid_t,
        gid: c.gid_t,
    };

    var cred: LinuxUCred = undefined;
    var len: c.socklen_t = @sizeOf(LinuxUCred);
    if (c.getsockopt(fd, c.SOL_SOCKET, c.SO_PEERCRED, &cred, &len) != 0) return error.PeerAuthFailed;
    if (cred.uid != c.geteuid()) return error.UnauthorizedPeer;
}

test "skip peer auth env bypasses fd checks" {
    try std.testing.expectEqual(@as(c_int, 0), c.setenv("CMUX_REMOTE_UNIX_SKIP_PEER_AUTH", "1", 1));
    defer _ = c.unsetenv("CMUX_REMOTE_UNIX_SKIP_PEER_AUTH");

    try authorizeClient(-1);
}
