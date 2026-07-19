# Binding Generation Contract

Generated bindings live under `cmux-tui/bindings/<lang>/` in a future round. They are generated from this spec and validated by the conformance suite in this file.

All bindings must expose the implemented protocol v5 commands, events, and socket transport. Proposed protocol v6 APIs may be generated behind explicit version checks or feature gates.

## Shared Requirements

Bindings must preserve wire names and schemas. They may expose idiomatic method names, but every method must map to exactly one command in `commands.md`.

Bindings must:

| Requirement | Contract |
| --- | --- |
| Version check | Call `identify` or require the caller to supply protocol compatibility before using newer features |
| Error handling | Preserve the server error string and expose a typed transport vs command distinction |
| Events | Route response lines and event lines correctly on full-duplex connections |
| Attach | Preserve attach ordering for the negotiated protocol: v5 `vt-state`, then `output`, then `detached`; v6 `vt-state`, then `(resized | output)*`, then `detached` |
| JSON mode | Provide a way to send raw command JSON for forward compatibility |
| Timeouts | Let callers configure request timeout without changing wire schema |
| Ids | Use numeric ids for v5 and `IdRef` for proposed v6 |

## Rust

Rust bindings should use typed request and response structs with Serde serialization. Public methods should return `Result<T, CmuxError>`, where `CmuxError` separates command errors, decode errors, connection errors, timeouts, and protocol-version errors.

Method names use snake_case. Wire command names remain kebab-case through Serde attributes. Events should be a non-exhaustive enum with typed payload structs and an `Unknown` variant for forward compatibility.

Streaming APIs should use an iterator or channel for blocking clients and may offer async adapters later. The first generated binding can be synchronous because the implemented server is synchronous.

## Python

Python bindings should provide a synchronous client and dataclasses for command results and events. Method names use snake_case, such as `read_screen(surface)` and `list_workspaces()`.

Errors should derive from a common `CmuxError`, with subclasses for `CommandError`, `ConnectionError`, `ProtocolError`, and `TimeoutError`. The server error string must be available as a property.

The client should support context-manager usage to close sockets deterministically. Event streams should be Python iterators yielding dataclass event objects. Raw JSON access should remain available for scripts.

## TypeScript

TypeScript bindings should expose promise-based command methods and discriminated unions for results and events. The `event` field is the event discriminator. Command errors should reject with a typed error carrying the server message and optional command id.

The `cmux` package is the frontend client library. Its package root conditionally exports a browser-safe ESM entry, while `cmux/node` explicitly exports the Node entry with the default Unix-socket behavior. Shared modules must not import Node builtins at module scope.

All clients accept a `Transport` with this contract:

```ts
interface Transport {
  send(json: string): void;
  onMessage(handler: (json: string) => void): () => void;
  onClose(handler: () => void): () => void;
  onError(handler: (error: Error) => void): () => void;
  close(): void;
}
```

`UnixSocketTransport` frames each JSON message as one line. `WebSocketTransport` frames each JSON message as one text frame, uses the browser global by default, and accepts an injected WebSocket-compatible constructor in Node without requiring a runtime dependency.

`CmuxRequest` is discriminated by exact wire `cmd`; `CmuxEvent` is discriminated by exact wire `event` and retains an unknown-event fallback. `request({cmd,...params})` infers successful response data from the request member. Typed command methods remain the preferred surface.

`attachSurface()` yields an async iterable. Its `vt-state.data`, `output.data`, and `resized.replay` values are decoded to `Uint8Array` without relying on `Buffer` in shared browser code. Wire event types continue to expose their exact base64 string fields.

Generated types must preserve exact field optionality. Unknown event names should be represented as `{ event: string; [key: string]: unknown }` rather than being dropped.

## Go

Go bindings should use `context.Context` on every command method. Method names use exported Go style, such as `ReadScreen(ctx, surface)` and `ListWorkspaces(ctx)`.

Errors should support `errors.Is` or `errors.As` for command error, connection error, timeout, and protocol mismatch. Command result structs should use JSON tags matching wire names.

Event and attach streams should expose receive methods that take a context and return typed event interfaces or structs. Callers must be able to close the client and unblock pending reads.

## Java

Java bindings should provide a client with builder-based configuration:

```text
CmuxClient.builder().session("main").build()
```

Command request objects with more than one optional parameter should use builders. Simple commands may be direct methods. Results should be immutable value objects.

Errors should use checked or clearly documented runtime exceptions with separate types for command errors, transport errors, decode errors, and protocol mismatch. Event streams should use an iterator, callback interface, or Java Flow publisher, with the simplest synchronous option generated first.

## Conformance Suite

Every generated binding and CLI implementation must pass the same conformance suite against a real headless server. The suite lives under `cmux-tui/bindings/conformance/` and is run with:

```bash
python3 cmux-tui/bindings/conformance/runner.py
```

### Fixture File Format

Conformance fixtures use a file wrapper:

```text
object{
  defaults?: object{timeout_ms?: uint64},
  fixtures: array<Fixture>
}
```

`Fixture`:

```text
object{
  name: string,
  requires?: object{commands?: array<string>},
  timeout_ms?: uint64,
  steps: array<Step>
}
```

`requires.commands` is a fixture-level skip gate. Before running the fixture, the runner probes each command. If the server lacks a required command, the fixture is reported as `SKIP`, not `PASS` and not `FAIL`. Skipped fixtures are counted separately in the summary and indicate an honest coverage gap for the tested server.

