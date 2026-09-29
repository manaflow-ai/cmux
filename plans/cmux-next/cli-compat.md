# cmux next: old `cmux` CLI compatibility

The shipped `cmux` CLI (`CLI/cmux.swift`), agent hooks, and shell integration talk to cmux-next through `CmuxNextControl/Compat/`. Old verb names, params, UUIDs, and `workspace:N` / `pane:N` / `surface:N` / `window:N` refs keep working. Methods the new app does not implement answer `{"ok":false,"error":{"code":"unsupported","message":"unsupported in cmux-next: <reason>"}}`, never a hang or a silent success.

## How it works

- Registration: `CompatService.install(on: router)` registers `ControlMethod`s on the lanes from architecture.md 5a, plus two router seams: `registerV1` (v1 text verbs) and `registerUnknownMethod` (typed `unsupported` for any unregistered method in an old namespace, `method_not_found` otherwise).
- Reads (`*.list`, `*.current`, `system.tree`, `system.identify`, `window.*` reads, `agent.resolve_delivery_target`) are `snapshot` methods over `ControlSnapshot.topology`. They never touch the main actor and never wait.
- Daemon verbs are `async` methods under the request deadline (2 s). They go straight to cmux-tui, the serialization point. Creation verbs read one fresh `list-workspaces` so they can report the refs of what they made.
- App-local changes (show a workspace in a window, focus a pane, select a tab, open/focus/close a window) run on the main actor through the router's bounded `MainActorWorkQueue` (`CompatFrontend.perform`, implemented by `AppCompatFrontend`). Browser page operations call `CompatFrontend.browser`, which hops to the main actor for WebKit/CEF.
- IDs: workspace UUID = durable workspace key; pane and surface UUIDs = the 32 hex digits of `pane_…` / `tab_…` resource ids (stable across app and daemon restarts). A surface also resolves by the UUID form of its terminal id. Refs are minted per kind on first sight, never reused in one app process, and start at 1 (the old app started at 1,000,000,000 and persisted blocks; scripts that only store refs within one run are unaffected).
- Windows: every window's sidebar lists every workspace, so `workspace.list` returns all workspaces and `selected` means "shown in the target window".

## Status by method, ranked by use

Usage columns: tests_v2 calls/files, skills mentions (via the CLI verb), and whether agent hooks or shell integration send it at runtime. Status: **impl** (fully backed), **daemon** (forwarded to a cmux-tui command), **app** (App intent through the work queue), **unsup** (typed unsupported, reason given).

