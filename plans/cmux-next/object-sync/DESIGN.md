# Object sync: one protocol for Mac, iPhone, web and Chief, with the Mac off

Status: design for review, 2026-10-18 (object-sync lane). Base read: `origin/feat-cmux-next`
7a440f4cd52d, `origin/feat-cnx-ios` 3d1255930b42, PR 20414 (Mac host), PR 20993 (CnxChief on
`cloud-api`). Binding inputs: spec `sync-and-transport.md` (draft 2), OWNERSHIP-PRINCIPLES.md,
`ownership-v2.md`, `home-messaging.md`, `transport.md`, `state-placement.md`,
`remote-state-ownership.md`, `mobile-rust-core.md` (MOBILE-RUST-1..5), and Lawrence's standing
rules (decouple from Swift, one protocol for web and native, shared Rust mobile core, many Chiefs on
one conversation model, two Chief brains).

The ask (Lawrence, 2026-10-19): "We need to have a macOS build that is synced to the iOS build
properly and then I need to be able to see that I can send messages and they are all individual
objects ... that communicate with each other. So I can have all the workspaces syncing ... I should
talk to durable objects so that even if my Mac is off I should be able to use it ... from first
principles, and not do anything hacky. Do not care about old code."

## 0. Summary

1. "The protocol Aziz uses for syncing everything" (cnx, `feat-cnx-ios`) is not a sync protocol.
   It is a tunnel. A Cloudflare Worker with one `TeamHub` Durable Object per team does presence,
   WebRTC/WireGuard signaling and a datagram relay. The phone dials the Mac, and every read and
   write (workspaces, tabs, terminals, agent chats, Mac Chief) goes through the tunnel to the Mac's
   cmux-tui daemon, chief socket and acpmux. The Mac is the only source of truth. With the Mac off,
   the phone shows a stale local JSON snapshot and can do nothing. The phone also discards the
   daemon's deltas and refetches the whole workspace list on every event.
2. cmux-next already has the right protocol, half built: the ownership wire `cmux.wire/1`
   (`backend/packages/ownership`, checked by `formal/OwnershipConvergence.tla`). Every entity has
   one owner. Owners commit ops with idempotency keys and publish ordered events per stream (`seq`).
   Clients hold a confirmed mirror plus an intent log, detect gaps, resume by `after_seq`, and settle
   lost replies from the snapshot's `decided` keys. ConversationDO, UserDO, MuxDO, TeamDO, CloudDO
   speak it today. PR 20993 put the phone's Cloud Chief on it.
3. Decision of this design: every object has exactly one home. Durable, shared, social and agent
   state is homed in a Durable Object, so the phone works with the Mac off. Machine-bound state
   (PTYs, files, local agent processes, the layout of workspaces whose terminals run on that Mac)
   is homed on that machine, and the machine publishes a read replica of it to its `HostDO`. With
   the Mac off, the phone reads that replica with an honest `offline since` state and cannot write
   to it (no fake success). Nothing is a CRDT. Nothing is mirrored by a Swift adapter.
4. One wire for everyone: Mac app, iPhone, web, TUI, CLI, the Mac daemon and the Cloud Chief speak
   `cmux.wire/1` frames. The Mac app speaks it to its local daemon. The daemon, the phone and web
   speak it to the DOs. The phone runs the same Rust client core as the daemon (`cmux-cloud-wire`
   stream mirror, bound by uniffi), so no sync logic is written in Swift or Kotlin.
5. The direct phone-to-Mac link (cnx WireGuard/WebRTC) is kept only as a data-plane fast path for
   live terminal bytes, browser video and file transfer, which the DO relay can also carry. No state,
   no command and no conversation ever needs it.
6. Phase 1 (started in this lane): the Rust stream mirror in `cmux-cloud-wire`, a port of the TS
   `ProjectionClient` in effects mode with the same frame types, gated by conformance vectors exported
   from the TS engine. It is the one client core that the Mac daemon, iOS and Android will use.

## 1. What exists today (read from code)

### 1.1 cnx (Abdulaziz, `feat-cnx-ios`)

| Piece | What it does | Where |
| --- | --- | --- |
| `cnx-ios-api` Worker | Stack JWT auth (two projects), devices, `GET /v1/me/macs`, prefs, invites, ICE, APNs push fan-out, bootstrap | `cnx-ios/backend/src/index.ts`, Postgres tables `devices`, `team_prefs`, `push_tokens` (`schema.ts`) |
| `TeamHub` DO, one per team (`idFromName(teamId)`, personal `personal-<sub>`) | presence of Macs, signaling `hello`/`presence`/`signal` frames, WireGuard relay binary frames `[16B session][16B to][datagram]`, membership cache, rate limits. Tables `macs`, `devices`, `sessions` (24 h) | `cnx-ios/backend/src/team-hub.ts` |
| `cnx-link` (Rust) | one reliable stream (WebRTC data channel or smoltcp TCP in userspace WireGuard), frames `u32 len, u32 channel, u8 type`, input lane, media lane (RTP H.264) | `cnx-ios/rust/crates/link` |
| `cnx-hostd` (Rust, Mac) | answers dials, pairing (`auth` service: Secure Enclave identity + Face ID approval keys, Mac identity TOFU), splices channels `daemon` (cmux-tui v12 lines, allowlist), `chief`, `acpmux`, `file`, `upload`, `browser`, `version` | `cnx-ios/rust/crates/hostd`, PR 20414 bundles it into the Mac app |
| Phone sync | `WorkspaceSync.swift` subscribes with `tree_events:"deltas"`, then re-runs `list-workspaces` on every event (deltas discarded). acpmux chats resume by `afterSeq`. Mac Chief by `conversation-snapshot` / `conversation-op` over the link. Offline outbox for Chief only (`cnx-chief-outbox.json`) | `CnxKit/Sources/CnxLive`, `CnxChief` |
| PR 20993 | `ChiefCloudBackend.swift` (681 lines): `GET /v1/wire/conv/<id>` (snapshot, events with `effects`, `snapshot.request` on gap, typing, `run.live`, `step.delta`), `POST /v1/read` (`conversation.snapshot`, `conversation.history`, `chief.list`), `POST /v1/ops` (`message.send` keyed by `client_msg_id`, edit, retract, reactions, `read_cursor.set`, `chief.create`) against `cloud-api` | `cnx-ios/CnxKit/Sources/CnxChief/ChiefCloudBackend.swift` |

Mac off today: `TeamHub` broadcasts `presence online:false`; a `signal` to it gets `offline`; the
phone's `LinkMachine` goes to `.macOffline`, shows the cached JSON, and redials when presence
returns. Only the Cloud Chief (PR 20993) and pushes the Mac already sent still work.

Not principled (the reasons this design replaces parts of it):

- Two sources of truth for Chief (Mac chief over the link, Cloud Chief on ConversationDO), each
  with its own outbox file.
- Two backends with duplicated identity: `cnx-ios-api` (Postgres devices, TeamHub presence) next
  to `cloud-api` (UserDO installs, TeamDO members and hosts, PairingDO, HostDO relay).
- Snapshot-on-every-event workspace sync with no revision check; O(tree) per title change.
- Policy written twice (`hostd/src/policy.rs` mirrors Swift `DaemonLanePolicy.swift`).
- No cloud state at all, so "Mac off" is a dead end by construction.
- Error detection by string matching (`"401"`, `"4002 "`), runtime `ALTER` schema changes,
  owner keys packed as `projectId:sub`, unsupervised hosts with no pairing.

Principled and worth keeping: userspace WireGuard with roaming, TURN-first fallback and
reachability markers; the input lane and the per-class send queue (no head-of-line blocking for
keystrokes); the media lane for browser video; Secure Enclave phone keys with Face ID approval for
risky answers; Mac identity pinning; content-minimized push (the Worker writes the text, the Mac
sends only a kind and a place); `Server-Timing` on every response; `locationHint` from the client's
location.

### 1.2 cmux-next cloud (`feat-cmux-next`, `backend/apps/api`)

