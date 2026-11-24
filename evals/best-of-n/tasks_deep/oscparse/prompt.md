Fix the OSC stream parser in `oscparse.py`.

Bug report: "After `cd ~/src/cmux` the sidebar sometimes keeps showing the old directory. It happens when a read
from the PTY ends right after the ESC of the ST terminator, so the shell's `ESC ] 7;file://mac/Users/leo/src/cmux
ESC \` arrives as `...cmux ESC` and then `\$ ` in the next chunk: no Cwd event at all, and a stray `\$ ` shows up."

Contract. One `OscParser` reads one stream, chunk by chunk. The events must not depend on where the stream is cut
into chunks: feeding it in any pieces yields the same events, in the same order, as feeding it in one piece, except
that the text may be divided among `Text` events differently (adjacent `Text` events concatenate to the same
string). Nothing is decided before the bytes that decide it have arrived. Everything else (which sequences become
which events, what counts as text) stays as the module docstring and `decode_osc` define it.
