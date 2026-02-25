# Remote SSH Living Spec

Last updated: February 23, 2026
Tracking issue: https://github.com/manaflow-ai/cmux/issues/151
Primary PR: https://github.com/manaflow-ai/cmux/pull/239
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
- `DONE` local app probes remote platform, builds/uploads `cmuxd-remote`, and runs `serve --stdio`.
- `DONE` daemon `hello` handshake is enforced.
- `DONE` bootstrap/probe failures surface actionable details.
- `DONE` bootstrap installs `~/.cmux/bin/cmux` wrapper (also tries `/usr/local/bin/cmux`) so `cmux` is available in PATH on the remote.

### 3.5 CLI Relay (Running cmux Commands From Remote)
- `DONE` `cmuxd-remote` includes a table-driven CLI relay (`cli` subcommand) that maps CLI args to v1 text or v2 JSON-RPC messages.
- `DONE` busybox-style argv[0] detection: when invoked as `cmux` via wrapper/symlink, auto-dispatches to CLI relay.
- `DONE` background `ssh -N -R 127.0.0.1:PORT:/local/cmux.sock` process reverse-forwards a TCP port to the local cmux socket. Uses TCP instead of Unix socket forwarding because many servers have `AllowStreamLocalForwarding` disabled.
- `DONE` relay process uses `ControlPath=none` (avoids ControlMaster multiplexing and inherited `RemoteForward` directives) and `ExitOnForwardFailure=no` (inherited forwards from user ssh config failing should not kill the relay).
- `DONE` relay address written to `~/.cmux/socket_addr` on the remote with a 3s delay after the relay process starts, giving SSH time to establish the `-R` forward.
- `DONE` Go CLI re-reads `~/.cmux/socket_addr` on each TCP retry to pick up updated relay ports when multiple workspaces overwrite the file.
- `DONE` `cmux ssh` startup exports session-local `CMUX_SOCKET_PATH=127.0.0.1:<relay_port>` so parallel sessions pin to their own relay instead of racing on shared socket_addr.
- `DONE` relay startup writes `~/.cmux/relay/<relay_port>.daemon_path`; remote `cmux` wrapper uses this to select the right daemon binary per session, including mixed local cmux versions.
- `DONE` ephemeral port range (49152-65535) filtered from probe results to exclude relay ports from other workspaces.
- `DONE` multi-workspace port conflict detection uses TCP connect check (`isLoopbackPortReachable`) so ports already forwarded by another workspace are silently skipped instead of flagged as conflicts.
- `DONE` orphaned relay SSH processes from previous app sessions are cleaned up before starting a new relay.

### 3.3 Error Surfacing
- `DONE` remote errors are surfaced in sidebar status + logs + notifications.
- `DONE` reconnect retry count/time is included in surfaced error text (for example, `retry 1 in 4s`).

### 3.4 Existing Temporary Behavior (To Remove)
- `TEMPORARY` current implementation probes remote listening ports and mirrors them locally with SSH `-L`.
- `TEMPORARY` sidebar shows local bind conflicts (`SSH port conflicts ...`) caused by that mirroring path.
- `TARGET` browser path must no longer depend on per-port mirroring.

## 4. Target Architecture (No Port Mirroring)

### 4.1 Browser Networking Path
1. One local proxy endpoint per SSH transport (not per workspace, not per detected port).
2. Proxy endpoint supports SOCKS5 and HTTP CONNECT.
3. Browser panels in remote workspaces are auto-wired to this proxy endpoint.
4. Browser panels in local workspaces are not force-proxied.

### 4.2 WKWebView Wiring
1. Use workspace/browser scoped `WKWebsiteDataStore.proxyConfigurations`.
2. Prefer SOCKS5 proxy config.
3. Keep HTTP CONNECT proxy config as fallback.
4. Re-apply/validate proxy config after reconnect.

### 4.3 Remote Daemon + Transport
1. Extend `cmuxd-remote` beyond `hello/ping` with proxy stream RPC (`proxy.open`, `proxy.close`).
2. Local side runs a transport-scoped proxy broker and multiplexes proxy streams over SSH stdio transport.
3. Remove remote service-port discovery/probing from browser routing path.

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
| M-002 | Remote bootstrap/upload/start + hello handshake | DONE | Current `cmuxd-remote` is minimal (`hello`, `ping`) |
| M-003 | Reconnect/disconnect UX + API + improved error surfacing | DONE | Includes retry count in surfaced errors |
| M-004 | Docker e2e for bootstrap/reconnect shell niceties | DONE | Existing docker tests currently validate mirroring-era path |
| M-004b | CLI relay: run cmux commands from within SSH sessions | DONE | Reverse TCP forward + Go CLI relay + bootstrap wrapper (PR #374) |
| M-005 | Remove automatic remote port mirroring path | TODO | Delete probe/listen mirror loop from `WorkspaceRemoteSessionController` |
| M-006 | Transport-scoped local proxy broker (SOCKS5 + CONNECT) | TODO | Local component in app/daemon layer |
| M-007 | Remote proxy stream RPC in `cmuxd-remote` | TODO | Add `proxy.open/close` and multiplexed stream handling |
| M-008 | WebView proxy auto-wiring for remote workspaces | TODO | Use `WKWebsiteDataStore.proxyConfigurations` |
| M-009 | PTY resize coordinator (`smallest screen wins`) | TODO | Session-level attachment-size aggregation |
| M-010 | Resize + proxy reconnect e2e test suites | TODO | Add dedicated docker cases for browser proxy + resize |

## 7. Acceptance Test Matrix (With Status)

### 7.1 Terminal + Reconnect

| ID | Scenario | Status |
|---|---|---|
| T-001 | baseline remote connect | DONE |
| T-002 | identical host reuse semantics | PARTIAL |
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
| W-001 | remote workspace browser auto-proxied | TODO |
| W-002 | browser egress IP equals remote host IP | TODO |
| W-003 | websocket via SOCKS5/CONNECT through remote daemon | TODO |
| W-004 | reconnect restores browser proxy path automatically | TODO |
| W-005 | local proxy bind conflict yields structured `proxy_unavailable` | TODO |

### 7.4 Resize

| ID | Scenario | Status |
|---|---|---|
| RZ-001 | two attachments, smallest wins | TODO |
| RZ-002 | grow one attachment, PTY stays bounded by smallest | TODO |
| RZ-003 | detach smallest, PTY expands to next smallest | TODO |
| RZ-004 | reconnect preserves session + applies recomputed size | TODO |

## 8. Removal Checklist (Port Mirroring)

Before declaring browser proxying complete:
1. remove remote port probe loop and `-L` auto-forward orchestration
2. remove mirror-specific sidebar conflict messaging as default remote behavior
3. replace mirroring tests with browser-proxy e2e tests
4. keep optional explicit user-driven forwarding as separate feature only if needed

## 9. Open Decisions

1. Proxy auth policy for local broker (`none` vs optional credentials).
2. Reconnect backoff profile and max retry budget.
3. Browser data-store isolation policy for remote vs local workspaces.
