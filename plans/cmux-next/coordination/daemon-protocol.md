# Lane: daemon-protocol

## Active streams
- Typed LayoutOp, daemon tab-conservation validation, proptest, TLA+ model (plans/cmux-next/formal/): tab-loss agent.
- Federation daemon (remote-terminal tabs, detached create, terminal.project delta): branch feat-cmux-next-federation-tui-r8.

## Landed
- 2026-10-01 6ed2890368a daemon: terminal-command-journal-v1: local-admin `set-terminal-command-history {enabled}` (off by default and after every start), journal kind `shell.command.finished` from reserved producer `cmux_shell`; app setting `history.terminalCommands` (default off) syncs it (30865b694a1); capability awaitingPin in the app until a pin carries it (history agent)
- 2026-10-01 a88885ccb59 daemon: launch-snapshot-v1, launch-snapshot.json next to the registry, identify.launch_snapshot_path; app draws it before connect (d5fad6dfe4a) (daemon-features agent)
- 2026-10-01 52ff0d719e7 daemon: notification-source-v1, `source` on notify/event/tab marker; daemon parses OSC 9/777/99 from every terminal; app path removed (facce30063b) (daemon-features agent)
- 2026-10-01 383bdf1a9a1 store: DaemonStore applies `tab-changed` pane moves from the daemon (tear-off desync) (tab-drag agent)
