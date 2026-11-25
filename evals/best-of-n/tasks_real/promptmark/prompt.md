Fix `ShellMarks` in `promptmark.py`. It sits on a terminal's output stream and puts terminal-mode resets in front of
shell-integration marks, so a program that dies with the mouse or the keyboard protocol still on does not leave the
next prompt broken.

Bug report (from cmux commit ed21d9f61e3, "reset modes at prompt marks split across reads"): the marks arrive over a
pty, and a read can end in the middle of one (`...\x1b]13` in one read, `3;A\x07` in the next). The filter only looks
inside one chunk, so a mark split across reads gets no reset at all.

The class:

- `ShellMarks()` starts not running. `feed(data: bytes) -> bytes` takes the next chunk and returns the bytes to pass
  on; `flush() -> bytes` returns whatever is still held back (at end of stream) and empties it.
- A mark is `MARK = b"\x1b]133;"` followed by one letter byte. Search for MARK; for each one found:
  - letter `C` (command started): set running.
  - letter `D` (command finished): if running, insert `KEYBOARD_RESET` right before the mark and clear running; if not
    running, nothing.
  - letter `A` (prompt start): if not running, insert `PROMPT_RESET` right before the mark; if running, nothing.
  - any other letter: nothing.
  After a mark the search goes on right after MARK (the letter and the rest of the mark pass through unchanged).
- The output with resets inserted is otherwise byte for byte the input; a reset never goes anywhere but directly before
  its mark's ESC.
- Split marks: the result must not depend on how the stream is cut. When a chunk (together with anything held from
  before) ends in a strict prefix of MARK, or in MARK with no letter yet, that tail is held back and parsed together
  with the next chunk; everything before it is returned now. Only such a tail is ever held: a chunk ending in
  `\x1b` alone or `\x1b]1` is held, one ending in `\x1bX` or `]133;` without the ESC is not. For any byte string and
  any way of cutting it, the concatenation of all `feed` results plus `flush()` equals the result of one `feed` of
  the whole string plus `flush()`.
- `KEYBOARD_RESET` and `PROMPT_RESET` are the module constants already in the file; keep their values.
