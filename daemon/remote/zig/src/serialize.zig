const std = @import("std");
const ghostty_vt = @import("ghostty-vt");

pub const HistoryFormat = enum(u8) {
    plain = 0,
    vt = 1,
    html = 2,
};

pub fn serializeTerminalState(alloc: std.mem.Allocator, term: *ghostty_vt.Terminal) ?[]u8 {
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    const had_synchronized_output = term.modes.get(.synchronized_output);
    if (had_synchronized_output) {
        term.modes.set(.synchronized_output, false);
        defer term.modes.set(.synchronized_output, true);
    }

    var term_formatter = ghostty_vt.formatter.TerminalFormatter.init(term, .vt);
    term_formatter.content = .{ .selection = null };
    term_formatter.extra = .{
        .palette = false,
        .modes = true,
        .scrolling_region = true,
        .tabstops = false,
        .pwd = true,
        .keyboard = true,
        .screen = .all,
    };

    term_formatter.format(&builder.writer) catch return null;
    const output = builder.writer.buffered();
    if (output.len == 0) return null;

    return alloc.dupe(u8, output) catch null;
}

pub fn serializeTerminal(alloc: std.mem.Allocator, term: *ghostty_vt.Terminal, format: HistoryFormat) ?[]u8 {
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    const options: ghostty_vt.formatter.Options = switch (format) {
        .plain => .plain,
        .vt => .vt,
        .html => .html,
    };
    var term_formatter = ghostty_vt.formatter.TerminalFormatter.init(term, options);
    term_formatter.content = .{ .selection = null };
    term_formatter.extra = switch (format) {
        .plain => .none,
        .vt => .{
            .palette = false,
            .modes = true,
            .scrolling_region = true,
            .tabstops = false,
            .pwd = true,
            .keyboard = true,
            .screen = .all,
        },
        .html => .styles,
    };

    term_formatter.format(&builder.writer) catch return null;
    const output = builder.writer.buffered();
    if (output.len == 0) return null;

    return alloc.dupe(u8, output) catch null;
}
