# Terminal Host Protocol v4

The terminal-host protocol is the bounded local binary data plane between a durable PTY host, the mux daemon, and disposable renderers. It is separate from the JSON mux control protocol. All integer fields are little-endian.

## Frame

Every frame has a 32-byte header followed by `payload_len` bytes:

| Offset | Width | Field |
| --- | --- | --- |
| 0 | 4 | Magic bytes `CMTH` |
| 4 | 2 | Protocol version, currently `4` |
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
4. On success, the host starts the PTY, publishes its discovery record, then
   returns `Ready`. If the PTY cannot be launched, it returns `LaunchFailed`
   with the same request id and exits without publishing a discovery record.

| Payload | Exact layout |
| --- | --- |
| `Bootstrap`, 52 bytes | `min_version:u16, max_version:u16, terminal_id:[u8;16], owner_token:[u8;32]` |
| `Ready`, 34 bytes | `selected_version:u16, terminal_id:[u8;16], incarnation:[u8;16]` |
| `LaunchFailed`, 5 to 4,100 bytes | `version:u16=1, kind:u16, message:UTF-8[1..4096]` |

A zero owner token is invalid. Negotiation selects the highest common version.
`LaunchFailed.kind` is 1 for exhausted PTY capacity and 2 for another launch
failure. The message is bounded diagnostic text for the local parent.

Every Unix-socket client sends `ClientHello`; the host replies with
`HostHello`, then `Snapshot`, then a full `Colors` frame at the snapshot's
sequence boundary. A smart renderer then receives same-boundary `Ready` before
it may publish the snapshot or send input.

| Payload | Exact layout |
| --- | --- |
| `ClientHello`, 60 bytes | `min_version:u16, max_version:u16, role:u8, reserved:[u8;3]=0, requested_rights:u32, terminal_id:[u8;16], token:[u8;32]` |
| `HostHello`, 40 bytes | `selected_version:u16, reserved:u16=0, granted_rights:u32, terminal_id:[u8;16], incarnation:[u8;16]` |

`ClientHello.sequence` is zero. Its permitted flags are
`FLAG_VIEWER_SIZE_ACKS` and `FLAG_SMART_RENDERER`. The host echoes viewer-size
acknowledgements only when `RESIZE` was granted, and echoes smart mode only for
renderer or admin roles negotiating protocol v3 or newer. Daemon adoption
applies a two-second read and write handshake timeout.

