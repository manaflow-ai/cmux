# cmux-next ownership v2: processes, owners, Home cache, cmux-acp

Status: proposal by the ownership v2 architect, 2026-10-03. For coordinator review; nothing here is
binding until decisions.md records it. Inputs: OWNERSHIP-PRINCIPLES.md (binding rules, unchanged by
this file), ownership.md, state-ownership.md, spec/00-overview.md section 4, decisions S8, H8, H15 to
H17, APP-R1, D5, D10, T2, P10, chief-mac.md, home-mac.md, home-messaging.md, feed.md, server.md,
transport.md. Code read at `origin/feat-cmux-next` f22f5449886.

Rules kept as is: one writer per entity, typed ops with idempotency keys, owners commit with a pure
reducer, clients are mirror + intent log, nothing queues while an owner is unreachable (U5), no
Swift code owns shared state (spec 00-overview section 4).

What this file changes: the process map (one per-machine daemon process instead of three), where Home
lives on a device (a Rust replica of the cloud owners inside the daemon, not a Swift client of the
DOs), the daemon's cloud identity (the daemon is its own install), and the acpmux -> cmux-acp rename.

## 0. Summary

1. One daemon process per machine: `cmux host run` (today `cmux-tui server`). It hosts owner actors as
   crates: session host, workspace store, cmux-acp (agent hub), cmux-home (Home replica + local
   conversation owner + drafts), chief, config, git/files, app supervisor, and the server roles. Each
   actor has its own SQLite file and its own writer. Actors call each other through typed in-process
   ports, never through the socket.
2. Separate processes stay only where a boundary is real: PTYs (one adoptable terminal-host process per
   PTY, already), agent harnesses (claude, codex children, already), app hosts (QuickJS sandbox), the
   browser host (JS VM, headless Chromium), the CUA app (its own TCC identity), the link (WireGuard key
   holder), Postgres on servers.
3. Every client is a projection over the daemon: the Mac app and TUI over the Unix socket, a web client
   over the daemon's authenticated local WebSocket, remote devices over the link. iOS has no daemon; it
   links the same Rust Home crate in-process (question L3).
4. The cloud DOs stay the owners of cloud state (ConversationDO, UserDO inbox, FeedDO, MuxDO, TeamDO).
   The daemon holds a replica: it caches, pages, searches and keeps the outbox and drafts. It never
   decides an op. Local-only conversations (D10) keep their owner in the daemon (`cmux-conversation`).
5. The daemon enrolls as its own install (D5 already lists "daemon per mini, daemon per VM"; this adds
   "daemon per Mac"). That removes APP-R1's cost and lets headless hosts sync Home and the feed.
6. One generic Rust cloud replica engine (`cmux-cloud-sync`) serves Home, the feed and later installs
   and app grants. Swift stops calling `/v1/ops` directly.

## 1. Ownership today (code at f22f5449886)

Processes today on a Mac with cmux-next: (1) the app; (2) the cmux-tui daemon, started by
`Packages/macOS/CmuxNext/Sources/CmuxNextDaemon/Launch/DaemonLauncher.swift` (`cmux-tui --session
cmux-app[-tag] server ensure`); (3) the acpmux daemon, started by
`Sources/CmuxNextAgentPane/AcpmuxDaemonLauncher.swift` (`acpmux daemon run --ready-fd 3`, its own
`~/.acpmux[/tags/<slug>]`, socket `acpmux.sock`, token WebSocket on `127.0.0.1:47811` or `:0`); (4) the
Bun mux brain host, started by `Sources/CmuxNextApp/Home/HomeBrainHost.swift` from
`CMUX_NEXT_MUX_HOST`, which can start acpmux a second way (`mux/host/src/acpmux-daemon.ts`); plus
per-PTY terminal hosts, agent harness children, the CEF helpers, and (designed) the browser host,
app hosts and `cmux-feed serve`.

