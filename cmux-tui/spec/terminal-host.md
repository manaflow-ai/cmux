# Terminal Host Protocol v1

The terminal-host protocol is the bounded local binary data plane between a durable PTY host, the mux daemon, and disposable renderers. It is separate from the JSON mux control protocol. All integer fields are little-endian.

## Frame

Every frame has a 32-byte header followed by `payload_len` bytes:

| Offset | Width | Field |
| --- | --- | --- |
| 0 | 4 | Magic bytes `CMTH` |
| 4 | 2 | Protocol version, currently `1` |
| 6 | 2 | Message kind |
| 8 | 4 | Flags |
| 12 | 4 | Payload length |
| 16 | 8 | Request id |
| 24 | 8 | Stream sequence |

Payloads are limited to 16 MiB. Clean EOF before a header ends the stream. EOF inside a header or payload is a truncation error. Bad magic, version zero, an unknown kind, or an oversized payload poisons the decoder.

## Roles and rights

| Value | Role | Maximum rights |
| --- | --- | --- |
| 1 | daemon mirror | `READ` |
| 2 | renderer | `RENDERER` |
| 3 | admin | `ADMIN` |

| Bit | Value | Right |
| --- | --- | --- |
| 0 | `0x01` | `READ` |
| 1 | `0x02` | `INPUT` |
| 2 | `0x04` | `RESIZE` |
| 3 | `0x08` | `TERMINATE` |
| 4 | `0x10` | `MINT_CAPABILITY` |

`RENDERER` is `0x07`; `ADMIN` is `0x1f`. Unknown bits, empty rights,
rights outside the selected role, and accepted clients without `READ` are
invalid.

The durable 32-byte owner token is reusable, terminal-bound, and valid only
for the admin role. Minted tokens are 32 random bytes, terminal-bound,
expiring, and one-use. A matching token is consumed before terminal, role, or
rights checks, so a failed authorization cannot retry it. Each host retains at
most 64 unexpired minted grants.

## Handshakes

The private bootstrap pipe uses:

1. Parent sends `Bootstrap`.
2. Host returns `Ready`, echoing the request id and creating the incarnation.
3. Parent sends `Launch`.
4. Host starts the PTY, publishes its discovery record, then returns `Ready`.

| Payload | Exact layout |
| --- | --- |
| `Bootstrap`, 52 bytes | `min_version:u16, max_version:u16, terminal_id:[u8;16], owner_token:[u8;32]` |
| `Ready`, 34 bytes | `selected_version:u16, terminal_id:[u8;16], incarnation:[u8;16]` |

A zero owner token is invalid. Negotiation selects the highest common version.

Every Unix-socket client sends `ClientHello`; the host replies with
`HostHello`, then `Snapshot`, then a full `Colors` frame at the snapshot's
sequence boundary.

| Payload | Exact layout |
| --- | --- |
| `ClientHello`, 60 bytes | `min_version:u16, max_version:u16, role:u8, reserved:[u8;3]=0, requested_rights:u32, terminal_id:[u8;16], token:[u8;32]` |
| `HostHello`, 40 bytes | `selected_version:u16, reserved:u16=0, granted_rights:u32, terminal_id:[u8;16], incarnation:[u8;16]` |

`ClientHello.sequence` is zero. Its only permitted flag is
`FLAG_VIEWER_SIZE_ACKS`. The host echoes that flag only when requested and
`RESIZE` was granted. Daemon adoption applies a two-second read and write
handshake timeout.

## Payload primitives

```text
string          = length:u32 + UTF-8 bytes, maximum 256 KiB
blob            = length:u32 + bytes, maximum 8 MiB
optional_string = tag:u8; 0 absent, 1 followed by string
rgb             = r:u8 + g:u8 + b:u8
```

Trailing bytes, invalid UTF-8, invalid optional tags, and duplicate palette
indexes are fatal.

## Message kinds