- Owner base `OwnerDO` (`owner-do.ts`) over `OwnerEngine` (`backend/packages/ownership`): ledger,
  pure reducer, one SQLite transaction for state + ledger + events + outbox, commit before publish,
  `request-settled` as the write barrier, hibernating subscribers, event window, outbox drained by
  alarm to PlanetScale projections.
- Wire frames (`ownership/src/types.ts`): client `op {op, params, idempotency_key, origin,
  expected_revision?}`, owner `event {stream, seq, tx, op, params, actor, origin, at, effects?}`,
  `result`, `reject {code, retryable}`, `request-settled {stream, sequence, ok}`, `snapshot {stream,
  seq, state, decided[], rows?}`. Client `ProjectionClient` (`client.ts`) = mirror + intent log,
  gap detection, held settles, reconnect resend with the same keys, 24 h intent TTL, U5 refusal.
- Sockets: `GET /v1/wire/{user|team|feed|cloud}` and `/v1/wire/conv/<id>`, `/v1/wire/mux/<agent>`
  (subprotocol `cmux.wire.v1`, credential in the Authorization header or a wire ticket). HTTP
  `POST /v1/read`, `POST /v1/ops`. Ops are rows of the Effect-Schema catalog
  (`backend/packages/protocol/src/op-def.ts`, owner `cloud:<DO>`), exported to Rust
  (`cmux-tui/crates/cmux-cloud-wire`, generated types, `cloud_vectors.rs`).
- DO classes (wrangler v1..v17): UserDO, TeamDO, SchedulerDO, ConnectionDO, AccountIndexDO, FeedDO,
  DomainDO, ConversationDO, MuxDO, AddressDO, PairingDO, HostDO, UsageMeterDO, TeamVmDO, CloudDO,
  SpendGuardDO, FreeDeviceDO, WireTicketDO, ChiefBrainDO, HandDO, OpencodeBrainDO.
- `HostDO` (95 lines) is only the datagram relay today; its header lists "rendezvous storage, wake,
  presence, cached tails" as not yet built. `HandDO` is the executor pattern already: an installed
  `acpmux hand` on a Mac dials out to `/v1/hands/<id>/socket`, the cloud sends `req`, the hand
  answers `res`, asks `approve`, streams `event {session, seq}`.
- `ChiefBrainDO` is keyed `brainName(agent, conversation)` = one brain and one OptChat memory per
  (chief, conversation), with the Rust optchat core compiled to WASM.

### 1.3 The Rust side

- The cmux-tui daemon (`cmux.protocol/2`, v12 JSON lines) owns terminals (`terminal_host` per PTY),
  the workspace store (`cmux-layout-reducer`, a pure reducer), local conversations
  (`cmux-conversation`), and spawns acpmux (agent sessions, turns, transcripts; JSON-RPC and a
  loopback WebSocket). `cmux-tui-cloud-conversations` is the daemon proxy for cloud conversations:
  it forwards ops with the client's key and never queues.
- `cmux-mobile-core` / `cmux-mobile-ffi`: slice 0 only (terminal sizing). Slices 1 to 4 are the
  wire client, the Home mirror, terminal frames, then transport.

### 1.4 The spec already points here

`sync-and-transport.md` section 5 (phase 1 topology) says: one WebSocket per install to its
`UserDO` gateway; host-owned streams reach the host through `HostDO`; `HostDO` keeps "the last
snapshot and a bounded event tail ... so a client can show a sleeping host's state read-only with
`owner.status: offline, cached_seq`. It never accepts ops for an offline host"; `TeamDO` is the
directory of hosts and of documents with their home (`host:<id>` or `cloud`). cnx went the other
way (phone dials Mac, Mac holds everything). This design finishes the spec's path and retires the
cnx state path.

## 2. Requirements, made testable

| # | Lawrence's words | Testable form |
| --- | --- | --- |
| R1 | "macOS build synced to the iOS build properly" | Mac and phone show the same objects at the same `seq` per stream; a change on one appears on the other in under 500 ms p95 on the same network (DO in region) |
| R2 | "messages ... are all individual objects that communicate" | each message, conversation, workspace, run, Chief, device and host has a stable id, one owner, and a stream; every change is an op with an idempotency key and an event with a `seq` |
| R3 | "all the workspaces syncing" | the workspace list, titles, status, unread, agent state and layout of every workspace on every host appear on every signed-in device |
| R4 | "talk to durable objects so even if my Mac is off I should be able to use it" | with the Mac powered off: the phone sends to any conversation, talks to a Chief and gets a reply, starts agent work on a cloud hand, reads every workspace's last known state |
| R5 | "the proper way from first principles, not hacky" | one owner per entity, one wire, no polling, no CRDT merge guessing, no Swift logic, honest offline states, idempotent retries, formal model kept green |
| R6 | standing: one protocol for web/Mac/iOS/Windows/Linux, logic in Rust or the backend | the phone links the same Rust core as the daemon; a web page runs against the same sockets |

## 3. First principles

1. One home per object. A fact has exactly one writer: a DO or one machine's daemon. Everyone else
   holds a mirror. (OWNERSHIP-PRINCIPLES, spec 2.)
2. Home follows the resource. State that only exists while a machine runs (a PTY, a file, a local
   process) is homed on that machine. State that must outlive any one machine (conversations,
   Chiefs, runs, the workspace registry, devices) is homed in a DO.
3. Reads never depend on the home being up. Every machine-homed stream is replicated to that host's
   `HostDO` (snapshot + bounded tail). Writes always go to the home, and are refused honestly when it
   is unreachable.
4. One wire. Every owner speaks the same frames. A client is the same state machine whether the
   owner is a DO, a daemon on the Unix socket, or a daemon behind `HostDO`.
5. Server-ordered ops, not CRDTs. Each owner orders its own stream. Conflicts are resolved by the
   owner's reducer (reject, `expected_revision`, or a commutative rule such as max for cursors).
6. Logic once, in Rust or in the owner. Swift and Kotlin render and send intents. The TS DO reducers
   and the Rust mirror are kept equal by conformance vectors.
7. Control plane and data plane are separate. State and commands go over the wire to owners. Bulk
   live bytes (terminal output, video) go over channels that may take a direct path.
8. Event-driven only. No polling, no timers as synchronization; DO alarms only for owner work
   (outbox drains, retention, wake retries).

## 4. Alternatives compared

| | A. Mac is the server, phone tunnels in (cnx today) | B. Cloud owns everything, the Mac is a thin client and executor | C. CRDT documents everywhere (Automerge/Loro/Yjs) synced through a DO | D. Homed single-writer objects + cloud replicas (chosen) |
| --- | --- | --- | --- | --- |
| Phone with Mac off | nothing works | everything works | everything works (but nothing executes) | conversations, Chiefs, runs on cloud hands, workspace registry: work; Mac-homed layout and terminals: read-only cached, offline shown |
| Mac with no internet | works | layout edits and messages refused (or need an offline queue that the cloud must then merge) | works | Mac-homed objects work; cloud objects read-only cached, sends refused (U5) or queued (decision L2) |
| Cmd+D latency on the Mac | local | one DO round trip unless optimistic overlay (then a second owner in practice) | local | local (the daemon owns Mac layout, B1 budgets in remote-state-ownership.md hold) |
| Invariants (participants, quotas, layout rules, ACL) | the Mac checks | the DO checks | nobody can reject a merged edit; invariants become repair passes | the home checks, always |
| Multi-user, team ACL | none (same user only) | natural | per-document ACL is hard, server cannot validate | natural (TeamDO directory + owner checks) |
| Fit with existing code | cnx code | rewrites the daemon's store into the cloud and contradicts `remote-state-ownership.md` | throws away the ownership engine and the TLA+ model; spec non-goal | uses OwnerEngine, ConversationDO, MuxDO, HostDO, HandDO, cmux-layout-reducer, the spec topology |
| Cost | cheapest | highest DO traffic (every keystroke-level layout op) | merge metadata grows forever | DO traffic only for shared state and replicas (bounded tails) |

D is chosen because it is the only option where every object has one writer that is available
when it matters: the cloud for things that must survive the Mac, the Mac for things that only
exist on the Mac. A loses R4 by construction. B makes the Mac worse at its own job (offline, Cmd+D)
and puts a cloud hop in front of local work. C trades a clear owner for merge rules that cannot
enforce invariants or ACLs, and the spec rejected it.