| State | Writer today (process, module) | Readers | Duplicates, second writers, gaps |
| --- | --- | --- | --- |
| Workspaces, screens, columns, panes, tabs, groups, pins, window records | cmux-tui daemon, `cmux-tui-core::state` + `mux.rs` + `workspace_registry` (SQLite) | app (`CmuxNextDaemon` `DaemonStore`), TUI, CLI | app second copies listed in ownership.md 5.1 (sidebar model, tab strip overrides, LayoutModel overrides, pendingClosed/pendingSelect); `DaemonStore.placeWorkspace` re-implements `presentation.rs move_workspace_to_group`; session host and store not yet split |
| Terminals (PTY, output, cwd, title, exit) | per-PTY terminal host process (`terminal_host_runtime`), registry in the daemon | app, TUI, CLI | death inferred on host loss (ownership.md 5.2) |
| Browser tabs | record: daemon store; runtime: app (`CmuxNextBrowser`, CEF/WebKit) | app, CLI | single-writer check on the record is client-enforced (state-ownership.md 7) |
| Agent sessions, turns, queue, permissions and rules, transcripts, handoff/adopt | acpmux daemon, `cmux-tui/crates/acpmux/src/hub/*`, files `$ACPMUX_HOME/sessions/<id>/session.json` + `events/NNNNNN.ndjson` (no SQLite) | agent pane webview (direct token WebSocket, `webviews/src/agent-session/acpmux/direct.ts`), app (`AcpmuxStatusClient.swift`), Bun brain host, `cmux acp`, agents (`ACPMUX_SOCKET`) | second agent-session notion in the cmux-tui daemon: `cmux-tui-core/src/agent_hooks.rs` keeps native-harness `agent_session_id`/parent/root from hooks; conversation parts cache acpmux status and reply previews (`CmuxNextDaemon/Conversations/ConversationPart.swift:23`); home and launch logic in three languages (Rust `acpmux/src/config.rs`, Swift `AcpmuxEnvironment.swift`, TS `mux/host/src/paths.ts`); daemon start logic in three places |
| Checkpoints | git refs `refs/cmux/checkpoints/*`, session-host git owner (checkpoints-rewind.md) | acpmux handoff, agent pane | git status/diff served by acpmux today, moving to the session host (#16941, S8) |
| Local conversations (D10) | cmux-tui daemon, `cmux-tui-core/src/conversation_store.rs` (`conversations.sqlite3`), reducer `cmux-conversation`, search `conversation_search.rs` | app `CmuxNextApp/Home/HomeService.swift` + `HomeConversationSession.swift`, Bun brain host | two Swift Home client stacks: `HomeService`/`HomeConversationSession` (mirror + intent log over the daemon) and `Packages/Shared/CmuxHomeCore` `HomeStore`/`HomeMirror`/`IntentLog` behind the `HomeSource` seam, whose only implementation is `MockHomeSource` |
| Cloud conversations, inbox, unread, read cursors | ConversationDO, UserDO `inbox:` stream (backend/apps/api/src) | no Mac or iOS client yet: no Swift or Rust code calls `/v1/wire/conv`; iOS `AppContainer.swift:94` uses `HomeStore(source: MockHomeSource())` | a cloud client would be a third Swift Home stack if built in Swift |
| Drafts | nobody (home-mac.md 3 calls the composer draft client view state, never persisted) | | conflicts with H17 |
| Chief brain | Bun process `mux/host` (TS), token minted by the app (`HomeService.homeDidOpen`) | | chief-mac.md moves it into the daemon (capability `chief-v1`) |
| Feed items | FeedDO (`backend/apps/api/src/feed-do.ts`, `domains/feed.ts`) | Mac `CmuxNextFeed/Wire/CloudFeedSource.swift` over `/v1/wire/feed` with the Stack token | second writer: `CmuxNextApp/Feed/FeedNotificationBridge.swift` copies each daemon notification into FeedDO because only the app holds a cloud credential; notifications while the app is closed are lost |
| Terminal notifications, rings, badges | cmux-tui daemon notification ledger (`terminal_metadata.rs` OSC 9/777/99, `mux.rs` sources and reads) | app, CLI | overlaps the feed (above) |
| Settings | Swift app, `CmuxNextSettings/CmuxConfigFile.swift` writes `~/.config/cmux/cmux.json`; `cmux settings` routes to the app socket | cmux-tui reads `mcp.enabled` (`cmux-tui/src/cli/mcp/config.rs`); MDM via `ManagedPreferences.swift` | TUI keeps a second file `~/.config/cmux/cmux-tui.json` with overlapping theme keys (`cmux-tui/src/config.rs`); the daemon cannot write settings without the app |
| Identity, credentials | Mac app: Stack session in Keychain (`CmuxNextCloud/Auth/CloudAuth.swift`), no install token yet on the Mac; iOS: Secure Enclave install key (`CmuxiOSIdentity`, `CmuxInstallAuthCore`); acpmux: WebSocket token in `$ACPMUX_HOME/config.json`; mux host: agent token file; daemon: none (`server.rs:5223` "this daemon has no Stack session"); `cmux-remote/identity.rs` own device identity | | APP-R1 keeps every cloud op in the app; four unrelated credential stores |
| Pairing, machines | TeamDO server directory (`domains/team-servers.ts`), PairingDO per code; mobile pairing in the daemon's in-memory `PairingBroker` (`cmux-tui-core/src/pairing.rs`) | Mac `CmuxNextApp/Cloud/MachineRegistry.swift` | machine registry assembled in Swift from three sources: `/api/vm` (old Next.js API), SSH saved hosts (daemon projection), local daemon; iOS keeps its own paired-Mac SQLite and `CmuxSyncStore` |
| Tunnels | `cmux-wg`, `cmux-remote`, `cmux-relay`, HostDO relay | | link process not yet separate |
| Apps, scenes | Rust `cmux-app-manifest` (v2 validator), `cmux-app-host` (QuickJS planned) | | Swift duplicates: `CmuxNextApps/Manifest/AppManifestValidator.swift` (v1), JavaScriptCore `Engine/AppEngine.swift`, `Registry/AppRegistryFile.swift` (stand-in for UserDO/TeamDO installs), scenes owned by Swift |
| Browser history, bookmarks | daemon (`frontend_browser_history.rs`, `bookmarks.rs`) | app | Swift `CmuxNextHistory/BrowserVisitLog.swift` writes its own `History.sqlite` per profile; `BookmarkFileStore.swift` JSON fallback |

### 1a. Patterns behind the duplicates

1. The app holds the only cloud credential on the Mac, so every cloud path runs through Swift (feed
   bridge, feed source, machine registry, planned Home cloud client). Headless hosts cannot do cloud
   work at all. Root cause: no daemon install identity (APP-R1).
2. Client stores are copied per surface: three intent-log implementations (`DaemonStore/IntentLog.swift`,
   `CmuxNextDaemon/Conversations` `ConversationIntentLog`, `CmuxHomeCore/Store/IntentLog.swift`); unread
   math in four places (`CmuxHomeCore/Model/Conversation.swift:83`, Mac `ConversationSummary.swift:57`,
   home-core, Rust `Summary.read_cursors`).
3. Process lifecycle logic is copied per language: three launchers and three home/path resolvers for
   acpmux (Rust, Swift, TS).
4. Rust and TS both implement the conversation reducer (`cmux-conversation`, home-core), held equal by
   the conformance corpus. This one is intended (cloud owner in TS, local owner in Rust, D-H2) and
   stays; the corpus must also cover cloud head fields the replica reads.
5. Session host and agent hub each keep an agent-session notion (`agent_hooks.rs` vs acpmux hub).

## 2. Target: processes and owners

### 2.1 First principles

1. Ownership is per entity, not per process. A process boundary is worth its cost only for one of:
   privilege or OS identity (TCC, sandbox, key custody), crash or resource isolation of untrusted or
   heavy code, or a lifecycle that must differ (outlive a restart).
2. Owners that call each other often belong in one process with typed ports: chief needs Home and
   agents in-process (H8); cmux-acp needs launch credentials, login environment (D26) and git/files
   from the session host (S8); Home needs the daemon's identity and the feed's transport.
3. The logic lives once, in Rust. Swift, TS web and the TUI render and send intents. The only
   exceptions are the cloud owners (TS home-core in DOs) and the conformance corpora that keep the two
   reducer languages equal.
4. A device holds replicas of cloud state, never a second owner. A local owner exists only for
   entities whose home is that machine (local conversations, local feed items, layouts homed there).

### 2.2 Process map (every machine)

```
 clients: Mac app (Swift) | TUI | CLI | MCP server (cmux mcp serve) | web client | remote devices
            Unix socket (same uid)      local WebSocket (per-launch secret, Origin/Host)    link
                          \                    |                                     /
 ┌───────────────────────── cmux host run  (one process, the `cmux` binary) ─────────────────────────┐
 │ router: one catalog, op family -> owner actor (owner_for), auth + actor stamp, events fan-out      │
 │ session    terminals registry, presence, grid, input order        terminals.sqlite3 (registry)    │
 │ store      layout documents, window records, browser tab records   workspace registry + journal    │
 │ acp        cmux-acp hub: agent sessions, turns, queue, permissions, transcripts, agent registry   │
 │ home       Home replica of cloud owners + local conversation owner + drafts + outbox + search    │
 │ chief      Rust brain host (ports into home and acp)                                              │
 │ sync       cmux-cloud-sync: install identity, token refresh, UserDO/FeedDO/conv sockets, ops     │
 │ config     cmux.json + managed prefs, schema-validated writes                                      │
 │ git/files  git status/diff, checkpoints, file search (S8)                                          │
 │ apps       app supervisor (installs/grants projection, op routing, provider channel to the app)   │
 │ server     postgres, health, updater (servers and team VM only)                                    │
 └────────────────────────────────────────────────────────────────────────────────────────────────────┘
  children: terminal hosts (1 per PTY) | agent harnesses | app hosts (QuickJS) | browser host | feed app
  separate: cmux link (WireGuard key, HostDO socket) | cmux Computer Use.app (TCC)
```

### 2.3 Owner table (target)

| State | Owner (single writer) | Where | Clients reach it by | Cloud relation |
| --- | --- | --- | --- | --- |
| Terminals | session actor + terminal host process | machine that runs the PTY | socket; remote via link | none (HostDO caches a read-only tail for offline hosts) |
| Layout, window records, browser tab records | store actor | the document's home (D2): the user's Mac now, `DocDO` later | socket; iOS via link | DocDO sequences synced documents (D2); device replica forwards ops |
| Browser runtime | the Mac app that renders the page | app | n/a | none |
| Agent sessions, turns, queue, permissions, transcripts, agent registry (ACP and hook-reported terminal agents) | acp actor (cmux-acp) | machine where the agent runs | ACP over the same socket (or `acp.sock` during migration); remote via link | none; Home `work` parts reference `{host, session}` |
| Checkpoints, git, file search | git/files actor | machine with the repo | socket | none |
| Cloud conversations, messages, reactions, read cursors | ConversationDO | cloud | daemon replica (home actor) | replica: owner -> daemon events, daemon -> owner ops |
| Inbox entries, unread, pins, mutes | UserDO `inbox:` | cloud | daemon replica | same |
| Local conversations (D10) | home actor, local owner (`cmux-conversation` reducer) | that Mac | socket | `conversation.promote` hands over to a ConversationDO (chief-mac.md 6) |
| Drafts (H17) | home actor, per device | each daemon | `home.draft.*` | never synced (question L4) |
| Outbox (sent, unacked cloud ops) | home actor / sync actor, per device | each daemon | read-only projection (pending rows) | resent with the same keys |
| Chief wake queue, cloud brain | MuxDO | cloud | | local brain holds a lease (`brain_host`) |
| Chief local brain | chief actor | the lease holder | catalog `chief.*` | subscribes to `mux:<agent>` |
| Feed items | FeedDO; `local:<install>` items by the local feed server until handoff (feed.md 5) | cloud / machine | daemon replica (sync actor) | replica, same engine as Home |
| Settings (cmux.json, managed prefs) | config actor | each machine | `settings.*` ops | device settings from team policy (E9) are inputs, not a second writer |
| Install identity (daemon) | sync actor; key in Keychain (macOS) or 0600 file (Linux) | each daemon | never exported | TeamDO/UserDO own the install record and grants |
| Install identity (app), Stack session | app (Keychain) | app | | |
| Host records, network policy | TeamDO | cloud | link + sync actor | replica |
| WireGuard key, overlay sessions | link | each machine | link sockets (transport.md 12a) | HostDO relay |
| App installs, grants | UserDO / TeamDO | cloud | apps supervisor replica | replica |
| App runtime state | app host process (per app) | machine | provider channel | |

### 2.4 Wires

- In-process: actor ports are Rust traits (`ConversationPort`, `AgentSessionPort`, `CloudPort`,
  `GitPort`), the pattern chief-mac.md 2 already uses. No actor reads another actor's tables.
- Local clients: one Unix socket, one catalog (D7). Framing stays line JSON `cmux.protocol/2` for cmux
  ops. ACP clients keep JSON-RPC: during migration the same process also listens on `acp.sock` and the
  existing token WebSocket; the end state is protocol negotiation at hello on the one socket.
- Web clients: one daemon WebSocket listener (127.0.0.1, per-launch secret, Origin/Host checks;
  identity-and-permissions.md 3), serving the same catalog. It replaces acpmux's `:47811` listener.
  The agent pane webview uses it through the native bridge handshake as today.
- Remote: other machines' daemons through `cmux link` (T2, transport.md 12). Daemons never connect to
  each other for state (L12-1 bulk copies excepted).
- Cloud: only the sync actor speaks to the API Worker (`/v1/wire/*`, `/v1/ops`, `/v1/read`). The app
  keeps only sign-in, install enrollment approval and pushes (iOS).

### 2.5 Remote hosts, Linux, Cloud VMs

- Every machine runs the same `cmux host run`; roles come from config (server.md 3). A Linux host or
  VM runs session, acp, git/files, apps; store only for its own TUI users (ownership.md summary 5).
- Agents run where the code is. An agent pane on the Mac showing a VM agent talks to the VM's acp
  actor through the link (`owner_for(acp session) = its host`). The Mac never mirrors a VM's agent
  sessions into its own acp actor.
- Home on a Linux host or VM: the home actor starts lazily, only when a local client subscribes or the
  host holds a chief lease. A team VM may hold the lease for a team chief.
- Two daemons that cache the same user (Mac + Linux host): both are replicas. Neither decides ops.
  Each has its own outbox with keys `<install>:<ulid>`, so the cloud ledger never confuses them. Read
  cursors are monotonic max (commutative). Drafts are per device. Local conversations are owned by one
  daemon (`local:<install>`) and are invisible elsewhere until promoted. Pushes come only from the
  cloud, so a second daemon never double-notifies. Exactly one daemon runs a chief's local brain
  (MuxDO lease).

### 2.6 Strongest objection and answer

Objection: one process puts terminals, agents, Home sync and chief in one blast radius and one upgrade
unit. A panic in the Home sync engine or the ACP hub kills the daemon that every window depends on,
and Leo's team loses an independent acpmux release cadence.

Answer:
1. The expensive state survives a daemon restart already: PTYs live in per-terminal host processes
   that the daemon re-adopts (`terminal_host.rs`: "each PTY lives in an independently adoptable
   process"); agent harnesses are child processes; every actor's state is in SQLite or append-only
   files. A daemon restart costs a reconnect, not a lost terminal or agent turn. The restart path must
   be tested (slice 2 adds the test).
2. Actor isolation inside the process: each actor runs on its own task set behind `catch_unwind` with a
   supervisor that restarts that actor; a panicking actor returns `owner.status offline` for its op
   family only. Release builds keep `panic = "unwind"` for this.
3. Release cadence is already one binary (S8, P10: the bundled daemon is built from the same commit as
   the app). Two processes from one binary add start races (three launchers today), fixed sleeps
   (state-ownership.md 4.5) and token handoffs without adding independence.
4. The boundary stays cheap to restore: every actor is a crate behind ports, so `cmux acp daemon run`
   keeps working as a standalone mode for tests and for users who run cmux-acp without cmux.

Second objection: a socket hop per transcript read makes Home slower than a Swift-embedded store.
Answer: the Swift `HomeStore` keeps its in-memory mirror; the socket carries only snapshots, pages and
deltas (a 60-message page is about 30 KB; a Unix socket round trip is tens of microseconds). This is
the Messages architecture on Apple platforms: Messages.app is a client of the `imagent` daemon, which
owns the message database.

## 3. Home cache and DO sync (H15 to H17)

### 3.1 Crates

| Crate | Kind | Contents |
| --- | --- | --- |
| `cmux-conversation` (exists) | pure | local owner reducer; conformance corpus `conversation-cases.json` |
| `cmux-home-replica` (new) | pure, no I/O | replica reducer: apply owner events per stream by seq, gap detection, page merge into segments, pending outbox rows, unread overlay, draft rules, eviction choice. Property tests: replica converges to owner state for any delivery order with gaps and duplicates (invariant 4) |
| `cmux-cloud-sync` (new) | I/O | install key + challenge/token refresh, UserDO gateway socket (`user:`, `inbox:`), FeedDO socket, per-conversation sockets, `/v1/ops` with idempotency keys, `/v1/read`, reconnect with resume, `owner.status`. Generic over streams; Home and feed plug in |
| `cmux-home` (new) | I/O, daemon actor | the home actor: `home-cache.sqlite3`, the local conversation owner (moved from `cmux-tui-core/src/conversation_store.rs`, `conversation_search.rs`, `server/conversations.rs`), the `home.*` socket API, search |
| `cmux-chief` (chief-mac.md) | pure + daemon shell | unchanged design; its ports point at `cmux-home` and `cmux-acp` in-process |

### 3.2 SQLite schema outline (`home-cache.sqlite3`, one file per signed-in account per daemon)

```
account(user_id PK, install_id, team_id, signed_in_at)
stream(stream PK, seq, snapshot_rev, status, last_event_at)          -- user:, inbox:, conv:<id>
inbox_entry(conversation PK, kind, title, last_seq, last_at, preview, unread, mentions, dm_peer,
            pinned, pin_position, muted_until, archived, marked_unread, rev)
conversation(id PK, owner_kind 'cloud'|'local', head_json, rev, participants_json,
             my_read_seq, history_visible_from_seq)
segment(conversation, low_seq, high_seq, PRIMARY KEY(conversation, low_seq))  -- contiguous cached ranges
message(conversation, seq, id UNIQUE, author, created_at, parts_json, edited_at, retracted,
        reactions_json, last_access, PRIMARY KEY(conversation, seq))
message_fts(fts5 trigram over message text, content=message)
read_cursor(conversation, participant, seq, PRIMARY KEY(conversation, participant))
outbox(key PK, conversation, op, params_json, state 'sending'|'failed', attempts, created_at, error)
draft(conversation PK, text, parts_json, updated_at)
```

Local conversations keep their own owner file `conversations.sqlite3` (owner tables and ledger);
`home-cache.sqlite3` holds only replica data. One writer per file.

### 3.3 Socket API (catalog family `home`, owner `home`)

Maps 1:1 onto `CmuxHomeCore.HomeSource`, so the Mac data protocol in home-mac.md is served unchanged:
`HomeStore` (Swift) gets a new `DaemonHomeSource`; the view still reads only `HomeStore`.

| Op | HomeSource method | Notes |
| --- | --- | --- |
| `home.subscribe {streams?}` -> events `home.connection`, `home.inbox`, `home.conversation`, `home.message`, `home.typing`, `home.outbox` | `events()` | first `connection`, then `inbox`; events carry stream and seq |
| `home.inbox.list` | `inbox()` | from cache; marks `stale` while offline |
| `home.conversation.snapshot {conversation, tail}` | `snapshot(of:tail:)` | served from cache; fetches from the owner when the cached tail is short; includes this device's pending outbox rows (`delivery: pending`) |
| `home.conversation.history {conversation, before_seq, limit}` | `history(...)` | cache first; a miss fetches `conversation.history` from the DO, stores it as a segment, then answers |
| `home.op {op, params, idempotency_key}` | `submit(_:)` | routes by owner kind: local owner or outbox -> DO. Refused with `owner_offline` when the DO link is down (U5). Returns `accepted` (in outbox) then the commit arrives as an event |
| `home.draft.get/set/clear {conversation}` | new | per device; `set` coalesces in the writer (no timer) |
| `home.search {q, conversation?, limit}` | `search(...)` | local FTS5 first (marked `partial`), then cloud `home.search` merged by message id when online |
| `home.contact.resolve` | `resolve(_:)` | passthrough read to the DO |
| `home.counts` | new | badge totals for the dock and sidebar |

The Swift `IntentLog` keeps only intents in flight to the local socket (sub-millisecond); the durable
pending state is the daemon's outbox. `HomeService` and `HomeConversationSession` (the second Swift
stack) are deleted.

### 3.4 Sync protocol with the DOs

- Always on while signed in: one UserDO gateway WebSocket (`/v1/wire/user`, streams `user:` and
  `inbox:`), resumed with the last seq; a gap or a pruned resume (E3: 30 days or 10,000 events) gets a
  snapshot.
- Hot conversations get `GET /v1/wire/conv/<id>` (snapshot with `tail`, resume with `after_seq`): those
  open in any client view (presence from the clients) plus the newest unread ones, capped (default 8
  sockets). Others catch up on `inbox.bump`: the bump carries `last_seq`; the daemon fetches the
  missing range. Backend ask: a read `conversation.since {after_seq, limit}` so catch-up needs no
  socket (today `conversation.history` pages only backwards).
- Ops: `POST /v1/ops` with the outbox key; the commit returns through the socket; a lost reply is
  resent with the same key (the DO ledger dedupes).
- Recent + lazy (H16): on connect, prefetch the newest 200 messages of the newest 50 inbox entries;
  older pages only on demand (scroll, search hit, chief catch-up). Cached older segments are evicted
  LRU when the file passes 256 MiB; heads, inbox, drafts, outbox and the recent window never evict.
  Defaults are settings (question L5).
- Offline (H17, U5): the composer stays editable; Send is disabled and the text stays in `draft`;
  `home.op` is refused (`owner_offline`). Ops sent before the disconnect stay in the outbox as
  `sending` and are resent with their keys after reconnect (the only resend U5 allows). Reads serve the
  cache marked `cached_seq`.
- Unread: owner-projected (`inbox_entry.unread`, `mentions`); a pending `read_cursor.set` lowers the
  displayed count at once. Local conversations compute unread in the local owner.
- Identity: the sync actor holds the daemon install key and mints short-lived access tokens by
  challenge (D5). The app approves the daemon install once, locally, with its own install token
  (`install.enroll_local {daemon_pubkey}`); Linux hosts and VMs use the device flow. The daemon never
  holds the Stack session. Sign-out revokes the daemon install too (L14-2) and wipes
  `home-cache.sqlite3`.
- Authorship: ops from the daemon carry the user's principal and `inst` = the daemon install; the app's
  user intents carry `origin: user` and the actor stamp through the socket, so the DO can still tell a
  user's send from a chief's (identity.md 3).

### 3.5 iOS and web

- iOS cannot run a daemon. Recommendation: link `cmux-home` + `cmux-cloud-sync` as a static library
  serving the same `home.*` protocol over an in-process byte channel, so the Swift `DaemonHomeSource`
  is the same code with a different transport. The phone then has offline drafts, cache and search
  with no Swift logic (question L3).
- Web: a browser on the Mac uses the daemon WebSocket. A pure web client (cmux.com) with no daemon
  is later; the same crates build to WASM with SQLite on OPFS.

## 4. Migration (each slice lands alone, tests first)

| # | Slice | Steps | Risks |
| --- | --- | --- | --- |
| 1 | Rename acpmux -> cmux-acp | after #16174 and #16898 land, in one cmux-tui landing window: `git mv cmux-tui/crates/acpmux cmux-tui/crates/cmux-acp`; package, lib (`cmux_acp`) and `[[bin]]` `cmux-acp`; argv[0] alias `acpmux` kept one release (`crates/cmux-tui/src/main.rs:1637-1644`); bundle `Contents/Resources/bin/cmux-acp` + `cmux-acp.version` (`scripts/cmux-next/bundle-acpmux.sh`, `build-acpmux.sh`, `bundle-cmux-tui.sh` aliases, pbxproj "Bundle acpmux" phase, `sign-cmux-bundle.sh`, `strip-release-bundle.sh`); env `ACPMUX_*` -> `CMUX_ACP_*` (about 22 names, `CMUX_NEXT_ACPMUX_BIN` -> `CMUX_NEXT_CMUX_ACP_BIN`), old names read with a deprecation log for one release; home `~/.acpmux` -> `<cmux state>/acp` with a one-time move; socket `acp.sock`; JSON-RPC `_acpmux/*` -> `_cmux_acp/*` with both accepted for one release; Swift `Acpmux*` types -> `CmuxAcp*` (49 files); `webviews/src/agent-session/acpmux/` -> `cmux-acp/` (about 150 files, vite configs, `package.json`); `mux/host` client; 7 workflows (`cmux-next.yml`, `release.yml`, `cmux-tui-build-package.yml`, `cmux-tui-artifacts.yml`, `ci-macos.yml`, `nightly.yml`, `reload-build.yml`), 5 tests, docs, skill `skills/acpmux` | Leo's ~20 open PRs conflict on moved paths: land after they merge or give Leo a rename script (`git mv` list + sed) to rebase; tagged builds with an old `~/.acpmux` must still find sessions (the one-time move) |
| 2 | One process | the cmux-tui daemon hosts the acp hub as an actor (`cmux_acp::hub` started in-process); delete `AcpmuxDaemonLauncher.swift`, `AcpmuxEnvironment.swift` mirror logic and `mux/host/src/acpmux-daemon.ts`; acp listeners (`acp.sock`, WebSocket) served by the daemon; launch credentials and login environment (D26) in-process; restart test: kill the daemon mid-turn, terminals and agent turn survive | the hub's blocking code and fixed sleeps on the daemon runtime; panic isolation (catch_unwind per actor) |
| 3 | Home actor and one Swift client | move `conversation_store.rs`, `conversation_search.rs`, `server/conversations.rs` into crate `cmux-home`; serve `home.*` (old `conversation-*` commands stay as aliases); Swift `DaemonHomeSource: HomeSource`; Mac Home uses `CmuxHomeCore.HomeStore`; delete `HomeService`, `HomeConversationSession`, `ConversationMirror`, `ConversationIntentLog`; drafts table + `home.draft.*` | Home lane 16 and the Home lead are mid-landing on `HomeTranscriptAdapter`; land after R14 or adapt the adapter in the same slice |
| 4 | Daemon install + cloud sync | `cmux-cloud-sync` with install key, `install.enroll_local` (backend), UserDO gateway, per-conversation sockets, outbox, `conversation.since` (backend ask), recent + lazy paging, eviction; capability `home-cloud-v1`; Home shows cloud conversations; conformance: replay home-core corpus events into `cmux-home-replica` | needs Lawrence on L2 (changes APP-R1's cost); backend routes |
| 5 | Chief in-process | chief-mac.md steps 3 to 5 with ports into `cmux-home` and `cmux-acp` directly; delete `HomeBrainHost.swift` and the token file | |
| 6 | Feed through the daemon | the feed stream on `cmux-cloud-sync`; the daemon posts terminal notifications to the feed itself and `FeedNotificationBridge.swift` is deleted (no lost notifications while the app is closed); `CloudFeedSource.swift` and `FeedService.swift` read through the daemon; the local feed server keeps feed.md 5 | feed lead owns it |
| 6b | One machine registry | the daemon serves `machines.list` from the TeamDO directory replica plus SSH hosts; Swift `MachineRegistry.swift` becomes a projection; `/api/vm` moves behind the sync actor until D11 ports VMs | old backend API shape |
| 7 | One agent registry | hook-reported terminal agents (`cmux-tui-core/src/agent_hooks.rs`) become cmux-acp observed sessions (acpmux already has `adopt.rs`); conversation parts reference `{host, session}` and stop caching status; the session host keeps only terminal facts | Leo's team owns the hub model |
| 8 | Settings writer in Rust | config actor owns cmux.json writes and managed prefs (E4 end state); Swift `SettingsController`/`CmuxConfigFile` become clients; `cmux-tui.json` keys fold into cmux.json | settings lane; JSONC in-place edit must move to Rust |
| 8b | Apps: delete Swift duplicates | Swift manifest v1 validator, JSC engine and `registry.json` go once the Rust supervisor and QuickJS host serve them (APP-V2) | app platform lead owns it |
| 9 | iOS links the Home crates | staticlib, in-process transport, Aziz's UI on `HomeStore` | iOS build size, Rust toolchain in iOS CI |
| 10 | One socket | ACP negotiated on the main socket; `acp.sock` and the separate WebSocket go | client churn in webviews |

Order: 1 and 3 can run in parallel; 2 after 1; 4 after 3; 5 after 2 and 3; 6 after 4.

## 5. Spec changes this plan requests (coordinator decides)

| Decision or plan | Change |
| --- | --- |
| APP-R1 | keep "no user credential in the daemon" (the daemon never holds the Stack session or the app's key) but the daemon becomes its own install with its own grant; the cost section goes away |
| D5 | install list adds "the daemon on each Mac", enrolled locally by the signed-in app |
| S8 | "one binary" becomes "one process": cmux-acp and Home are actors in the daemon process |
| H8, chief-mac.md 2 | placement unchanged (daemon process); the acpmux socket hop becomes an in-process port after slice 2 |
| home-mac.md 3 | composer draft moves from client view state to the daemon (H17); the window may still restore its own copy for instant display |
| home-messaging.md 13 | Mac and iOS clients reach the DOs through the Rust sync crates, not a generated Swift cloud client; backend adds `conversation.since` and `install.enroll_local` |
| spec 00-overview 4 | add rows for `cmux-home`, `cmux-cloud-sync`, config actor; rename acpmux rows to cmux-acp |

## 6. Questions

### For Lawrence

L1. One daemon process for session host, cmux-acp, Home and chief?
1. Rec: one process, actors as crates, standalone `cmux acp daemon run` kept for tests and non-cmux users.
2. Two processes (session daemon; cmux-acp + Home + chief).
3. Keep three (session daemon, cmux-acp, Home sync).

L2. How does the daemon act as the user in the cloud?
1. Rec: the daemon is its own install (D5 key, app approves it once locally, device flow on Linux/VMs); APP-R1's cost goes away.
2. The app relays short-lived access tokens to the daemon (no daemon key; Home sync stops when the app quits; no headless).
3. The app stays the cloud client (Swift talks to the DOs; the daemon caches only local conversations).

L3. iOS Home logic?
1. Rec: link the same Rust Home crates in-process (one logic, offline drafts and cache on the phone).
2. Swift `HomeStore` talks to the DOs directly on iOS (logic in two languages).
3. The phone reads Home through the user's Mac daemon (fails when the Mac sleeps).

L4. Drafts?
1. Rec: per device, in the daemon, never synced.
2. Synced through UserDO (continue on another device; more writes, a sync conflict rule needed).

L5. Cache size defaults (settings either way)?
1. Rec: newest 200 messages of the newest 50 conversations, older pages on demand, 256 MiB LRU.
2. Everything the user can read (full offline search; large first sync).
3. Only conversations the user opens.

L6. Rename scope for acpmux -> cmux-acp?
1. Rec: everything (crate, binary, bundle, env, home dir, socket, `_acpmux/*` methods, Swift and TS names), with one release of aliases.
2. Crate, binary and bundle only; env, wire methods and TS names stay.

### For Leo's team (agent pane, acpmux)

1. Do you run acpmux outside cmux (standalone users, other hosts)? If yes, the standalone mode stays supported.
2. Can the hub run as an actor inside the cmux daemon (blocking calls, fixed sleeps, global state, its own tokio runtime)? What breaks?
3. Rename timing: which of your open PRs must land first, and do you want a rename script for the rest?
4. Should hook-reported terminal agents (`agent_hooks.rs`) become cmux-acp observed sessions, so one registry lists every agent?
5. Transcripts are ndjson segments today. Keep files, or move to SQLite for search and paging?
6. The agent pane connects to the token WebSocket directly. OK to move it to the daemon WebSocket (same catalog, per-launch secret) in slice 10?

### For Aziz's team (UI)

1. Will iOS and Mac use `CmuxHomeCore.HomeStore` behind `HomeSource` as the only Home client seam (no second store)?
2. Is a Rust static library in the iOS app acceptable (size, build, CI)?
3. Offline UI: Send disabled, composer editable, draft persisted, pending rows shown from the daemon outbox. Any state missing?
4. Mobile agent UI: it reaches cmux-acp on the Mac or VM through the link (ACP over `cmux.wire/1`). Is anything needed beyond the ACP catalog?
5. Status of #16521 (Agent GUI conversation layers): keep, rebase, or close?