| Value | Name | Direction | Required right | Payload |
| --- | --- | --- | --- | --- |
| 1 | `Bootstrap` | parent to host | private pipe | fixed handshake |
| 2 | `Ready` | host to parent | private pipe | fixed handshake |
| 3 | `ClientHello` | client to host | pre-authentication | fixed handshake |
| 4 | `HostHello` | host to client | handshake | fixed handshake |
| 5 | `Snapshot` | host to client | `READ` | snapshot layout |
| 6 | `Output` | host to client | `READ` | raw PTY bytes |
| 7 | `Resized` | host to client | `READ` | resize layout |
| 8 | `Colors` | host to client | `READ` | terminal-color layout |
| 9 | `Title` | host to client | `READ` | UTF-8 title bytes |
| 10 | `Pwd` | host to client | `READ` | UTF-8 cwd; empty means cleared |
| 11 | `Bell` | host to client | `READ` | empty |
| 12 | `Exit` | host to client | `READ` | empty; v1 has no exit status |
| 13 | `ResyncRequired` | host to client | `READ` | empty |
| 14 | `Launch` | parent to host | private pipe | launch layout |
| 15 | `Capability` | host to client | response | 32-byte token |
| 16 | `ResizeAck` | host to client | response | `cols:u16, rows:u16, result_flags:u32` |
| 100 | `Input` | client to host | `INPUT` | raw PTY bytes |
| 101 | `Paste` | client to host | `INPUT` | raw bytes; host applies DEC 2004 wrapping |
| 102 | `ViewerSize` | client to host | `RESIZE` | `cols:u16, rows:u16` |
| 103 | `ReleaseViewer` | client to host | `RESIZE` | empty |
| 104 | `Terminate` | client to host | `TERMINATE` | empty |
| 105 | `MintCapability` | client to host | `MINT_CAPABILITY` | `rights:u32, ttl_ms:u32` |
| 106 | `SetDefaults` | client to host | `MINT_CAPABILITY` | default-color layout |

`ResizeAck.result_flags & 1` means the request changed canonical geometry;
other bits are invalid. Acknowledgements require negotiated
`FLAG_VIEWER_SIZE_ACKS` and a nonzero request id. Without acknowledgements,
`ViewerSize` uses the broadcast `Resized` plus `Colors` path.

## Variable payloads

`Launch` is limited to 1 MiB:

```text
endpoint:string
record_path:string
term:string
cols:u16
rows:u16
scrollback:u32
cwd:optional_string
argc:u16
argv[argc]:string
envc:u16
env[envc]:{key:string,value:string}
defaults:DefaultColors
```

`argc` is from 1 through 256. `envc` is at most 1,024.

`Snapshot`:

```text
cols:u16
rows:u16
pid:u32
replay:blob
cwd:optional_string
argc:u16
argv[argc]:string
```

PID zero means absent. Snapshot `argc` may be zero.

`Resized` producer payload:

```text
cols:u16
rows:u16
replay_len:u32
replay:[u8;replay_len]
```

Geometry clamps to `1..=10,000` per dimension and rejects an area above
4,000,000 cells.

`DefaultColors`:

```text
flags:u8
[fg:rgb] [bg:rgb] [cursor:rgb] [selection_bg:rgb] [selection_fg:rgb]
[cursor_style:u8]
[cursor_blink:u8]
palette_count:u16
palette[palette_count]:{index:u8,color:rgb}
```

Flag bits 0 through 6 are foreground, background, cursor, cursor style, cursor
blink, selection background, and selection foreground. Bit 7 is invalid. RGB
fields appear in the order shown. Cursor styles are block `1`, block-hollow
`2`, bar `3`, and underline `4`; blink is `0` or `1`.

`Colors` has an independent schema version. Frame protocol v1 emits Colors
schema v2 and accepts v1:

```text
schema_version:u16
flags:u16
palette_count:u16
reserved:u16=0
[fg:rgb] [bg:rgb] [cursor:rgb]
[cursor_style:u8,cursor_blink:u8]
palette[palette_count]:{index:u8,color:rgb}
```

