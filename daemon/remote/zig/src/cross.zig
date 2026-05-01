const builtin = @import("builtin");

pub const c = switch (builtin.os.tag) {
    .macos => @cImport({
        @cInclude("sys/ioctl.h");
        @cInclude("termios.h");
        @cInclude("stdlib.h");
        @cInclude("unistd.h");
    }),
    .freebsd => @cImport({
        @cInclude("termios.h");
        @cInclude("libutil.h");
        @cInclude("stdlib.h");
        @cInclude("unistd.h");
    }),
    else => @cImport({
        @cInclude("sys/ioctl.h");
        @cInclude("pty.h");
        @cInclude("stdlib.h");
        @cInclude("unistd.h");
    }),
};

pub const forkpty = if (builtin.os.tag == .macos)
    struct {
        extern "c" fn forkpty(
            master_fd: *c_int,
            name: ?[*:0]u8,
            termp: ?*const c.struct_termios,
            winp: ?*const c.struct_winsize,
        ) c_int;
    }.forkpty
else
    c.forkpty;
