# cmx Swift client

Swift Package that lets the macOS cmux app (or any Swift/AppKit app)
attach to a cmx server.

## Status

This directory is a scaffold. The Rust server supports all three needed
pieces — Unix socket + MessagePack protocol (M3), multi-workspace tab
stack (M5/M6), and WebSocket transport with token auth (M9) — but the
actual Swift attach loop is not yet implemented in-tree.

The project decision (from the architecture plan) is that the macOS cmux
app's integration point is a new `CmxTerminalPanel` type that:

1. opens the user's `$XDG_RUNTIME_DIR/cmux-cli/server.sock` directly
   (single multiplexed connection per panel, no `cmx attach` subprocess),
2. uses Grid attach mode (`ClientMsg::Hello { mode: Grid }`) and receives
   raw PTY byte streams from the server,
3. feeds those bytes into a local libghostty-vt instance from Ghostty's
   XCFramework (`example/swift-vt-xcframework`),
4. renders via the same SwiftUI layer the existing `TerminalPanel` uses.

Long-term v2 goal (out of scope for cmux-cli v1): migrate every
`TerminalPanel` in the macOS app to the `CmxTerminalPanel` path, so the
GUI gains detach/attach + remote for free.

## Wire contract (for the implementation)

All fields are MessagePack (named-fields encoding, matching
`rmp_serde::to_vec_named`).

Client → server:

| Variant | Field name | Payload shape |
|---|---|---|
| `hello` | `{ version, mode, viewport, token }` | `version: u32 = 1`, `mode: "ansi"\|"grid"`, `viewport: { cols, rows }`, `token: String?` |
| `input` | `{ data }` | `data: Bytes` (keystrokes/paste) |
| `resize` | `{ viewport }` | |
| `command` | `{ id, command }` | `command` is a tagged enum — see `cmux-cli-protocol/src/lib.rs` for the full set |
| `detach` | | |
| `ping` | | |

Server → client:

| Variant | Notes |
|---|---|
| `welcome` | `{ server_version, session_id }` |
| `ansi_data` | `{ data }` — Ansi mode: write verbatim to the terminal emulator |
| `pty_bytes` | `{ tab_id, data }` — Grid mode: feed into the local libghostty-vt for `tab_id` |
| `active_workspace_changed` | `{ index, workspace_id, title }` |
| `active_tab_changed` | `{ index, tab_id }` |
| `command_reply` | `{ id, result: ok{data?} \| err{message} }` |
| `bye` | session over |
| `pong` | |
| `error` | fatal |

### Framing

- **Unix socket**: 4-byte big-endian length prefix, then the MessagePack
  payload.
- **WebSocket**: one binary frame per message — no length prefix.

## Transport choice

- On the local Mac, default to Unix socket.
- For a remote Mac (SSH dev VM, etc.), use WebSocket and pass `token`.

The macOS cmux CLI (`repo/CLI/cmux.swift`) already exposes a full
`--socket` / `--password` global flag shape that can be reused here.

## Adding the implementation

1. Vendor [Flight-School/MessagePack](https://github.com/Flight-School/MessagePack)
   (or roll a minimal encoder — the protocol is ~15 types).
2. Fetch Ghostty's libghostty-vt XCFramework build:
   `cd ghostty && zig build -Demit-lib-vt-xcframework` — wire the
   resulting XCFramework into `Package.swift`.
3. Implement `CmxSession.attach()` using `NWConnection` over AF_UNIX,
   send `hello`, read `welcome`, then run a select-style loop over the
   incoming frame stream and a `DispatchSource` watching user input.
4. Expose `onAnsiData: (Data) -> Void` and `onPtyBytes: (UInt64, Data) -> Void`
   callbacks so the embedder (the cmux macOS app) can pipe into its own
   renderer.