## 5. Object model

Ids: owner-assigned, prefixed, never reused (`home-messaging.md` 2). Streams: one per owner object.

| Object | Id | Home (single writer) | Stream | DO class / place | Mac off |
| --- | --- | --- | --- | --- | --- |
| User, installs, grants, inbox, Chief records | `user_…`, `inst_…` | UserDO | `user:<u>`, `inbox:<u>` | UserDO | works |
| Team, members, roles, hosts directory, document homes, policy | `team_…` | TeamDO | `team:<t>` | TeamDO | works |
| Device (an install of the app or daemon on one machine) | `inst_…` with `install_kind` mac, ios, daemon, web, vm | UserDO (record), the device (keys) | `user:<u>` | UserDO | works |
| Host (a machine that runs a daemon: Mac, Linux box, Cloud VM) | `host_…` | TeamDO (record, ACL), HostDO (presence, replica, relay) | `host:<h>` | HostDO, one per host | presence `offline since`, replica readable |
| Conversation (DM, group, chief thread, workspace conversation) | `conv_…` | ConversationDO | `conv:<id>` | ConversationDO | works |
| Message (with `thread_root`/`reply_to`, parts, reactions, edits) | `msg_…`, dense `seq` | ConversationDO (row table) | inside `conv:<id>` | ConversationDO | works |
| Read cursor | (conv, participant) | ConversationDO, monotonic max | inside `conv:<id>` | | works |
| Chief | `agent_…` | UserDO (record), MuxDO (wake queue, brain lease, brain impl) | `mux:<agent>` | MuxDO | works (cloud brain answers) |
| Chief brain run (one turn) | `run_…` | ChiefBrainDO | `run` events into `conv:` | ChiefBrainDO | works |
| Workspace record (identity: name, color, icon, home, conversation, status, unread, agent summary) | `ws_…` | TeamDO directory row (the record); the workspace's home owns the contents (section 5.1) | `team:<t>` directory + `doc:<ws>` | TeamDO | record works; contents per home |
| Workspace document (screens, columns, panes, tab order) | `doc:<ws>` | its home: `host:<h>` (default for Mac workspaces) or `cloud` (DocDO) | `doc:<ws>` | daemon store actor, replicated to HostDO; or DocDO | Mac-homed: read-only cached; cloud-homed: works |
| Terminal session | `host:<h>/term_…` | the host's session actor + terminal host process | `host:<h>/session`, channel `terminal_bytes` | daemon; HostDO keeps title, cwd, status, last 64 KiB screen | offline shown with last screen, no input |
| Agent session (acpmux) and its turns | `host:<h>/acp_…` | the host's acp actor | `host:<h>/acp` | daemon; HostDO keeps session list, status, last turn summary | offline shown, history readable from replica window |
| Agent run on a cloud hand | `run_…` | HandDO (request ledger, events) for the hand; the run record in the Chief's conversation | `hand:<id>` | HandDO | works (Freestyle hand) |
| Hand (an executor: Mac acpmux hand, sandbox, VM) | `hand_…` | HandDO | | HandDO | Mac hand: offline; cloud hands: work |
| Feed item, approval request | `feed_…` | FeedDO | `feed:<u>` | FeedDO | works |
| Cloud machine | `vm_…` | CloudDO | `cloud:<t>` | CloudDO | works |
| Attachment bytes | content hash | R2, quota in UserDO | | R2 | works |
| Drafts, scroll, selection, open pane | | the device | never synced | | local |

### 5.1 Workspaces: record in the cloud, contents at their home

A workspace is two objects:

- The workspace record lives in the cloud directory (TeamDO rows, personal team for a single user):
  id, name, color, icon, home (`host:<h>` or `cloud`), its workspace conversation id, a status
  summary (agent state, unread, last activity) published by the home. This is what the phone's
  workspace list renders, and it is always available.
- The workspace document (layout, tabs, references to terminals and agent sessions) is owned by its
  home. A Mac workspace is homed on that Mac's daemon, which keeps Cmd+D local (B1 budget,
  `remote-state-ownership.md`). The daemon publishes `doc:<ws>` events to `HostDO`, which keeps the
  snapshot and tail, so the phone renders the layout with the Mac off and marks it offline.
- A workspace whose terminals run in the cloud (Cloud VM, team VM) or that has none yet
  ("conversation-first" workspaces created from the phone) is homed in `DocDO` and is fully
  editable from any device.
- Moving the home (`workspace.move_home {to}`) is an explicit op, like `conversation.promote`:
  the old home freezes the document at a `seq`, the new home starts from that snapshot, the
  directory row flips. Terminals never move (data-model.md 1.2a); a moved workspace references
  them remotely.

### 5.2 Hosts (remote hosts joining the tailnet)

Lawrence, 2026-10-18 (via the coordinator): Linux, Windows and macOS hosts join the network; each
host is a sidebar group that shows exactly its sessions; hosts are discovered and synced across
all of the user's clients. The companion design is `plans/cmux-next/remote-hosts/DESIGN.md`
(another lane); this section fixes only the object model it plugs into.

- A host is one object with two parts: the record (`host_…`: name, platform, owner user, team,
  enrolled by which install, capabilities, reach policy) is a row of the TeamDO directory
  (`team:<t>` stream), and the live part (presence, replica of its host-homed streams, relay,
  forwarded ops) is its `HostDO`. The Mac is a host like any other; so is a Cloud VM.
- Discovery = the directory. A host appears on every client of the user when its enrollment
  commits in TeamDO (`host.enroll`, by the host's daemon install after the user approves it on a
  signed-in client, or by the device flow on a headless Linux box). No client scans the network.
  Network reach (tailnet address, WireGuard key, endpoints) is a field of the record that the
  transport reads; it is not how clients learn that a host exists.
- The sidebar group of a host is a projection: the rows of `host:<h>/session` (its terminal
  sessions and workspaces homed there), served live by the host, or from `HostDO`'s replica with
  `owner.status offline since` when it is off. A client never merges two hosts' lists into one
  owner.
- Group order, collapsed state and which hosts are hidden are the user's organization. Today
  `data-model.md` 1.2(c) keeps personal organization only in the Mac's home session. Lawrence's
  "synced across the user's clients" moves it to the user's own stream: a `sidebar` document in
  UserDO (`user:<u>`), one writer (UserDO), every client a mirror. Per-device state that must not
  sync (window frames, scroll, which pane has focus) stays on the device.

### 5.3 Identity and versions that UI animation and sizing can rely on

The sync UX design (`plans/cmux-next/sync-ux/DESIGN.md`, another lane) animates renames and
reorders keyed by stable object ids and picks multi-client sizing policies. The protocol gives it:

1. Stable ids. Every object (workspace, tab, pane, terminal, host, message, conversation) has an
   owner-assigned id that is never reused or renamed. A rename changes a field, never the id. An
   optimistic intent gets a client-minted id in the client's namespace (client id + UUIDv7,
   `remote-state-ownership.md` A2) that the owner accepts as the final id, so a pending row
   becomes the confirmed row without a key change (no remount, no flash).
2. One change, one event. Every event names its stream `seq` and, in effects mode, the exact rows
   written (`writes: [{table, key, n, row}]`). A client diffs per key: a write that changes only
   `order_key` is a reorder; one that changes `title` is a rename; a delete is a removal. No
   client diffs whole lists.
3. Explicit order. Ordered collections that people rearrange (sidebar groups, workspaces, tabs)
   carry an `order_key` (a fractional index string, as `cmux-layout-reducer::sidebar_doc::order_key`
   does already), so a move is one row write and two clients' moves never renumber siblings.
4. Per-object revision. Each row carries `rev` = the `seq` of the event that last wrote it, so a
   client can drop a stale optimistic animation (its intent settled at a lower `rev`) and order
   animations from different streams per object.
5. Origin and actor. Events carry `actor` and `origin` (user, cli, mcp, script, remote), so the UI
   can animate a remote change (another device, an agent) differently from the local user's own
   change, which was already shown optimistically.
