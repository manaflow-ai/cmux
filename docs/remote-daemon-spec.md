# Remote SSH Living Spec

Last updated: March 12, 2026
Tracking issue: https://github.com/manaflow-ai/cmux/issues/151
Primary PR: https://github.com/manaflow-ai/cmux/pull/1296
CLI relay PR: https://github.com/manaflow-ai/cmux/pull/374

This document is the working source of truth for:
1. what is implemented now
2. what is intentionally temporary
3. what must be built next

## 1. Document Type

This is a **living implementation spec** (also called an **execution spec**): a spec-level document with status tracking (`DONE`, `IN PROGRESS`, `TODO`) and acceptance tests.

## 2. Objective

`cmux ssh` should provide:
1. durable remote terminals with reconnect/reuse
2. browser traffic that egresses from the remote host via proxying
3. tmux-style PTY resize semantics (`smallest screen wins`)

## 3. Current State (Implemented)

### 3.1 Remote Workspace + Reconnect UX
- `DONE` `cmux ssh` creates remote-tagged workspaces and does not require `--name`.
- `DONE` scoped shell niceties are applied only for `cmux ssh` launches.
- `DONE` context menu actions exist for remote workspaces (`Reconnect Workspace(s)`, `Disconnect Workspace(s)`).
- `DONE` socket API includes `workspace.remote.reconnect`.

### 3.2 Bootstrap + Daemon
- `DONE` local app probes remote platform, verifies a release-pinned `cmuxd-remote` artifact by embedded manifest SHA-256, uploads it when missing, and runs `serve --stdio`.
- `DONE` daemon `hello` handshake is enforced.
- `DONE` daemon now exposes proxy stream RPC (`proxy.open`, `proxy.close`, `proxy.write`, `proxy.stream.subscribe`) plus pushed `proxy.stream.*` events.
- `DONE` local proxy broker now tunnels SOCKS5/CONNECT traffic over daemon stream RPC instead of `ssh -D`.
- `DONE` daemon now exposes session resize-coordinator RPC (`session.open`, `session.attach`, `session.resize`, `session.detach`, `session.status`, `session.close`).
- `DONE` transport-level proxy failures now escalate from broker retry to full daemon re-bootstrap/reconnect in the session controller.
- `DONE` SOCKS handshake parsing now preserves pipelined post-connect payload bytes instead of dropping request-prefix bytes.
- `DONE` `workspace.remote.configure.local_proxy_port` exists as an internal deterministic test hook for bind-conflict regression coverage.
- `DONE` bootstrap/probe failures surface actionable details.
- `DONE` bootstrap installs `~/.cmux/bin/cmux` wrapper (also tries `/usr/local/bin/cmux`) so `cmux` is available in PATH on the remote.

### 3.5 CLI Relay (Running cmux Commands From Remote)
- `DONE` `cmuxd-remote` includes a table-driven CLI relay (`cli` subcommand) that maps CLI args to v1 text or v2 JSON-RPC messages.
- `DONE` busybox-style argv[0] detection: when invoked as `cmux` via wrapper/symlink, auto-dispatches to CLI relay.
- `DONE` background `ssh -N -R 127.0.0.1:PORT:127.0.0.1:LOCAL_RELAY_PORT` process reverse-forwards a TCP port to a dedicated authenticated local relay server. Uses TCP instead of Unix socket forwarding because many servers have `AllowStreamLocalForwarding` disabled.
- `DONE` relay process uses `-S none` / standalone SSH transport (avoids ControlMaster multiplexing and inherited `RemoteForward` directives) and `ExitOnForwardFailure=yes` so dead reverse binds fail fast instead of publishing bad relay metadata.
- `DONE` relay address written to `~/.cmux/socket_addr` on the remote only after the reverse forward survives startup validation.
- `DONE` Go CLI no longer polls for relay readiness. It dials the published relay once and only refreshes `~/.cmux/socket_addr` a single time to recover from a stale shared address rewrite.
- `DONE` `cmux ssh` startup exports session-local `CMUX_SOCKET_PATH=127.0.0.1:<relay_port>` so parallel sessions pin to their own relay instead of racing on shared socket_addr.
- `DONE` relay startup writes `~/.cmux/relay/<relay_port>.daemon_path`; remote `cmux` wrapper uses this to select the right daemon binary per session, including mixed local cmux versions.
- `DONE` relay startup writes `~/.cmux/relay/<relay_port>.auth` with a relay ID and token; the local relay requires HMAC-SHA256 challenge-response before forwarding any command to the real local socket.
- `DONE` ephemeral port range (49152-65535) filtered from probe results to exclude relay ports from other workspaces.
- `DONE` multi-workspace port conflict detection uses TCP connect check (`isLoopbackPortReachable`) so ports already forwarded by another workspace are silently skipped instead of flagged as conflicts.
- `DONE` orphaned relay SSH processes from previous app sessions are cleaned up before starting a new relay.

