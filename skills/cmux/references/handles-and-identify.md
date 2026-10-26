# Selectors and Identify

Every instance selector is a public id, `current`, or an exact name. Ids are typed (`ws_…`, `screen_…`, `pane_…`, `tab_…`, `term_…`, `browser_…`, `notification_…`, `agent_…`) and stay stable across app and daemon restarts. `name:<value>` forces a name. The old `window:N`, `workspace:N`, `pane:N` and `surface:N` refs and `--id-format` are gone.

```bash
cmux app identify                                  # app bundle, tag, control socket
cmux terminal "$CMUX_TUI_TERMINAL_ID" show --json  # the caller terminal and its tabs
cmux tab tab_… show --json                         # a tab and its pane
cmux workspace current show --json                 # the focused workspace
cmux workspace name:api show                       # by exact name
```

`current` resolves to the caller's own workspace, screen, pane and tab (its terminal's place, or where the app shows its agent chat); `focused` resolves to the one the person looks at. A nested `current` or name fills missing ancestors with `current` (`focused` with `focused`); an id needs no ancestors. Outside cmux, or with `--socket`/`--session`, `current` is that session's active object.
