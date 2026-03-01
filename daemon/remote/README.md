# cmuxd-remote (Go)

Go remote daemon for `cmux ssh` bootstrap and capability negotiation.

Current commands:
1. `cmuxd-remote version`
2. `cmuxd-remote serve --stdio`

Current RPC methods (newline-delimited JSON):
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
