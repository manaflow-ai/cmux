# cmux next: old `cmux` CLI compatibility

The shipped `cmux` CLI (`CLI/cmux.swift`), agent hooks, and shell integration talk to cmux-next through `CmuxNextControl/Compat/`. Old verb names, params, UUIDs, and `workspace:N` / `pane:N` / `surface:N` / `window:N` refs keep working. Methods the new app does not implement answer `{"ok":false,"error":{"code":"unsupported","message":"unsupported in cmux-next: <reason>"}}`, never a hang or a silent success.

## How it works

- Registration: `CompatService.install(on: router)` registers `ControlMethod`s on the lanes from architecture.md 5a, plus two router seams: `registerV1` (v1 text verbs) and `registerUnknownMethod` (typed `unsupported` for any unregistered method in an old namespace, `method_not_found` otherwise).
- App-state reads (`system.ping`, `system.capabilities`, `window.list`, `window.current`) are `snapshot` methods over `ControlSnapshot`. Reads that name daemon objects (`*.list`, `*.current`, `system.tree`, `system.identify`, `agent.resolve_delivery_target`) are `async` methods: one fresh `list-workspaces` joined with the snapshot's app-local state (windows, focus, selection), so a read that follows a write sees it. Neither touches the main actor.
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
| surface.list | 89/50 | 1 | yes | list-panels | impl (fresh read) |
| workspace.close | 84/57 | 2 | | close-workspace | daemon `close-workspace` |
| surface.split | 80/30 | 4 | | new-split | daemon `split` (right/down); left/up and browser via `new-tab` + `move-tab-to-split` |
| workspace.current | 70/28 | 2 | yes | current-workspace | impl (fresh read) |
| debug.* (app.activate, shortcut.simulate, terminal.read_text, command_palette.*, layout, …) | 69/37 and more | 0 | | none | unsup: old-app debug methods |
| surface.focus | 68/21 | 1 | | focus-panel | app |
| workspace.list | 67/27 | 1 | yes | list-workspaces | impl (fresh read) |
| surface.send_text | 57/28 | 4 | | send, send-panel | daemon `send` |
| pane.list | 46/20 | 2 | | list-panes | impl (fresh read) |
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
| surface.health | 16/10 | 2 | | surface-health | impl (fresh read) |
| window.list / v1 list_windows | 16/15 | 3 | yes | list-windows | impl (snapshot) |
| workspace.rename | 14/9 | 0 | | rename-workspace, rename-window | daemon `rename-workspace` (clears a sidebar title override) |
| browser.url.get, browser.get.url, browser.get.title | 13/7 | 2 | | browser url, get title | app |
| system.identify | 14/11 | 15 | | identify | impl (fresh read): focused + caller objects |
| browser.focus_webview, browser.is_webview_focused | 11/8, 10/7 | 0 | | focus-webview | unsup |
| notification.create / create_for_target / create_for_caller / create_for_surface | 11/2 + 3/2 | 9 | | notify | daemon `notify` (subtitle folded into the body) |
| notification.list / v1 list_notifications | 11/3 | 1 | | list-notifications | daemon `list-notifications` |
| surface.drag_to_split, surface.split_off | 10/2 | 4 | | drag-surface-to-split, split-off | unsup: use surface.move |
| browser.cookies.*, storage, download, console, dialog, frame, … (≈85 methods) | ≈2 each | 6+ | | browser … | unsup (namespace) |
| pane.surfaces | 9/8 | 4 | | list-pane-surfaces | impl (fresh read) |
| browser.click / fill / type / focus / get.text / get.value | 8/4 … | 7–26 | | browser click/fill/… | app (selector or snapshot ref `eN`) |
| browser.wait | 7/5 | 18 | | browser wait | unsup: page waits need a Promise-aware eval |
| system.capabilities | 7/7 | 4 | | capabilities | impl (snapshot) |
| pane.create | 7/4 | 8 | | new-pane | daemon (see surface.split); dock placement unsup |
| tab.action / surface.action | 6/2 + 4/4 | 1 | | tab-action, rename-tab | daemon: rename, clear_name, pin, unpin, close, close_others/left/right, move_to_new_workspace |
| surface.current | 6/6 | 0 | | none | impl (fresh read) |
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
| system.tree | 0 | 10 | | tree | impl (fresh read) |
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

Tagged build `clic` (local, clean environment, `CMUX_NEXT_NO_ACTIVATE=1`, `CMUX_NEXT_SOCKET_MODE=automation`), socket `/tmp/cmux-debug-clic.sock`, cmux-tui pinned `4adc02c`, 2026-09-29.

