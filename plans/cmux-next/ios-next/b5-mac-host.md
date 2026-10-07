# B5 `mac-host`: the Mac side of `cmux.mobile/1`

Status: lane B5 of [PLAN.md](PLAN.md), 2026-10-06, branch `feat-cmux-next-ios-b5-mac-host`.
Wire: [a0-rpc.md](a0-rpc.md). Link: [a3-link.md](a3-link.md) (section 10, `LinkAcceptor`, `LinkHost`).
Control plane: B1 `b1-control-do.md`, merged into this branch from `feat-cmux-next-ios-b1-control-do`
(the uplink rides its `CmuxControlPlane` transport). Binding: OWNERSHIP-PRINCIPLES.md, architecture.md 5a, ghostty-next.md 2,
skills/cmux-socket-policy (relay authorization).

Code: `Packages/Shared/CmuxMobileHost` (module `CmuxMobileHost`, Swift 6, macOS 14, no AppKit, no
CmuxNext dependency). Depends on `CmuxLink`, `CmuxMobileWire`, `CmuxTerminalStream`, `CmuxControlPlane`.
`MobileHost` is single use: `stop()` is final, the app makes a new one per sign-in.

## 1. Where the host lives

Decision: a Swift gateway, `MobileHost`, embedded in the cmux-next app process, that owns no entity.

| Fact the phone sees | Owner (single writer) | What `MobileHost` holds |
| --- | --- | --- |
| Terminal bytes, GHOSTSNP snapshots, grid, input order, presence, kick | cmux-tui session host | nothing beyond a bounded per-viewer send buffer (dropped on overflow, ghostty-next.md 2) |
| Workspaces, panes, tabs, status, unread | daemon workspace store | the last projected state per stream, to diff and to answer `subscribe`; never written by a client |
| Browser page and video | the Mac app's Chromium runtime (each Mac renders its own) | nothing; the browser channel is served in the same process by C2 |
| Remote desktop | `cmux-rd-host` | nothing; C3 bridges the channel |
| Paired devices, revocation | `UserDO` trust store (B6), mirrored to the Mac | a read-only mirror behind `MobileTrustStore` |
| Link sessions, channels, credit | `CmuxLink` (`LinkHost`) | connection-scoped state only |

Why the app process and not the daemon:

- The gateway is a client of the session host, like the Mac's own terminal views: it attaches with
  the same `attach-surface` snapshot attach and forwards frames unchanged. Ownership stays where it
  is; the gateway is a projection plus an op forwarder, so placing it is a deployment question.
- `CmuxLink` and its `LinkHost` exist only in Swift today (A3). The Rust codec and `LinkHost` role
  (a3-link.md 10) would be a second implementation of the session machine with no consumer yet.
- C2 (browser) must terminate in the app: Chromium runs there. Terminating the link in the daemon
  would force a second hop daemon to app for every browser frame.
- The B2 WebRTC carrier is Swift (libwebrtc), so its `LinkAcceptor` lives in the app anyway.

Cost: phones reach a Mac only while cmux-next runs. Headless hosts (Mac minis without the app,
Cloud VMs for C12) need the Rust side: a `cmux-link-session` crate replaying the `LinkFrame` golden
vectors and serving the same channel kinds from the daemon. The seams below (`MobileDaemon`,
`MobileChannelHandler`) are the contract that implementation must match; it is phase 2, not this
lane. The existing irx compat host (`CmuxNextMobile/MobileIrxHost`) keeps serving the shipping
phone until D3 switches it off; `MobileHost` does not share its socket or its admission.

## 2. `cmux.mobile/1` over `CmuxLink` (the binding)

A0 framed records for a raw carrier (channel 0 handshake, credit records, odd/even ids). `CmuxLink`
already owns channel ids, revisions, credit, close and resume, so B5 binds A0 onto it:

- One A0 channel = one `LinkChannel`. Every link message is exactly one A0 `StreamRecord`
  (`u32 channel | u64 seq | u8 flags | payload`) with the A0 channel id and a per-direction seq from
  1. The header stays so payloads are carrier-independent and the A0 fixtures apply unchanged.
