title: Browser tabs from the CLI open where you are
category: fixed
docs: https://cmux.com/docs/browser-automation

`cmux browser open` and `cmux tab create browser` now open a real browser tab in the caller's pane, or in the focused pane of the front window when you run them from an SSH shell. The tab uses your default browser engine and profile.
