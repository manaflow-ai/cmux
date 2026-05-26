# cmux.json settings

Global app preferences live in `~/.config/cmux/cmux.json`.

## `app.confirmQuit`

Controls when cmux asks before quitting:

- `always`: show the quit confirmation on Cmd+Q or app quit.
- `dirty-only`: show it only when a workspace has a terminal or panel that reports close confirmation is needed.
- `never`: quit immediately.

Default: `always` for stable and nightly builds. DEV builds always behave as `never`, regardless of the file setting, so tagged development builds can be replaced without a full-screen quit dialog.

The older boolean `app.warnBeforeQuit` still works as a fallback when `app.confirmQuit` is not set. `true` maps to `always`; `false` maps to `never`.

## `terminal.sessionBackend`

Controls how new local terminal surfaces are launched:

- `native`: start the normal Ghostty-backed shell managed by cmux.
- `zellij`: start eligible local terminals with `zellij attach --create --force-run-commands <stable-session-name>`
  and zellij options for detach-on-close, session serialization, full scrollback
  serialization, and Kitty keyboard protocol support.

Default: `native`.

The zellij backend is opt-in and applies to newly-created local terminals that do
not already have an explicit startup command, restored agent resume input, tmux
resume command, or remote attach command. Existing zellij-backed surfaces persist
their zellij session name in cmux's session snapshot so relaunch reattaches to
the same zellij session. The `zellij` CLI must be on `PATH`.