### 3.6 Artifact Trust
- `DONE` release and nightly workflows publish `cmuxd-remote` assets for `darwin/linux × arm64/amd64`.
- `DONE` release and nightly apps embed a compact `CMUXRemoteDaemonManifestJSON` in `Info.plist` with exact asset URLs and SHA-256 digests.
- `DONE` `cmux remote-daemon-status` exposes the current manifest entry, local cache verification state, release download command, and GitHub attestation verification command.

### 3.3 Error Surfacing
- `DONE` remote errors are surfaced in sidebar status + logs + notifications.
- `DONE` reconnect retry count/time is included in surfaced error text (for example, `retry 1 in 4s`).

### 3.4 Removed Temporary Behavior
- `DONE` removed remote listening-port probe loop and per-port SSH `-L` mirroring.
- `DONE` remote browser routing now uses a single shared local proxy endpoint instead of detected-port mirroring.
- `DONE` remote status now includes structured proxy metadata (`remote.proxy`) and `proxy_unavailable` error code when proxy setup fails.

## 4. Target Architecture (No Port Mirroring)

### 4.1 Browser Networking Path
1. `DONE` one local proxy endpoint is created per SSH transport/session key (not per detected port).
2. `DONE` endpoint is provided by a local broker that supports SOCKS5 + HTTP CONNECT and tunnels via daemon stream RPC.
3. `DONE` browser panels in remote workspaces are auto-wired to the workspace proxy endpoint.
4. `DONE` browser panels in local workspaces are not force-proxied.
5. `DONE` identical SSH transports share one endpoint via a transport-scoped broker.

### 4.2 WKWebView Wiring
1. `DONE` use workspace-scoped `WKWebsiteDataStore(forIdentifier:)`.
2. `DONE` apply workspace/browser scoped `proxyConfigurations`.
3. `DONE` prefer SOCKS5 proxy config.
4. `DONE` keep HTTP CONNECT proxy config as fallback.
5. `DONE` re-apply proxy config on reconnect/state updates.

### 4.3 Remote Daemon + Transport
1. `DONE` `cmuxd-remote` now supports proxy stream RPC (`proxy.open`, `proxy.close`, `proxy.write`, `proxy.stream.subscribe`) with pushed `proxy.stream.data/eof/error` events.
2. `DONE` local side now runs a shared local broker that serves SOCKS5/CONNECT and tunnels each stream over persistent daemon stdio RPC without polling reads.
3. `DONE` removed remote service-port discovery/probing from browser routing path.

### 4.4 Explicit Non-Goal
1. Automatic mirroring of every remote listening port to local loopback is not a goal for browser support.

## 5. PTY Resize Semantics (tmux-style)

### 5.1 Core Rule
For each session with multiple attachments, the effective PTY size is:
1. `cols = min(cols_i over attached clients)`
2. `rows = min(rows_i over attached clients)`

This is the `smallest screen wins` rule.

### 5.2 State Model
Per session track:
1. set of active attachments `{attachment_id -> cols, rows, updated_at}`
2. effective size currently applied to PTY
3. last-known size when temporarily unattached

### 5.3 Recompute Triggers
Recompute effective size on:
1. attachment create
2. attachment detach
3. resize event from any attachment
4. reconnect reattach

### 5.4 Correctness Requirements
1. Never shrink history because of UI relayout noise; only PTY viewport changes.
2. On reconnect, reuse persisted session and recompute from active attachments.
3. If no attachments remain, keep last-known PTY size (do not force 80x24 reset).

## 6. Milestones (Living Status)

| ID | Milestone | Status | Notes |
|---|---|---|---|
| M-001 | `cmux ssh` workspace creation + metadata + optional `--name` | DONE | Covered by `tests_v2/test_ssh_remote_cli_metadata.py` |
| M-002 | Remote bootstrap/upload/start + hello handshake | DONE | Includes daemon capability handshake + status surfacing |
| M-003 | Reconnect/disconnect UX + API + improved error surfacing | DONE | Includes retry count in surfaced errors |
| M-004 | Docker e2e for bootstrap/reconnect shell niceties | DONE | Docker suites validate proxy-path bootstrap and reconnect behavior |
| M-004b | CLI relay: run cmux commands from within SSH sessions | DONE | Reverse TCP forward + Go CLI relay + bootstrap wrapper |
| M-005 | Remove automatic remote port mirroring path | DONE | `WorkspaceRemoteSessionController` now uses one shared daemon-backed proxy endpoint |
| M-006 | Transport-scoped local proxy broker (SOCKS5 + CONNECT) | DONE | Identical SSH transports now reuse one local proxy endpoint |
| M-007 | Remote proxy stream RPC in `cmuxd-remote` | DONE | `proxy.open/close/write/proxy.stream.subscribe` plus pushed stream events implemented |
| M-008 | WebView proxy auto-wiring for remote workspaces | DONE | Workspace-scoped `WKWebsiteDataStore.proxyConfigurations` wiring is active |
| M-009 | PTY resize coordinator (`smallest screen wins`) | DONE | Daemon session RPC now tracks attachments and applies min cols/rows semantics with unit tests |
| M-010 | Resize + proxy reconnect e2e test suites | DONE | `tests_v2/test_ssh_remote_docker_forwarding.py` validates HTTP/websocket egress plus SOCKS pipelined-payload handling; `tests_v2/test_ssh_remote_docker_reconnect.py` verifies reconnect recovery and repeats SOCKS pipelined-payload checks after host restart; `tests_v2/test_ssh_remote_proxy_bind_conflict.py` validates structured `proxy_unavailable` bind-conflict surfacing and `local_proxy_port` status retention under bind conflict; `tests_v2/test_ssh_remote_daemon_resize_stdio.py` validates session resize semantics over real stdio RPC process boundaries; `tests_v2/test_ssh_remote_cli_metadata.py` validates `workspace.remote.configure` numeric-string compatibility, explicit `null` clear semantics (including `workspace.remote.status` reflection), strict `port`/`local_proxy_port` validation (bounds/type), case-insensitive SSH option override precedence for StrictHostKeyChecking/control-socket keys, and `local_proxy_port` payload echo for deterministic bind-conflict test hook behavior |

