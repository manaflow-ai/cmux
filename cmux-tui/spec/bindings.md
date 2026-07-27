# Binding Contract

Bindings live under `cmux-tui/bindings/<lang>/`. The checked-in TypeScript,
Python, Rust, C++, Zig, Go, and Java clients combine generated wire models with
handwritten transports and ergonomic helpers. [`sdk-schema.json`](sdk-schema.json)
is the reviewed generator input. [`inventory.json`](inventory.json) and the
normative protocol files remain authoritative when the SDK IR disagrees.

Every supported binding must expose every implemented protocol v10 command and
event allowed by its selected profile, including stable split ids, stack
layouts, per-surface client sizing, and `set-split-ratio`. A public raw-request
method is required for forward compatibility, but it does not satisfy typed
coverage. APIs newer than the connected server must be guarded by explicit
version checks or feature gates.

## Shared Requirements

Bindings must preserve wire names and schemas. They may expose idiomatic method names, but every method must map to exactly one command in `commands.md`.

Bindings must:

| Requirement | Contract |
| --- | --- |
| Version check | Call `identify` or require the caller to supply protocol compatibility before using newer features; require `attach-initial-size` for initial attach sizing and `workspace-registry-v1` for registry APIs |
| Error handling | Preserve the server error string and expose a typed transport vs command distinction |
| Profiles | Expose `control`, `frontend`, `local-admin`, and `provider-authority` explicitly; refuse profiles whose transport cannot meet the trust boundary |
| Events | Route response lines and event lines correctly on full-duplex connections; preserve an `Unknown` event |
| Attach | Preserve byte, render, and browser attach ordering, including attach-scoped notification, scroll, overflow, and detached events |
| Title changes | Decode `title-changed` as a typed event with `surface` and an optional `title`; protocol v7 guarantees the authoritative title, while v5-v6 omit it |
| JSON mode | Provide a public raw command entry point for forward compatibility |
| Timeouts | Let callers configure request timeout without changing wire schema; document that timeout does not cancel server execution |
| Ids | Use canonical decimal numeric ids for implemented mux requests; interactive attach short ids do not add wire-level `IdRef` support |
| Limits | Bound message, pending-response, pre-authentication, and unread-event buffers |
| Concurrency | Document thread safety and use either one response-routing reader or explicit request serialization |
| Close | Closing a client must unblock pending reads and stop owned transports |

## Current support matrix

| Binding | Unix | WebSocket | Public raw request | Typed v10 inventory |
| --- | --- | --- | --- | --- |
| TypeScript | yes | yes | yes | 83 commands, 44 events |
| Python | yes | no | yes | 83 commands, 44 events |
| Rust | yes | no | yes | 83 commands, 44 events |
| C++ | yes | injected transport | yes | 83 commands, 44 events |
| Zig | yes | no | yes | 83 commands, 44 events |
| Go | yes | no | yes | 83 commands, 44 events |
| Java | yes | no | yes | 83 commands, 44 events |

## Language rollout

The first complete release set is TypeScript, Python, Rust, C++, Zig, Go, and Java. The next set is C# and Swift. C++ uses a native wire client with value types and RAII rather than a Rust ABI wrapper. Zig owns its allocator and exposes error unions. C# provides synchronous and `Task` APIs with `CancellationToken`. Swift uses `Codable`, structured concurrency, and `AsyncSequence`. Shell users use the generated CLI and JSON mode instead of a separate stateful SDK.

## Protocol v7 SDK Expectations

SDKs that expose protocol v7 should provide a version-gated render attachment iterator whose first item is typed `render-state` and whose later union is `render-delta | scroll-changed | detached`; it must preserve plain UTF-8 run text, exact optional fields, resolved colors, row indexes, and unknown-event fallback without routing render events through a VT emulator. Subscribe APIs should default to `tree_events:"coarse"` and expose explicit `"deltas"` opt-in. Delta event unions add every workspace/screen/pane/tab lifecycle event with typed subject and parent ids plus the exact `list-workspaces` entity payload, while retaining `tree-changed` as an explicit resync case rather than an ordinary-change dependency. Detailed per-language API design, generated models, and conformance fixtures are deferred to a later SDK round.

## Protocol v8 SDK Expectations

