# Selectors and Identify

Every instance selector is a public id, `caller`, `current`, `focused`, or an exact name. Ids are typed (`ws_…`, `screen_…`, `pane_…`, `tab_…`, `term_…`, `browser_…`, `notification_…`, `agent_…`) and stay stable across app and daemon restarts. `name:<value>` forces a name. The old `window:N`, `workspace:N`, `pane:N` and `surface:N` refs and `--id-format` are gone.

```bash
cmux app identify                                  # app bundle, tag, control socket
cmux terminal "$CMUX_TUI_TERMINAL_ID" show --json  # the caller terminal and its tabs
cmux tab tab_… show --json                         # a tab and its pane
cmux workspace caller show --json                  # the workspace this command runs in
cmux pane caller split --right                     # split the caller's own pane
cmux workspace name:api show                       # by exact name
```

`caller` resolves to the caller's own workspace, screen, pane, tab and terminal: the cmux terminal (`CMUX_TUI_TERMINAL_ID`) or agent chat (`CMUX_AGENT_SESSION`) the command runs in. It fails when there is no caller or the command names another session with `--socket`/`--session`. `current` is the caller's object as well whenever a caller is known; without one (a shell outside cmux, or `--socket`/`--session`) it is the session's focused workspace, screen and pane. `focused` is always the one the person looks at (the app's focus). A nested `caller`, `current` or name fills missing ancestors with `current`; an id needs no ancestors.
