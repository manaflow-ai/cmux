# Remote Daemon Spec (SSH + Proxy)

Last updated: February 21, 2026  
Tracking issue: https://github.com/manaflow-ai/cmux/issues/151

## 1. Goals

1. Make `cmux ssh <target>` reusable and reliable for repeated connections.
2. Reuse a single SSH transport for identical normalized host configs.
3. Run a remote Go daemon (`cmuxd-remote`) for session control and proxying.
4. Treat web proxying (HTTP CONNECT + SOCKS5 + websocket traffic) as core behavior.
5. Keep plain shell usage (`ssh <target>`) unchanged.

## 2. Non-Goals (v1)

1. Full remote filesystem sync.
2. TLS interception/MITM.
3. Cross-user multi-tenant daemon sharing.

## 3. Architecture

### 3.1 Components

1. `cmux` CLI and local app runtime.
2. Local SSH connection pool manager.
3. Remote daemon: `cmuxd-remote` (Go, cross-compiled).
4. Local proxy listener(s) for browser and tool traffic.

### 3.2 Reuse Model

1. One active SSH transport per `ConnectionKey`.
2. One SSH transport can host multiple logical remote sessions/workspaces.
3. Reuse decision is based on normalized SSH config, not raw alias text.

### 3.3 ConnectionKey Normalization

Source: `ssh -G <target>` output plus explicit CLI flags.

Required key fields:
1. resolved `hostname`
2. resolved `user`
3. resolved `port`
4. ordered `identityfile` list + `identitiesonly`
5. `proxyjump`
6. `proxycommand`
7. host key trust policy knobs (`stricthostkeychecking`, user known hosts path, global known hosts path)
8. auth-impacting extra options passed by `cmux ssh --ssh-option`

Rules:
1. All key names lowercased.
2. Whitespace trimmed.
3. Multi-value fields normalized to deterministic order where OpenSSH order is not semantic.
4. Hash with stable format to form `connection_key_hash`.

### 3.4 Remote Daemon Bootstrap

Remote install path:
1. `~/.cmux/bin/cmuxd-remote/<version>/<os>-<arch>/cmuxd-remote`
2. metadata: `~/.cmux/bin/cmuxd-remote/<version>/manifest.json`

Bootstrap flow:
1. resolve target + connection key
2. open SSH transport (or reuse existing)
3. check remote daemon binary + checksum
4. upload if missing/mismatched
5. exec `cmuxd-remote serve --stdio`
6. perform version/capability handshake

### 3.5 Local/Remote Protocol

Transport:
1. framed multiplexed protocol over SSH stdio
2. one control channel + N data channels

Required control RPCs:
1. `hello`
2. `session.create`
3. `session.attach`
4. `session.detach`
5. `session.close`
6. `session.resize`
7. `session.signal`
8. `service.watch`
9. `proxy.open`
10. `proxy.close`
11. `heartbeat`

Required observability fields in status APIs:
1. `connection_key_hash`
2. `transport_id`
3. `transport_refcount`
4. `last_heartbeat_at`
5. `reconnect_attempts`
6. `proxy_channels_active`

### 3.6 Proxying Model

Proxy roles:
1. local HTTP CONNECT endpoint bound to loopback
2. local SOCKS5 endpoint bound to loopback
3. optional explicit local forward binds for known remote ports

Behavior:
1. CONNECT/SOCKS requests are tunneled to remote daemon, which dials remote destinations.
2. Daemon may enforce allow/deny policy (default allow loopback targets + discovered listening services).
3. Websocket traffic must pass transparently through both proxy modes.
4. Local bind conflicts are surfaced as structured errors and trigger next-port fallback where configured.

### 3.7 Reconnect Semantics

States:
1. `connected`
2. `degraded`
3. `reconnecting`
4. `disconnected`
5. `fatal`

Rules:
1. Transport loss moves all attached logical sessions to `reconnecting`.
2. If reattach succeeds, restore `connected` without creating duplicate sessions.
3. Persistent sessions survive local app restart and reconnect.
4. Ephemeral sessions may be GC'd by daemon after TTL if no client reattaches.

## 4. Security Requirements

1. SSH remains the auth boundary.
2. Remote binary integrity must be checksum-verified before exec.
3. Daemon listens only on stdio/unix socket/loopback (never public interfaces by default).
4. No plaintext persistence of SSH secrets outside normal SSH tooling.

## 5. Test Strategy

Three layers:
1. unit tests: normalization, key hashing, state machine transitions
2. integration tests: dockerized ssh targets + proxy fixtures
3. end-to-end tests: cmux CLI + UI socket methods + process-level assertions

Required test fixtures:
1. existing SSH fixture (`tests/fixtures/ssh-remote/`)
2. HTTP CONNECT target fixture (HTTP service behind daemon)
3. websocket fixture (echo server behind daemon)
4. fault fixture (transport kill, delayed network, remote daemon restart)

## 6. Test Matrix

Pass criteria convention:
1. every case defines deterministic assertions
2. all `MUST` assertions pass on CI
3. flaky cases are not allowed for merge gates