| Method / v1 verb | tests_v2 | skills | hooks | CLI verbs | Status |
| --- | --- | --- | --- | --- | --- |
| workspace.create | 116/79 | 8 | | new-workspace, workspace create | daemon `create-workspace` + `create-terminal` (cwd, initial_command, initial_env, focus, group_id); `layout` unsup: "create, then split" |
| workspace.select | 97/61 | 1 | | select-workspace | app |
| surface.list | 89/50 | 1 | yes | list-panels | impl (snapshot) |
| workspace.close | 84/57 | 2 | | close-workspace | daemon `close-workspace` |
| surface.split | 80/30 | 4 | | new-split | daemon `split` (right/down); left/up and browser via `new-tab` + `move-tab-to-split` |
| workspace.current | 70/28 | 2 | yes | current-workspace | impl (snapshot) |
| debug.* (app.activate, shortcut.simulate, terminal.read_text, command_palette.*, layout, …) | 69/37 and more | 0 | | none | unsup: old-app debug methods |
| surface.focus | 68/21 | 1 | | focus-panel | app |
| workspace.list | 67/27 | 1 | yes | list-workspaces | impl (snapshot) |
| surface.send_text | 57/28 | 4 | | send, send-panel | daemon `send` |
| pane.list | 46/20 | 2 | | list-panes | impl (snapshot) |
| surface.read_text | 41/26 | 1 | | read-screen | daemon `read-screen`; `scrollback`/`lines` add `read-scrollback` |
| browser.eval | 38/11 | 1 | | browser eval | app (engine eval, JSON-safe via toJSON) |
| surface.send_key | 29/13 | 8 | | send-key | daemon `send-key` (old names mapped: enter, esc, ctrl-c, sigint, shift+tab, …) |
| workspace.remote.* | 23/16 | 0 | | ssh | unsup: cmux-remote replaces the remote mirror |
| surface.close | 22/7 | 3 | | close-surface | daemon `close-terminal` / `close-surface` |
| window.focus / window.close | 22/18, 14/14 | 2 | | focus-window, close-window (v1) | app (v2 and v1 `focus_window`, `close_window`) |
| window.current / v1 current_window | 22/20 | 0 | | current-window | impl (snapshot) |
| notification.clear / v1 clear_notifications | 22/4 | 0 | yes (v1) | clear-notifications, notify --clear | daemon `ack-tab-notifications` per unread tab |
| app.focus_override.set, app.simulate_active | 22/3 | 0 | | set-app-focus | unsup: old-app debug feature |
| browser.navigate | 21/9 | 8 | | browser goto/navigate | app |
| browser.open_split | 18/14 | 12 | | browser open | daemon `new-frontend-browser-tab` + `move-tab-to-split` (always a new split; the old "reuse right sibling" policy is not implemented) |
| surface.create | 18/12 | 7 | | new-surface | daemon `new-tab` / `new-frontend-browser-tab`; dock placement and providers unsup |
| pane.focus | 16/10 | 2 | | focus-pane | app |
| surface.health | 16/10 | 2 | | surface-health | impl (snapshot) |
| window.list / v1 list_windows | 16/15 | 3 | yes | list-windows | impl (snapshot) |
| workspace.rename | 14/9 | 0 | | rename-workspace, rename-window | daemon `rename-workspace` (clears a sidebar title override) |
| browser.url.get, browser.get.url, browser.get.title | 13/7 | 2 | | browser url, get title | app |
| system.identify | 14/11 | 15 | | identify | impl (snapshot): focused + caller objects |
| browser.focus_webview, browser.is_webview_focused | 11/8, 10/7 | 0 | | focus-webview | unsup |
| notification.create / create_for_target / create_for_caller / create_for_surface | 11/2 + 3/2 | 9 | | notify | daemon `notify` (subtitle folded into the body) |
| notification.list / v1 list_notifications | 11/3 | 1 | | list-notifications | daemon `list-notifications` |
| surface.drag_to_split, surface.split_off | 10/2 | 4 | | drag-surface-to-split, split-off | unsup: use surface.move |
| browser.cookies.*, storage, download, console, dialog, frame, … (≈85 methods) | ≈2 each | 6+ | | browser … | unsup (namespace) |
| pane.surfaces | 9/8 | 4 | | list-pane-surfaces | impl (snapshot) |
| browser.click / fill / type / focus / get.text / get.value | 8/4 … | 7–26 | | browser click/fill/… | app (selector or snapshot ref `eN`) |
| browser.wait | 7/5 | 18 | | browser wait | unsup: page waits need a Promise-aware eval |
| system.capabilities | 7/7 | 4 | | capabilities | impl (snapshot) |
| pane.create | 7/4 | 8 | | new-pane | daemon (see surface.split); dock placement unsup |
| tab.action / surface.action | 6/2 + 4/4 | 1 | | tab-action, rename-tab | daemon: rename, clear_name, pin, unpin, close, close_others/left/right, move_to_new_workspace |
| surface.current | 6/6 | 0 | | none | impl (snapshot) |
| system.ping / v1 ping | 5/4 | 4 | | ping | impl |
| window.create / v1 new_window | 5/5 | 0 | | new-window | app |
| pane.resize | 5/4 | 0 | | resize-pane | unsup |
| browser.snapshot | 4/4 | 21 | | browser snapshot | app (role outline with `[ref=eN]`, page title/url/text) |
| browser.screenshot | 4/4 | 5 | | browser screenshot | unsup |
| surface.move / surface.reorder | 4/4 + 1/1 | 6 + 1 | | move-surface, reorder-surface | daemon `move-tab` / `move-tab-to-workspace` |
| pane.swap | 2/2 | 0 | | swap-pane | daemon `swap-pane` |
| pane.break / pane.join / pane.last | 2/2 | 0 | | break/join/last-pane | unsup |
| workspace.reorder | 1/1 | 1 | | reorder-workspace | daemon `move-workspace` |
| workspace.next / previous | 1/1 | 0 | | next/previous-window | app |
| workspace.last | 1/1 | 0 | | last-window | unsup: no focus history yet |
| workspace.action | 1/1 | 7 | | workspace-action | unsup: use `cmux action run` |
| workspace.move_to_window | 1/1 | 2 | | move-workspace-to-window | unsup: windows do not own workspaces |
| surface.trigger_flash | 1/1 | 3 | | trigger-flash | unsup |
| surface.clear_history | 1/1 | 0 | | clear-history | daemon `clear-history` |
| terminal.paste | 1/1 | 0 | | paste | daemon `send` with `paste` |
| system.tree | 0 | 10 | | tree | impl (snapshot) |
| notification.dismiss / mark_read / jump_to_unread | 0 | 1 | | dismiss-notification, … | daemon ack (the ledger has no delete) / app for jump |
| feed.push | 0 | 3 | yes (every hook) | hooks feed | unsup: the agent feed is not in cmux-next yet |
| agent.resolve_delivery_target | 0 | 0 | yes | hooks | impl by surface_id; pid routing answers "No live delivery target" |
| agent.hook.*, surface.resume.*, workspace.set_auto_title, surface.sync_codex_native_title, agent.hibernation.* | 0 | 0 | yes | hooks | unsup: agent state moves to cmux-tui report-agent |
| v1 set_status / clear_status / list_status | 3/1 (CLI) | 2 | yes | set-status, … | impl: in-memory per workspace (bounded), not rendered in the sidebar yet |
| v1 set_progress / clear_progress / log / clear_log / list_log / sidebar_state | CLI | 1–2 | | set-progress, log, sidebar-state | impl (same store; sidebar_state reads cwd/branch from cmux-tui) |
| v1 set_agent_pid / clear_agent_pid | 0 | 0 | yes | hooks | impl (stored) |
| v1 report_pwd / report_git_branch / report_pr / report_tty / ports_kick | 0 | 0 | shell integration | none | accepted (`OK`): cmux-tui derives cwd (OSC 7) and branch per tab itself |
| v1 notify_target / notify_target_async | 0 | 0 | yes (codex) | none | daemon `notify` |
| v1 agent_journal_append | 0 | 0 | yes (main hook notification path) | none | unsup |
| layout.*, session.*, vm.*, mobile.*, simulator.*, canvas.*, markdown.*, … | ≤2 | many (vm) | | | unsup (namespace reasons in `CompatUnsupported`) |

## Verification

<!-- RESULTS -->