For a newly launched v4 host, the first authenticated owner `HostHello` also
sets `FLAG_LAUNCH_ACTIVATION_REQUIRED`. The PTY reader remains behind a launch
barrier until that owner sends `Activate`. The launcher sends it only after the
terminal, tab, pane, screen, and workspace projection is durable. The child may
fill the bounded kernel PTY buffer while waiting, which applies backpressure
without retaining an unbounded userspace queue. A failed owner connection,
five-second launch-owner timeout, or `Terminate` releases the barrier so the
child cannot remain stranded. A replacement daemon that claims an abandoned
launch owner releases the barrier after validating existing topology.

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
| 2 | `Ready` | host to parent or client | handshake | fixed private payload or empty smart barrier |
| 3 | `ClientHello` | client to host | pre-authentication | fixed handshake |
| 4 | `HostHello` | host to client | handshake | fixed handshake |
| 5 | `Snapshot` | host to client | `READ` | snapshot layout |
| 6 | `Output` | host to client | `READ` | raw PTY bytes |
| 7 | `Resized` | host to client | `READ` | resize layout |
| 8 | `Colors` | host to client | `READ` | terminal-color layout |
| 9 | `Title` | host to client | `READ` | UTF-8 title bytes |
| 10 | `Pwd` | host to client | `READ` | UTF-8 cwd; empty means cleared |
| 11 | `Bell` | host to client | `READ` | empty |
| 12 | `Exit` | host to client | `READ` | versioned process outcome |
| 13 | `ResyncRequired` | host to client | `READ` | empty or attach-gap layout |
| 14 | `Launch` | parent to host | private pipe | launch layout |
| 15 | `Capability` | host to client | response | 32-byte token |
| 16 | `ResizeAck` | host to client | response | `cols:u16, rows:u16, result_flags:u32` |
| 17 | `ClearHistoryAck` | host to client | response | `status:u8`; a negotiated smart client receives clear-history replay bytes after a successful status |
| 18 | `CellPixelSizeAck` | host to client | response | `width_px:u16, height_px:u16` |
| 19 | `KittyGraphicsLimitsAck` | host to client | response | four little-endian `u64` limits |
| 20 | `LaunchFailed` | host to parent | private pipe | versioned launch failure |
| 21 | `TerminateAck` | host to client | response | empty; confirms the authoritative host received `Terminate` |
| 22 | `DetachAck` | host to client | response | empty; final source-ordered frame for this client |
| 100 | `Input` | client to host | `INPUT` | raw PTY bytes |
| 101 | `Paste` | client to host | `INPUT` | raw bytes; host applies DEC 2004 wrapping |
| 102 | `ViewerSize` | client to host | `RESIZE` | `cols:u16, rows:u16` |
| 103 | `ReleaseViewer` | client to host | `RESIZE` | empty |
| 104 | `Terminate` | client to host | `TERMINATE` | empty |
| 105 | `MintCapability` | client to host | `MINT_CAPABILITY` | `rights:u32, ttl_ms:u32` |
| 106 | `SetDefaults` | client to host | `MINT_CAPABILITY` | default-color layout |
| 107 | `ClearHistory` | client to host | `INPUT` | optional encoded fallback key |
| 108 | `SetCellPixelSize` | client to host | `RESIZE` | `width_px:u16, height_px:u16` |
| 109 | `SetKittyGraphicsLimits` | client to host | `MINT_CAPABILITY` | four little-endian `u64` limits |
| 110 | `Activate` | launch owner to host | `ADMIN` | empty |
| 111 | `Detach` | daemon owner to host | `ADMIN` | empty |

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
cell_width_px:u16
cell_height_px:u16
kitty_limits:{image_bytes:u64,inflight_bytes:u64,images:u64,placements:u64}
```

`argc` is from 1 through 256. `envc` is at most 1,024.

`LaunchFailed` starts with little-endian `version:u16=1, kind:u16`, followed
by 1 through 4,096 bytes of UTF-8 diagnostic text. Kind 1 means PTY capacity
is exhausted. Kind 2 covers another launch failure. Unknown versions, kinds,
empty messages, invalid UTF-8, and oversized messages are malformed.

`Exit` starts with little-endian
`version:u16=1, outcome_kind:u8, flags:u8, exited_at_ms:u64`. Exit-code
outcomes use kind 1, zero flags, and `code:i32`. Signal outcomes use kind 2,
flag bit 0 for `core_dumped`, and `signal:i32`; other flag bits are zero.
Unknown outcomes use kind 3, zero flags, and a non-empty UTF-8 reason of at
most 4,096 bytes. Kinds 1 and 2 are 16-byte payloads. Unknown payloads are
12 through 4,108 bytes.

`Snapshot`:

```text
cols:u16
rows:u16
pid:u32
replay:blob
cwd:optional_string
argc:u16
argv[argc]:string
kitty_alias_count:u16
kitty_aliases[kitty_alias_count]:{image_id:u32,image_number:u32}
cell_width_px:u16
cell_height_px:u16
kitty_replay_state:KittyReplayState
```

PID zero means absent. Snapshot `argc` may be zero. Protocol v2 appends a
Kitty image-alias table and cell pixel width and height. Protocol v3 appends
Kitty graphics limits, the replay cursor offset, and the primary and alternate
image-id cursors. Protocol v4 keeps the v3 snapshot payload unchanged.

Legacy `Resized` producer payload:

```text
cols:u16
rows:u16
replay_len:u32
replay:[u8;replay_len]
kitty_alias_count:u16
kitty_aliases[kitty_alias_count]:{image_id:u32,image_number:u32}
cell_width_px:u16
cell_height_px:u16
kitty_replay_state:KittyReplayState
```

Protocol v2 and later append the same Kitty image-alias table and cell pixel
size used by `Snapshot`. Protocol v3 and later then append the Kitty replay
state. Decoders select the exact tail from the negotiated frame version and
reject trailing bytes.

A smart renderer instead receives an unflagged four-byte
`cols:u16,rows:u16` payload, or an eight-byte payload that appends
`cell_width_px:u16,cell_height_px:u16`. Smart `Output` is the unmodified PTY
byte stream. Smart live frames never use a following `Colors` pair.

`KittyReplayState` is four `u64` limits followed by
`replay_cursor_offset:u32`, then replay and live next-image ids for the primary
screen, followed by the same pair for the alternate screen. Alias counts are
limited to 4,096 and image ids and numbers are nonzero.

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

`Colors` has an independent schema version. The current frame protocol emits Colors
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

`FLAG_COLORS_FOLLOW` is bit 0. A legacy live `Output` that changes authored
color or cursor semantics and every legacy `Resized` frame set it. The
immediately following sequence must be `Colors`. Producers enqueue the pair
atomically and consumers stage both before publishing state. Smart `Output`
and `Resized` frames carry raw source transitions with flags zero. The flag is
invalid on other messages.

`FLAG_VIEWER_SIZE_ACKS` is bit 1 and is valid only in `ClientHello` and `HostHello`. When negotiated, a `ViewerSize` request receives `ResizeAck`. Resize acknowledgement flag bit 0 means the request changed the canonical grid and the corresponding sequenced `Resized` plus `Colors` transition was enqueued first.

`FLAG_SMART_RENDERER` is bit 2 and is valid only in `ClientHello` and
`HostHello`. A smart stream snapshots at the authoritative parser-applied
source cursor, replays retained raw PTY frames after that cursor, then tees
future PTY bytes to each client independently. Each client owns its viewer
size and local scroll viewport.

`FLAG_LAUNCH_ACTIVATION_REQUIRED` is bit 3 and is valid only in a protocol-v4
`HostHello` sent to the first authenticated launch owner. `Activate` has zero
flags, request id zero, sequence zero, and an empty payload.

## Ordering and recovery

A renderer applies every live sequence exactly once. A gap, duplicate, flagged frame without the required next `Colors`, or invalid flag is fatal. The renderer disconnects and obtains a new `Snapshot`; continuing from a damaged sequence would corrupt its mirror.

The launch barrier orders the first exact `Output` after the durable topology
projection. The mux's terminal-output path remains asynchronous and bounded.
Before a daemon shutdown closes a persistent-host socket, `Detach` removes that
client from future publication under the host source-order lock and queues
`DetachAck` after all prior live frames. The daemon drains and journals those
frames through the receipt before it closes the socket.
When `Exit` arrives, the mux fences that ingress queue before committing exit
and detaching topology, so every preceding output record retains the terminal,
tab, pane, screen, and workspace subjects.

`ResyncRequired` is also terminal for the current mirror. The host publishes
an empty payload for an ordered live reset. When an attach cannot join the
retained stream, the payload is `requested_after:u64, retained_after:u64,
reason:u8`; reason `0` is a retention gap and reason `1` is subscriber queue
overflow. All fields are little-endian and clients must reconnect for either
reason.

The host publishes
`Exit` only after the final `Output`. It uses the normal live sequence,
`request_id:0`, and frame flags zero. `Exit` ends live process output but does
not by itself tombstone the durable terminal registry entry. The host writes
the exact outcome and host generation to an internal `.exit` sidecar before
publishing `Exit`. The mux removes that sidecar only after committing the
matching outcome to SQLite. A failed commit leaves the sidecar for restart
reconciliation, and reconnecting waiters observe the SQLite result.

The exit sidecar is `<root>/<terminal UUID>.exit`, beside the live
`<terminal UUID>.json` record. It is strict JSON:

```json
{
  "record_version": 1,
  "terminal_id": "32-character canonical UUIDv4 hex",
  "incarnation": "32-character canonical UUIDv4 hex",
  "exit": {
    "outcome": {"kind": "exit", "code": 0},
    "exited_at_ms": 0
  }
}
```

`outcome` uses the same exit, signal, or unknown union as the `Exit` frame.
After PTY drain, the host creates a mode-`0600`
`<terminal UUID>.tmp-<pid>-<counter>` with `create_new`, writes and fsyncs the
JSON, atomically renames it to `.exit`, then fsyncs the parent directory. An
existing equal record is accepted; an unequal record is retained and fails
the write. Removal rereads the canonical filename, owner, mode, link count,
and full record. The mux removes and parent-fsyncs only an exact
terminal, host-generation, and outcome match already committed to SQLite.
Missing means already acknowledged; any mismatch remains for recovery.

## Discovery and authority

The mux control command `mint-terminal-renderer` returns the terminal-host endpoint, stable terminal id, incarnation, one-use capability, rights bits, and TTL. Renderers must not receive the daemon's durable owner capability. `resolve-terminal`, `list-terminals`, and `terminal-events` provide the control-plane mapping from stable identities to the current daemon generation.

Terminal-host protocol changes use their own version and do not change `identify.protocol`.

## Limits and failure behavior

- Frame payload: 16 MiB.
- VT replay or blob: 8 MiB.
- Launch payload: 1 MiB.
- String: 256 KiB.
- Per-client outbound queue: 256 legacy frames or 4,096 smart frames; raw PTY
  output is capped at 8 MiB, with bounded headroom for one maximum state
  transition.
- Smart replay retention: 4,096 frames and 8 MiB including headers.
- Renderer grant TTL: 60 seconds maximum.

`LaunchFailed` is the only typed failure frame and is valid only as the
private-pipe response to `Launch`. Invalid magic, zero or unsupported version,
unknown kind, oversized or truncated payload, malformed handshake, denied
rights, malformed control payload, unknown flags, invalid sequence, or queue
overflow closes or rejects the connection. A client reconnects, authenticates
again, and consumes a fresh `Snapshot` plus same-boundary `Colors`.

Discovery records use JSON `record_version:4`. Terminal and incarnation are
32-character lowercase UUIDv4 hex, owner token and process nonce are
64-character lowercase hex, the Unix-socket path is canonical, and the host
PID is nonzero. Record directories are mode `0700`; records and sockets are
mode `0600`.

## Durability boundary

The append-only journal is exact while a mux daemon owns the authenticated host
tap. A host `Snapshot` preserves renderable terminal state across daemon
replacement, and the exit sidecar preserves the final process outcome, but the
host does not currently retain an acknowledged raw-output spool. Bytes emitted
while no daemon tap exists can therefore be recovered visually from a snapshot
but cannot be reconstructed as exact historical `terminal.output` records. The
mux commits a replacement checkpoint after it applies such a reconnect snapshot
and before it accepts the new live boundary. Restoration starts from that
durable terminal state, but consumers must not claim byte-exact output history
across an unplanned no-tap interval until a durable host spool exists.

## Version compatibility

Protocol v1 carries the base snapshot and legacy replay stream. Protocol v2
adds Kitty image aliases and cell-pixel metrics. Protocol v3 adds Kitty replay
state, Kitty quota controls, and the smart raw-byte stream. Protocol v4 adds
the launch activation barrier. A v4 client may negotiate v1 or v2 only in
legacy mode; smart renderers require v3 and restart their handshake on any gap
or `ResyncRequired` frame.
