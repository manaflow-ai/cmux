# V2 Socket API + Test Migration

This doc tracks the migration from the existing v1 line protocol (space-delimited commands) to a v2 JSON protocol intended for LLM agents.

## Goals

- Add a **v2 JSON socket protocol** (handle-based: `window_id`, `workspace_id`, `pane_id`, `surface_id`).
- Keep **v1 fully working** until v2 reaches feature parity.
- Re-implement the existing automated test suite to use **v2**.
- Run both suites:
  - v1 tests (existing `tests/`)
  - v2 tests (new `tests_v2/`)

## Non-Goals (for initial parity)

- Removing v1.
- Changing existing v1 behaviors/output formats.

## Status

- [x] Implement v2 request/response envelope (JSON, newline-delimited)
- [x] Implement v2 core methods (workspaces/surfaces/panes/input/notifications/browser)
- [x] Implement v2 multi-window methods (windows + cross-window workspace moves)
- [x] Add `surface.trigger_flash` (agent-visible highlight for a surface)
- [x] Implement v2 debug/test methods (simulate typing, render stats, screenshots, etc.)
- [x] Add `tests_v2/` using v2 client
- [x] Add runners for v1 + v2 suites on the VM (`./scripts/run-tests-v1.sh`, `./scripts/run-tests-v2.sh`)
- [x] Verify v1 suite passes (VM)
- [x] Verify v2 suite passes (VM)

Notes:
- A close-top nested split sequence (T-shape) could leave terminal views detached from the window until the user switched workspaces.
  Fix: a debounced post-close reattach pass (see `Sources/Workspace.swift`, `Sources/Panels/TerminalPanel.swift`).

## V2 Protocol Sketch

Each request is one JSON object per line:

```json
{"id":"1","method":"workspace.list","params":{}}
```

Each response is one JSON object per line:

```json
{"id":"1","ok":true,"result":{...}}
```

Errors:

```json
{"id":"1","ok":false,"error":{"code":"not_found","message":"workspace not found"}}
```

Notes:
- `id` is echoed back when present (string or number).
- v2 methods should accept **IDs**; v2 responses may include ephemeral `index` fields for ordering/debugging, but IDs are the stable handles.

## Method Parity Checklist (v1 -> v2)

Windows:
- [x] list_windows -> `window.list`
- [x] current_window -> `window.current`
- [x] focus_window -> `window.focus`
- [x] new_window -> `window.create`
- [x] close_window -> `window.close`
- [x] move_workspace_to_window -> `workspace.move_to_window`

Workspaces:
- [x] list_workspaces -> `workspace.list`
- [x] new_workspace -> `workspace.create`
- [x] select_workspace -> `workspace.select`
- [x] current_workspace -> `workspace.current`
- [x] close_workspace -> `workspace.close`

Surfaces / Splits:
- [x] list_surfaces -> `surface.list`
- [x] focus_surface / focus_surface_by_panel -> `surface.focus`
- [x] new_split -> `surface.split`
- [x] new_surface -> `surface.create`
- [x] close_surface -> `surface.close`
- [x] drag_surface_to_split -> `surface.drag_to_split`
- [x] refresh_surfaces -> `surface.refresh`
- [x] surface_health -> `surface.health`
- [x] trigger_flash -> `surface.trigger_flash` (new in v2)

Panes:
- [x] list_panes -> `pane.list`
- [x] focus_pane -> `pane.focus`
- [x] list_pane_surfaces -> `pane.surfaces`
- [x] new_pane -> `pane.create`

Input:
- [x] send / send_surface -> `surface.send_text`
- [x] send_key / send_key_surface -> `surface.send_key`

Notifications:
- [x] notify -> `notification.create`
- [x] notify_surface -> `notification.create_for_surface`
- [x] notify_target -> `notification.create_for_target`
- [x] list_notifications -> `notification.list`
- [x] clear_notifications -> `notification.clear`
- [x] set_app_focus -> `app.focus_override.set`
- [x] simulate_app_active -> `app.simulate_active`

Browser:
- [x] open_browser -> `browser.open_split`
- [x] navigate -> `browser.navigate`
- [x] browser_back -> `browser.back`
- [x] browser_forward -> `browser.forward`
- [x] browser_reload -> `browser.reload`
- [x] get_url -> `browser.url.get`
- [x] focus_webview -> `browser.focus_webview`
- [x] is_webview_focused -> `browser.is_webview_focused`

Debug / Test-only:
- [x] set_shortcut -> `debug.shortcut.set`
- [x] simulate_shortcut -> `debug.shortcut.simulate`
- [x] simulate_type -> `debug.type`
- [x] activate_app -> `debug.app.activate`
- [x] is_terminal_focused -> `debug.terminal.is_focused`
- [x] read_terminal_text -> `debug.terminal.read_text`
- [x] render_stats -> `debug.terminal.render_stats`
- [x] layout_debug -> `debug.layout`
- [x] bonsplit_underflow_count/reset -> `debug.bonsplit_underflow.*`
- [x] empty_panel_count/reset -> `debug.empty_panel.*`
- [x] focus_notification -> `debug.notification.focus`
- [x] flash_count/reset -> `debug.flash.*`
- [x] panel_snapshot/panel_snapshot_reset -> `debug.panel_snapshot.*`
- [x] screenshot -> `debug.window.screenshot`

## Test Migration

v1 suite stays in `tests/`.

v2 suite lives in `tests_v2/` and should:
- use a v2 JSON client (`tests_v2/cmux.py`)
- avoid depending on v1 text output formats

VM runners:
- v1: `ssh cmux-vm 'cd /Users/cmux/cmux && ./scripts/run-tests-v1.sh'`
- v2: `ssh cmux-vm 'cd /Users/cmux/cmux && ./scripts/run-tests-v2.sh'`

## Open Questions

- Should v2 require explicit `workspace_id`/`surface_id` for all operations, or default to the currently-focused ones?
- For move/reorder operations (future): what are the policies for empty workspaces/windows?