A command step sends one command and checks the response:

```text
object{
  type: "command",
  request: object,
  expect: object,
  match?: "exact"|"partial",
  bind?: object<string,string>,
  timeout_ms?: uint64
}
```

`match:"exact"` requires exact JSON equality. `match:"partial"` requires the expected object to be a recursive subset of the actual object. For arrays in partial mode, expected entries match by index and extra actual entries are ignored.

`bind` maps variable names to JSON paths evaluated against that step's command response. Paths are dot-separated and start at the response object, such as `data.surface` or `data.workspaces[0].screens[0].panes[0].id`. A later request, expectation, or event predicate may use `"$name"` to substitute the bound JSON value. Missing paths fail the fixture.

Every step has a timeout. `timeout_ms` on the step wins; otherwise the fixture runner uses `defaults.timeout_ms`; otherwise it uses 5000 ms.

A `wait_contains` step repeats a command until the response value at `path` contains `contains` or the timeout expires:

```text
object{
  type: "wait_contains",
  request: object,
  path: string,
  contains: string,
  timeout_ms?: uint64
}
```

This is used for PTY output assertions where `send` and terminal rendering are asynchronous.

### Event Transcript Format

Event expectation steps use `type:"expect_events"`, a stream name, and an `expect` array. Matching is an in-order subsequence over the event stream. Each expected event is a partial match: specified fields must equal after variable substitution, unspecified fields are ignored. Unrelated interleaved events are tolerated. The step fails if the subsequence is not observed before timeout.

A stream step opens a persistent stream, usually by sending `subscribe`:

```json
{"type":"stream","name":"events","request":{"id":3,"cmd":"subscribe"},"expect":{"id":3,"ok":true},"match":"partial"}
```

### Worked Fixture: Subscribe And New Tab

This fixture uses only protocol v5 commands and can run against a headless server.

```json
{
  "defaults": { "timeout_ms": 5000 },
  "fixtures": [
    {
      "name": "subscribe-new-tab",
      "steps": [
        {
          "type": "command",
          "request": { "id": 1, "cmd": "new-workspace", "cols": 80, "rows": 24 },
          "expect": { "id": 1, "ok": true },
          "match": "partial",
          "bind": { "surface0": "data.surface" }
        },
        {
          "type": "command",
          "request": { "id": 2, "cmd": "list-workspaces" },
          "expect": { "id": 2, "ok": true },
          "match": "partial",
          "bind": {
            "workspace0": "data.workspaces[0].id",
            "screen0": "data.workspaces[0].screens[0].id",
            "pane0": "data.workspaces[0].screens[0].panes[0].id"
          }
        },
        {
          "type": "stream",
          "name": "events",
          "request": { "id": 3, "cmd": "subscribe" },
          "expect": { "id": 3, "ok": true },
          "match": "partial"
        },
        {
          "type": "command",
          "request": { "id": 4, "cmd": "new-tab", "pane": "$pane0" },
          "expect": { "id": 4, "ok": true },
          "match": "partial",
          "bind": { "surface1": "data.surface" }
        },
        {
          "type": "expect_events",
          "stream": "events",
          "expect": [
            { "event": "tree-changed" }
          ]
        },
        {
          "type": "command",
          "request": { "id": 5, "cmd": "list-workspaces" },
          "expect": {
            "id": 5,
            "ok": true,
            "data": {
              "workspaces": [
                {
                  "id": "$workspace0",
                  "screens": [
                    {
                      "id": "$screen0",
                      "panes": [
                        {
                          "id": "$pane0",
                          "active_tab": 1,
                          "tabs": [
                            { "surface": "$surface0" },
                            { "surface": "$surface1" }
                          ]
                        }
                      ]
                    }
                  ]
                }
              ]
            }
          },
          "match": "partial"
        }
      ]
    }
  ]
}
```

### Attach Transcript Format

Attach fixtures validate the replay ordering contract:

```json
{
  "name": "attach-replay-then-live",
  "surface_setup": {"cmd": "run", "command": "printf before; read x; printf after"},
  "attach": {"cmd": "attach-surface", "surface": "$surface0"},
  "expect_prefix": [{"event": "vt-state", "surface": "$surface0"}],
  "actions": [{"cmd": "send", "surface": "$surface0", "text": "x\r"}],
  "expect_later": [{"event": "output", "surface": "$surface0"}]
}
```

For protocol v5, setup uses implemented commands rather than proposed `run`.

### End-to-End Scenario

Each binding must replay this scenario against a real headless server:

1. Connect to the server and call `identify`.
2. Create a workspace with `new-workspace`.
3. Send a shell command that prints a unique marker.
4. Wait for the marker using either proposed `wait-for` when available or a `read-screen` polling loop on v5.
5. Read the screen and assert the marker is present.
6. Rename the surface.
7. Subscribe and trigger a resize.
8. Assert one `surface-resized` event arrives for the changed size and no second event arrives for the same size.
9. Attach to the surface and assert `vt-state` precedes live `output`.
10. Close the workspace and assert the tree no longer contains it.

The suite must fail if a binding drops unknown events, loses command ids, cannot distinguish command errors from transport failures, or assumes `attach-surface` response arrives before `vt-state` on a v5 server.
