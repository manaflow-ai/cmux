# Remote Daemon Spec (Concise)

Last updated: February 21, 2026  
Tracking issue: https://github.com/manaflow-ai/cmux/issues/151

## 1. Scope

`cmux ssh` should support:
1. one client connected to multiple daemons at once
2. tmux-style persistent remote/local sessions
3. SSH transport reuse for identical targets
4. first-class web proxying (HTTP CONNECT + SOCKS5 + websocket)

Remote daemon is Go (`cmuxd-remote`) for portability.

## 2. Core Invariants

1. **Daemon owns non-layout state**: PTYs, process lifecycle, scrollback, cwd/title, service/port discovery, proxy channels, persistence.
2. **Client owns layout**: windows/workspaces/panes/focus/reorder remain in Swift app.
3. **Session is durable; attachment is disposable**: UI panes attach/detach from daemon sessions.
4. **Transport is separate from session**: one SSH transport can carry many sessions.
5. **Reuse key is normalized config**: not raw alias text.
6. **One protocol for local and remote**: unix socket and SSH stdio are transport adapters for the same RPC/stream contract.

## 3. Multi-Daemon Model

1. Client has a daemon router keyed by `daemon_id`.
2. Any workspace pane may point to any daemon.
3. Attachment identity:
   - `pane_id -> daemon_id + session_id + stream_id`
4. Handles exposed in APIs include daemon scope where relevant:
   - `daemon_id`, `session_id`, `transport_id`, `connection_key_hash`
5. Cross-daemon "move pane" is modeled as attach/create on target daemon, not live PTY migration.

## 4. Connection Reuse

Connection reuse key (`ConnectionKey`) is derived from `ssh -G` plus cmux flags:
1. hostname, user, port
2. identity files + `IdentitiesOnly`
3. `ProxyJump` / `ProxyCommand`
4. host-key policy options that change trust/auth semantics
5. auth-impacting `--ssh-option` values

Reuse rule:
1. identical normalized key => reuse same SSH transport
2. any key difference => new transport

## 5. Bootstrap + Protocol

Bootstrap:
1. ensure remote binary at `~/.cmux/bin/cmuxd-remote/<version>/<os>-<arch>/cmuxd-remote`
2. checksum-verify before exec
3. run `cmuxd-remote serve --stdio`
4. negotiate version/capabilities
5. if bootstrap fails, fail `cmux ssh` with actionable error (no silent fallback to plain ssh mode)

Minimum RPC surface:
1. `hello`
2. `session.create|attach|detach|close|resize|signal`
3. `service.watch`
4. `proxy.open|close`
5. `heartbeat`

Protocol requirement:
1. multiplexed framed streams (control + PTY + proxy data)

## 6. Proxying

Proxy endpoints (loopback only by default):
1. HTTP CONNECT
2. SOCKS5

Behavior:
1. requests tunnel to daemon, daemon dials destinations
2. websocket must work in both proxy modes
3. local bind conflicts return structured errors (+ optional next-port fallback)

## 7. Reconnect Semantics

States:
1. `connected`
2. `degraded`
3. `reconnecting`
4. `disconnected`
5. `fatal`

Rules:
1. transport loss moves all attached sessions to `reconnecting`
2. successful reattach must keep same `session_id` (no duplicate shells)
3. `cmux ssh` defaults to persistent sessions
4. persistent sessions survive app restart/disconnect
5. ephemeral sessions can be GC'd after TTL when explicitly requested

## 8. Test Matrix

All cases require deterministic `MUST` assertions.

### 8.1 Terminal

| ID | Scenario | MUST Assertions |
|---|---|---|
| T-001 | baseline connect | one transport, one session, connected state |
| T-002 | identical host twice | same `transport_id`, refcount 2, one SSH process |
| T-003 | different identity/options | different `connection_key_hash`, separate transports |
| T-004 | no `--name` | workspace created with non-empty title |
| T-005 | scoped niceties | only `cmux ssh` command metadata includes scoped `GHOSTTY_SHELL_FEATURES` SSH additions |
| T-006 | detach/reattach | same `session_id`, state/history preserved |

### 8.2 Web Proxy

| ID | Scenario | MUST Assertions |
|---|---|---|
| W-001 | HTTP CONNECT | fixture response matches expected body |
| W-002 | SOCKS5 | response parity with direct remote |
| W-003 | websocket via CONNECT | echo integrity, no unexpected close |
| W-004 | websocket via SOCKS5 | echo integrity |
| W-005 | port conflict | structured conflict error + fallback behavior |
| W-006 | concurrent PTY + proxy load | no PTY stall; proxy latency/error budget met |
| W-007 | browser auto wiring | browser workflow uses daemon-backed proxy automatically when remote session is active |

### 8.3 Reconnect

| ID | Scenario | MUST Assertions |
|---|---|---|
| R-001 | kill transport | sessions enter `reconnecting`, retries begin |
| R-002 | reconnect success | return to `connected`, same `session_id`s |
| R-003 | reconnect exhausted | transition to `disconnected` with actionable error |
| R-004 | daemon restart | client reattaches per policy without duplicate sessions |
| R-005 | app restart (persistent) | session continuity retained |

### 8.4 Multi-Daemon

| ID | Scenario | MUST Assertions |
|---|---|---|
| M-001 | one client, two daemons | panes/workspaces may attach to different `daemon_id`s simultaneously |
| M-002 | per-daemon failure isolation | daemon A outage does not impact daemon B sessions |
| M-003 | mixed local+remote | local `cmuxd` and remote `cmuxd-remote` coexist under same client layout |
| M-004 | reconnect with mixed daemons | only affected daemon’s panes transition state; others remain connected |

## 9. CI Gates

1. `remote-terminal-core`: T-001..T-005
2. `remote-proxy-core`: W-001..W-004, W-007
3. `remote-reconnect-core`: R-001..R-003
4. `remote-multidaemon-core`: M-001..M-002

## 10. Open Decisions

1. proxy endpoint scope: per daemon transport vs per workspace
2. reconnect retry budget and backoff profile
