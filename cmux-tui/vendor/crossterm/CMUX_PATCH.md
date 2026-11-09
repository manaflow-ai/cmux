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

## Zero terminal coordinates

Mouse reports (normal, rxvt, SGR) and cursor position reports carry 1-based
positions, and the parser subtracted 1 from what the host terminal sent. A 0
panicked builds with overflow checks (cmux debug builds) and wrapped to 65535
in release. The cmux patch refuses a 0 position as malformed input, as the
parser already refuses a bad button byte. Found by the `tui_keys` target in
`cmux-tui/fuzz`; regression test `zero_coordinates_are_refused_not_underflowed`.
Remove this part when upstream Crossterm checks the subtraction.

## Host OSC replies are not input

A program asks its terminal for colors with `ESC ] 10 ; ? ST` and
`ESC ] 11 ; ? ST`, and the terminal answers on the program's input. Upstream
Crossterm has no OSC grammar: it read `ESC ]` as Alt+] and the rest of the
reply as typed text. The cmux client asks at startup and waits a short time,
so a host that answered later had its reply typed into the focused pane
(bench round 4: `10;rgb:fdfd/ffff/f1f1` in the shell, and a bell).

The cmux patch scans only the replies the client asks for, `ESC ] 10 ;` and
`ESC ] 11 ;` followed by printable text up to BEL or `ESC \`, at most 64 bytes
(`event/host_reply.rs`, `scan_host_reply`), and drops a complete reply. The
parser waits for the end of such a started reply. Any other `ESC ]` (`ESC ]`
alone, `ESC ] a`, `ESC ] ESC [ A`, `ESC ] 1 2`, a control byte or too much
text in the reply) is Alt+], and the bytes after `ESC ]` are parsed again as
input: the shared parse loop `parse::advance` (used by the tty and mio
sources) takes the length each event used from `parse_event_len`, so no
typed key is dropped. The client's startup input reader (`ui/graphics.rs`)
uses the same scanner and event length. Regression tests: `cmux-tui/crates/cmux-tui/tests/tui_host_color_replies.rs`
and `crossterm_host_replies.rs`. Remove this part when upstream Crossterm
parses OSC replies.
