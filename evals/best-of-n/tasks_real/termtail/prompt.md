Fix `TailLine` in `termtail.py`. It reads a pinned terminal's raw output, chunk by chunk as the reader gets it, and
keeps the last non-empty line the terminal printed, for a one-line ticker in the sidebar.

Bug report (from cmux commit 8c14cae03c5, CMUX-283): lines are split on every `\n` and `\r` before escapes are
stripped, so a window title or shell-integration string holding a line break ends a line inside it and shows its rest
(`\x1b]0;one\ntwo\x07` shows `two`). And a link whose escape runs past `MAX_LINE_BYTES` is cut in half, and stripping
the open half takes the rest of the line with it.

Wanted behavior (constants `MAX_LINE_BYTES = 1024`, `MAX_TAIL_CHARS = 160`, `MAX_TAIL_BYTES = 480` stay as they are):

- `feed(data: bytes) -> bool` reads the next chunk and returns whether the tail has a change not taken yet.
  `take_change() -> str | None` returns the tail if it changed since the last `take_change` (else `None`) and clears
  the flag. `tail` (an attribute) is the current tail, `None` before any; `pending` (a `bytearray` attribute) holds the
  text bytes of the line being printed.
- Escapes are parsed byte by byte as they come, with the state kept across chunks, and never kept in `pending`. With
  ESC = `0x1b`, BEL = `0x07`, CAN = `0x18`, SUB = `0x1a`:
  - CAN or SUB, in any state, ends any escape (back to text) and is itself dropped.
  - In text: ESC starts an escape; `\n` or `\r` ends the line; any other byte goes to `pending` while `pending` has
    fewer than `MAX_LINE_BYTES` bytes (later bytes of a long line are dropped; escapes after them still parse).
  - After ESC: `[` starts a CSI; `]`, `P`, `X`, `^` or `_` starts a string (OSC, DCS, SOS, PM, APC); ESC starts a new
    escape; `\n` or `\r` ends the line and stays in this state; any other byte ends the escape (a two-byte escape such
    as `ESC 7`).
  - In a CSI: a byte in `0x40..0x7e` ends it; ESC starts a new escape; `\n` or `\r` ends the line and stays in the CSI;
    other bytes are part of it.
  - In a string: BEL ends it; ESC moves to "ESC inside a string"; every other byte, `\n` and `\r` included, is part of
    the string (it ends no line).
  - ESC inside a string: the same as after ESC (`\` thus ends the string as ST, `[` starts a CSI, and so on), except
    that `\n` and `\r` there are just a byte that ends the escape and do not end the line.
- Ending a line: if `pending` is empty, nothing happens. Else the bytes are decoded as UTF-8 (invalid bytes become
  U+FFFD), cleaned with `clean_line`, and `pending` is emptied. A cleaned line that is empty, or equal to the current
  tail, changes nothing; any other becomes the tail and marks a change.
- `clean_line(text: str) -> str`: tabs become spaces; other control characters (Unicode category `Cc`) are dropped; a
  space is dropped at the start or after another space (runs fold to one); the result stops before the character that
  would make it longer than `MAX_TAIL_CHARS` characters or `MAX_TAIL_BYTES` UTF-8 bytes; trailing whitespace is
  trimmed.
- A line still being printed (no `\n` or `\r` yet) is not the tail: a progress bar redrawn after `\r` shows its newest
  finished frame.