- Credit records (`0x04`) are refused on a link channel (`proto.bad_record`): link acks on
  consumption are the credit. `channel.open.window` sets the host's send budget for that channel
  (clamped to 4 KiB..4 MiB).
- A0 channel 0 is the first link channel the phone opens, stream `cmux.mobile/session`, reliable,
  `control` priority. It carries `hello`, `hello.ok`, `error` only.
- Every other channel: the opener's first record is `channel.open` (JSON), the host's first record
  is `channel.opened` or `channel.refused` (then the host closes the link channel). Ids: phone odd,
  host even, unique per session; a reused id or wrong parity is refused (pane-protocol decision 3).
  A channel opened before `hello.ok` is refused `auth.unauthenticated`.
- `channel.close`/`channel.closed` map to `LinkChannel.close()`; a host-initiated close with a
  reason (kick, exit, revoke) first sends `channel.closed {code}` as the last record.
- Link stream names (informational): `rpc`, `terminal/<term_id>`, `browser/<tab_id>`, `rd/<display>`,
  `files.upload/<name>`, `files.download`.

## 3. Device authorization

Default deny. A session is served only after `hello` proves a paired, unrevoked device of the
account this Mac is signed into.

- `hello` carries `auth {install, key_id, issued_at, sig}` (cap `device-proof`; unknown members are
  ignored by A0 decoders, so older peers are unaffected). `sig` is an ECDSA P-256 signature
  (raw r||s, base64url) by the device's paired key over
  `cmux.mobile/1 hello\n<host id>\n<link session id>\n<install>\n<issued_at ms>`. iOS keeps the key in
  the Secure Enclave (P-256 is what it signs).
- `TrustStoreAuthorizer` accepts only when: the install is in `MobileTrustStore`, not revoked, its
  `user` equals the Mac's account user (team members are not enough for terminal access until B6
  says so), `key_id` matches, the signature verifies, `issued_at` is within 120 s of the Mac clock,
  and `(install, link session id)` was not seen before (replay cache). The session id binds the proof
  to one link session, so a captured hello cannot open another.
