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
sources through one `InputParser`, `event/input_parser.rs`) takes the length
each event used from `parse_event_len`, so no typed key is dropped. Alt+] and
one or two digits with nothing after them (`ESC ] 1`, `ESC ] 1 1`) may start a
reply, so they are held; when no byte comes for 50 ms (each byte starts the
time again) they are typed keys, Alt+] and the digits. The sources poll no
longer than that time. A held start with reply text (`ESC ] 1 1 ;`) waits for
its next byte as before.

Known limit: a late reply whose bytes arrive split, with more than 50 ms after
`ESC ] 1` or `ESC ] 1 1` and before the rest (a slow ssh or mosh link), is
read as Alt+], the digits, and the rest as typed text, as upstream Crossterm
reads it. Holding until a terminator would hold a typed Alt+] and digit until
the next key, so the quiet time stays. A reply split after its `;` is still
dropped whole. The client's startup input reader (`ui/graphics.rs`)
uses the same scanner and event length. Regression tests: `cmux-tui/crates/cmux-tui/tests/tui_host_color_replies.rs`
and `crossterm_host_replies.rs` (the quiet time with a given clock). Remove this part when upstream Crossterm
parses OSC replies.

## A waker for a blocked poll

Upstream exposes the event source's waker only to `EventStream`. A thread
that reads with `poll` and `read` had to poll on a short timeout to notice
that it should stop, so an idle client woke ten times a second. The cmux
patch adds `poll_waker()` and `PollWaker::wake()` (feature `event-stream`): a
blocked `poll` returns `Ok(false)`, as it does for `EventStream`'s own wake.
cmux-tui's input reader polls without a short cap and its shutdown wakes it.
Regression coverage: `the_input_reader_waits_without_a_timer_and_stops_on_wake`
in `cmux-tui/crates/cmux-tui/src/app/tests/host_input.rs`. Remove this part
when upstream Crossterm exposes a waker for `poll`.
