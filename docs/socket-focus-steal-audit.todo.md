# Socket/CLI No-Focus-Steal Todo

## Goal
Ensure commands run through the cmux Unix socket/CLI do not steal user focus from the current UI workflow.

Policy target:
- App activation/window raising from socket commands: **never**.
- In-app focus mutation from socket commands: only for explicit focus-intent commands.
- Non-focus commands must not move workspace/pane/surface focus as a side effect.

## Task Checklist
- [x] Inventory all v1 + v2 socket command entrypoints.
- [x] Add socket-command focus policy context in `TerminalController`.
- [x] Suppress app activation for socket command path in `AppDelegate` (`focusMainWindow`, `createMainWindow`).
- [x] Gate in-app focus mutation side-effects in v2 handlers.
- [x] Gate in-app focus mutation side-effects in legacy v1 handlers.
- [x] Add explicit CLI `rename-tab` command with env-default targeting.
- [x] Update CLI help/usage/subcommand docs for `rename-tab`.
- [x] Add regression tests for rename-tab and no-unintended-focus-side-effects.
- [x] Run build + targeted tests.
- [ ] Open PR.

## Explicit Focus-Intent Allowlist
These may mutate in-app focus/selection state:

v1:
- `focus_window`
- `select_workspace`
- `focus_surface`
- `focus_pane`
- `focus_surface_by_panel`
- `focus_webview`
- `focus_notification` (debug)
- `activate_app` (debug)

v2:
- `window.focus`
- `workspace.select`
- `workspace.next`
- `workspace.previous`
- `workspace.last`
- `surface.focus`
- `pane.focus`
- `pane.last`
- `browser.focus_webview`
- `browser.focus`
- `browser.tab.switch`
- `debug.notification.focus`
- `debug.app.activate`

All other commands should preserve current user focus context.

## Command Coverage Matrix (All Command Families)
- [x] v1 `ping`, `help`
- [x] v1 window commands (`list_windows`, `current_window`, `focus_window`, `new_window`, `close_window`)
- [x] v1 workspace commands (`move_workspace_to_window`, `list_workspaces`, `new_workspace`, `close_workspace`, `select_workspace`, `current_workspace`)
- [x] v1 surface/pane commands (`new_split`, `list_surfaces`, `focus_surface`, `list_panes`, `list_pane_surfaces`, `focus_pane`, `focus_surface_by_panel`, `drag_surface_to_split`, `new_pane`, `new_surface`, `close_surface`, `refresh_surfaces`, `surface_health`)
- [x] v1 input commands (`send`, `send_key`, `send_surface`, `send_key_surface`, `read_screen`)
- [x] v1 notification/status/log/report commands (`notify*`, `list_notifications`, `clear_notifications`, `set_status`, `clear_status`, `list_status`, `log`, `clear_log`, `list_log`, `set_progress`, `clear_progress`, `report_*`, `ports_kick`, `sidebar_state`, `reset_sidebar`)
- [x] v1 browser commands (`open_browser`, `navigate`, `browser_back`, `browser_forward`, `browser_reload`, `get_url`, `focus_webview`, `is_webview_focused`)
- [x] v1 debug/test commands (shortcut, type, drop/pasteboard, overlay probes, focus checks, screenshots, render/layout/flash/panel snapshot)

- [x] v2 system methods (`system.*`)
- [x] v2 window methods (`window.*`)
- [x] v2 workspace methods (`workspace.*`)
- [x] v2 surface methods (`surface.*`, `tab.action`)
- [x] v2 pane methods (`pane.*`)
- [x] v2 notification methods (`notification.*`)
- [x] v2 app methods (`app.*`)
- [x] v2 browser methods (full `browser.*` set including tab/network/trace/input)
- [x] v2 debug methods (`debug.*`)

## CLI Coverage
- [x] Ensure every top-level CLI command routes to non-focus-stealing socket behavior.
- [x] Add/verify `rename-workspace` + `rename-window` behavior remains intact.
- [x] Add explicit `rename-tab` command (defaults to `CMUX_TAB_ID` / `CMUX_SURFACE_ID` / `CMUX_WORKSPACE_ID` when flags omitted).
