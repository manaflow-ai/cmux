# SDK contract

cmux ships handwritten resource APIs for Rust, Python, TypeScript, Go, Java,
C++20, and Zig. Each package also contains a generated private-protocol layer
under an explicit `raw` namespace.

The split is deliberate:

- [`resource-operations-v2.json`](resource-operations-v2.json) defines the
  stable public operations, selectors, fields, results, errors, and streams.
- Public resource handles, options, lifecycle, errors, and conveniences are
  handwritten in each language.
- Mechanical protocol-v12 models are generated deterministically and exposed
  only through `raw`.
- A catalog descriptor in every package proves that all 125 transported
  operations have the same class and wire name.
- The six sidebar plugin operations are local CLI/filesystem APIs. Transported
  SDK roots expose sidebar views, not plugin resource handles.

Code generation is a repository build tool. It is never a consumer dependency
and does not define the public API.

## Shared behavior

Every high-level SDK must provide:

| Area | Contract |
| --- | --- |
| IDs | Distinct typed wrappers for every opaque resource prefix; no numeric or abbreviated forms |
| Selectors | ID, `current`, or exact name; name lookup returns all matches |
| Handles | Machine, session, workspace, screen, pane, tab, terminal, browser, and auxiliary resource handles |
| Routing | Session resources always carry machine and session selectors; direct opaque targets require no hidden lookup |
| Names | Exact bytes, including empty, whitespace, and Unicode; duplicate names stay ambiguous |
| Commands | Exact argument arrays, target-platform shell scripts, and explicitly selected shell executables |
| Mutations | Secure 128-bit default idempotency keys; explicit keys use 1 to 128 UTF-8 bytes, contain non-whitespace, and exclude Unicode control scalars; optional expected revision, one wire request, and no implicit retry |
| Results | Flat `value`, `generation`, decimal-string `revision`, and `replayed` fields |
| Errors | Transport, timeout, decode, and structured resource errors retain code, message, details, and retryability |
| Streams | Typed items, explicit cancellation, bounded unread queues, structured end state, and per-stream overflow isolation |
| Evolution | Unknown stream variants retain their discriminator and complete raw object; malformed known variants fail decoding |
| Secrets | Pairing codes and renderer tokens are redacted from formatting and errors |
| Raw access | Private protocol-v12 APIs are reachable only through a package path containing `raw` |

Decimal wire values remain strings. TypeScript never converts them to
`number`; Java uses `BigInteger`; other SDKs validate canonical unsigned
decimal text before an optional native conversion.

The server may return `mutation.indeterminate` after a crash around an external
effect. SDKs retain the structured error and never repeat that key
automatically.

## Commands

An exact command preserves every argument and does not invoke a shell:

```text
["printf", "%s\n", "$HOME"]
```

A shell command asks the server to use the target platform's default shell
with `-lc`. Choosing a specific executable sends the exact array:

```text
["/bin/zsh", "-lc", "printf ready"]
```

SDKs never read, expand, or transmit the caller's `$SHELL`.

## Streams

The public stream families are:

- session snapshots and atomic resource-change batches;
- styled terminal render snapshots, patches, and scroll state;
- browser state and frames;
- styled sidebar render snapshots, patches, and scroll state.

Each stream has a caller-generated typed ID. The server installs its event tap
before acknowledging the open request and releases the initial snapshot after
that response. Cancellation is connection-local. A queue holds at most 256
messages and 16 MiB. Overflow ends only that stream with a gap and recovery
cursor.

## Language mapping

| Language | Public style | Owned lifetime | Minimum | Runtime dependencies |
| --- | --- | --- | --- | --- |
| Rust | `Result`, typed handles, blocking iterators | `Client` and stream objects | Rust 1.88 | `serde`, `serde_json`, `getrandom`, narrow Unix support |
| Python | typed classes and dataclasses, sync plus `asyncio` facade | context-managed clients and iterators | Python 3.9 | standard library |
| TypeScript | branded IDs, promises, discriminated unions, async iterables | client, stream, and `AbortSignal` | Node 20 or browser ESM | none |
| Go | generic typed selectors, `context.Context`, typed stream receivers | client, context, and stream cancellation | Go 1.22 | standard library |
| Java | immutable values, builders, `BigInteger`, synchronous streams | `AutoCloseable` client and streams | Java 17 | standard library |
| C++ | value types, `result<T>`, `std::variant`, move-only RAII streams | RAII client and streams | C++20, CMake 3.20 | standard library |
| Zig | typed IDs, error unions, explicit allocator-owned values | explicit `deinit` | Zig 0.15.2 | standard library |