6. Sizing. Terminal size is owned by the session host (spec 3.4): clients send
   `presence.set {viewport {cols, rows}, visible, active}`; the host computes the canonical grid by
   its policy and publishes it as a terminal field; the `presence` frame lists every attached
   client's viewport. The policy itself (minimum of visible viewports, the active client wins, or a
   per-terminal pin) is a host setting that the sync UX design chooses; the protocol needs no change
   for any of them.

Every workspace gets a conversation (`conv_…`, kind `workspace`) in ConversationDO at creation.
That is where the phone talks to the workspace and its agents with the Mac off; the Chief and
agents read and post there; the Mac shows the same thread. This is the "messages to a workspace"
path of the acceptance test.

## 6. Sync protocol

The protocol is `cmux.wire/1` as implemented by `backend/packages/ownership` and specified by
spec `sync-and-transport.md` section 3. This section lists only what this design adds or fixes.

### 6.1 Frames (unchanged)

Client: `hello`, `subscribe {stream, after_seq?}`, `unsubscribe`, `op {op, params,
idempotency_key, origin, expected_revision?}`, `snapshot.request {pending[]}`, `rpc` (at-most-once
runtime commands such as `terminal.input`), `presence.set`, `channel.open/credit/close`, and the
ephemeral producer frames `typing {on}`, `run.publish {run, steps}`, `live.publish {frame}`
(section 10.1).
Owner: `welcome`, `snapshot {stream, seq, state, decided[], rows?}`, `event {stream, seq, tx, op,
params, actor, origin, at, effects?}`, `result`, `reject`, `request-settled {stream, sequence,
ok}`, `owner.status {stream, status, since, cached_seq?}`, `presence`, `rpc.result`.

### 6.2 Client state machine (the Rust mirror, phase 1)

Per stream: `confirmed {state, seq}`, loaded rows, `pending` intents (ordered), `held` settles,
`buffered` events, `awaiting` flag. Rules (equal to `ProjectionClient`):

- An event with `seq = confirmed.seq + 1` applies. Row-mode owners send `effects {state, writes}`,
  which the mirror applies without running the reducer; JSON-mode streams carry the op, and a mirror
  that has no reducer for that domain asks for a snapshot instead (effects mode is the default for
  every new owner, so mirrors in any language need no reducers).
- `seq > confirmed.seq + 1` is a gap: buffer it and send `snapshot.request {pending keys}`.
- `request-settled ok` settles an intent only once the mirror reached its `sequence` (held until
  then), so the UI never flickers back to pre-op state.
- Snapshot: replace confirmed state and rows when `snap.seq >= confirmed.seq`, drop decided keys
  from `pending` and `expired`, then replay buffered events.
- A snapshot that does not decode: stay awaiting, keep the buffered events, and send `snapshot.request` again after a backoff (6 attempts after 250 ms, 500 ms, 1 s,
  2 s, 4 s and 8 s; the delay is capped at 30 s). After the last attempt the connection is dropped
  and the next one subscribes again. The failure count carries over (except when another principal
  signs in, which resets the mirror) until a snapshot decodes or an event applies in order, so an
  owner that keeps sending a bad snapshot is asked once per connection and the transport's
  reconnect backoff paces it. A snapshot that decodes but that the relay cannot use counts as a
  failed one after the failures before it; it and an event the relay cannot use give no position
  (the buffered events they released are dropped, the next snapshot covers them), so the next
  connection subscribes fresh. An event that does not decode asks for a snapshot at once. The
  daemon's reconnect backoff resets only after a snapshot or event reached clients with no
  snapshot failing, not on `welcome`.
- Reconnect: resend every pending intent with its original key, then request a snapshot. Intents
  older than 24 h expire and are shown, never resent (owners keep decided keys 7 days).
- Visible state = confirmed + pending intents rendered from their params (a pending bubble, a
  greyed new tab). Optimistic local layout (Cmd+D) is the home's job, not the mirror's: the Mac
  daemon is the home of Mac layout.

### 6.3 Cursors, backfill, history

- Resume: `subscribe {after_seq}`; the owner replays from its event window (30 days or 10,000
  events, E3) or answers a snapshot when the cursor is older.
- Row-backed history: a snapshot carries the newest rows (message tail); older pages come from the
  read `conversation.history {before_seq, limit}`. Add `conversation.since {after_seq, limit}`
  (asked in `ownership-v2.md` 3.4) so a client catching up on a conversation it is not subscribed
  to needs no socket.
- Inbox-driven catch-up: a client subscribes to `inbox:<u>` always and to at most N hot
  conversations; `inbox.bump {last_seq}` tells it which conversations moved; it fetches ranges.
- Host replicas: `HostDO` serves `subscribe host:<h>/session`, `doc:<ws>`, `host:<h>/acp` from its
  stored snapshot and tail when the host is offline, with `owner.status offline, cached_seq`. When
  the host reconnects it sends `resume {stream: last_published_seq}`; the HostDO asks for what it
  lacks; clients receive the new events with no gap because the host's `seq` is the stream's `seq`.

### 6.4 Conflict rules

- Single writer per stream, so there are no concurrent writes to merge. Two devices that send
  conflicting intents get them ordered by the owner; the second may be rejected
  (`revision.conflict` with `expected_revision`, or a reducer rule).
- Commutative fields use commutative rules: read cursors are max; reactions are a set keyed by
  (author, part, kind); inbox bumps apply only with a newer `rev`.
- Layout ops carry the ids they act on (pane id, tab id), never indexes, so an op on a moved tab
  still applies or is rejected with a reason (`cmux-layout-reducer` already rejects unknown ids).

### 6.5 Offline behavior (U5 and one proposed exception)

- Owner unreachable (no network, or the host is off): the op is refused at once with
  `owner_unreachable`; the control is disabled and says why ("Your Mac is offline since 21:04").
  Intents sent before the drop stay pending and are resent on reconnect with the same key.
- Drafts are per device and never lost.
- Proposed exception (decision L2): `message.send` may wait in the device outbox while the device
  itself has no network, because ConversationDO dedupes by `client_msg_id` and a message is an
  append (no invariant can be broken by sending it later). The bubble shows "Waiting for network",
  and the intent TTL (24 h) still applies. This matches what people expect from Messages and what
  cnx's Chief outbox already does, but it relaxes U5, so Lawrence decides.
