# Remote PTY (cmuxd) Checklist

## ✅ Done + Tested
- [x] cmuxd requires `--stdio` or `--ws` (tests/e2e/test_config.py)
- [x] JSON `ping`→`pong` (tests/e2e/test_sessions.py::test_json_ping_pong)
- [x] Sessions: `list_sessions`, `new_session`, `attach_session`, session-scoped `list_panes` (tests/e2e/test_sessions.py::test_sessions_list_attach_and_scope)
- [x] `session_id` in `welcome`/`snapshot`/events (tests/e2e/test_sessions.py)
- [x] `new_pane` with `cwd` over SSH (tests/e2e/test_ssh.py::test_ssh_new_pane_cwd)
- [x] OSC notify types (OSC 9/777/99 + unicode + long body) (tests/e2e/test_sessions.py::test_metadata_and_notifications)
- [x] WebSocket protocol core messages + WS ping/pong frames (tests/e2e/test_ws.py)
- [x] Docker E2E harness for cmuxd (scripts/test-e2e-docker.sh, tests/e2e/docker/*)

## ⚠️ Done but docker E2E xfails (CMUX_E2E_DOCKER=1)
- [ ] OSC title updates (OSC 0/2 → `title_update`) (tests/e2e/test_sessions.py::test_title_update)
- [ ] OSC cwd updates (OSC 7 → `cwd_update`) (tests/e2e/test_sessions.py::test_metadata_and_notifications)
- [ ] SSH `pane_exited` event after shell exit (tests/e2e/test_ssh.py::test_ssh_pane_exit_event)

## ⚠️ Done but Untested
- [ ] `close_pane` (cmuxd/src/main.zig)
- [ ] Session cleanup on last pane close (cmuxd/src/main.zig)
- [ ] `list_session_panes` (cmuxd/src/main.zig)
- [ ] `error` responses for failed `attach_session` (cmuxd/src/main.zig)
- [ ] Unix socket transport end-to-end (`cmuxd --unix` + cmuxterm client)
- [ ] SSH attach path via cmuxterm connection registry (Sources/GhosttyTerminalView.swift)
- [ ] cmuxterm connection registry + session picker flow (Sources/GhosttyTerminalView.swift, Sources/ContentView.swift, Sources/TabManager.swift)
- [ ] UI updates from `title_update`/`cwd_update` and `notify` (Sources/GhosttyTerminalView.swift, Sources/TerminalNotificationStore.swift)
- [ ] Multi-connection restore on launch (Sources/TabManager.swift)

## ✅ Done (No automated test)
- [x] `docs/remote-pty-spec.md` updated for Option B + OSC types

## 🧾 TODO
- [ ] Persist `{connection_id, session_id, pane_id}` mapping for reattach across restarts
- [ ] Idle session cleanup / GC policy
- [ ] E2E multi-session in one cmuxd and multi-connection in client
- [ ] E2E resize + scrollback per session/pane
- [ ] Notifications end-to-end through cmuxterm UI with multiple connections
- [ ] E2E `close_pane` behavior + client UI response