SDKs must treat `layout.split` and `set-split-ratio` as protocol-v8 features. A client connected to protocol 7 must not require the field or send the command.

## Protocol v9 SDK Expectations

SDKs must treat stack layout nodes and `new-pane` as protocol-v9 features. `new-pane` must fail locally before sending when the identified server reports protocol 8 or older.

## Protocol v10 SDK Expectations

SDKs must require a surface id for every client-sizing mutation and expose `size_participating` on each surface-size report. They must not model participation as one client-wide boolean.

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

`attachSurface()` yields an async iterable. In byte mode, its `vt-state.data`, `output.data`, and `resized.replay` values are decoded to `Uint8Array` without relying on `Buffer` in shared browser code. In protocol-v7 render mode, run text remains a JavaScript string and is never base64-decoded. Wire event types continue to expose their exact fields.

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

## C++

C++ bindings use a native Unix/WebSocket wire implementation, RAII connection and stream objects, `std::variant` event unions, fixed-width integer types, and `std::optional` for nullable fields. Public methods accept typed request values and return a result type that distinguishes transport, timeout, decode, protocol, and command errors. No public header may depend on a Rust ABI.

## Zig

Zig bindings accept an explicit allocator for every client and owned result. Wire structs preserve exact integer widths and optionality. Commands return error unions, streams have explicit `deinit`, and unknown events retain their decoded JSON value. Generated code must support the repository's pinned Zig version.

## C#

C# bindings provide immutable records, `IDisposable` and `IAsyncDisposable` clients, synchronous methods, `Task` variants, and `IAsyncEnumerable` streams. Cancellation stops local waiting and closes a dedicated stream transport; it must not claim to cancel a server command.

## Swift

Swift bindings use `Codable` value types, a `Sendable` client, `async throws` command methods, and `AsyncSequence` streams. Error enums preserve the server string and separate transport, timeout, decode, protocol, and command failures. Apple-platform WebSocket support must use an injected transport so the shared model layer remains portable.

## Deterministic generation

The generator consumes the reviewed schema-v2 protocol IR and emits only
manifest-owned files. It:

1. Runs without a language model, network lookup, timestamps, random ordering, or machine-specific paths.
2. Renders every selected language twice in independent temporary directories and requires byte-for-byte equality.
3. Stages every selected language before changing the working tree.
4. Writes atomically and deletes only stale paths owned by the previous manifest.
5. Emits schema, protocol, profile, command, event, and IR-hash metadata into each package.
6. Fails in CI when generated output differs from the reviewed schema.

Regenerate every SDK with:

```bash
cmux-tui/bindings/generate.sh
```

Verify checked-in output without writing with:

```bash
cmux-tui/bindings/generate.sh --check
```

## Conformance suite

Every binding must pass the same public-SDK contract in
`cmux-tui/bindings/conformance/`. The language-neutral fixture document has a
`contract_version`, 34 `fake_cases`, and three `real_cases`. Each adapter
accepts one JSON request on standard input and returns one JSON result on
standard output, as defined by
[`adapter-protocol.md`](../bindings/conformance/adapter-protocol.md).

The metadata audit requires all 83 commands and 44 events. Fake cases cover
framing, exact `uint64` values, optional-nullable and required-nullable
presence, optional non-null rejection, limits, timeouts, pre-acknowledgement
events, unknown events, overflow, close behavior, every stream mode, all
authority profiles, and provider denial with zero bytes written. Exact request
matching proves omitted, explicit-null, and concrete values produce distinct
wire shapes. Real cases start an isolated headless server and cover
`identify`, `ping`, workspace and terminal creation, send, wait, read, ordered
delta events, rename, close, and disappearance.

Run every required adapter against a prebuilt server with:

```bash
python3 cmux-tui/bindings/conformance/runner.py \
  --require python,typescript,rust,go,java,cpp,zig \
  --cmux-tui-bin cmux-tui/target/debug/cmux-tui
```

The complete matrix is 266 checks, 38 per language. The suite fails on stale
generated output, missing required toolchains,
metadata gaps, adapter build failures, response mismatches, unexpected
authority writes, or live lifecycle failures. The complete fixture and runner
contract is documented in
[`bindings/conformance/README.md`](../bindings/conformance/README.md).
