# cmux remote transport and remote sessions

Status: plan, 2026-10-18. Base: `origin/feat-cmux-next` at `1b8b4ef5039`.
Author: a Claude Code planning agent for the Chief. Companion:
[`REPORT.md`](../../REPORT.md) (inventory with commits and authors).
Cloud workspaces, templates and billing are planned separately in
`~/fun/cmux-worktrees/cloud-orchestration/PLAN.md`; this plan does not repeat
them. A Cloud VM is one more kind of remote computer here.

## 0. Summary

The user's request is "a transport like Tailscale, our own wire-type tunnel, one
that carries terminals, VNC, our GPL-3.0 RustDesk-style desktop, ACP sessions,
ACP mocks and transcripts (gzip and paginated), plus remote sessions: one
sidebar group per computer listing its browsers, VNCs, terminals and chats."

Most of the parts exist. They are split across **three transport stacks that
were each declared the future**:

| Stack | Where | Declared by |
| --- | --- | --- |
| `cmux-remote` session layer: Noise XX, `CMXR` v5 frames, lanes, generations and replay, over unix / ssh / ws / iroh / relay / DO relay / wireguard carriers | `cmux-tui/crates/cmux-remote{,-protocol}` | `cmux-tui/docs/remote.md` |
| WireGuard overlay: `cmux-wg` (boringtun + smoltcp), `cmux-transport` (STUN, path selector, relay frames), `cmux-link`, HostDO relay | `cmux-tui/crates/cmux-{wg,transport,link}` | `plans/cmux-next/transport.md` (2026-10-02, "replaces iroh everywhere in cmux-next") |
| irx: QUIC over the iroh fork, one QUIC stream per lane, signed pair grants | `Packages/Shared/CmuxIrxTransport` | `docs/irx-transport-design.md` (shipped for phones on 2026-10-13, after transport.md) |

