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
| 3 | admin | `ADMIN \| CLIPBOARD_READ` |

| Bit | Value | Right |
| --- | --- | --- |
| 0 | `0x01` | `READ` |
| 1 | `0x02` | `INPUT` |
| 2 | `0x04` | `RESIZE` |
| 3 | `0x08` | `TERMINATE` |
| 4 | `0x10` | `MINT_CAPABILITY` |
| 5 | `0x20` | `CLIPBOARD_READ` |

`RENDERER` is `0x07`; `ADMIN` is `0x1f`. Unknown bits, empty rights,
rights outside the selected role, and accepted clients without `READ` are
invalid. `CLIPBOARD_READ` is outside `ADMIN`: only the owner token grants it,
and only as `ADMIN | CLIPBOARD_READ`; minted capabilities never carry it. A
daemon requests it only from a host whose discovery record sets
`supports_clipboard_read:true`, at the current protocol version, and requires
the granted rights to equal its request; older hosts reject the bit.

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

A replacement host started with `--adopt-pty-fd N` (see PTY custody below)
receives `LaunchAdopt` in place of `Launch`. Its successful `Ready` carries
the adopted incarnation, not the one the bootstrap `Ready` reported.

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
`FLAG_VIEWER_SIZE_ACKS`, `FLAG_SMART_RENDERER`, `FLAG_TERMINAL_METADATA`,
`FLAG_VIEWER_SIZE_PRIORITY`, and `FLAG_PTY_CUSTODY`. The host echoes viewer-size acknowledgements only
when `RESIZE` was granted, and echoes smart mode only for renderer or admin
roles negotiating protocol v3 or newer. A v4 host echoes terminal metadata
only when the client requests it, and echoes viewer-size priority only to a
renderer granted `RESIZE`. Daemon adoption applies a two-second read and write
handshake timeout.

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
| 23 | `InputAck` | host to client | response | empty; confirms the authoritative PTY writer accepted and flushed `Input` |
| 24 | `ClipboardReadRequest` | host to owner | `CLIPBOARD_READ` | `token:u64, location:u8` (0 standard, 1 selection, 2 primary) |
| 25 | `ClipboardReadCancel` | host to owner | `CLIPBOARD_READ` | `token:u64`; the host refused that open read itself |
| 26 | `PtyCustody` | host to owner | owner token, `FLAG_PTY_CUSTODY` | `version:u16=1, child_pid:u32, session_id:u32`, PTY master attached as `SCM_RIGHTS` |
| 27 | `LaunchAdopt` | parent to host | private pipe | adopt-launch layout |
| 100 | `Input` | client to host | `INPUT` | raw PTY bytes; a nonzero request id asks a supporting host for `InputAck` |
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
| 112 | `ClipboardReadReply` | owner to host | `CLIPBOARD_READ` | `token:u64, outcome:u8` (0 refused, 1 granted), text blob |