### Rust

The `cmux-sdk` package exports crate `cmux`. Resource handles clone without
I/O. Mutation helpers create one secure key; `_with` variants accept explicit
mutation options. Typed streams are owned iterators with cancellation handles.
The optional `cmux-sidebar` package applies terminal-style render patches to a
Ratatui buffer and forwards typed input without adding Ratatui to the base SDK.
Private models live under `cmux::raw`.

### Python

`cmux.Client` is synchronous and supports `with`. `cmux.aio.Client` mirrors the
resource graph for `asyncio`. Cancellation closes its dedicated connection and
releases reader threads. The package supports Python 3.9 without runtime
dependencies. Private models live under `cmux.raw`.

### TypeScript

The `cmux-sdk` package root exports the portable client. `cmux-sdk/browser` is
browser-safe ESM and accepts an injected WebSocket transport. `cmux-sdk/node`
adds Unix socket discovery. Shared modules import no Node built-ins.
Stream APIs are `AsyncIterable`, accept `AbortSignal`, and preserve decimal
strings. Private models live under `cmux-sdk/raw`.

### Go

Package `cmux` accepts `context.Context` on blocking operations. Context
cancellation stops local waiting and closes dedicated streams; it does not
claim to cancel an already executing mutation. A dial function can inject a
transport on Windows and in tests. Private models live under `cmux/raw`.

### Java

Package `com.cmux` uses builders for requests with several optional fields and
immutable results. `Client` and `ResourceStream` support
try-with-resources. A transport can be injected for WebSockets, non-Unix
platforms, and tests. Private models live under `com.cmux.raw`.

### C++20

Headers under `cmux` expose native C++ value types and no Rust ABI.
`cmux::result<T>` separates typed failure categories. The default transport is
Unix JSON Lines; applications inject other transports. Private headers live
under `cmux/raw`.

### Zig

Public methods accept an explicit allocator for owned data. Results and streams
require `deinit`. Errors retain structured remote fields and secret values are
zeroized when their owning values are released. Private modules live under
`raw`.

## Transport parity

Unix sockets use one JSON object per line. WebSockets use one JSON object per
text frame. Both carry the same `cmux.protocol/2` envelopes and ordering.
Transport-specific code may frame and authenticate a connection; it may not
change operation parameters or results.

Public clients must bound:

- one request to 4 MiB;
- one response or stream envelope to 16 MiB;
- pending response routing;
- unread messages and bytes independently for each stream.

Closing a client unblocks pending reads and releases owned transports.

## Deterministic raw generation

The raw generator:

1. consumes the reviewed protocol-v12 schema;
2. renders each selected language twice and requires byte equality;
3. stages all outputs before changing the checkout;
4. writes atomically;
5. deletes only files owned by the previous manifest;
6. records schema and output hashes;
7. fails CI when checked-in output drifts.

Regenerate:

```bash
python3 cmux-tui/bindings/codegen/generate.py --write
```

Verify without writing:

```bash
python3 cmux-tui/bindings/codegen/generate.py --check
```

## Acceptance

Each language must pass:

- unit tests for IDs, selectors, requests, results, errors, redaction, and
  unknown variants;
- exact fake-server transcripts for ordering, cancellation, timeout, overflow,
  and idempotency;
- clean package installation and an external consumer build;
- catalog descriptor parity for every transported operation;
- a live isolated server flow that creates, runs, reads, mutates, streams, and
  closes resources;
- its minimum compiler or runtime version.

The repository-level boundary checker rejects private resource fields,
private identity forms, raw imports, and missing operation descriptors from
high-level packages.

The next likely SDKs are C# and Swift. They should follow this contract only
after the seven initial packages and protocol have shipped stable.