- Taken exception, the Mac Chief mailbox (user request 2026-10-21, "handle the case if my macbook
  is offline"; cmux-prompts logs/iphone-chief-DESIGN.md): `conversation.message.send` on a host's
  `host:<h>/chief` stream with the host offline is kept by HostDO (one entry per idempotency key,
  200 per host, 7 days) and answered `op.queued`; the next publisher gets the kept ops in order with
  `to: "mailbox"`, and its `request-settled` removes each. The host dedupes by key, so a message is
  delivered once. Every other offline op is still refused.

## 7. Who is authoritative for what

| Data | Authority | Mac off | Phone offline (no network) |
| --- | --- | --- | --- |
| Conversations, messages, reactions, cursors | ConversationDO | phone reads and writes | phone reads its cache; send refused (or queued, L2) |
| Inbox, unread, pins | UserDO | works | cache |
| Chief records, wake queue, cloud brain | UserDO, MuxDO, ChiefBrainDO | works | cache |
| Workspace records (list, titles, status) | TeamDO directory; status fields published by the home | list works, Mac rows show `offline since` | cache |
| Mac workspace layout | the Mac daemon; replica in HostDO | read-only replica | cache |
| Cloud workspace layout | DocDO | works | cache |
| Terminals on the Mac | the Mac daemon | title, cwd, last screen (64 KiB), `offline since`; no input | cache |
| acpmux sessions on the Mac | the Mac daemon | session list, last turn summary, transcript window from the replica; no new turn | cache |
| Agent work on cloud hands | HandDO | works | cache |
| Files on the Mac | the Mac | unavailable (honest), except attachments already uploaded to R2 | |

The Mac is one more client of every DO stream, plus the executor for what only it can do: it owns
its PTYs, files, local agents and its workspaces' layout, publishes their replicas, and answers
requests routed to it through `HostDO` (`rpc`, `channel.open`) and `HandDO` (`req`).

## 8. Transport

- Control plane: one WebSocket per device. Target: the `UserDO` gateway multiplexing every stream
  the device subscribes to (spec 5). Today: one socket per owner (`/v1/wire/user`, `/v1/wire/conv/<id>`,
  ...). Phase 3 adds the gateway; the frames already carry `stream`, so clients only change the URL.
  Hibernation keeps idle sockets free; WebSocket pings are runtime auto-responses (no DO wake).
- The Mac daemon keeps one outbound socket to its `HostDO` (it exists for the relay) and adds the
  publisher role: it pushes events of its host-homed streams, answers forwarded ops and `rpc`, and
  serves `channel.open`. No inbound port, no pairing step for state.
- Data plane for live bytes: a channel ticket minted by `UserDO` (`/v1/wire/ticket` exists) opens a
  WebSocket to `HostDO`, which splices it to a link sub-channel on the host. Fast path: when the
  phone and the Mac can reach each other (same LAN, punched UDP, TURN), the same channel rides an
  end-to-end WireGuard session (`cmux-wg`, cnx's roaming and lanes). The channel's identity,
  ticket and framing do not change with the path. Why keep a direct path at all: terminal echo
  latency (measured TURN 16 ms vs a far Worker relay 240 to 345 ms on 2026-10-13; the HostDO is
  placed near the host per `transport.md` 6, so relay cost is mostly the triangle) and video
  volume (DO relay billing per message). Why not more: everything else is small, ordered and must
  work with the Mac off, so it belongs to owners.
- Why not WebRTC as well: one userspace WireGuard stack serves the phone, the Mac, Linux and Cloud
  VMs (`transport.md`), so a second transport doubles the test surface for no new path. cnx's
  WebRTC carrier can stay until the WireGuard path covers the same networks (decision L5).

## 9. Auth, devices and teams

- Identity: Stack Auth session (human) or install token (device, daemon), verified by the Worker.
  Principals are built only by the Worker and never read from frames (`types.ts` Principal).
- Devices are installs in UserDO (`install_kind` mac, ios, daemon, web, vm). The cnx `devices`
  table, `TeamHub` presence and `cnx-ios-api` device routes are replaced by install records, HostDO
  presence and TeamDO's host directory.
- The Mac daemon is enrolled once by the Mac app (`install.enroll_local {daemon_pubkey}`,
  `ownership-v2.md` 3.4) and mints short-lived tokens by challenge. It never holds the Stack
  session.
- Phone keys: keep cnx's Secure Enclave identity key and Face ID approval key, registered on the
  phone's install record. Approval-required ops (Chief question answers that execute, money and
  destructive ops) carry an approval signature that the owner checks; the Mac no longer has to be
  the checker, because the owner is.
- Reach to a host: TeamDO compiles which installs may reach which host (same user by default,
  team policy later). HostDO admits relay and channel sockets only for those installs. The Mac's
  WireGuard still drops unknown keys.
- Teams: TeamDO members and roles; a personal account is a team of one; no project-prefixed
  owner keys (one Stack project per environment).

## 10. Chief

- A Chief is an agent principal (`agent_…`, class `mux`) with a record in UserDO and a MuxDO.
  ConversationDO wakes it (`mux.wake` on DM, mention, reply). MuxDO decides which brain runs:
  the cloud brain (ChiefBrainDO, pi-durable) or a local brain on a host that holds the lease.
- Both brains are ordinary clients of ConversationDO: they read with `conversation.snapshot` /
  `since`, post with `message.send` under the agent principal, stream progress as `run` events
  (`run.live`, `step.delta` in PR 20993). The phone needs no Chief-specific path: a Chief thread is a
  conversation.
- One memory per Chief: today `brainName = agent/conversation` gives one OptChat memory per
  (chief, conversation). The standing rule says one memory per Chief across all its conversations.
  Recommendation for the brain lane (not changed here): one ChiefBrainDO per agent, conversations as
  inputs of that one memory, runs keyed by `(agent, conversation, seq)`.
- The Mac Chief over the cnx `chief` channel is retired: the local Rust brain posts to the same
  ConversationDO thread through the daemon's cloud sync, so there is one thread and one outbox.
- Hands: the Chief's tools call HandDO (cloud sandboxes, VMs) or the Mac's acpmux hand. With the Mac
  off, a Mac hand answers `offline` and the Chief can choose a cloud hand.

### 10.1 The Mac mini Chief on `cmux.wire/1` (live runs, run steps, typing)

Today a local Chief brain (optchat-chief on a Mac mini, through the daemon proxy) can commit
messages to a cloud conversation, but it cannot show its work. `CloudPort`
(`Native/OptChat/optchat-chief/src/cloud/port.rs`) answers `typing_unsupported` and
`drafts_unsupported`, and inherits `runs_unsupported` (`run_append`) and `live_unsupported`
(`live_publish`) from the `ConversationPort` defaults. The only producer of run changes and live
frames in the cloud is the internal Worker RPC `ConversationDO.agentFrame(entity, agent, {typing} |
{run, steps} | {live})` (`backend/apps/api/src/conversation-do.ts`), which only `ChiefBrainDO`
can call. Result: on the phone the cloud Chief streams its reply and shows steps; the Mac mini
Chief is silent until its message commits.

Decision: the agent's needs are frames of `cmux.wire/1` on the conversation socket. There is no
agent-only path: the frames are the same for every producer, and the owner's authorization rule
decides who may send them.

| Need | Frame from the producer (conversation socket) | What members receive | Kept |
| --- | --- | --- | --- |
| typing | `typing {on}` (exists today for every participant) | `conversation-typing {conversation, participant, on}` | never; gated by `typingGate` |
| run record and steps of the running turn | `run.publish {run, steps[]}` (`conversation-runs-v1` shapes) | `conversation-run-changed {conversation, run, steps}` | the live buffer only (as today) |
| live frames of the running turn | `live.publish {frame}` (`chief-live-v1`: `step.delta`, `run.activity`) | the frame (`t` = `type`), and the `run.live` snapshot on join, reconnect and `run.live.get` | the live buffer only |
| the reply draft | no separate frame: the streaming reply text is the `step.delta` live frame | as above | never |

Rules:

1. Ephemeral. These frames are not ops: no idempotency key, no ledger, no `seq`, never in the
   outbox or PlanetScale. A member that misses one asks for `run.live.get` or reads the run again.
   The committed reply is still a `message.send` op under the agent principal.
2. Admission is the owner's existing rule, applied to the socket principal: the principal is an
   agent participant of the conversation that has not left (the check `agentFrame` does today),
   with a per-agent rate limit like `typingGate`. A user principal sending `run.publish` or
   `live.publish` gets `error auth.forbidden`.
3. One implementation. `ConversationDO.onFrame` handles `typing`, `run.publish` and
   `live.publish` with one function; `agentFrame` becomes the in-Worker caller of that same
   function (ChiefBrainDO keeps its RPC as a transport, not as a second rule set).
4. The daemon relays, it does not interpret. The daemon proxy already has a per-target outbox for
   client frames on the conversation socket (`run.live.get`). It adds three commands for trusted
   local clients, `cloud-conversation-typing`, `cloud-conversation-run-publish` and
   `cloud-conversation-live-publish`, that put the frame in that outbox while the stream is live
   (refused with `cloud_unavailable` otherwise, never queued), advertised as
   `cloud-agent-frames-v1`. The socket's principal is the lease's (an agent lease on the Mac mini
   Chief host), so the owner's rule 2 applies with no daemon-side policy.
5. `CloudPort` implements `typing`, `run_append`, `live_publish` and `draft` (as a `step.delta`)
   over those commands when the daemon advertises `cloud-agent-frames-v1`, and keeps the
   `*_unsupported` answers otherwise.
6. The spec frame list (section 6.1 here, `sync-and-transport.md` section 3) gains `run.publish`
   and `live.publish` as client frames; `conversation-typing`, `conversation-run-changed` and the
   live frames are owner frames.

Done when: a Mac mini Chief turn shows typing, the streaming reply and run steps on the phone and
on the Mac exactly as a cloud Chief turn does, with the same frames, and `CloudPort` answers no
`*_unsupported` for these four needs against a backend that has the frames.

## 11. Mapping cnx onto this design

| cnx piece | Verdict | Why |
| --- | --- | --- |
| `cnx-ios-api` Worker (devices, macs, prefs, bootstrap, invites) | replace with `cloud-api` ops (UserDO installs, TeamDO hosts, team invites) | one identity and device model; no second Postgres |
| `TeamHub` presence | replace with HostDO presence + `host:` stream | presence belongs to the host object, and the replica lives there |
| `TeamHub` signaling | move to HostDO `candidates` frames (`transport.md` 6) | same function, keyed by host, admitted by TeamDO reachability |
| `TeamHub` relay | merge into HostDO relay | the frame formats are equivalent; one relay |
| `cnx-link` WireGuard, roaming, TURN, lanes, media lane | keep as the data-plane fast path (`cmux-wg`/`cmux-link`) | well measured and principled |
| WebRTC carrier | keep until WireGuard covers the same networks, then delete (L5) | one transport stack |
| `cnx-hostd` `daemon` service (v12 lines over the link, allowlist) | replace | phone talks to owners through the wire; ops are authorized by owners, not by a line filter |
| `cnx-hostd` `chief` service | replace | Chief threads live in ConversationDO |
| `cnx-hostd` `acpmux` service | replace with `host:<h>/acp` stream + `rpc` through HostDO | same reasons; transcripts replicate |
| `cnx-hostd` `file`, `upload`, `browser` services | keep as channels (`channel.open kind file / screencast`) over HostDO or the direct path | bulk bytes |
| `policy.rs` + `DaemonLanePolicy.swift` | delete both | owners check ops; no line filters, no Swift policy |
| Pairing (`auth`, Secure Enclave keys, Mac TOFU) | keep the keys, move the checks to owners and HostDO admission | keys are good; the checker should not need the Mac to be on |
| APNs push (`notify`) | move to UserDO push queue (`home-messaging.md` 3) | pushes come from the owner that knows the event, Mac on or off |
| `WorkspaceSync.swift`, `LiveSnapshotStore`, `ChiefOutbox`, `ChiefCloudBackend.swift` | replace with the Rust mirror through uniffi | no Swift sync logic (MOBILE-RUST-1) |

## 12. Durable Object scale and cost

- Storage: 10 GB per object (SQLite). Conversations: p99 1M messages, about 2 GB (`home-messaging.md`
  6). HostDO replica: per host stream one snapshot plus a bounded tail (cap 10 MiB or 24 h per
  stream, 64 KiB screen per terminal), so a host with 200 terminals stays under 50 MB.
- Throughput: about 1,000 simple ops per second per object; about 4,000 relayed messages per second
  per HostDO (`transport.md` 13.4). Split by entity, never by user: a chatty Chief thread is one
  object; a team is not one object for messages.
- Fan-out: an event is sent to each subscribed socket of that object. Large fan-out (a 64-person
  group) is fine; anything bigger fans out through UserDO inbox bumps (coalesced per drain), not
  by sockets on one object.
- Hibernation: subscribers hibernate; pings auto-respond; an idle host costs about nothing
  (measured object eviction after 30 s, wake 15.5 ms p50). A DO with a pending alarm wakes only for
  that alarm.
- Alarms: one per object (AlarmSerial multiplexes): outbox drains, retention, owner-wake retries,
  HostDO offline detection grace. No alarm is a poll of another system except provider state
  repair in CloudDO.
- Cost: requests dominate; batching relay frames cuts billing about 12 times; a phone that is
  connected but idle costs nothing in duration. Video over the DO relay is the expensive case, which
  is why the direct path exists.

## 13. Security

- Identity only from the Worker; owners re-check membership and grants on every op.
- Replicas in HostDO are readable only by principals TeamDO allows for that host; the replica holds
  terminal screen text, which can contain secrets: it is encrypted at rest by Cloudflare, capped,
  never projected to PlanetScale, deletable by the owner (`host.replica.purge`), and can be turned
  off per host (decision L4).
- Push payloads stay content-minimized (cnx rule).
- Approval signatures (Face ID key) are checked by the owner that executes the op.
- Relay and channels carry WireGuard ciphertext or ticket-bound streams; HostDO cannot read relayed
  WireGuard datagrams; HostDO channel splices for the fallback path are TLS to the edge, plaintext
  inside the Worker (same trust as every op).
- No secrets in logs, tokens never in URLs (wire tickets for browsers).

## 14. Migration plan

| Phase | Work | Owner of the code | Done when |
| --- | --- | --- | --- |
| 1 | Rust stream mirror in `cmux-cloud-wire` (frames + mirror, effects mode), conformance vectors exported from the TS engine; bind in `cmux-mobile-ffi` | this lane (CORE paths in cmux-tui/crates) | Rust replays the same vectors as `ProjectionClient` with equal visible state and settles |
| 2 | The daemon's cloud sync uses the mirror (`cmux-tui-cloud-conversations` → subscribe + mirror, resume); the phone's Cloud Chief uses the same mirror through uniffi instead of `ChiefCloudBackend.swift` | daemon lane, iOS lane | PR 20993's Swift sync code deleted; Mac and phone render the same Chief thread from one engine |
| 3 | HostDO publisher: host-homed streams (`host:<h>/session`, `doc:<ws>`, `host:<h>/acp`) published by the daemon, snapshot + tail stored, `owner.status`; ops and `rpc` forwarded to the online host | backend + daemon | the phone lists Mac workspaces and terminals with the Mac off, marked offline |
| 4 | Workspace records in TeamDO, workspace conversations, `workspace.move_home`, DocDO for cloud-homed workspaces (layout reducer as WASM, like optchat) | backend | create a workspace on the phone with the Mac off; it appears on the Mac when it returns |
| 5 | UserDO gateway (one socket per device) | backend | phone and daemon use one socket |
| 6 | Data plane: channel tickets to HostDO for terminal bytes, then the WireGuard fast path from cnx (`cmux-wg`); retire `cnx-ios-api`, `TeamHub`, hostd `daemon`/`chief`/`acpmux` services, Swift policy | transport + iOS lanes | live terminal on the phone through HostDO and direct; cnx Worker deleted |

Phase 1, slice 1 (built 2026-10-18, branch `feat-cmux-next-object-sync`):

- `cmux-tui/crates/cmux-cloud-wire/src/frames.rs`: the socket frames (`event` with `effects`,
  `request-settled`, `snapshot` with `decided` and `rows`, `op`, `snapshot.request`).
- `cmux-tui/crates/cmux-cloud-wire/src/mirror.rs`: `StreamMirror`, the sans-I/O client engine
  (confirmed mirror, rows, intent log, held settles, gap buffer, reconnect resend, 24 h TTL, U5
  refusal), a port of `ProjectionClient`.
- `backend/packages/ownership/scripts/export-mirror-vectors.ts` writes
  `schemas/ownership-mirror/vectors.json`: 12 hand cases and 12 seeded runs of the REAL
  `ProjectionClient` against the REAL `OwnerEngine` (row mode, reordering, duplicates,
  disconnects, retries, a clock jump past the TTL), 754 steps; `bun run catalog:check` fails on
  drift. `tests/mirror_vectors.rs` replays every step and compares the frames sent and the whole
  client state after it. Result: `cargo test`, `clippy -D warnings` and `fmt --check` green on rbx.

Phase 1, slice 2 (built 2026-10-19):

- `cmux-cloud-wire` mirror gains the relay surface: `without_rows`, `PositionOnly`, `resume`
  (subscribe `after_seq` or buffer until the snapshot), `resync`, `reset` for a new principal, and
  `receive_applied` (the applied frames in order). Event and snapshot frames keep unknown fields,
  so a relay passes them on unchanged.
- `cmux-tui-cloud-conversations/src/stream.rs` keeps no position of its own: the daemon proxy uses
  `StreamMirror`. A behavior change: the events that arrive after a gap are buffered and reach
  clients after the snapshot (before, they were dropped until the next gap). The daemon test
  `a_gap_resyncs_replays_the_buffered_events_and_a_reconnect_resumes_after_them` was red before
  the change and is green after it. A snapshot behind the position replaces it only when it
  answers a resume (an owner that lost its tail); a gap buffers at most 1024 events.
- `cmux-mobile-ffi/src/ownership.rs`: `OwnershipMirror`, a uniffi object with a JSON-text surface
  (frames in and out as the socket carries them, `view()` for rendering). The change listener
  came in slice 3. `tests/ownership_vectors.rs` replays every
  vector through the exported surface.
- Next slice: the phone's Cloud Chief uses `OwnershipMirror` (phase 2, iOS lane) instead of its
  Swift stream code.

Phase 1, slice 3 (2026-10-19):

- A snapshot that does not decode no longer leaves a stream stuck. `StreamMirror::receive_value`
  handles a known frame whose fields do not decode: an event resyncs, a snapshot is asked for again
  after `SnapshotBackoff` (`snapshot_failed`, `snapshot_retry_at`, `snapshot_retry_due`), and after
  the last attempt it reports `SnapshotRetry::Exhausted`. The daemon proxy waits for the retry time
  in its receive timeout (no extra timer), drops the socket on exhaustion, and keeps its reconnect
  backoff while snapshots keep failing. Before, an undecodable snapshot was dropped and the stream
  waited for a snapshot that never came. Daemon tests
  `a_snapshot_that_does_not_decode_is_asked_for_again_and_the_stream_recovers` (red before, green
  after) and `a_snapshot_that_never_decodes_is_asked_for_a_bounded_number_of_times_then_the_stream_reconnects`.
- `OwnershipMirror::receive` takes `now_ms` and handles the same cases itself; `OwnershipStep`
  reports `snapshot_retry_at_ms` and `reconnect`, and `snapshot_retry_due` sends the request.
- The phone observes the mirror, it does not poll: `OwnershipMirrorListener` (uniffi foreign trait,
  `on_change(view)`) set with `OwnershipMirror::set_listener` is told once after every call that
  changed the view, after the lock is released, and never for a call that did not. `set_listener`
  returns the view at that moment, so no change falls between reading and listening. The view has a
  `generation` (one more per change; keep the highest when several threads call). `tests/ownership_vectors.rs` checks both rules on every step
  of every vector.

Phase 3, slice 1 (2026-10-19): the HostDO replica, backend side.

- `GET /v1/wire/host/<host>` (scope `host`, also for wire tickets). TeamDO names the role from the
  host record (`hostReplicaRole`): the install that enrolled the host is the publisher, the owner's
  other sessions and installs are readers, anyone else gets 403. A chief token gets 403 too (no
  chief needs the replica yet; the Mac mini Chief uses the conversation socket, section 10.1). An
  install token without an expiry gets 403. Team-shared hosts come with the TeamDO reach policy
  (section 9), not here.
- `backend/apps/api/src/host-replica/store.ts`: per stream the last published snapshot (decided keys
  stripped: they answer one client) and every event after it, in the host's `seq`. Events append
  only at `head + 1`; a gap or an over-full tail asks the host for one new snapshot. The tail is
  never trimmed by itself (a snapshot plus every later event is the only consistent answer): past
  1,000 events or 8 MiB it asks for a snapshot, at twice that it stops appending. Snapshot 1 MiB,
  512 streams per host, one event 256 KiB, stream names `host:<h>/...` or `doc:ws_...`, at most
  96 printable ASCII characters.
- `backend/apps/api/src/host-replica/wire.ts`: the publisher sends `publish {stream, snapshot |
  event}` and answers forwarded frames with their `to`; on connect it gets `welcome {heads}` (where
  to resume). Readers use the ordinary client frames: `subscribe {stream, after_seq?, pending?}`
  answers `owner.status {status, since, cached_seq}` and then the events after the cursor when the
  tail has all of them, else the snapshot and the whole tail. `op` and `snapshot.request` with
  pending keys go to the online host with the reader's principal; offline, an op gets
  `reject owner_unreachable` (retryable) and `request-settled ok:false` at once (U5). An op in
  flight when the publisher closes or is replaced gets the same refusal (the replica records each
  forwarded op until its `request-settled`; 64 per reader socket). Online means the current
  publisher's socket is open (its id is stored; a socket that vanished without a close counts as
  offline), and frames from a replaced publisher are ignored. A cursor ahead of the replica gets
  `owner.status` with the lower `cached_seq` and nothing else, so a reader never goes back.
  Presence changes go to every subscribed reader as `owner.status`. A reader subscribes at most 30
  times in 10 s. Sockets register in the user's UserDO (instant revocation, chief archive) and close
  at token expiry by alarm.
