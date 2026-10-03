# Lane: durable-sessions

## Active streams
- Durable sessions (U1, R41): terminals and agent sessions survive app update, daemon and acpmux restarts; no false "Process exited". Plan plans/cmux-next/durable-sessions.md. Owns: acpmux agent hosts (`__agent-host`, spool, adopt), acpmux hub recovery after adopt, PTY unadoptable-host state, typed terminal end reasons, app restart of stale daemon/acpmux after an update. Does not own: tab.restart (restart-tab, tab-restart-v1: tab.restart agent), agent pane UI (Leo's team). Branch feat-cmux-next-durable-sessions (durable-sessions lead)

## Landed
