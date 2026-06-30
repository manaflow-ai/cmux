# cmuxd-remote (Go)

Go remote daemon for `cmux ssh` bootstrap, capability negotiation, and remote proxy RPC. It is not in the terminal keystroke hot path.

## Commands

1. `cmuxd-remote version`
2. `cmuxd-remote serve --stdio`
3. `cmuxd-remote serve --stdio --persistent --slot <slot>`
4. `cmuxd-remote serve --ws --auth-lease-file <path> [--rpc-auth-lease-file <path>] [--listen 127.0.0.1:7777]`
5. `cmuxd-remote cli <command> [args...]` — relay cmux commands to the local app over the reverse SSH forward

`serve --ws` is explicit opt-in for cloud VM images only. The normal `cmux ssh`
code path uses `serve --stdio --persistent --slot <slot>` over an SSH exec
channel. That stdio process is only a proxy to an authenticated per-slot daemon
with credentials and logs under `~/.cmux/daemon/<version>/<slot>/`, so remote PTY sessions
can survive local surface close, local reconnect, and app relaunch. The persistent
server never opens a public listener; it accepts only a per-user Unix socket under
`/tmp/cmuxd-remote-<uid>/` and the slot token.

When invoked as `cmux` (via wrapper/symlink installed during bootstrap), the binary auto-dispatches to the `cli` subcommand. This is busybox-style argv[0] detection.

## RPC methods (newline-delimited JSON over stdio)

1. `hello`
2. `ping`
3. `proxy.open`
4. `proxy.close`
5. `proxy.write`
6. `proxy.stream.subscribe`
7. async `proxy.stream.data` / `proxy.stream.eof` / `proxy.stream.error` events
8. `session.open`
9. `session.close`
10. `session.attach`
11. `session.resize`
12. `session.detach`
13. `session.status`
14. `pty.attach`
15. `pty.write`
16. `pty.resize`
17. `pty.detach`
18. `pty.close`
19. `pty.list`

Current integration in cmux:
1. `workspace.remote.configure` now bootstraps this binary over SSH when missing.
2. Client sends `hello` before enabling remote proxy transport.
3. Local workspace proxy broker serves SOCKS5 + HTTP CONNECT and tunnels stream traffic through `proxy.*` RPC over `serve --stdio`, using daemon-pushed stream events instead of polling reads.
4. Daemon status/capabilities are exposed in `workspace.remote.status -> remote.daemon` (including `session.resize.min`).
5. Persistent SSH terminals require the `pty.session.persistent_daemon` capability before cmux will restore a saved remote PTY session ID after relaunch.

## Persistent SSH PTY daemon

`cmux ssh` uses one persistent daemon slot per CLI-launched SSH workspace. The
slot name is generated locally, validated as `[A-Za-z0-9._-]{1,128}`, and sent
to the remote daemon bootstrap as `--slot`.

Remote slot files:
1. `/tmp/cmuxd-remote-<uid>/cmuxd-<slot-hash>.sock` authenticated Unix socket for stdio proxies.
2. `~/.cmux/daemon/<version>/<slot>/auth.token` random 32-byte hex token, mode `0600`.
3. `~/.cmux/daemon/<version>/<slot>/daemon.lock` single-owner lock.
4. `~/.cmux/daemon/<version>/<slot>/daemon.log` startup and crash diagnostics.

PTY lifecycle:
1. A local attach creates or reuses a named `pty.*` session in the persistent daemon.
2. If the local surface closes, the stdio proxy disconnects and its attachment detaches, but the PTY process and bounded scrollback remain in the daemon.
3. `cmux ssh-session-list` calls `pty.list`; `cmux ssh-session-attach` creates a new local terminal whose startup script calls `ssh-pty-attach --require-existing`.
4. `cmux ssh-session-cleanup` calls `pty.close` to terminate a persisted PTY session explicitly.
5. Sessions with no attachments keep their last-known size and are reaped by the daemon idle TTL.

## Cloud WebSocket PTY transport

The WebSocket PTY transport is locked until the backend writes a short-lived
lease file. The baked image contains only the daemon binary and service command,
not user secrets or provider API keys.

Lease file shape:

```json
{
  "version": 1,
  "token_sha256": "<sha256 hex of client attach token>",
  "expires_at_unix": 1770000000,
  "session_id": "optional-session-binding",
  "single_use": true
}
```

Client flow:

1. Connect to `/terminal`.
2. Send a text JSON auth frame first: `{"type":"auth","token":"...","session_id":"...","cols":80,"rows":24}`.
3. After `{"type":"ready"}`, binary WebSocket frames are terminal input/output.
4. Text frames after auth are control frames such as `{"type":"resize","cols":120,"rows":40}`.

Security invariants:

1. `serve --ws` fails to start without `--auth-lease-file`.
2. Missing, expired, wrong-token, or wrong-session leases close with WebSocket
   policy violation before a PTY is started.
3. Successful single-use leases are consumed before the shell is spawned, so a
   replay gets `no active lease`.
4. Provider traffic auth remains separate. E2B images should be created with
   `network.allowPublicTraffic: false`, so E2B requires
   `e2b-traffic-access-token` before the daemon sees the request.

`workspace.remote.configure` contract notes:
1. `port` / `local_proxy_port` accept integer values and numeric strings; explicit `null` clears each field.
2. Out-of-range values and invalid types return `invalid_params`.
3. `local_proxy_port` is an internal deterministic test hook used by bind-conflict regressions.
4. SSH option precedence checks are case-insensitive; user overrides for `StrictHostKeyChecking` and control-socket keys prevent default injection.

