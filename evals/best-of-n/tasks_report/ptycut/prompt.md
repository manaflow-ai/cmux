# Mouse wheel over Codex types `[<65;30;7M` into its composer

Scrolling fast with the mouse wheel over Codex in a cmux terminal on macOS sometimes types text like `[<65;30;7M`
into Codex's composer. Each wheel step reaches the program as an escape sequence (`ESC [<65;30;7M`, 11 bytes).

A macOS PTY holds at most `CAPACITY` (1022) bytes of input; when it is nearly full, `cut(buffer, room, capacity)` in
`ptycut.py` decides how many leading bytes of our pending input to write into the `room` bytes left (or `None` to write
nothing and wait for room). Today it writes all the room there is, wherever that falls. When a write stops inside an
escape sequence, Codex's read ends with the start of the sequence: it takes the ESC for the Esc key and the rest as
typed text.

An escape sequence (an ESC up to the next ESC) should never be split if it could still be written whole later. Text
can be cut anywhere, and a write should still use as much of the room as it safely can, or input stalls. Careful: a
sequence longer than the whole queue can never be written whole, so it must not wait forever either (it has to be cut, but a write that ends on its ESC is exactly the bug above).