- Carriers that authenticate the peer themselves (B4 pins device keys, B2's signaling `from`) may
  also pass a `CarrierAttestation`; when present it must name the same install, else deny. Gap:
  `LinkHost` hides the transport from the session, so `MobileHost` cannot obtain one yet; B2/B4 need
  a peer-identity hook on `LinkSession` (CmuxLink change) to feed it.
- Revocation: `MobileTrustStore.revocations()` (the store marks the device revoked before it
  yields) reaches every session of that install, including one still in admission (matched by the
  hello's claimed install; the hello path then answers `auth.forbidden`). The session's
  `MobileSessionGate` closes first, so no op runs and no input reaches a terminal after that point;
  each channel gets `channel.closed {code: auth.revoked}` within a 500 ms grace on the injected
  clock, then the link session closes whether or not the peer read them. Ops also re-check the trust
  store per op. Sign-out or account switch stops the host (`MobileHost.stop()`).
- Failures answer `error {code: auth.unauthenticated | auth.forbidden}` on channel 0 and close the
  link session; nothing else is served.

Relay authorization (skills/cmux-socket-policy): the phone is treated like a relay client.

- Default deny on ops: `MobileOpPolicy` allowlists `workspace.rename`, `workspace.tab.close`, and
  (C5) `workspace.close` and `workspace.read` (`MobileDaemonOp.closeWorkspace` / `.markWorkspaceRead`,
  same id scoping, caps `workspace.close`, `workspace.read`; `workspace.preview` for preview lines,
  which `WorkspaceStreamOwner` sanitizes with `MobilePreview` and sends at most once per second per
  tab with one trailing flush on the injected clock)
  (user-owned objects, ids scoped to this host's current tree, unknown or ref-form ids refused with
  `workspace.not_found` / `workspace.tab_not_found`). Every op rejects params outside its schema,
  and command-bearing params (`command`, `initial_command`, `argv`, `env`, `cwd`, `shell`,
  `tmux_start_command`, `pane_start_command`) are refused on every op with `auth.forbidden`.
- Terminal-spawning ops (`workspace.create`, `workspace.tab.create`) are refused
  `auth.forbidden` (`details.reason: spawn_unverified`) until a live verification on a tagged build
  shows the new terminal runs on this Mac's session host as the user's login shell with no phone
  input in its argv, cwd or env. `MobileHostConfiguration.allowsTerminalSpawn` (default false) is
  the one switch; the daemon half must take no argv/cwd/env from the phone (the irx compat lane's
  `DaemonLanePolicy.creationFields` rule).
- Terminal input is the purpose of a terminal channel: allowed only for an authorized device, only
  to a `term_…` id that resolves in this host's tree when the channel opens, and only as
  `TerminalInput` records (keys, mouse, paste). No channel param carries a command.
- `task.*` ops and `files.*` are not served until their lanes (C8, C4) add their policy.

## 4. Service map

| `cmux.mobile/1` | Served by | Daemon capability |
| --- | --- | --- |
| session `hello` / `hello.ok` | `MobileSessionServer` | none (caps: `device-proof`, `read`, `resume`) |
| `rpc` channel: `subscribe` / `snapshot.request` / `unsubscribe` `workspace:<host>` | `WorkspaceStreamOwner` | tree snapshot + tree change events (`subscribe`, `export-layout`; app: `DaemonConnection.snapshot()` / `events`) |
| `rpc` `op workspace.rename` | `MobileRpcService` -> `MobileDaemon.perform` | `rename-workspace` |
| `rpc` `op workspace.tab.close` | same | `close-surface` / `close-terminal` |
| `rpc` `op workspace.create`, `workspace.tab.create` | refused (spawn_unverified) | `create-workspace`, `create-terminal` (no argv/cwd/env) |
| `rpc` `read files.list` | `MobileReadHandler` seam (C4) | none yet |
| `rpc` `op task.*`, `read task.list` | refused `proto.unsupported` until C8 | task runner |
| `terminal` channel | `TerminalChannelBridge` -> `MobileDaemon.attachTerminal` | `attach-surface` snapshot attach (`terminal-snapshot-v1`, `terminal-snapshot-history-v1`), `send`, `resize-attached-view`, `set-client-sizing`, snapshot request |
| `terminal.input` record | `MobileTerminalAttachment.write` | `send` (attributed to the device) |
| `terminal.viewport`, `terminal.presence` | `MobileTerminalAttachment.viewport/presence` | `resize-attached-view`, `set-client-sizing` (smallest viewer wins) |
| `terminal.snapshot_request` | `requestSnapshot` | attach snapshot request (`reason`, `have`) |
| `terminal.size`, `terminal.title`, `terminal.exited`, `terminal.kicked` | daemon events forwarded as JSON records | attach `resized`/size, title, exit, kick |
| `terminal.history`, `terminal.read_range`, `terminal.kick` | `MobileTerminalAttachment` (optional; default refused `proto.unsupported`) | `read-scrollback` / history pages, kick |
| `browser` channel | `MobileChannelHandler` for `.browser` (C2) | Mac browser host (`CmuxNextBrowserHost`) |
| `rd` channel | handler for `.rd` (C3) | `cmux-rd-host` |
| `files.upload` / `files.download` | handlers (C4) | none yet |
| control: `host.presence.set`, `host.caps.set`, workspace snapshot/events, forwarded `op workspace.*` | `HostControlUplink` over B1's host socket | same as the rows above |

Terminal flow (ghostty-next.md 2): the bridge reads daemon frames into a buffer bounded by the
channel window (default 262144). The link send suspends while the phone has not consumed; when the
buffer would exceed the window, the bridge drops every buffered frame, asks the daemon for a snapshot
(`reason: gap`), and skips frames until the next `snapshot_ready`, which goes out with the
`keyframe` flag. A slow phone costs one snapshot, never a disconnect or an unbounded buffer.

## 5. Registration with `HostDO` (B1)

`HostControlUplink` speaks B1's host role on `/v1/wire/host/<host>` through a `HostControlSocket`
seam (the app supplies a WebSocket with subprotocols `cmux.wire.v1, bearer.<install token>`):

1. `hello` (caps `read`, `signal`, `presence`, `resume`), wait for `hello.ok`.
2. `op host.caps.set {caps, versions}` and `op host.presence.set {state: online}` with fresh keys.
3. `snapshot.request {stream: workspace:<host>}` from `HostDO` -> `snapshot {stream, seq, state,
   decided: []}`; afterwards every projected change goes up as `event` in seq order. A
   `snapshot.request` after a gap gets a fresh snapshot.
4. Forwarded `op workspace.*` arrives with `from` (device install) and `actor`; it runs through the
   same `MobileOpPolicy` and ledger (keyed `(from, idempotency_key)`) as the link `rpc` channel and
   is answered `result`/`reject` + `request-settled` with `to: from`. A device using both paths
   dedupes on the same key.
5. `signal` frames addressed to the host are handed to the `SignalingSink` seam (B2).

Seq and epoch: the workspace stream's seq starts at the host process's start time in milliseconds
and grows by one per event, so a restarted host never reuses a seq a mirror holds. Every snapshot and
event also carries a top-level `epoch` member (`ep_<start>_<random>`, one per stream instance; A0
decoders ignore unknown members), as B1 section 11 asks: a `subscribe` with `after_seq` and another
`epoch` gets a snapshot, and `HostDO` can do the same for device cursors. A0 should add `epoch` to
`snapshot`, `event` and `subscribe` in the catalog and schemas.

A `snapshot.request` with `to` (a device's pending keys) is answered with a snapshot to that device
only, carrying its decided keys from the ledger; the broadcast forwarder is untouched. Forwarded ops
run per device in order, devices concurrently; a malformed forwarded op is still settled
(`validation.invalid` + `request-settled`) so `HostDO`'s forward does not wait for its TTL. The
production socket is `ControlPlaneHostSocket` over B1's `ControlPlaneConnection`
(`URLSessionControlPlaneTransport`); `ControlPlaneClient` itself is the device role and is not used
for the host role.

The uplink depends only on frames listed in b1-control-do.md sections 2 and 3 (`to`/`from` members
on top of A0 frames, handled as raw JSON members).

## 6. Seams for later lanes

| Lane | Seam in `CmuxMobileHost` | Default |
| --- | --- | --- |
| C1 terminal-rpc | `MobileTerminalAttachment` (history, read_range, kick are optional methods); `TerminalChannelBridge` | snapshot attach + bytes + input + viewport + presence + snapshot request |
| C2 browser | `MobileChannelHandler` registered for `.browser`; gets the opened `MobileChannel` and the principal | refused `channel.unknown_kind` |
| C3 rd | handler for `.rd` | refused |
| C4 files | handlers for `.filesUpload`, `.filesDownload`; `MobileReadHandler` for `files.list` | refused |
| C8 task | `MobileOpPolicy` entries + `MobileDaemon.perform` cases | refused |
| B2 webrtc | `LinkAcceptor` passed to `MobileHost`, optional `CarrierAttestation`, `SignalingSink` | loopback in tests |
| B6 pairing | `MobileTrustStore` (device keys, revocations) | `StaticTrustStore` (tests, DEV) |
| App wiring | `MobileDaemon` over `DaemonConnection` + `TerminalAttachment` (map `TerminalChannelEvent.snapshot` to `TerminalFrame` `snapshotReady/snapshotHistory`, `.output` to `bytes` with the running offset, `.resized` to `terminal.size`) | fake daemon in tests |

## 7. Tests

45 Swift Testing tests in `Packages/Shared/CmuxMobileHost/Tests`, over `CmuxLinkTesting` loopback carriers
with a fake daemon and a fake control socket: device proof (accept, unknown, revoked, other account,
bad signature, stale, replay, attestation mismatch, revocation kicks live sessions), session rules
(channel before hello, parity, reused id, unknown kind, handler seam), rpc (snapshot, event on
change, `after_seq` replay, gap snapshot, rename result + settled, idempotent replay, spawn refused,
command params refused, unknown id refused), terminal (opened params, keyframe snapshot, bytes,
input and viewport forwarded, not found, overflow drops backlog and requests one snapshot), uplink
(hello, caps, presence, snapshot on request, events, forwarded op answered with `to`), and review
regressions (revoking a peer that stopped reading, revocation during admission, contiguous seqs under
credit pressure, `channel.close` while backpressured, a change during the first load, epoch mismatch,
scoped pending-key snapshot, malformed forwarded op settled).

No Rust in this lane, so nothing needs cargo.
