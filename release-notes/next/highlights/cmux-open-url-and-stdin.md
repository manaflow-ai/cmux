title: cmux open opens URLs, also from stdin
category: fixed
action: none

`cmux open <url>` opens a browser tab again: in the pane of the terminal you run it from, in the pane of `--workspace <ws_…>` (without moving your view), or in the focused pane. When the window shows Home, the tab opens in one of the window's workspaces and the window shows it. `cmux open -` reads one URL per line from stdin, so a URL that carries a token never appears in the process list; it checks every line before it opens any and stops at the first URL the app refuses.