- `swift test --filter CmuxNextControlTests`: 56 tests pass (compat: UUID/ref derivation, resolution by UUID/ref/index/terminal alias, focus from app state, v1 tokenizing, key mapping, sidebar ordering and bounds, typed unsupported errors, fail-fast without a daemon, deadline).
- `scripts/cmux-next/cli-compat-e2e.py` (40 `cmux …` commands with asserted output: ping, capabilities, identify, windows, workspace create/rename/select/current/list/close, tree, new-split, new-pane, new-surface, list-panes/pane-surfaces/panels, focus-pane, send, send-key, read-screen (plus `--lines --scrollback`), rename-tab, notify, list/clear-notifications, set-status, list-status, set-progress, log, sidebar-state, env caller identify, browser open/eval/url, typed unsupported): **40/40 pass**.
- `scripts/cmux-next/cli-compat-tests-v2.py` over `tests_v2/test_*.py` (125 files): **17 pass, 81 fail, 2 timeout, 25 not run** (4 drive the user's GUI via osascript or measure the release app, 21 need SSH hosts or Cloud VMs). 39 of the failures call old-app `debug.*` methods (command palette, shortcut simulation, panel snapshots, layout dumps), which cmux-next does not port. The rest are listed below with causes. Counts are merged from two full runs: the last full run hit system-wide `PTY capacity exhausted` from test file 28 on, because other agents' leaked cmux-tui terminal hosts held 409 of the 511 PTYs; its passes count, and its later failures fall back to the previous run on the same code except the snapshot-publish fix, whose two affected files were re-run.

History: first build 18 pass (daemon reads, own snapshot); moving reads to the published `ControlSnapshot` dropped to 15 because the snapshot lags writes (see Decisions); fresh reads and publish-after-intent restored them.

| File | Result | Cause |
| --- | --- | --- |
| background_read_text_starts_terminal | pass |  |
| background_split_send_text_starts_terminal | pass |  |
| background_workspace_idle_thread_footprint | fail | workspace.create layout unsupported |
| browser_api_comprehensive | fail | browser.wait unsupported |
| browser_api_extended_families | fail | browser.wait unsupported |
| browser_api_p0 | fail | browser.wait unsupported |
| browser_api_unsupported_matrix | fail | expects the full old browser method matrix in capabilities |
| browser_cli_agent_port | fail | browser.wait unsupported |
| browser_cli_wait_and_screenshot | fail | cmux.cmuxError: CLI failed (/Users/lawrence/Library/Developer/Xcode/DerivedData/cmux-clic/Build/Products/Debug/cmux DEV  |
| browser_custom_keybinds | fail | 2 test(s) failed. |
| browser_devtools_visibility_stability | fail | browser.focus_webview unsupported |
| browser_eval_domrect | fail | browser eval of DOMRect returns null |
| browser_file_url_load | pass |  |
| browser_goto_split | fail | Results: 0 passed, 2 failed |
| browser_hidden_screenshot_fresh | fail | browser.screenshot unsupported |
| browser_open_split_reuse_policy | fail | browser.open_split reuse policy not implemented |
| browser_panel_stability | fail | Results: 0 passed, 2 failed |
| cli_background_terminal_helpers_start_pty | fail | cmux.cmuxError: CLI failed (/Users/lawrence/Library/Developer/Xcode/DerivedData/cmux-clic/Build/Products/Debug/cmux DEV  |
| cli_browser_console_errors_text | fail | browser.wait unsupported |
| cli_global_flags_and_v1_error_contract | fail | bundled CLI crashes on --help (cmuxfoundation resource bundle missing) |
| cli_id_format_defaults | pass |  |
| cli_identify_ref_resolution | pass |  |
| cli_new_workspace_background_metadata | pass |  |
| cli_new_workspace_command_queue | pass |  |
| cli_new_workspace_external_git_branch_refresh | fail | sidebar git branch refresh (daemon branch polling differs) |
| cli_new_workspace_layout_command_queue | fail | workspace.create layout unsupported |
| cli_non_focus_commands_preserve_workspace | fail | cmux.cmuxError: CLI failed (/Users/lawrence/Library/Developer/Xcode/DerivedData/cmux-clic/Build/Products/Debug/cmux DEV  |
| cli_sidebar_metadata_commands | pass |  |
| close_surface_selection | fail | 2 test(s) failed |
| close_workspace_selection | fail | 2 test(s) failed |
| cloud_browser_userspace_e2e | not-run | needs CMUX_TEST_VM_ID |
| cloud_workspace_layout_sync | not-run | needs CMUX_TEST_VM_ID |
| command_palette_backspace_go_back | fail | old-app debug.* methods |
| command_palette_focus | fail | old-app debug.* methods |
| command_palette_focus_lock_workspace_spawn | fail | old-app debug.* methods |
| command_palette_fuzzy_ranking | fail | old-app debug.* methods |
| command_palette_modes | fail | old-app debug.* methods |
| command_palette_navigation_keys | fail | old-app debug.* methods |
| command_palette_rename_enter | fail | old-app debug.* methods |
| command_palette_rename_select_all | fail | old-app debug.* methods |
| command_palette_search_action_sync | fail | old-app debug.* methods |
| command_palette_search_typing_stability | fail | old-app debug.* methods |
| command_palette_shortcut_hint_sync | fail | old-app debug.* methods |
| command_palette_switcher_all_windows | fail | old-app debug.* methods |
| command_palette_switcher_cross_workspace_surface_focus | fail | old-app debug.* methods |
| command_palette_switcher_renamed_surface | fail | old-app debug.* methods |
| command_palette_switcher_surface_precedence | fail | old-app debug.* methods |
| command_palette_switcher_type_labels | fail | old-app debug.* methods |
| command_palette_window_scope | fail | old-app debug.* methods |
| config_settings_sources_and_sync | fail | source-shape test for the old app |
| cpu_notifications | not-run | falls back to osascript keystrokes |
| cpu_usage | not-run | measures the running cmux by process name, not the tagged socket |
| ctrl_enter_keybind | not-run | drives the app through osascript |
| ctrl_interactive | not-run | interactive; the upstream runner skips it too |
| ctrl_socket | fail | ⚠️  1 test(s) failed |
| focus_history_shortcut_cross_workspace | fail | old-app debug.* methods |
| focus_notification_dismiss | fail | app.focus_override (old-app debug) |
| initial_terminal_interactive_and_rendering | fail | old-app debug.* methods |
| layout_save_open | fail | workspace.create layout unsupported |
| lint_swiftui_patterns | fail | source-shape lint of old SwiftUI files |
| mobile_workspace_list_all_windows | fail | old-app debug.* methods |
| nested_split_does_not_disappear | fail | old-app debug.* methods |
| nested_split_no_arranged_subview_underflow | fail | old-app debug.* methods |
| nested_split_no_detach_during_update | fail | old-app debug.* methods |
| nested_split_panel_routing | fail | old-app debug.* methods |
| nested_split_preserves_existing_split | fail | old-app debug.* methods |
| new_tab_interactive_after_splits | fail | old-app debug.* methods |
| new_tab_render_after_splits | fail | old-app debug.* methods |
| notifications | fail | app.focus_override (old-app debug) |
| pane_break_swap_preserve_focus | fail | pane.swap result timing |
| pane_resize_preserves_ls_scrollback | fail | old-app debug.* methods |
| pane_resize_preserves_visible_content | fail | old-app debug.* methods |
| read_screen_capture_pane_parity | pass |  |
| rename_tab_cli_parity | pass |  |
| rename_window_workspace_parity | pass |  |
| restore_launch_lease_contention | pass |  |
| shortcut_window_scope | fail | old-app debug.* methods |
| signals_auto | pass |  |
| simulator_capabilities | fail | simulator.* unsupported |
| socket_send_text_burst_intact | pass |  |
| split_cmd_d_ctrl_d_geometry_fuzz | fail | old-app debug.* methods |
| split_cmd_d_ctrl_d_two_pane_frame_guard | fail | old-app debug.* methods |
| split_cmd_shift_d_ctrl_d_no_portal_orphans | fail | cmux.cmuxError: debug log not found at /tmp/cmux-debug-clic.log for socket=/tmp/cmux-debug-clic.sock |
| split_flash_and_layout | fail | old-app debug.* methods |
| ssh_remote_browser_favicon_uses_proxy | not-run | needs CMUX_SSH_TEST_HOST |
| ssh_remote_browser_move_rebinds_proxy | not-run | needs CMUX_SSH_TEST_HOST |
| ssh_remote_cli_metadata | not-run | needs CMUX_SSH_TEST_HOST |
| ssh_remote_cli_relay | not-run | needs CMUX_SSH_TEST_HOST |
| ssh_remote_daemon_resize_stdio | not-run | needs CMUX_SSH_TEST_HOST |
| ssh_remote_docker_bootstrap_nonlogin_shell | not-run | needs CMUX_SSH_TEST_HOST |
| ssh_remote_docker_forwarding | not-run | needs CMUX_SSH_TEST_HOST |
| ssh_remote_docker_reconnect | not-run | needs CMUX_SSH_TEST_HOST |
| ssh_remote_image_drop_upload | not-run | needs CMUX_SSH_TEST_HOST |
| ssh_remote_interactive_cmux_command_regression | not-run | needs CMUX_SSH_TEST_HOST |
| ssh_remote_last_surface_clears_remote_state | not-run | needs CMUX_SSH_TEST_HOST |
| ssh_remote_port_detection | not-run | needs CMUX_SSH_TEST_HOST |
| ssh_remote_proxy_bind_conflict | not-run | needs CMUX_SSH_TEST_HOST |
| ssh_remote_resize_scrollback_regression | not-run | needs CMUX_SSH_TEST_HOST |
| ssh_remote_second_session_mux_regression | not-run | needs CMUX_SSH_TEST_HOST |
| ssh_remote_shell_integration | not-run | needs CMUX_SSH_TEST_HOST |
| ssh_remote_shortcuts_stay_remote | not-run | needs CMUX_SSH_TEST_HOST |
| ssh_tui_file_preview | not-run | needs CMUX_SSH_TEST_HOST |
| ssh_tui_workspace_selection | not-run | needs CMUX_SSH_TEST_HOST |
| surface_catalog_stable_identity | fail | workspace.create layout unsupported |
| surface_list_custom_titles | pass |  |
| surface_move_reorder_api | pass |  |
| tab_dragging | timeout | timed out (drives many debug.* calls) |
| tab_workspace_action_naming | fail | tab.action pin payload shape |
| terminal_focus_routing | fail | old-app debug.* methods |
| terminal_input_render_report | fail | old-app debug.* methods |
| terminal_multi_image_drop | fail | old-app debug.* methods |
| terminal_notification_rendering | fail | old-app debug.* methods |
| terminal_paste_delivery | fail | AssertionError: Use the isolated issue tag |
| tmux_compat_geometry | fail | pane.list pixel_frame not reported |
| tmux_compat_matrix | fail | cmux.cmuxError: Timed out waiting for condition |
| trigger_flash | fail | old-app debug.* methods |
| update_timing | fail | source-shape test for the old app |
| v1_panel_creation_preserves_focus | fail | cmux.cmuxError: 'new_surface' failed: "ERROR: Unknown command 'new_surface'. cmux-next speaks v2 JSON requests only." |
| visual_screenshots | timeout | timed out (drives many debug.* calls) |
| visual_typing_char_by_char | fail | old-app debug.* methods |
| windows_api | fail | workspace.move_to_window unsupported (windows do not own workspaces) |
| workspace_create_background_starts_terminal | fail | workspace.create layout unsupported |
| workspace_create_initial_env | pass |  |
| workspace_create_layout | fail | workspace.create layout unsupported |
| workspace_relative | fail | stale test: the current CLI keeps workspace ids in default --json output (preservesStableIDsByDefault) |

## Decisions and follow-ups

- Reads that name daemon objects run on the `async` lane with one fresh `list-workspaces` (off the main actor, deadline-bound), joined with the snapshot's app-local state. The published `ControlSnapshot` lags cmux-tui by a frame plus delta delivery, and `surface.list` right after `workspace.create` returned no surfaces (tests_v2 `background_*`). Only `system.ping`, `system.capabilities`, `window.list`, and `window.current` answer from the snapshot. Moving the rest to the snapshot lane needs a write barrier (publish-after-delta for a known mutation), not a timing guess.
- App intents publish the snapshot synchronously before replying, so `select-workspace` followed by `current-workspace` agrees.
- `workspace.close` ends each terminal before `close-workspace`: cmux-tui keeps a closed workspace's terminal hosts and PTYs alive (one tests_v2 run leaked 251 hosts). The App's own workspace close has the same leak and needs the same fix or a daemon change.
- Terminals the App creates (tab strip, splits) get `CMUX_SOCKET_PATH`/`CMUX_TAG` from `LaunchIdentity`, but no `CMUX_WORKSPACE_ID`/`CMUX_SURFACE_ID`: `new-tab` and `split` cannot reserve a terminal id. Only `workspace.create` terminals get them. Hooks inside App-created terminals fall back to the focused surface. Fix: daemon-injected placement env, or `terminal_id` on `new-tab`/`split`.
- Sidebar status/progress/log is stored and queryable but not rendered by the cmux-next sidebar yet.
- Agent hooks: `feed.push`, `agent_journal_append`, and `agent.hook.*` answer typed unsupported, so hook notifications, the feed, and permission replies do not reach cmux-next. They belong on cmux-tui `report-agent`.
- `select-workspace` once exceeded the 2 s deadline while the App rebuilt a workspace's content on the main thread (later switches took 80-500 ms). The watchdog (`debug.hangs`) should show whether content switching stalls the main thread.
- A new split moves the daemon's active pane; the old app kept focus unless `--focus true`.
- The bundled `cmux` CLI crashes on `--help` (missing `cmuxfoundation` resource bundle) in cmux-next app bundles.
