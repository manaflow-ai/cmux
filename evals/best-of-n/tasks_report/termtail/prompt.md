# Pinned terminal ticker shows half a window title, and loses the line after a long link

The sidebar ticker for a pinned terminal (`TailLine` in `termtail.py`, fed the terminal's raw output chunk by chunk as
it is read) should show the last non-empty line the terminal printed. Two bugs:

1. A program set the window title with a line break in it (`\x1b]0;one\ntwo\x07`) and the ticker showed `two`. A
   title is not printed text.
2. A line with a hyperlink whose escape is longer than `MAX_LINE_BYTES` (`ok \x1b]8;;https://example.com/uuu...\x1b\\link\x1b]8;;\x1b\\`)
   showed `ok` without its `link`: everything after the long escape was lost.