Plus two media stacks: `cmux.rd/1` (cmux's own remote desktop, GPL-3.0, merged)
and WebRTC/RFB on the unmerged `feat-cmux-next-vnc{,-rust}` branches.

**Recommendation.** Do not build a fourth transport and do not embed Tailscale.
Make one cmux session protocol (the existing `cmux-remote` session layer,
extended) the only thing services talk to, and treat WireGuard overlay, iroh
QUIC, the WebSocket relay and SSH as interchangeable *carriers* under it. Add
the missing typed services (VNC, desktop, browser, ACP, transcript, file), a
datagram side channel for media, and a per-machine **catalog** that feeds a
"remote session" sidebar group. Then pick one long-term carrier with data
(section 11, question 1).

## 1. What "regspiry" most likely means

"regspiry" is a voice typo for **registry**. In the last week it means two
linked things, and the user's sentence ("the registry changes and the Tailscale
stuff") fits both:

1. **`MachineRegistry`** (app side): `Packages/macOS/CmuxNext/Sources/CmuxNextApp/Cloud/MachineRegistry.swift`.
   It holds every daemon the app shows (local, each Cloud VM, each SSH machine,
   each paired server), and each one gets its own sidebar section. PR #21322
   ("machines: connect owner-fenced inventory and catalog discovery", Leo,
   `59d0076c54c`, 2026-10-18, 374 files) added `MachineRegistry+MachineCatalog`,
   the agent-inventory watch carrier and its routes, and the catalog publisher.
   That is the base for the remote-sessions sidebar group.
2. **The device registry** (cloud side): the PlanetScale tables `devices` /
   `device_app_instances` and `/api/devices`. `docs/multi-machine-sessions.md`
   (Leo Li, `95d4af0220d`, 2026-10-18, branch `docs/multi-machine-sessions`,
   unmerged, design only) makes it the one "My machines" list. It records the
   Tailscale incident that drives this plan: the tailnet policy blocked the VM
   from reaching the Mac, and only a hand-made reverse SSH tunnel worked.

Other "registry" meanings (the public ACP agent registry in
`acpmux/src/registry.rs`, the cmux-tui workspace registry store, the acpmux
protocol method IR) are not related to transport.

## 2. Goals and non-goals

Goals:

- G1. Any two cmux endpoints that the user owns can connect, with no open
  inbound port, no Remote Login, no tailnet ACL edit and no VPN prompt. The
  user's laptop is usually the machine that can dial out but cannot be dialed.
- G2. One session per (device, remote machine). It carries every traffic type
  as a typed channel, with priorities, so a 4 GB file or a video stream never
  delays a keystroke.
- G3. Reconnect after network change, sleep or relay failover in under 3 s,
  without the user seeing a new shell. Channels that can resume do resume.
- G4. Transcripts and other large text move compressed and paginated, with a
  cursor that survives growth and fails clearly after a rewrite.
- G5. A sidebar group per remote computer that lists what is reachable there
  (terminals, browsers, VNC and desktop targets, chats) and stays live.
- G6. Least privilege: a paired machine gets only what its trust tier allows.
  Today "every enrolled device has full daemon authority".

Non-goals:

- A general IP VPN. Like `iroh-app-transport-architecture.md` says, private
  resources are named, allowlisted exports. The system VPN role (`cmux vpn up`,
  Network Extension) stays a separate, optional feature.
- Billing, templates, VM lifecycle (cloud plan).
- Replacing SSH for users who want plain SSH. cmux can still write an SSH
  `Host` alias that rides the tunnel (multi-machine doc, step 7).

## 3. Architecture

```text
 Services      terminal  acp  transcript  file  vnc  desktop  browser  tcp  catalog
                  │       │       │         │     │      │        │      │      │
 L3 session  ── cmux session (Noise XX, CMXR frames, lanes, services, resume) ──┐
                  │ reliable streams                       │ datagrams (media)  │
 L2 carrier  ── overlay (cmux-wg) │ iroh QUIC │ relay WSS / DO │ SSH │ unix ─────┤
 L1 paths    ── direct LAN │ direct WAN (punched / IPv6) │ VPC tunnel │ relay ──┘
 L0 identity ── device key, device registry row, pair grant, trust tier
```

### 3.1 L0 identity and the device registry

- One long-lived key pair per (device, app install). The private key is created
  on the device and stays there (Keychain `ThisDeviceOnly`, or a 0600 file).
  This is already the rule in transport.md section 8 and irx L0.
- **Today there are three device keys per Mac**: the Noise static key of
  `cmux-remote`, the WireGuard key of `cmux link`, and the iroh EndpointID.
  Plan: one Ed25519 identity key signs a small *key bundle*
  `{noise_x25519, wg_x25519, iroh_ed25519, created, expires}`, and the
  registry stores the bundle. Peers pin the identity key, not each carrier key.
  Then a carrier change never needs a re-pair.
- The registry row (`devices`) is the address book, not the authority:
  `{device_id, owner_user, display_name, os, kind: mac|linux|vm|ios,
  key_bundle, hints: [relay_home, public_direct, tailscale_name, ssh_alias],
  last_transports, login_user, home}`. Hints never authorize (iroh doc rule).
- Pairing stays explicit: QR or one-time code, approved on the other machine
  (existing `cmux-remote` enrollment invitation; CmuxHive flow on main). A
  registry row or a matching Tailscale name never creates a grant.
- Grants: a backend-signed pair grant `{initiator_key, acceptor_key, tier,
  services[], exp}` verified offline at admission (irx L2 already does this).

### 3.2 L1/L2 carriers and NAT traversal: the options

| Option | What we get | Cost and risk | Verdict |
| --- | --- | --- | --- |
| **Embed tsnet / Tailscale** | Mature NAT traversal and DERP, MagicDNS | Go runtime inside the app and iOS; identity and ACLs owned by the customer's tailnet (the exact failure on 2026-10-18); needs a Tailscale or Headscale control server; one VPN slot on iOS | No. Keep Tailscale as an underlay *hint* only: a 100.x path is a direct path candidate after admission |
| **Userspace WireGuard overlay (`cmux-wg`)** | Already carries Cloud VM terminals; one key per device; the Freestyle VPC path; HostDO relay; multipath selector with measured hysteresis | smoltcp has no SACK; bulk upload over about 1 MiB failed through Freestyle (being fixed); TCP-in-WebSocket on the relay; HostDO rendezvous not finished | Keep. It is the only carrier into the Freestyle VPC |
| **Plain QUIC (quinn) with our own STUN / relay** | Streams and datagrams, per-stream flow control | We would rebuild hole punching, relays and path migration that iroh already has | No |
| **iroh (irx, forked)** | QUIC streams and datagrams, NAT traversal, managed relays, path migration; shipped and soaked on iOS | Fork upkeep (noq, iroh-ffi), relay-biased path choice (iroh#4247), no relay-only privacy mode | Keep. Best fit for laptop, Mac mini and phone pairs today |
| **Own relay only (`cmux-relay` WSS, Cloudflare DO relay)** | Works through any HTTPS proxy; already end-to-end Noise | TCP over TCP; no direct path | Keep as the last-resort carrier |

So the carrier set is: overlay (Cloud VPC, and direct UDP), iroh (device to
device), WSS relay (UDP blocked, enterprise proxies), SSH and unix (explicit
and local). The session layer above them is the same, which is what
`cmux-remote` already does. The merge decision between overlay and iroh is a
user question (section 11, question 1). It does not block phases 1 to 3.

### 3.3 L3 session: one multiplexed wire protocol

Base: `cmux-remote-protocol` v5. Header (60 bytes, big-endian), already merged:

```text
 0      4    5    6        8                24       32       40       48       56   60
 | CMXR | v=5| lane| flags  | session id (16) | gen (8) | seq (8) | ack (8) | stream (8) | len (4) | payload ≤ 48 KiB
 lane:  0 interactive · 1 control · 2 bulk · 3 tunnel
 flags: RELIABLE OPEN FIN RESET ACK_ONLY REPLAY SESSION_CLOSE HEARTBEAT_REQ HEARTBEAT_RESP
```

Frames are Noise-encrypted end to end on every carrier, so relays and
Freestyle see only ciphertext. On iroh, a lane can map 1:1 to a QUIC stream
(irx style) to remove head-of-line blocking; the frame stays the same.

A channel opens with the existing `ServiceControl::Open { service, metadata }`.
The plan extends `Service` (today: `MuxControl`, `WorkspaceRpc`,
`ProcessStream`, `TerminalBytes`, `TcpTunnel`, `ComputerUse`) and adds a
capability string for each new service:

| Service (new in bold) | Lane | Priority | Resume after reconnect | Payload after open |
| --- | --- | --- | --- | --- |
| `mux-control`, `workspace-rpc` | control | 0 | replay by seq | JSON RPC |
| **`catalog-v1`** | control | 0 | snapshot + deltas from revision | JSON events (section 5) |
| `terminal-bytes-v1` | interactive | 1 | by output offset (viewer credit 256 KiB) | CMTH frames |
| **`acp-v1`** | interactive | 1 | by acpmux event cursor (`hub/paging.rs`) | ACP JSON-RPC lines |
| **`desktop-rd1`** | interactive + datagrams | 2 | no: new keyframe | `cmux.rd/1` stream frames; media on datagrams |
| **`browser-rb1`**, **`browser-cdp-v1`** | interactive + datagrams | 2 | no / CDP re-attach | `cmux.rb/1` on `cmux.rd/1`; CDP JSON |
| **`vnc-rfb-v1`** | tunnel | 2 | no: new RFB handshake | raw RFB to the host's loopback VNC server |
| `tcp-tunnel` | tunnel | 3 | no (tunnel bytes never replay) | raw bytes |
| **`transcript-v1`** | bulk | 4 | by page cursor | transcript pages (section 4.5) |
| **`file-v1`** | bulk | 4 | by byte offset + content hash | offset chunks |

**Datagrams.** `cmux.rd/1` has its own FEC, NACK and congestion control and
wants an unreliable path. Each carrier offers one if it can: QUIC datagrams on
iroh, overlay UDP port 4103 (`remote-desktop` service) on `cmux-wg`, nothing on
WSS relay or SSH. With no datagram path, `desktop-rd1` uses its existing stream
mode. The session advertises `max_datagram` and path changes (transport.md 12a
`path.changed`), so the media engine adapts.

### 3.4 Flow control and backpressure

Keep the current, tested rules; make them per service:

- Strict priority by lane: control, then interactive, then media datagrams,
  then tunnel, then bulk. Bulk is paced (twice the flight per RTT, as in
  `cmux-wg` TR1) and never raises interactive p99 by more than 10 ms.
- Per-channel credit windows (receiver grants bytes): terminal 256 KiB per
  viewer; ACP 1 MiB; transcript and file 4 MiB; tunnel 1 MiB. A full window
  backpressures the writer. Streams never drop.
- Media datagrams older than 50 ms in the send queue are dropped first.
- Existing caps stay: 256 logical streams, 32 MiB unread data, 64 service
  handlers per client session.
- Cancel is per channel (`RESET`), so cancelling one transfer does not tear down
  the session.

### 3.5 Auth and encryption: three gates

1. **Reachability** (network: WireGuard AllowedIPs, relay tickets, iroh relay
   tokens). Decides only who can send packets.
2. **Device authentication** (Noise XX against the pinned identity key bundle,
   or iroh TLS EndpointID plus the signed pair grant).
3. **Service authority** (new). Each `ServiceControl::Open` is checked against
   the grant's tier and service list before a handler starts. Tiers, from the
   multi-machine doc: `full`, `agents-only` (ACP, transcript, catalog),
   `view-only` (catalog, read-only terminals, VNC view), `none`. The default
   toward the user's personal machine is `none` until the user picks.
   VNC: RFB passwords and Apple DH stay inside the encrypted session; cmux never
   sends plain RFB over the network, and never runs a VNC server
   (remote-desktop.md RD9).

### 3.6 Reconnect and resume

Already in `cmux-remote`: a fresh Noise handshake, pinned daemon key, fenced
generations, exchanged receive cursors, one replay of unacknowledged
mutations, a resume lease (120 s default), and a cycle through all route
candidates, even across carrier types. Add:

- One reconnect owner per peer (irx `IrxPeerEngine` rule: automatic triggers
  join the dial in progress; backoff 0.4 s doubling to 5 s while a network path
  exists).
- Race all carriers at dial (transport.md "connect fast, then improve"), keep
  the first that admits, upgrade in the background.
- Per service: resumable services reopen with their cursor; tunnel, VNC and
  desktop reopen fresh, and the UI shows "reconnected" instead of stale pixels.

## 4. Channel details

### 4.1 Terminals
Use `terminal-bytes-v1` as it is (CMTH frames, viewer size priority,
snapshots on bulk, `generation` + `offset` ordering). No change.

### 4.2 VNC (compatibility)
The host side opens a loopback TCP connection to the local VNC server (macOS
Screen Sharing on 5900, or a Linux VNC server) only when the grant allows
`vnc-rfb-v1`; the client feeds the bytes to the RFB client. The Swift RFB 3.8
client on `feat-cmux-next-vnc` (`Packages/Shared/CmuxVNC`) is the client;
remote-desktop.md asks for a Rust one later. The WebRTC and Worker signaling
path on that branch is not needed when the session exists. Reuse its codecs and
tests, and drop its plain-TCP network path.

### 4.3 cmux desktop (`cmux.rd/1`, the GPL-3.0 RustDesk-style engine)
Already merged: `cmux-rd-{core,engine,proto,ffi,host}`, `cmux-encode`, the
remote view pane. The plan only gives it a carrier: `desktop-rd1` opens the
control stream on the session and binds the datagram side channel. macOS and
Windows hosts are later phases (the Linux X host exists; `cmux-screen` on the
unmerged vnc-rust branch has macOS capture with p50 40–53 ms key latency).

### 4.4 Browsers
`browser-rb1` carries the remote browser tab video (`cmux-remote-browser`,
`cmux.rb/1` on `cmux.rd/1`). `browser-cdp-v1` carries CDP to
`cmux-browser-host` for agent control. Loopback web previews keep using the
existing `loopback-forward` / `tcp-tunnel`.

### 4.5 ACP sessions, mocks and transcripts
- **Live ACP.** acpmux peers today connect over `ws://` with a peer token, or
  over SSH (`acpmux/src/peer.rs`). Add the cmux session as a third peer carrier:
  `acp-v1` opens a JSON-RPC stream to the remote acpmux, authorized by the
  grant tier, with no acpmux port open anywhere.
- **Mocks.** A mock is an `acp-v1` channel with `metadata.mode = "replay"` and
  a fixture id. The host's acpmux plays the fixture (the existing
  `acpmux/tests/fixtures` and `webviews/.../acpmux/replay` timelines) with the
  same framing as a live agent, so the remote UI and CI share one path.
- **Transcripts.** `transcript-v1` serves pages built by the prototype crate
  `cmux-tui/crates/cmux-remote-transcript` (this commit):
  - a page holds at most N entries and B uncompressed bytes; one oversized
    entry (≤ 8 MiB) is sent alone, so paging always moves;
  - the body is length-prefixed entries, gzip by default (`identity` for tiny or
    already compressed data), with the uncompressed length and SHA-256 in the
    header. The reader refuses pages over its limit and never inflates past the
    declared length (gzip bomb guard);
  - the cursor is opaque `{transcript, generation, next_index}`. It stays valid
    while the transcript only grows (the end cursor polls for new entries). A
    rewrite (compaction, fork) bumps `generation`, and old cursors fail with
    `StaleCursor`, so the client restarts and never skips or repeats entries.
  - Today `acpmux.transfer.v1` sends 4 MiB base64 pages with no compression.
    Phase 2 makes `_acpmux/transfer_read` and `_acpmux/events` use this codec
    when both sides advertise `transcript-pages-v1`. Negotiate `zstd` later if
    measurements justify a new dependency (gzip via `flate2` is already in the
    workspace).

### 4.6 Files
`file-v1`: offset-addressed chunks with a whole-file SHA-256 at the end,
resumable by offset, bulk lane. It replaces ad hoc scp for Finder-over-hosts
(transport.md 12c) and image paste.

## 5. Remote sessions: one sidebar group per computer

### 5.1 What the user sees
A group per remote computer ("cosmic-gray", "Huge Blue", "cmux16", each Cloud
VM). Its header shows the name, the online state, and a path badge (direct,
VPC, relay, RTT). Under it, sections that appear only when they have items:

- **Terminals**: the host's cmux-tui workspaces and PTYs (attach on click).
- **Chats**: acpmux sessions on that host (open in an agent pane; the host
  label stays on the receipt `qualifiedSessionId`).
- **Browsers**: browser-host tabs and loopback dev servers that are listening.
- **Screens**: the cmux desktop host (`cmux.rd/1`) when it runs, and VNC
  targets the user added or that are found on loopback (5900).

Offline computers keep their last snapshot, greyed, with "last seen".

### 5.2 How it is found and kept live
- The group list comes from `MachineRegistry`, which gets its machines from the
  device registry (owned machines first, then team machines), the Cloud VM
  list, and saved SSH machines. The sidebar groups by machine; it does not
  create machines.
- Each host's daemon publishes a **catalog**: a versioned list of items
  `{item_id, kind: terminal|chat|browser|screen|vnc|tunnel, title, state,
  updated_at, open: {service, metadata}}`. #21322's
  `MachineCatalogPublisher` / `AgentInventoryWatch` is the start. Generalize the
  agent inventory into this catalog instead of building a second one.
- Transport: `catalog-v1` on the control lane: `watch {since_revision}` gives a
  snapshot if the revision is too old, else deltas; each event carries
  `revision`. After a reconnect the client resends its revision. No polling.
- Presence (`workers/presence`) says online or offline before any connection
  exists, so the sidebar can show state without dialing every machine.
- Opening an item sends its `open` descriptor as a `ServiceControl::Open`. One
  shared action path serves the sidebar, the command palette, the CLI
  (`cmux remote open <machine> <item>`) and the Chief.
- SwiftUI rule: rows get value snapshots and closure bundles only (snapshot
  boundary rule in `CLAUDE.md`). The catalog model is an `@MainActor
  @Observable` coordinator that projects `AsyncStream` events from a
  catalog service actor.

## 6. GPL-3.0 and licensing

- The cmux clients (macOS app, iOS app, CLI, cmux-tui) are already
  GPL-3.0-or-later (root `LICENSE`). The cmux desktop engine crates say
  `GPL-3.0-or-later`. So a GPL-3.0 desktop engine in the client creates no new
  conflict.
- The server directories are BUSL-1.1 (`web/`, `backend/`, `workers/*`,
  `services/iroh-relay-minter`, `cmux-tui/relays/cloudflare-do`). Rule: relays
  and backends never link or bundle `cmux-rd-*`, `cmux-encode` or other GPL
  client code. They forward ciphertext only. This keeps the license split clean.
- **Do not copy RustDesk source.** RustDesk is AGPL-3.0 (its `LICENCE` file on
  `master`, checked 2026-10-18). Its network clause would reach every host that
  serves it. Our engine is a clean implementation; keep a short
  provenance note in `cmux-rd-*` and do not paste code from RustDesk. It is
  fine to study protocols and to interoperate.
- x264 (GPL-2.0-or-later, licensed for patents separately) stays an opt-in
  feature that waits for the legal decision. Cisco OpenH264 binary stays the
  default.
- Apple App Store distribution of GPL code needs Manaflow to hold the rights
  (CLA for contributions, no third-party GPL in the iOS binary). Check this
  before the desktop viewer goes into the iOS app.

## 7. Milestones

Effort is for one experienced engineer with agents; "M" = 1–2 weeks.

| Phase | Deliverable | Effort | Exit test (fleet / CI, not this Mac) |
| --- | --- | --- | --- |
| P0 (this commit) | Plan; `cmux-remote-transcript` page codec with 8 tests | done | `cargo test -p cmux-remote-transcript` |
| P0A Service authority | Immutable service authority on every authenticated grant and logical connection; deny `ServiceControl::Open` before handler dispatch unless the grant explicitly lists the service; require identical authority across physical lanes and reconnects | done | a grant with no services gets `permission-denied`; existing grants retain only the six services that existed when the gate landed |
| P1 Catalog | After P0A, add `catalog-v1` to the intended grant tiers in `cmux-remote`; generalize #21322 inventory into the catalog; sidebar "remote session" group over existing SSH, Cloud and paired daemons | M | two daemons in CI: add, remove and rename items, delta order, reconnect with an old revision gets a snapshot; a grant without catalog authority is refused |
| P2 Transcripts and ACP | `transcript-v1` on the bulk lane; acpmux `transfer_read`/`events` negotiate `transcript-pages-v1`; `acp-v1` peer carrier; replay mocks over `acp-v1` | M | 50 MB transcript: wire bytes below 25 % of today; kill the carrier mid-transfer and resume by cursor with no gap or repeat |
| P3 Media | `desktop-rd1` and `browser-rb1` services with a datagram side channel (QUIC datagrams, overlay 4103), stream mode fallback; `vnc-rfb-v1` with the CmuxVNC client merged from the vnc branch | M–L | key echo p50 ≤ RTT + 20 ms on direct; relay-only run of 15 min with no stale frame after a reconnect |
| P4 Identity | One identity key with a signed key bundle; registry row carries the bundle and hints; persisted trust tiers populate the P0A service authority | M | revoke a device and the next admission fails; a `view-only` peer cannot open `terminal-bytes-v1` input |
| P5 Machines | "Add a machine" flow and probe from the multi-machine doc; Linux daemons register in the device registry and heartbeat presence | M | the 2026-10-18 setup (tagged VM, blocked tailnet ACL, closed port 22) works with no manual step |
| P6 Converge | Choose the long-term carrier (overlay or iroh) from soak data; delete the loser's duplicate code paths | L | 15-minute soak per carrier pair, same acceptance as `irx-soak` |

## 8. Wire sketches for the new services

```jsonc
// ServiceControl::Open, catalog
{"type":"open","service":"catalog-v1","metadata":{"since":"1842"}}
// event (one JSON per frame on the stream)
{"revision":1843,"op":"upsert","item":{"id":"chat:acpmux:7f3c","kind":"chat",
  "title":"fix sidebar drop","state":"working","updated_at":"2026-10-18T22:01:09Z",
  "open":{"service":"acp-v1","metadata":{"session":"7f3c"}}}}
{"revision":1844,"op":"remove","id":"terminal:ws_12:pty_3"}

// transcript
{"type":"open","service":"transcript-v1","metadata":{"transcript":"acp:7f3c",
  "cursor":"eyJ0Ijoi...","max_entries":"500","max_page_bytes":"1048576","encoding":"gzip"}}
// each page: u32 header_len | header JSON | u32 body_len | body (gzip of [u32 len | entry]*)
{"transcript":"acp:7f3c","generation":3,"start_index":500,"entry_count":500,
 "total_entries":1234,"next_cursor":"eyJ0...","at_end":false,"encoding":"gzip",
 "uncompressed_len":412233,"sha256":"9b1e..."}

// VNC
{"type":"open","service":"vnc-rfb-v1","metadata":{"target":"loopback:5900"}}
// then raw RFB 3.8 bytes both ways
```

## 9. What to reuse (and what not)

Reuse:
- `cmux-remote` + `cmux-remote-protocol`: session, Noise, lanes, resume,
  providers, limits.
- `cmux-wg`, `cmux-transport`, `cmux-link`: overlay, STUN, path selector,
  relay frames, datagram service plan.
- irx: admission with offline grant verification, single dialer, keepalive,
  journal, soak analyzer.
- `cmux-relay`, `relays/cloudflare-do`: content-blind fallback.
- `cmux-rd-*`, `cmux-encode`, `cmux-remote-browser*`, the remote view pane.
- #21322 machine catalog and inventory watch; `MachineRegistry`; presence.
- acpmux peers, host-qualified receipts, transfer v1, `hub/paging.rs`, replay
  fixtures.
- `CmuxVNC` RFB client and its tests (unmerged branch).

Do not reuse:
- Tailscale TCP (legacy, plaintext above the overlay; compatibility only).
- `CmuxLinkDirect` hand-written Swift Noise IK (unmerged; iroh and Noise XX in
  Rust already cover it).
- The vnc branch's plain-TCP and WebRTC/Worker signaling paths when a cmux
  session exists.
- `chatmux-relay`'s temporary hand-written wire module as a protocol model.

## 10. Risks

- Three carriers stay in the tree until P6. Mitigation: services see only the
  session, and the conformance suite in `cmux-remote` runs on each carrier.
- One identity key per device is a migration: old pinned Noise keys must keep
  working during the change (accept either until the bundle is pinned).
- iroh relay-biased path selection and the `cmux-wg` bulk defects can make
  media slow. P3 exit tests measure both.
- The catalog could leak the names of private items to a low-tier peer. The
  host filters the catalog by the peer's tier before it sends.

## 11. Open questions for the user

1. Long-term carrier: transport.md (2026-10-02) says the WireGuard overlay
   replaces iroh in cmux-next; irx shipped for phones on 2026-10-13. Keep both
   behind the session layer until a P6 soak decides, or decide now?
2. Default trust toward the user's own laptop from a VM or a second machine:
   `none` (recommended), `agents-only` or `full`?
3. Should `vnc-rfb-v1` reach only loopback VNC servers on the host, or also LAN
   VNC servers next to it (the host as a jump box)?
4. Is the cmux desktop engine to ship on iOS (App Store and GPL question,
   section 6)?
5. Compression: gzip only (no new dependency), or add zstd now?
6. Team machines: should the sidebar show teammates' shared machines, or only
   the user's own?
7. "Our own implementation of RustDesk that is GPL-3.0": this plan reads it as
   the existing clean `cmux.rd/1` engine (own code, GPL-3.0-or-later). A fork of
   RustDesk itself would have to stay AGPL-3.0. Which one is meant?