### 6.1 Terminal Session Cases

| ID | Scenario | Setup | Steps | MUST Assertions |
|---|---|---|---|---|
| T-001 | Single connect baseline | fresh app, no pooled transport | `cmux ssh cmux-vm` | one transport created; one remote session attached; workspace shows remote state `connected` |
| T-002 | Reuse identical host | existing connected transport for key K | run `cmux ssh cmux-vm` twice | both workspaces map to same `transport_id`; `transport_refcount == 2`; only one SSH transport process for key K |
| T-003 | Do not reuse changed identity | key file A then key file B | run `cmux ssh host --identity A`, then B | two distinct `connection_key_hash` values; two transport processes |
| T-004 | Do not reuse changed proxyjump | host via jump1 then jump2 | run with different jump options | no reuse across different normalized proxy settings |
| T-005 | Optional name behavior | none | run `cmux ssh host` (no `--name`) | workspace is created; title non-empty; no CLI error |
| T-006 | Scoped ssh niceties | none | run `cmux ssh host --json` and inspect emitted command metadata | emitted `ssh_command` includes scoped `GHOSTTY_SHELL_FEATURES ... ssh-env,ssh-terminfo`; plain shell default features remain unchanged |
| T-007 | Session detach/attach | persistent session enabled | create session, detach local workspace, reattach | same remote `session_id`; shell state/history retained |
| T-008 | Explicit close | active session + transport refcount 1 | close workspace | remote session closes; transport released when refcount reaches 0 |

### 6.2 Web Proxy Traffic Cases

| ID | Scenario | Setup | Steps | MUST Assertions |
|---|---|---|---|---|
| W-001 | HTTP CONNECT basic | remote HTTP service on loopback | open local CONNECT proxy; fetch remote URL through proxy | 200 response body matches fixture payload |
| W-002 | SOCKS5 basic | same as W-001 | fetch remote URL through SOCKS5 endpoint | response matches direct remote response |
| W-003 | Websocket through CONNECT | remote websocket echo service | connect websocket via CONNECT proxy and exchange messages | echo payload integrity; no unexpected close frames |
| W-004 | Websocket through SOCKS5 | same as W-003 | connect via SOCKS5 | echo payload integrity |
| W-005 | Concurrent browser + terminal traffic | active terminal workload + browser requests | run high-volume stdout in session while proxying requests | no stalled PTY stream; proxy p95 latency below threshold |
| W-006 | Service discovery to local exposure | remote daemon detects listening app port | start remote web app, observe status payload | detected port listed; local forwarded/proxy route becomes reachable |
| W-007 | Local port conflict handling | reserve desired local bind port beforehand | request proxy/forward for conflicting port | conflict is reported structurally; allocator picks fallback if enabled |
| W-008 | Large response streaming | remote serves large payload | fetch 100MB file through proxy | byte count matches; no truncation/corruption |

### 6.3 Reconnect + Failure Cases

| ID | Scenario | Setup | Steps | MUST Assertions |
|---|---|---|---|---|
| R-001 | Transport process killed | active shared transport with 2 sessions | kill local SSH process | both sessions enter `reconnecting`; auto-reconnect starts |
| R-002 | Reconnect success reattach | continue R-001 with healthy remote | wait for reconnect | both sessions return `connected`; same remote `session_id`s; no duplicate shells |
| R-003 | Reconnect failure exhaustion | block network to host during reconnect | wait past retry budget | state becomes `disconnected` with actionable error; no busy-loop retries |
| R-004 | Remote daemon restart | kill `cmuxd-remote` but keep SSH transport | observe client recovery | daemon restarts or re-exec path runs; sessions reattached per policy |
| R-005 | Persistent session across app restart | persistent session active | quit/relaunch cmux and reattach | session state preserved; command history/output continuity verified |
| R-006 | Ephemeral session GC | ephemeral session detached | wait TTL expiration | session removed remotely; subsequent attach gets not-found and creates fresh session |
| R-007 | Proxy channels during reconnect | active websocket + HTTP requests | induce transport flap | in-flight streams fail cleanly; new streams succeed after reconnect |
| R-008 | Heartbeat timeout | drop packets without killing process | observe heartbeat | timeout transitions to `degraded`/`reconnecting`; recovery after network restore |

## 7. CI Gate Proposal

Gate suites:
1. `remote-terminal-core` = T-001..T-006
2. `remote-proxy-core` = W-001..W-004, W-006
3. `remote-reconnect-core` = R-001..R-004

Nightly suites:
1. high-load and large payload tests (W-005, W-008)
2. long-running durability and GC tests (R-005..R-008)

## 8. Open Design Decisions

1. Whether proxy endpoint is per transport (`connection_key_hash`) or per workspace by default.
2. Default session policy (`ephemeral` vs `persistent`) for `cmux ssh`.
3. Exact retry/backoff budgets for reconnect on laptop sleep/wake.
4. Whether daemon upgrades are eager (on connect) or lazy (on capability miss).
