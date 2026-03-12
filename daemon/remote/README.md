# cmuxd-remote (Go)

Go remote daemon for `cmux ssh` bootstrap, capability negotiation, and remote proxy RPC. It is not in the terminal keystroke hot path.

## Commands

1. `cmuxd-remote version`
2. `cmuxd-remote serve --stdio`
3. `cmuxd-remote cli <command> [args...]` — relay cmux commands to the local app over the reverse SSH forward

When invoked as `cmux` (via wrapper/symlink installed during bootstrap), the binary auto-dispatches to the `cli` subcommand. This is busybox-style argv[0] detection.

## RPC methods (newline-delimited JSON over stdio)

1. `hello`
2. `ping`
3. `proxy.open`
4. `proxy.close`
5. `proxy.write`
6. `proxy.read`
7. `session.open`
8. `session.close`
9. `session.attach`
10. `session.resize`
11. `session.detach`
12. `session.status`

Current integration in cmux:
1. `workspace.remote.configure` now bootstraps this binary over SSH when missing.
2. Client sends `hello` before enabling remote proxy transport.
3. Local workspace proxy broker serves SOCKS5 + HTTP CONNECT and tunnels stream traffic through `proxy.*` RPC over `serve --stdio`.
4. Daemon status/capabilities are exposed in `workspace.remote.status -> remote.daemon` (including `session.resize.min`).

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

The `cli` subcommand (or `cmux` wrapper/symlink) connects to the local cmux app through an SSH reverse forward and relays commands. It supports both v1 text protocol and v2 JSON-RPC commands.

Socket discovery order:
1. `--socket <path>` flag
2. `CMUX_SOCKET_PATH` environment variable
3. `~/.cmux/socket_addr` file (written by the app after the reverse relay establishes)

For TCP addresses, the CLI retries for up to 15 seconds on connection refused, re-reading `~/.cmux/socket_addr` on each attempt to pick up updated relay ports.

Authenticated relay details:
1. Each SSH workspace gets its own relay ID and relay token.
2. The app runs a local loopback relay server that requires an HMAC-SHA256 challenge-response before forwarding a command to the real local Unix socket.
3. The remote shell never gets direct access to the local app socket. It only gets the reverse-forwarded relay port plus `~/.cmux/relay/<port>.auth`, which is written with `0600` permissions and removed when the relay stops.

Integration additions for the relay path:

1. Bootstrap installs `~/.cmux/bin/cmux` wrapper and keeps a default daemon target (`~/.cmux/bin/cmuxd-remote-current`).
2. A background `ssh -N -R` process reverse-forwards a TCP port to the authenticated local relay server. The relay address is written to `~/.cmux/socket_addr` on the remote.
3. Relay startup writes `~/.cmux/relay/<port>.daemon_path` so the wrapper can route each shell to the correct daemon binary when multiple local cmux instances or versions coexist.
4. Relay startup writes `~/.cmux/relay/<port>.auth` with the relay ID and token needed for HMAC authentication.
