# cmuxd-remote (Go)

Go remote daemon for `cmux ssh` bootstrap and capability negotiation.

Current commands:
1. `cmuxd-remote version`
2. `cmuxd-remote serve --stdio`

Current RPC methods (newline-delimited JSON):
1. `hello`
2. `ping`

Current integration in cmux:
1. `workspace.remote.configure` now bootstraps this binary over SSH when missing.
2. Client sends `hello` before enabling remote port probing/forwarding.
3. Daemon status/capabilities are exposed in `workspace.remote.status -> remote.daemon`.
