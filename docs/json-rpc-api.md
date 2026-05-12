# cmux JSON-RPC API

cmux exposes its local automation API over the same Unix socket used by the
`cmux` CLI. The socket accepts one UTF-8 JSON request per line and writes one
UTF-8 JSON response per line. Requests that include `"jsonrpc": "2.0"` receive
JSON-RPC 2.0 responses. Requests without that field keep the legacy v2 envelope
so existing CLI and test clients continue to work.

This is the first public contract for the socket API. Prefer the JSON-RPC
envelope for new integrations.

## Transport

- Path: the value of `CMUX_SOCKET_PATH`, `--socket`, or the socket path reported
  by `cmux identify --json`.
- Framing: newline-delimited JSON. Each request and response is one line.
- Encoding: UTF-8.
- Concurrency: open a separate connection for long-lived subscriptions.
- Auth: same local socket policy as the CLI. Password mode requires the existing
  `auth.login` handshake before other methods.

Example:

```json
{"jsonrpc":"2.0","id":"1","method":"system.ping","params":{}}
```

Response:

```json
{"jsonrpc":"2.0","id":"1","result":{"pong":true}}
```

Requests with `"jsonrpc": "2.0"` and no `"id"` member are JSON-RPC
notifications. cmux executes those methods but does not write a response frame.
An explicit `"id": null` is still a request and receives a response with
`"id": null`.

## Errors

JSON-RPC mode uses standard numeric error codes where possible and preserves the
cmux domain error code in `error.data.cmux_code`.

```json
{
  "jsonrpc": "2.0",
  "id": "bad-method",
  "error": {
    "code": -32601,
    "message": "Unknown method",
    "data": { "cmux_code": "method_not_found" }
  }
}
```

Common mappings:

| cmux code | JSON-RPC code |
| --- | --- |
| `parse_error` | `-32700` |
| `invalid_request` | `-32600` |
| `method_not_found` | `-32601` |
| `invalid_params` | `-32602` |
| `invalid_dispatch` | `-32603` |
| other cmux errors | `-32000` |

## Discovery

Call `system.capabilities` or run `cmux capabilities` to list available methods.
The result includes the socket protocol name, socket API version, JSON-RPC
version, access mode, and method names.

```json
{"jsonrpc":"2.0","id":"cap","method":"system.capabilities","params":{}}
```

The CLI also exposes a raw method bridge:

```bash
cmux rpc workspace.list '{}'
cmux rpc surface.send_text '{"surface_id":"...","text":"git status\n"}'
```

`cmux rpc` currently uses the compatibility v2 envelope internally but calls the
same method table as JSON-RPC clients.

## Method Families

Stable public method names are dot-separated and grouped by domain.

| Family | Examples |
| --- | --- |
| System | `system.ping`, `system.capabilities`, `system.identify`, `system.tree`, `system.top` |
| Windows | `window.list`, `window.current`, `window.focus`, `window.create`, `window.close` |
| Workspaces | `workspace.list`, `workspace.create`, `workspace.select`, `workspace.current`, `workspace.close`, `workspace.rename`, `workspace.reorder` |
| Panes | `pane.list`, `pane.focus`, `pane.surfaces`, `pane.create`, `pane.resize`, `pane.swap`, `pane.break`, `pane.join`, `pane.last` |
| Surfaces | `surface.list`, `surface.current`, `surface.focus`, `surface.create`, `surface.close`, `surface.move`, `surface.send_text`, `surface.send_key`, `surface.read_text` |
| Browser | `browser.open_split`, `browser.navigate`, `browser.snapshot`, `browser.click`, `browser.type`, `browser.eval`, `browser.screenshot` |
| Notifications | `notification.create`, `notification.list`, `notification.clear` |
| Events | `events.stream` |

Use `system.capabilities` as the authoritative method list for the running app.

## Handles

Most methods accept UUIDs and stable session refs for windows, workspaces, panes,
and surfaces. Refs look like `window:1`, `workspace:2`, `pane:1`, and
`surface:3`. Methods that list objects return both the UUID (`id`) and ref
(`ref`) when available.

Inside a cmux terminal, callers can use:

- `CMUX_WORKSPACE_ID`
- `CMUX_SURFACE_ID`
- `CMUX_TAB_ID`

## Events

`events.stream` upgrades one socket connection into a long-lived subscription.
In JSON-RPC mode, the initial response contains the subscription ack as
`result`. Replay and live events are emitted as JSON-RPC notifications whose
`method` is the event name.

Request:

```json
{"jsonrpc":"2.0","id":"events-1","method":"events.stream","params":{"after_seq":123,"categories":["workspace","pane"]}}
```

Initial response:

```json
{"jsonrpc":"2.0","id":"events-1","result":{"type":"ack","protocol":"cmux-events","version":1,"subscription_id":"..."}}
```

Event notification:

```json
{"jsonrpc":"2.0","method":"workspace.created","params":{"type":"event","seq":124,"name":"workspace.created","category":"workspace","payload":{}}}
```

Heartbeat notification:

```json
{"jsonrpc":"2.0","method":"cmux.events.heartbeat","params":{"type":"heartbeat","latest_seq":124}}
```

The existing `cmux events` command prints the legacy event frames documented in
`docs/events.md`. Both stream forms use the same event bus, replay buffer,
filters, and slow-consumer policy.

## Versioning

`system.capabilities.result.version` is the cmux socket API version. JSON-RPC
envelope support is advertised through `system.capabilities.result.jsonrpc`.

Backwards-compatible method additions do not bump the socket API version.
Breaking method or event shape changes must bump the socket API version and be
called out in the changelog.
