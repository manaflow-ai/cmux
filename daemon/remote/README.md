# cmuxd-remote (Go)

Go remote daemon for `cmux ssh` bootstrap, capability negotiation, and CLI relay.

## Commands

1. `cmuxd-remote version`
2. `cmuxd-remote serve --stdio`
3. `cmuxd-remote cli <command> [args...]` — relay cmux commands to the local app over the reverse TCP forward

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

## CLI relay

The `cli` subcommand (or `cmux` wrapper/symlink) connects to the local cmux app's socket through an SSH reverse TCP forward and relays commands. It supports both v1 text protocol and v2 JSON-RPC commands.

Socket discovery order:
1. `--socket <path>` flag
2. `CMUX_SOCKET_PATH` environment variable
3. `~/.cmux/socket_addr` file (written by the app after the reverse relay establishes)

For TCP addresses, the CLI retries for up to 15 seconds on connection refused, re-reading `~/.cmux/socket_addr` on each attempt to pick up updated relay ports.

Integration additions for the relay path:

1. Bootstrap installs `~/.cmux/bin/cmux` wrapper and keeps a default daemon target (`~/.cmux/bin/cmuxd-remote-current`).
2. A background `ssh -N -R` process reverse-forwards a TCP port to the local cmux Unix socket. The relay address is written to `~/.cmux/socket_addr` on the remote.
3. Relay startup writes `~/.cmux/relay/<port>.daemon_path` so the wrapper can route each shell to the correct daemon binary when multiple local cmux instances/versions coexist.
