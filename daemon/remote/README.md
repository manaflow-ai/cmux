# cmuxd-remote (Go)

Minimal remote daemon scaffold for `cmux ssh`.

Current commands:
1. `cmuxd-remote version`
2. `cmuxd-remote serve --stdio`

Current RPC methods (newline-delimited JSON):
1. `hello`
2. `ping`

This scaffold is intentionally small so `cmux` can start integrating daemon bootstrap,
capability negotiation, and protocol evolution without coupling to the Swift app runtime.