## Distribution

Release and nightly builds publish prebuilt `cmuxd-remote` binaries on GitHub Releases for:
1. `darwin/arm64`
2. `darwin/amd64`
3. `linux/arm64`
4. `linux/amd64`

The app embeds a compact manifest in `Info.plist` with:
1. exact release asset URLs
2. pinned SHA-256 digests
3. release tag and checksums asset URL

Release and nightly apps download and cache the matching binary locally, verify its SHA-256, then upload it to the remote host if needed. Dev builds can opt into a local `go build` fallback with `CMUX_REMOTE_DAEMON_ALLOW_LOCAL_BUILD=1`.

To inspect what a given app build trusts, run:
1. `cmux remote-daemon-status`
2. `cmux remote-daemon-status --os linux --arch amd64`

The command prints the exact release asset URL, expected SHA-256, local cache status, and a copy-pasteable `gh attestation verify` command for the selected platform.

## CLI relay

The `cli` subcommand (or `cmux` wrapper/symlink) connects to the local cmux app through an SSH reverse forward and relays commands using the v2 JSON-RPC protocol.

Cloud VM images install `/usr/local/bin/cmux` as a symlink to `cmuxd-remote`,
so `cmux --help` works before a user-specific SSH bootstrap has written
`~/.cmux/bin/cmux`.

Socket discovery order:
1. `--socket <path>` flag
2. `CMUX_SOCKET_PATH` environment variable
3. `~/.cmux/socket_addr` file (written by the app after the reverse relay establishes)

For TCP addresses, the CLI dials once and only refreshes `~/.cmux/socket_addr` a single time if the first address was stale. Relay metadata is published only after the reverse forward is ready, so steady-state use does not rely on polling.

Authenticated relay details:
1. Each SSH workspace gets its own relay ID and relay token.
2. The app runs a local loopback relay server that requires an HMAC-SHA256 challenge-response before forwarding a command to the real local Unix socket.
3. The remote shell never gets direct access to the local app socket. It only gets the reverse-forwarded relay port plus `~/.cmux/relay/<port>.auth`, which is written with `0600` permissions and removed when the relay stops.

Integration additions for the relay path:

1. Bootstrap installs `~/.cmux/bin/cmux` wrapper and keeps a default daemon target (`~/.cmux/bin/cmuxd-remote-current`).
2. A background `ssh -N -R` process reverse-forwards a TCP port to the authenticated local relay server. The relay address is written to `~/.cmux/socket_addr` on the remote.
3. Relay startup writes `~/.cmux/relay/<port>.daemon_path` so the wrapper can route each shell to the correct daemon binary when multiple local cmux instances or versions coexist.
4. Relay startup writes `~/.cmux/relay/<port>.auth` with the relay ID and token needed for HMAC authentication.

### Protocol and flags

All relay commands use v2 JSON-RPC. Flags map to JSON params via `flagToParamKey` (e.g. `--workspace` → `workspace_id`). Boolean flags (`--focus`) accept `true`/`false`/`1`/`0` and are sent as JSON booleans.

Environment fallbacks:
- `CMUX_WORKSPACE_ID` — used as `workspace_id` when `--workspace` is not provided
- `CMUX_SURFACE_ID` — used as `surface_id` when `--surface` is not provided

### Migration notes

**`new-workspace`**: The flags `--command` and `--working-directory` were removed. They were accepted by the old relay but sent incorrect param names that `workspace.create` does not use, so the server silently ignored them. Use `--cwd` for the working directory.

**`send` / `send-key`**: The `--text` and `--key` flags were removed. Both commands now take their argument positionally, matching the Mac CLI convention: `cmux send "hello world"` and `cmux send-key ctrl+c`.

**Window commands**: Prior to this release, `list-windows`, `current-window`, `new-window`, `focus-window`, and `close-window` used a v1 text protocol and returned plain-text responses (e.g. `window:abc123` per line). They now use v2 JSON-RPC and return JSON. Scripts parsing that output will need updating.

Browser relay behavior:

1. `cmux browser ...` inside an SSH session controls the local cmux browser through the authenticated relay, not a browser process inside the VM.
2. The remote CLI supports the common automation commands: `open`, `navigate`, `back`, `forward`, `reload`, `get-url`, `snapshot`, `eval`, `wait`, `click`, `dblclick`, `hover`, `focus`, `check`, `uncheck`, `fill`, `type`, `press`, `select`, and `screenshot`.
3. Commands that target an existing browser surface default to `CMUX_SURFACE_ID`; `open` defaults to `CMUX_WORKSPACE_ID` so agents can create a browser pane next to the active SSH terminal.

Workspace group relay behavior:

1. `cmux workspace group <sub>` (and the `cmux workspace-group <sub>` alias) maps to the `workspace.group.*` v2 methods, with the same subcommands and flags as the macOS CLI: `list`, `create`, `ungroup`, `delete`, `rename`, `collapse`, `expand`, `pin`, `unpin`, `add`, `remove`, `set-anchor`, `new-workspace`, `set-color`, `set-icon`, `move`, and `focus`.
2. The group id comes from `--group <id>` or the first positional argument and accepts UUIDs or refs such as `workspace_group:1`. Like the macOS CLI, `add` and `set-anchor` require explicit `--group <id> --workspace <id>`.
