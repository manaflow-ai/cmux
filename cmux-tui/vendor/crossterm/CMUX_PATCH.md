# cmux Crossterm patch

This directory vendors Crossterm 0.29.0. cmux enables Kitty keyboard protocol
flags 4 and 16, but upstream 0.29.0 discards the reported shifted key,
PC-101-layout key, and associated text while parsing CSI-u events.

The cmux patch adds `EnhancedKeyEvent`, preserves those fields in the Unix
parser, and keeps the original `KeyEvent` identity and modifiers intact. Remove
the patch when [crossterm-rs/crossterm#968](https://github.com/crossterm-rs/crossterm/issues/968)
ships in the Crossterm version used by cmux.

## End of input on the controlling terminal

The Unix mio event source reads the terminal in a loop and only left that loop
for `WouldBlock` or `Interrupted`. A read that returned zero bytes, or any other
error such as the `EIO` a hung-up pty can report, fell through to the next
iteration. Once a terminal emulator exits without delivering `SIGHUP`, its
descriptor stays ready and every read reports end of input, so the loop never
exited: the client pinned one core and, with its input thread unable to return,
stopped responding to `SIGTERM`.

The cmux patch returns `UnexpectedEof` for a read of zero bytes and propagates
every other read error, so the caller learns the terminal is gone. It carries
only the classification, not wording, so the client can localize the reason.
Regression coverage: `cmux-tui/crates/cmux-tui/tests/dead_tty_input.rs`. Remove
this part of the patch when the Crossterm version used by cmux reports end of
input.

## Coordinate 0 in mouse and cursor position reports

The Unix parser turned the 1-based coordinates of a mouse report (X10, rxvt
and SGR encodings) and a cursor position report into 0-based ones with `- 1`.
A report with coordinate 0, or an X10 byte below 33, overflowed: a panic in
builds with overflow checks (cmux-tui dev builds) and column 65535 otherwise.
The cmux patch clamps a mouse coordinate of 0 to 0, so the event (often a
button release) still arrives, and reports a cursor position report with a 0
as a malformed event. Regression input:
`cmux-tui/fuzz/regressions/tui_input/`. Remove this part when upstream
Crossterm checks the subtraction.
