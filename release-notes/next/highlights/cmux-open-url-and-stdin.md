title: cmux open opens URLs, also from stdin
category: fixed
docs: https://cmux.com/docs/api

`cmux open <url>` opens a browser tab again, in the pane you run it from or the focused pane. `cmux open -` reads URLs from stdin, so a URL that carries a token never shows in the process list.
