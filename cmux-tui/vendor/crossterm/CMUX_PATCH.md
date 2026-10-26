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

## Parsing buffered bytes

`parse_event_from_bytes` and `parse_input_from_bytes` (both `#[doc(hidden)]`,
Unix) run the reader's parser on bytes the caller holds, with no terminal.
`parse_event_from_bytes` returns only public events. `parse_input_from_bytes`
also reports a complete terminal reply (cursor position, keyboard enhancement
flags, primary device attributes) as `ParsedInput::Reply`, so a caller that
feeds bytes one at a time ends the sequence there, as the reader does, instead
of reading the reply as incomplete. cmux uses them for startup input in
`ui/graphics.rs` and for the `tui_keys` fuzz target. Regression test
`a_complete_reply_is_told_apart_from_an_incomplete_sequence`.
