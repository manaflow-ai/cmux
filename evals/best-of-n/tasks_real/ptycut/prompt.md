Fix `cut` in `ptycut.py`. It decides how much of a pending write to hand to a macOS PTY master right now.

Bug report (from cmux commit f7f9702ce84, "never cut an escape sequence after its ESC on a full macOS PTY"): a mouse
wheel over Codex typed `[<65;30;7M` into its composer. A macOS PTY holds at most `CAPACITY` (1022) bytes of input for
the program; a write that does not fit is taken byte by byte until the queue is full. When the queue fills right after
an ESC, the program's next read ends in a lone ESC: the TUI reads that as the Esc key and types the rest of the escape
sequence as text. Today `cut` hands over all the room there is, wherever that falls.

`cut(buffer: bytes, room: int, capacity: int = CAPACITY) -> int | None` returns how many leading bytes of `buffer` to
write now into `room` free bytes of the queue, or `None` to write nothing yet and wait for room. ESC is the byte
`0x1b`; "a sequence" is an ESC and everything up to the next ESC (or the end of the buffer).

- A buffer that fits (`len(buffer) <= room`) is written whole: return `len(buffer)`.
- Otherwise, if an ESC starts at some index `i` with `1 <= i <= room`, return the largest such `i`: everything before
  the last escape sequence that starts within the room (an ESC at index `room` itself counts: the room is filled
  exactly and the next write starts on that ESC). An ESC at index 0 never counts here.
- Otherwise, if the buffer starts with ESC: when its first sequence (index 0 up to, not including, the next ESC, or the
  whole buffer when there is none) is at most `capacity` bytes long, or `room` is 0, return `None` (it waits until it
  can start whole). A first sequence longer than `capacity` could never fit even an empty queue, so it falls through
  to the next rule.
- Otherwise (text with no ESC to cut at): with `room` 0 return `None`; when the byte at index `room - 1` is ESC, return
  `room - 1` if that is at least 1, else `None`; else return `room`. The result never ends right after an ESC.
- `room` is never negative; `capacity` is positive.