OSC 52 clipboard reads are denied by default. While a `CLIPBOARD_READ` owner
connection is attached, the host defers each program read and sends
`ClipboardReadRequest` to the newest such connection, with request id and
sequence 0, outside both live sequences. One read per terminal is open; a
read arriving while one is open, an open read after 60 seconds, the open read
of an owner that disconnects, and every open read at terminal end are refused
with an empty clipboard. A refused reply's text is ignored; granted text over
1 MiB is refused. Replies to unknown or already answered tokens are ignored; a
reply from a connection without `CLIPBOARD_READ` closes it. Without such an
owner, reads are ignored. When the host refuses the open read itself, on the
timeout or at terminal end, it sends `ClipboardReadCancel` with that token
(request id and sequence 0) to the owner it asked, before the slot can take
another read; it sends none after a reply or to an owner that disconnected.
The owner drops its pending read for that token and ignores a cancel for any
other token. An unnegotiated or malformed cancel ends the owner connection.
When the newest owner disconnects, the next read goes to the newest remaining
one.

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
seed:optional blob
```

`argc` is from 1 through 256. `envc` is at most 1,024. The fields before
`seed` are limited to 1 MiB. `seed` is present only when bytes follow
`kitty_limits`; it is a blob of at most 8 MiB of VT replay that the host applies
to its own parser before it reads the PTY and never writes to the PTY, as for
`LaunchAdopt`. An owner sends it when it respawns a terminal whose shell was lost
with its host (cx-6so.49 L2): the new shell starts below the previous screen.
A host that predates the field rejects a seeded `Launch`; owners only seed
hosts they start from their own binary.

`LaunchAdopt` replaces `Launch` for a host started with `--adopt-pty-fd N`.
The fields before `seed` are limited to 1 MiB and `seed` is a blob of at most
8 MiB:

```text
endpoint:string
record_path:string
term:string
cols:u16
rows:u16
scrollback:u32
defaults:DefaultColors
cell_width_px:u16
cell_height_px:u16
kitty_limits:{image_bytes:u64,inflight_bytes:u64,images:u64,placements:u64}
child_pid:u32
session_id:u32
incarnation:[u8;16]
seed:blob
```

`child_pid` and `session_id` are nonzero; `incarnation` is a canonical
UUIDv4. `seed` is VT replay of the terminal's screen; the host applies it to
its own parser before it reads the PTY and never writes it to the PTY. It may
be empty. There is no command, cwd, or environment: no child is spawned. The
replay carries the title (OSC 2) and working directory (OSC 7); an owner
appends the last OSC 9;4 progress (`ESC ] 9 ; <progress> ESC \`) after it, and
the host also feeds the seed to its terminal-metadata parser, discarding any
notifications and shell marks, so its snapshots report that progress. Known gap:
the seed is applied with plain VT writes, so Kitty graphics placements and
image-number aliases from before the replacement are not restored; programs
redraw their images on the next update.

`LaunchFailed` starts with little-endian `version:u16=1, kind:u16`, followed
by 1 through 4,096 bytes of UTF-8 diagnostic text. Kind 1 means PTY capacity
is exhausted. Kind 2 covers another launch failure. Unknown versions, kinds,
empty messages, invalid UTF-8, and oversized messages are malformed.

`Exit` starts with little-endian
`version:u16=1, outcome_kind:u8, flags:u8, exited_at_ms:u64`. Exit-code
outcomes use kind 1, zero flags, and `code:i32`. Signal outcomes use kind 2,
flag bit 0 for `core_dumped`, and `signal:i32`; other flag bits are zero.
Unknown outcomes use kind 3, zero flags, and a non-empty UTF-8 reason of at
most 4,096 bytes. The reason `exit-unobserved` means a replacement host saw
its adopted session end without being able to read the status. Kinds 1 and 2 are 16-byte payloads. Unknown payloads are
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
image-id cursors. Protocol v4 keeps the v3 snapshot payload unchanged unless
`FLAG_TERMINAL_METADATA` was negotiated. A negotiated v4 snapshot then
appends `osc_progress:string`, a bounded OSC 9 progress value with at most 256
Unicode characters and no control characters. The value is captured while
the host's authoritative VT parser is at the same snapshot boundary. A client
that does not negotiate the flag receives the original v4 bytes and must
reject an unnegotiated trailing field.

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

`FLAG_TERMINAL_METADATA` is bit 4 and is valid only in protocol-v4
`ClientHello` and `HostHello`. It negotiates the optional `Snapshot` metadata
tail described above. The metadata is a generic terminal primitive. It does
not identify agents or select plugin policy.

`FLAG_VIEWER_SIZE_PRIORITY` is bit 5 and is valid only in `ClientHello` and
`HostHello`. Hosts that predate it reject a hello carrying it, so a client sets
it only when the host record advertises `supports_viewer_size_priority`.

`FLAG_PTY_CUSTODY` is bit 6 and is valid only in protocol-v4 `ClientHello` and
`HostHello`, alone. Hosts that predate it reject a hello carrying it, so the
owner sets it only when the host record advertises `supports_pty_custody`.

## PTY custody and adoption

A host normally holds the only copy of its PTY master, so the kernel hangs up
the shell when the host dies. PTY custody gives the owner a second copy. The
owner sends `ClientHello` with role admin, rights exactly
`ADMIN | CLIPBOARD_READ` (only the owner token grants `CLIPBOARD_READ`, so this
proves the owner), protocol v4 only, and `FLAG_PTY_CUSTODY` as its only flag.
The host answers `HostHello` echoing the flag, then one `PtyCustody` frame
with the same request id whose bytes carry the master descriptor as
`SCM_RIGHTS`, then closes the connection. The connection takes no snapshot,
joins no stream, and never claims the launch owner. Any other hello carrying
the flag, a host whose child already ended, or a host without a master
descriptor closes the connection with nothing sent. The owner applies a
two-second timeout and marks the received descriptor close-on-exec.

A replacement host is started as `__terminal-host --bootstrap-stdio
--adopt-pty-fd N` with the master at descriptor `N` (at least 3), receives
`Bootstrap` with the same terminal id and owner token, then `LaunchAdopt`. It
serves the same terminal id and the same incarnation, because the shell is the
same run; only the host process, process nonce, PID, and socket change. It
publishes its record at the same `<terminal UUID>.json` path, replacing the
dead host's record, and then runs like any host. The parent commits and
activates it at once, because the terminal's topology already exists.

The adopted shell is not the replacement host's child, so it cannot wait for
or reap it. The host observes the end with a pidfd on Linux or a kqueue
`NOTE_EXIT` filter on macOS (falling back to probing the PID) and reports
`Unknown { reason: "exit-unobserved" }` through the normal drain, `.exit`
sidecar, and `Exit` path. The mux classifies exactly that reason as a process
end; every other unknown reason remains a host loss. Before signaling the
session group for `Terminate`, the host proves the PID still leads the adopted
session (`getsid`, or a pidfd on Linux). The adopted child must lead its
session (`child_pid == session_id`). A replacement that fails before it
publishes its record leaves the session running for its owner.

Two hosts must never serve one incarnation. Every host holds an exclusive
`flock` on `<root>/<terminal UUID>.<incarnation UUID>.pty.lock` (mode `0600`,
`O_NOFOLLOW`) for its whole process lifetime, taken before it opens or touches
a PTY and before it publishes anything. A host that cannot take it, for
example because the old host is stopped rather than dead, returns
`LaunchFailed` and exits without a record, sidecar, `Ready`, or PTY byte. The
kernel releases the lock only when the holder process is gone. Exit sidecar
acknowledgement and stale-record removal delete the file only while holding
the lock themselves; an owner at startup and a session reset also delete every
such file whose lock is free.

The cmux-tui daemon takes custody of every connected host whose record
advertises `supports_pty_custody` (after launch, adoption, and each reconnect)
and keeps it with that connection, so it is released when the terminal ends,
is closed, or its host is replaced. When its reconnect loop proves a host dead
and there is no `.exit` sidecar for the incarnation, the daemon starts a
replacement host on its copy, if it still holds one, it is not shutting down,
the registry still names the incarnation running (neither exited nor
tombstoned), and the shell still leads its session and is not a zombie. The
seed is the daemon's replay of the terminal. On success the reconnect loop
attaches to the replacement like any reconnect; the terminal keeps its id,
incarnation, surface, and tab and records no end, and the daemon appends an
`"event":"host_replaced"` line (old and new host PID, recorded signals) to
`terminal-losses.jsonl` and removes the dead host's `.signals`. When a
published replacement is live but not yet attached, the loop attaches to it.
Otherwise the dead host is a host loss as before. A host that died while no
daemon ran has no custody holder and stays a host loss.

## Viewer-size arbitration

Every renderer granted `RESIZE` holds a viewer size, reserved at the snapshot
grid on connect and replaced by each `ViewerSize`. An admin connection holds
one only after it sends `ViewerSize`, and a connection without `RESIZE` never
holds one. The canonical grid is the per-dimension minimum over the held
sizes. When at least one connection that negotiated
`FLAG_VIEWER_SIZE_PRIORITY` holds a size, the minimum is taken over those
connections alone and every other viewer crops or pans. Priority starts with
the connect-time reservation and lasts for the connection: `ReleaseViewer`
drops only the size, which hands the grid back until the next `ViewerSize`,
and disconnecting drops both. Without priority connections the reduction is
unchanged. `ResizeAck` always carries the resulting canonical grid.

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

The mux control command `mint-terminal-renderer` returns the terminal-host endpoint, stable terminal id, incarnation, one-use capability, rights bits, TTL, and `supports_viewer_size_priority` from the host record. Renderers must not receive the daemon's durable owner capability. A mint the host does not answer fails with `error_code` `terminal_host_unavailable` and `error_details.reason` `timeout` (no answer within the 2 s control deadline) or `disconnected` (the admin connection ended first; a host refuses a bad request by closing it). The `error` text keeps the root cause after the outer context, and the client may retry. `terminal.renderer_grant.create` returns the same failure as retryable `terminal_host.unavailable` with `details.terminal_id` and `details.reason`. A mint sent right after `set-default-colors` is answered: the host applies the defaults first, and the reply reaches the daemon although the defaults update restarts its stream. `resolve-terminal`, `list-terminals`, and `terminal-events` provide the control-plane mapping from stable identities to the current daemon generation.

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
PID is nonzero. `supports_pty_custody` advertises `FLAG_PTY_CUSTODY` and adopt launches.
`supports_input_ack` is an additive boolean capability; a
missing or false value means receipted API input must fail before sending while
legacy fire-and-forget input remains available. Record directories are mode
`0700`; records and sockets are
mode `0600`.

Discovery records use JSON `record_version:4`. A host that supports the
optional snapshot tail advertises `supports_terminal_metadata:true`, and one
that accepts `FLAG_VIEWER_SIZE_PRIORITY` advertises
`supports_viewer_size_priority:true`; records from older hosts omit the fields
and default them to false; the same holds for `supports_clipboard_read` and
`supports_pty_custody`, which records before version 4 must not set. Terminal and
incarnation are 32-character lowercase UUIDv4 hex, owner token and process
nonce are 64-character lowercase hex, the Unix-socket path is canonical, and
the host PID is nonzero. Record directories are mode `0700`; records and
sockets are mode `0600`.

## Host process placement (Cloud scopes)

A daemon started with `CMUX_TUI_HOST_SCOPES=systemd` on a systemd machine
moves each terminal host it starts into its own transient scope
`cmux-terminal-host-<pid>.scope` in `cmuxhosts.slice`, before the
host receives `Launch` or `LaunchAdopt`: the daemon waits (at most 2 s)
until the host's own cgroup names the scope, so the host's child inherits the
scope and a stop or restart of the daemon's unit leaves the host running for
adoption. The move is `org.freedesktop.systemd1.Manager.StartTransientUnit`
with the host PID, run as `busctl` with a fixed argument vector (through
`sudo -n` when the daemon is not root), and only for an unreaped child of
the daemon, checked against `/proc/<pid>/stat` first. The move fails open:
when the call fails, the host keeps running unscoped in the daemon's cgroup
and the daemon logs the failure once. A scope is therefore not an isolation
or security guarantee, only a lifetime boundary. Without the variable, or
without systemd, hosts are not moved. A machine shutdown stops every scope;
the host honors that `SIGTERM` from PID 1 and ends its terminal through the
normal exit path.

## Durability boundary

The append-only journal is exact while a mux daemon owns the authenticated host
tap. A host `Snapshot` preserves renderable terminal state across daemon
replacement, and the exit sidecar preserves the final process outcome, but the
host does not currently retain an acknowledged raw-output spool. Bytes emitted
while no daemon tap exists can therefore be recovered visually from a snapshot
but cannot be reconstructed as exact historical `terminal.output` records.
After the mux applies such a reconnect snapshot, and before it accepts output
from the new live boundary, it appends a required `terminal.output.gap` record
with reason `host_reconnect` to that terminal's journal lane. This is O(1) per
reconnect. A journal retention worker then commits one checkpoint that covers
every terminal that reconnected since the last one: at most one per 30 s
interval, after a reconnect wave settles for one second, and never while
`shutdown-daemon` is ending terminals (terminals that ended are dropped from
it). A restore from an older checkpoint reports the gap as unsupported until
that checkpoint exists. Consumers must not claim byte-exact output history
across an unplanned no-tap interval until a durable host spool exists.

## Version compatibility

Protocol v1 carries the base snapshot and legacy replay stream. Protocol v2
adds Kitty image aliases and cell-pixel metrics. Protocol v3 adds Kitty replay
state, Kitty quota controls, and the smart raw-byte stream. Protocol v4 adds
the launch activation barrier and the optional negotiated terminal metadata
snapshot tail. A v4 client may negotiate v1 or v2 only in legacy mode; smart
renderers require v3 and restart their handshake on any gap or
`ResyncRequired` frame. The daemon's adoption path can still connect to legacy
host records at an older version. This document specifies the daemon-side v4
framing; renderer interoperability remains partial. Newly launched daemon
hosts enforce v4-only renderer handshakes by passing
`PROTOCOL_VERSION..=PROTOCOL_VERSION` to `CapabilityStore::accept`; the one-use
token minted by `CapabilityStore::mint` carries no protocol version. The
higher-level legacy renderer-grant response reports the selected host version,
but no grant API offers mutually supported downgrade negotiation. The current
cross-language renderer accepts only v1-v3 and pins its `ClientHello` to the
selected version. This spec therefore does not advertise renderer attach to
newly launched hosts; renderer v4 support or explicit mutually supported
version negotiation remains future work.