Flags are foreground `0x1`, background `0x2`, cursor `0x4`, and cursor visual
`0x8`. Schema v1 permits only `0x1..0x7`; schema v2 requires `0x8`. V2 cursor
styles are block `1`, underline `2`, and bar `3`. Maximum Colors payload is
1,043 bytes.

`MintCapability` accepts a rights mask containing `READ` and contained within
`RENDERER`: `0x01`, `0x03`, `0x05`, or `0x07`. TTL is from 1 through 60,000
milliseconds. The runtime renderer helper requests `0x07`; responses time out
after two seconds.

`request_id` is nonzero for request/response control messages and their sequence is zero. Live host-to-client state uses `request_id:0` and a contiguous sequence. Snapshot and its immediately following full-state `Colors` frame use the same boundary and consume no sequence numbers.

## Atomic color transitions

`FLAG_COLORS_FOLLOW` is bit 0. A live `Output` that changes authored color or cursor semantics and every `Resized` frame set it. The immediately following sequence must be `Colors`. Producers enqueue the pair atomically and consumers stage both before publishing state. The flag is invalid on other messages.

`FLAG_VIEWER_SIZE_ACKS` is bit 1 and is valid only in `ClientHello` and `HostHello`. When negotiated, a `ViewerSize` request receives `ResizeAck`. Resize acknowledgement flag bit 0 means the request changed the canonical grid and the corresponding sequenced `Resized` plus `Colors` transition was enqueued first.

## Ordering and recovery

A renderer applies every live sequence exactly once. A gap, duplicate, flagged frame without the required next `Colors`, or invalid flag is fatal. The renderer disconnects and obtains a new `Snapshot`; continuing from a damaged sequence would corrupt its mirror.

`ResyncRequired` is also terminal for the current mirror. `Exit` ends live process output but does not by itself tombstone the durable terminal registry entry.

## Discovery and authority

The mux control command `mint-terminal-renderer` returns the terminal-host endpoint, stable terminal id, incarnation, one-use capability, rights bits, and TTL. Renderers must not receive the daemon's durable owner capability. `resolve-terminal`, `list-terminals`, and `terminal-events` provide the control-plane mapping from stable identities to the current daemon generation.

Terminal-host protocol changes use their own version and do not change `identify.protocol`.

## Limits and failure behavior

- Frame payload: 16 MiB.
- VT replay or blob: 8 MiB.
- Launch payload: 1 MiB.
- String: 256 KiB.
- Per-client outbound queue: 256 frames and 8 MiB including headers.
- Renderer grant TTL: 60 seconds maximum.

There is no wire error frame. Invalid magic, zero or unsupported version,
unknown kind, oversized or truncated payload, malformed handshake, denied
rights, malformed control payload, unknown flags, invalid sequence, or queue
overflow closes or rejects the connection. A client reconnects, authenticates
again, and consumes a fresh `Snapshot` plus same-boundary `Colors`.

Discovery records use JSON `record_version:2`. Terminal and incarnation are
32-character lowercase UUIDv4 hex, owner token and process nonce are
64-character lowercase hex, the Unix-socket path is canonical, and the host
PID is nonzero. Record directories are mode `0700`; records and sockets are
mode `0600`.

## Known v1 constraints

The current host process does not expose the child's full `ExitStatus` through the public control protocol. Portable execution completion requires the vNext process outcome contract in [`programmability.md`](programmability.md#required-vnext-primitives).

The current producer encodes `Resized` with `replay_len`, but the consumer in
`surface.rs` treats bytes after the first four as replay and includes that
length word. This makes terminal-host v1 partial rather than interoperable for
resize replay. The decoder must consume `replay_len`, validate the remaining
length, and pass only replay bytes to the VT state. Producer-consumer and
cross-language fixtures must pass before the domain is promoted to
`implemented`.