## 7. Acceptance Test Matrix (With Status)

### 7.1 Terminal + Reconnect

| ID | Scenario | Status |
|---|---|---|
| T-001 | baseline remote connect | DONE |
| T-002 | identical host reuse semantics | DONE |
| T-003 | no `--name` | DONE |
| T-004 | reconnect API success/error paths | DONE |
| T-005 | retry count visible in daemon error detail | DONE |

### 7.2 CLI Relay

| ID | Scenario | Status |
|---|---|---|
| C-001 | `cmux ping` from remote session | DONE |
| C-002 | `cmux list-workspaces --json` from remote | DONE |
| C-003 | `cmux new-workspace` from remote | DONE |
| C-004 | `cmux rpc system.capabilities` passthrough | DONE |
| C-005 | TCP retry handles relay not yet established | DONE |
| C-006 | multi-workspace port conflict silent skip | DONE |
| C-007 | ephemeral port filtering excludes relay ports | DONE |

### 7.3 Browser Proxy (Target)

| ID | Scenario | Status |
|---|---|---|
| W-001 | remote workspace browser auto-proxied | DONE |
| W-002 | browser egress equals remote network path | DONE |
| W-003 | websocket via SOCKS5/CONNECT through remote daemon | DONE |
| W-004 | reconnect restores browser proxy path automatically | DONE |
| W-005 | local proxy bind conflict yields structured `proxy_unavailable` | DONE |
| W-006 | proxy transport failure triggers daemon re-bootstrap and recovers after host recreation | DONE |
| W-007 | SOCKS greeting/connect + immediate pipelined payload in same write remains intact | DONE |

### 7.4 Resize

| ID | Scenario | Status |
|---|---|---|
| RZ-001 | two attachments, smallest wins | DONE |
| RZ-002 | grow one attachment, PTY stays bounded by smallest | DONE |
| RZ-003 | detach smallest, PTY expands to next smallest | DONE |
| RZ-004 | reconnect preserves session + applies recomputed size | DONE |
| RZ-005 | daemon stdio RPC round-trip enforces resize semantics end-to-end | DONE |

## 8. Removal Checklist (Port Mirroring)

Before declaring browser proxying complete:
1. `DONE` remove remote port probe loop and `-L` auto-forward orchestration
2. `DONE` remove mirror-specific routing behavior as default remote behavior
3. `DONE` replace mirroring docker assertions with proxy egress assertions
4. `DONE` keep optional explicit user-driven forwarding out of this path; no automatic mirroring remains in browser routing

## 9. Open Decisions

1. Proxy auth policy for local broker (`none` vs optional credentials).
2. Reconnect backoff profile and max retry budget.

## 10. Socket API Contract Notes

### 10.1 `workspace.remote.configure` Port Fields
1. `port` and `local_proxy_port` accept integer values and numeric strings.
2. Explicit `null` clears each field.
3. Out-of-range values and invalid types (for example booleans/non-numeric strings/fractional numbers) return `invalid_params`.
4. `local_proxy_port` is an internal deterministic test hook to force local bind conflicts in regression coverage.

### 10.2 SSH Option Precedence
1. `StrictHostKeyChecking` default (`accept-new`) is only injected when no user override is present.
2. Control-socket defaults (`ControlMaster`, `ControlPersist`, `ControlPath`) are only injected when missing.
3. SSH option key matching is case-insensitive for precedence checks in both CLI-built commands and remote configure payloads.

### 10.3 SSH Docker E2E Harness Knobs
1. `CMUX_SSH_TEST_DOCKER_HOST` sets the SSH destination host/IP used by docker-backed SSH fixtures (default `127.0.0.1`).
2. `CMUX_SSH_TEST_DOCKER_BIND_ADDR` sets the bind address used in fixture container publish mappings (default `127.0.0.1`).
3. Defaults preserve loopback behavior on a single host; override both when docker runs on a different host (for example VM -> host OrbStack).
