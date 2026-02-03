# Remote PTY Server (cmuxd) Spec

## Goals
- Run cmuxterm sessions on a remote macOS or Linux host and attach from the local UI.
- Preserve Ghostty behavior (scrollback, modes, selection, key handling).
- Support multiple remote endpoints (local daemon, Docker, SSH VMs) with a single UI.
- Server owns **sessions** (one PTY per session); client owns **tabs/splits**.
- Local host macOS mode: run cmuxd as a daemon so Swift UI restarts do not kill PTYs.

## Non-goals (v1)
- Multiple simultaneous viewers on the same session.
- Browser client.
- GPU rendering on the server.

## Architecture
### Server: cmuxd (Zig)
- Owns PTYs and sessions (one PTY per session).
- Uses Ghostty core headless terminal state for snapshots and parsing.
- Exposes protocol over:
  - SSH stdio: `ssh -T host cmuxd --stdio`
  - WebSocket: `cmuxd --ws :port`
  - Unix socket: `cmuxd --unix /path`

### Client: cmuxterm (Swift)
- UI only. No PTY locally in remote mode.
- Connects to multiple cmuxd endpoints via WS, SSH stdio, or unix sockets.
- Renders remote panes by feeding output and snapshots into GhosttyKit.
- Tabs/splits are client-managed and map to separate remote sessions.
- Remote endpoints are configured via `~/Library/Application Support/cmuxterm/remote-connections.json`.

## Ghostty Integration (chosen for v1)
### Manual backend + snapshot VT
- Use Ghostty manual IO mode.
- C ABI: `ghostty_surface_process_output(surface, bytes, len)`.
- Client forwards user input to cmuxd; cmuxd forwards PTY output back.
- cmuxd can export a VT snapshot for reattach.

## Protocol (Option B)
### Framing
- Newline-delimited JSON for stdio (SSH/unix socket).
- WebSocket text frames with identical JSON payloads.
- Binary data is base64-encoded.

### Handshake
- `hello` → `welcome`.
- `welcome` includes `session_id`, `pane_id`, and `capabilities`.
- Optional `capabilities` request returns a `capabilities` message.

### Core Messages
- Sessions:
  - `list_sessions` → `sessions` (array of `{session_id, pane_id, title, cwd}`)
  - `new_session` → `session_created`
  - `attach_session` → `session_attached`
- Panes (legacy/compat):
  - `list_panes` → `panes` (supports optional `session_id` for scoping)
  - `new_pane` → `pane_created` (legacy alias for `new_session`)
- IO:
  - `input`, `resize`, `snapshot_request` → `snapshot`, `output`
  - `pane_exited`
  - `ping` → `pong`
- Metadata / notifications:
  - `title_update`, `cwd_update`, `notify`
- Errors:
  - `error` (e.g., failed `attach_session`)

### IDs
- `session_id` identifies a session.
- `pane_id` identifies the stream for that session.
- Output/snapshot/metadata/notify events include both IDs.

## OSC Support
cmuxd emits metadata/notifications from OSC sequences:
- Title: OSC 0 / OSC 2 → `title_update`
- CWD: OSC 7 → `cwd_update` (raw URI string)
- Desktop notifications:
  - OSC 9 (iTerm2) → `notify`
  - OSC 99 (kitty) → `notify`
  - OSC 777;notify (rxvt) → `notify`

## Config
Explicit transport enablement required:

```
cmuxd --stdio
cmuxd --ws 0.0.0.0:4070
cmuxd --unix /path/to/cmuxd.sock
```

Rules:
- If none of `--stdio`, `--ws`, or `--unix` is specified, cmuxd exits with error.

## Local Host macOS Daemon Mode
- cmuxd runs as LaunchAgent or foreground daemon.
- cmuxterm can attach via unix socket (preferred) or WS.
- UI restarts reattach to running sessions.

## Tests
### cmuxd E2E
- SSH stdio and WS handshake
- Session list/new/attach
- List panes scoping by session
- Snapshot + resize
- OSC metadata + notifications

### Docker E2E
```
./scripts/test-e2e-docker.sh
```
