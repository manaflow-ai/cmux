# Lane: daemon-protocol

## Active streams
- Typed LayoutOp, daemon tab-conservation validation, proptest, TLA+ model (plans/cmux-next/formal/): tab-loss agent.
- Federation daemon (remote-terminal tabs, detached create, terminal.project delta): branch feat-cmux-next-federation-tui-r8.

## Landed
- 2026-10-03 (this push) daemon/SDK (GPUI lane): raw `new-frontend-browser-tab` takes an optional `idempotency_key` (capability frontend-browser-tab-keys-v1; key row `frontend_browser_tab_keys` commits with the frontend browser record in cmux-tui-core::state; keyed creates run one at a time; a retry returns the first tab with `replayed:true`, a retry after the tab closed is refused, same key with another request is idempotency.conflict; result gains `replayed`); sdk-schema field + regenerated raw bindings in all languages. cmux-sdk (Rust only): `Workspace::update`, `Tab::pin/unpin/update`, typed `ColumnUpdateOptions::pin/unpin/width` with catalog validation, `Session::window_records/put_window_record/delete_window_record` (record revision CAS), `raw::Client::create_frontend_browser_tab` (keyed, refuses a daemon without the capability before sending) and `write_frontend_browser_tab`, `request_raw` returns protocol/2 failures as `Error::Protocol`; live test typed_state_ops_live joins the cmux-tui-sdks live step. No catalog change. Sticky in the layout document stays with ad349 (GPUI lane)
- 2026-10-01 6ed2890368a daemon: terminal-command-journal-v1: local-admin `set-terminal-command-history {enabled}` (off by default and after every start), journal kind `shell.command.finished` from reserved producer `cmux_shell`; app setting `history.terminalCommands` (default off) syncs it (30865b694a1); capability awaitingPin in the app until a pin carries it (history agent)
- 2026-10-01 a88885ccb59 daemon: launch-snapshot-v1, launch-snapshot.json next to the registry, identify.launch_snapshot_path; app draws it before connect (d5fad6dfe4a) (daemon-features agent)
- 2026-10-01 52ff0d719e7 daemon: notification-source-v1, `source` on notify/event/tab marker; daemon parses OSC 9/777/99 from every terminal; app path removed (facce30063b) (daemon-features agent)
- 2026-10-01 383bdf1a9a1 store: DaemonStore applies `tab-changed` pane moves from the daemon (tear-off desync) (tab-drag agent)