- A host that leaves its owner loses its replica (slice 1b): when TeamDO commits `host.remove`,
  `server.revoke`, or a member cleanup that orphans the member's hosts, it queues the host in its
  own SQL (`team-host-replica-drop.ts`, backoff per host) and calls `HostDO.dropReplica`. HostDO
  forgets every stored stream and closes every replica socket (4403). A removed or revoked host is
  also tombstoned (later upgrades get 410; the same install enrolls again under a new id). An
  orphaned host is not: it keeps its id, and its former owner may enroll it again after rejoining.
  The alarm retries a failed call; a replayed op queues nothing. `hostReplicaRole` gives an orphaned
  host, or a principal that is no longer a team member, no role. Known gap: an upgrade whose role
  was checked just before an orphaning can still open after the drop (no tombstone to stop it); it
  lives until its token expires or the install is revoked. A host epoch on the record would close
  it, when a reassign op exists. Tests: `test/host-replica.test.ts` (host removed) and
  `test/team-member-remove.test.ts` (owner left the team).
- Test: `backend/apps/api/test/host-replica.test.ts` drives the real Worker sockets (403 for a
  stranger; publish, live read, gap request, forwarded op and its settle, an op in flight refused
  when the host goes away, offline status, resume from the replica with the host off, offline
  refusal, a cursor ahead of the replica, another host's stream refused, heads on reconnect).
- The daemon publisher (slice 2, `cmux-tui-cloud-conversations/src/host_replica.rs` and
  `cmux-tui-core/src/server/cloud_host_replica.rs`, capability `cloud-host-replica-v1`): the
  verified app leases its install token (`cloud-host-replica-set`); the daemon enrolls the host,
  publishes `host:<h>/session` (the `list-workspaces` tree) and runs forwarded ops through its own
  command path. Only `workspace.rename` with fixed fields runs (remote relay default deny), only for
  the token's user, never for a principal with `agent`; the cloud key is namespaced per user in
  the daemon's idempotency store. The seq never goes back in one daemon, and a stream the replica
  does not hold starts at the wall clock (ms), so a reader's cursor from before a purge or a restart
  is always behind. The off switch L4 is `cloud-host-replica-clear {purge: true}`: the publisher
  sends `replica.purge`, HostDO refuses the ops in flight, forgets every stream and answers
  `replica.purged`. A host the cloud removed (410, 4403) stays off for that install until the app
  clears the replica; close 4000 (another socket of the install) waits for a new lease.
  Deliberate first step: each event carries the whole tree in `effects.state` (O(tree) per
  change, the cost section 1 names); diffs per workspace come when the tree has per-object revisions.
- The owner's delete (slice 3): `host.replica.purge {host}` is a TeamDO op for the host's owner
  only (no agent, not an orphaned host); it is audited and queues a drop without a tombstone, so
  HostDO forgets the stored streams and closes every replica socket (4403) also while the Mac is
  off. The host keeps its id. An open publisher's daemon then stays `forbidden` until the app
  clears the replica (the off switch or sign-out); a Mac that was off publishes again at its next
  lease while its own switch is on. Test: `test/host-replica.test.ts` (owner purge with the host
  off, a stranger refused, the install publishes again).
- The Swift lease caller (slice 3, `CmuxNextPhoneAccess/CloudHostReplicaFollower.swift`): L4 is
  `phone.cloudReplica` in Settings > Accounts > Phone Access, opt-in until #13742 decides the
  default; agents may not change it (`.privacy`). While it is on, the account is signed in, Cloud
  is allowed and the local daemon serves `cloud-host-replica-v1`, the app leases its install token
  (`cloud-host-replica-set`, `expires_at` from the JWT); off sends `clear {purge: true}`;
  sign-out clears; `cloud-host-replica-needed` invalidates the install token and leases again (a
  purge in flight leases and purges again: a lease resets a pending purge). User defaults name the
  account whose copy may exist until the daemon that was asked to purge shows `off`, so an off
  switch set while the app was closed, or a purge that did not finish, still purges later. A
  daemon restart on the same connection leases again. The daemon asks again every 30 s while its
  token is refused (a pending purge waits the same way; only a replaced socket, 4000, retries it
  after a backoff), and paces asks of one reason to one per 30 s across leases. Cost: the old token's socket still
  closes 4401 at its expiry after an in-place renewal, so each renewal (about every 8 minutes with
  10-minute install tokens) costs a reconnect and one full snapshot.
- Next slice: the phone's reader through `OwnershipMirror` (after the cnx-ios fold-in).

Each phase deletes what it replaces in the same change (no twins). Each phase lands on
`feat-cmux-next` in small slices as soon as its slice is green (Lawrence, 2026-10-18: "cut our
stuff into the main feature branch ASAP so there is no drift"); no phase lives on a side branch
for more than a day.

### 14.1 Folding `feat-cnx-ios` into `feat-cmux-next`

`feat-cnx-ios` lives apart today: its own `cnx-ios/` tree (app, CnxKit Swift packages, backend
Worker, Rust crates `link`, `hostd`, `ffi`, verify scripts) based on main. The fold makes it one
more client of the same backend and one Rust workspace, in this order:

1. Land as is, behind no flag, under `ios-next/` (or keep `cnx-ios/`) on `feat-cmux-next`: the
   app and CnxKit, with their own CI workflow. Nothing in the existing iOS app changes. This stops
   the drift first; the rest is ordinary refactoring on one branch.
2. Rust crates move into `cmux-tui/crates/` (`cnx-link` next to `cmux-link`/`cmux-wg`, `cnx-hostd`
   as a mode of the daemon's link process), which needs the chief's LOCK turn for `Cargo.lock`.
   Duplicates with `cmux-wg` are merged on one side, keeping cnx's measured roaming and lanes.
3. The phone's state paths switch one at a time to the shared Rust mirror (phase 2): Cloud Chief
   first (PR 20993's backend already is `cloud-api`), then workspaces from the host replica
   (phase 3), then acpmux transcripts. Each switch deletes the Swift sync code it replaces
   (`ChiefCloudBackend.swift`, `WorkspaceSync.swift`, `LiveSnapshotStore`, the outbox files).
4. Device, presence and push move from `cnx-ios-api` to `cloud-api` ops (installs, HostDO presence,
   UserDO push). The `cnx-ios-api` Worker and its Postgres database are deleted when no shipped
   build calls them (L3). The `cnx-ios/backend` folder is BSL server code like `backend/`; it must
   follow the same CLA rule when it moves.
5. The `daemon`, `chief` and `acpmux` hostd services and the twin `policy.rs` /
   `DaemonLanePolicy.swift` are deleted last, when no phone build uses them.

Abdulaziz owns the app and CnxKit; this lane owns the shared protocol and the Rust mirror; the
fold steps 1 and 2 need his agreement on paths and timing (decision L6).

## 15. Acceptance test

Setup: staging `cloud-api`, a tagged Mac build signed in as user U with a workspace W (homed on the
Mac, one terminal T running `top`), the phone build signed in as U, Chief C with the cloud brain.

1. Mac on: the phone shows W with the same title and status, T's live screen, and W's conversation.
   Measure: Mac title change visible on the phone in < 500 ms p95 (20 samples).
2. Power the Mac off (or stop its daemon and network).
   - Within 60 s the phone shows W and T as `offline since <time>`; T shows its last screen; the input
     field and new-tab controls for W say "Mac offline" (no spinner, no fake success).
   - The phone sends `m1` to W's conversation and `m2` to C. Both are committed (`request-settled ok`,
     `seq` assigned). C replies `r2` within 30 s (cloud brain).
   - The phone asks C to run a task on a cloud hand; the run shows progress events.
3. Power the Mac on.
   - Within 10 s of its daemon reconnecting, the Mac shows `m1`, `m2`, `r2` and the run at the same
     `seq` as the phone (compare stream heads).
   - W and T on the phone return to live; T accepts input.
4. Faults: kill the phone's socket during step 2's send; on reconnect the intent is resent with the
   same key and the message exists once (count rows by `client_msg_id`).

Pass = every step holds on 3 consecutive runs; the stream heads match; no duplicate messages.

## 16. Decisions for Lawrence

Status 2026-10-19 (coordinator): every item below uses its recommendation as the default.
Default, Lawrence can override. The coordinator reports an override to this lane.

| Item | Default in force |
| --- | --- |
| L1 | Mac workspace layout is owned by the Mac daemon; the cloud holds a read-only copy |
| L2 | only `message.send` waits in the device outbox while the device has no network; every other op is refused offline (U5) |
| L3 | retire `cnx-ios-api` and `TeamHub` after phase 6; the phone uses `cloud-api` for everything |
| L4 | the host's cloud object stores the last 64 KiB of each terminal screen, with a per-host off switch |
| L5 | keep WebRTC until WireGuard covers the same networks, then delete it |
| L6 | the chief's fold-in agent moves `feat-cnx-ios` into `feat-cmux-next`; this lane does not do a second fold (section 14.1 is input for that agent) |
| L7 | sidebar organization lives in the user's account (UserDO `sidebar` document) |


- L1 Where a Mac workspace's layout lives. Options: `on the Mac that runs its terminals, with a read-only copy in the cloud (Cmd+D stays instant and works offline; the phone cannot rearrange a Mac workspace while the Mac is off)` or `in the cloud (the phone can rearrange it with the Mac off; every Mac layout change needs the network)`. Recommendation: on the Mac.
- L2 Messages typed while the phone or Mac has no network. Options: `refuse Send and keep a draft (current rule U5)` or `queue only message sends in the device outbox and send them when the network returns (like Messages)`. Recommendation: queue message sends only.
- L3 The cnx Worker and TeamHub. Options: `retire cnx-ios-api and TeamHub after phase 6 and move the phone to cloud-api for everything` or `keep cnx-ios-api as a separate service for the phone tunnel`. Recommendation: retire.
- L4 Terminal screen copies in the cloud. Options: `store the last 64 KiB of each terminal screen in the host's cloud object so the phone can show it with the Mac off` or `store only titles and status, never screen text`. Recommendation: store it, with a per-host off switch.
- L5 Second transport. Options: `keep WebRTC next to WireGuard until WireGuard covers the same networks, then delete it` or `delete WebRTC now and use WireGuard plus the cloud relay only`. Recommendation: keep it until covered.

- L6 Where Abdulaziz's iPhone app lives. Options: `move feat-cnx-ios into feat-cmux-next now (one branch, one backend, its Rust crates into cmux-tui) and switch its sync paths to the shared Rust core one by one` or `keep feat-cnx-ios as a separate branch on main and only share the backend`. Recommendation: move it into feat-cmux-next now.
- L7 Where sidebar organization (host group order, collapsed and hidden hosts, workspace order) lives. Options: `in your account in the cloud, so every Mac, iPhone and web client of yours shows the same sidebar` or `on each Mac only, as data-model.md says today`. Recommendation: in your account (your words: "synced across the user's clients").

## 17. What this means for work in flight

- PR 20993 (CnxChief on `cloud-api`): correct direction; land it. Phase 2 replaces its Swift
  socket and outbox with the Rust mirror; its frame shapes stay.
- Chief brain production promote and unii parity: unaffected; the one-memory-per-Chief note
  (section 10) is for that lane to decide.
- Matched Mac build pairing with the phone today: unaffected for now; it rides cnx until phase 6.
  New features should not extend hostd's `daemon`/`chief` allowlists.
- `cmux-mobile-core` slice 2 (Home mirror) uses this design's mirror as its engine.
