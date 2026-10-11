# cmux-next Home at scale: owners across placements, hosted capacity

Status: proposal for review by the backend lead, 2026-10-03 (branch feat-cmux-next-home-scale).
No code changes. Binding inputs: OWNERSHIP-PRINCIPLES.md, home-messaging.md (sections 1 to 22),
home.md section 5, optchat.md (branch feat-cmux-next-chief, decisions O1 to O4), chief-mac.md, and
Lawrence's rules of 2026-10-03: state lives in Rust; the Swift app is a projection that talks to the
Rust daemon over a Unix socket (a WebSocket for web or remote clients); the Rust daemon talks to the
Durable Objects; an agent's memory lives on the MacBook, on a Mac mini the user owns, or hosted.

Part A closes gap G5 (who owns what when the parts of one user's setup run in different places) and
specifies the daemon proxy for cloud conversations (gap G2). Part B sizes the hosted service for
100k monthly active users (MAU) with headroom to 1M. Section C lists follow-up tasks with owners;
section D lists the decisions this design needs. Numbers carry units; every assumption has an id
(A1, A2, ...) so a reviewer can challenge it. Prices are list prices as last known to the author and
are UNVERIFIED until someone checks the current price pages.

What the code does today was read from `backend/packages/ownership/src/{engine,outbox,schema}.ts`,
`backend/apps/api/src/{owner-do,do-outbox,projection}.ts` and
`backend/packages/home-core/src/conversation/{fanout,outbox}.ts` at 6e067991310.

# Part A: ownership across placements

## A1. Three choices, not one

"Placement" hides three separate choices. Each has its own owner and they must not be tied together
by accident.

| Choice | Owner of the entity | Where it can run |
| --- | --- | --- |
| Conversation owner: who commits messages, cursors, participants, invites | one owner per conversation (`local:<host>`, `cloud`, `server:<id>`) | the MacBook daemon, the Mac mini daemon, ConversationDO, a self-hosted server |
| Agent memory (OptChat log, tree, view) | one memory service per agent (O2) | the MacBook daemon, the Mac mini daemon, a hosted memory object (O3 default) |
| Brain host: the process that runs the agent's turns | one brain host per agent (kernel lock, chief-mac.md section 2) | a daemon on a Mac, or the cloud MuxDO loop |

A chief whose memory lives on the Mac mini can post into a cloud group. A cloud-owned chief thread
can have its brain on the MacBook. The conversation owner never depends on where the memory lives;
the agent is a participant (a principal), not an owner.

Note: optchat.md names a `MemoryDO` for hosted memory. That is a new DO class owned by the chief
lane; this document only refers to it.

## A2. Which places may own a conversation (first principles)

An owner of a conversation must pass three tests:

1. Reachable: every participant who may write must reach the owner whenever they want to write.
   When the owner is unreachable, nothing queues (OWNERSHIP-PRINCIPLES), so an often-offline owner
   blocks every other participant.
2. Neutral: every human participant must accept that the owner enforces the rules (order, edits,
   retraction, removal, history visibility, an agent's turn budget) and holds the history. A
   person's laptop is not neutral for another person's messages.
3. Capable: the owner must do or reach the side effects: inbox updates on every participant's
   devices, push, invites, search.

| Owner | Reachable | Neutral for other humans | Side effects |
| --- | --- | --- | --- |
| MacBook daemon | no (sleeps, travels, closes) | no | local only; push and invites need a cloud relay |
| User's Mac mini daemon | mostly (always on, behind the user's overlay) | no, unless the other humans knowingly accept it | through relays (`push.relay`, `invite.relay`) |
| ConversationDO | yes | yes (operated by cmux under its terms) | all |
| Self-hosted team server (home-messaging.md section 11) | yes, for members of that team on its network | yes for the team that operates it (its members accepted the team's policy) | through relays |

Rules that follow:

- R1. A conversation with exactly one human (a chief thread, notes, the user with their own agents)
  may be owned by any placement the user picks. RECOMMEND the default owner of a new chief thread is
  the chief's memory placement (O3 makes that hosted for a new user), so a fully local setup keeps
  working offline and a hosted setup needs no Mac.
- R2. A conversation with two or more humans, or with another user's agent, is owned by
  ConversationDO. Exception: a self-hosted team server may own it when the conversation's `team` is
  the server's team and every human participant is a member or guest of that team.
- R3. The local owner (`cmux-conversation`) refuses `participants.add` of a second human or of
  another user's agent with a new reject `needs_shared_owner`. The app offers "Move to cloud"
  (promotion, A5). The add is never queued and never silently promoted.
- R4. A user's own Mac mini does not own conversations with other humans. DECISION D1 below; the
  alternative is to register the mini as a self-hosted server of a team of one with guests, which
  makes its availability and its custody of other people's messages explicit at join.

Why a DM is always cloud-owned even when both people run Mac minis: the DM ConversationDO is also
the single writer of the pair's relationship state (section 16.7), which every compose check and
block reads. Splitting the pair's relationship from its messages would put two owners on one
consent decision.

## A3. Owner table per placement

`local` = the MacBook daemon, `mini` = the user's Mac mini daemon, `server` = a self-hosted team
server. "Projection" means a copy written only from the owner's events.

| Entity | MacBook only | MacBook + own Mac mini | Hosted (default) | Team with a self-hosted server |
| --- | --- | --- | --- | --- |
| One-human conversation (head, messages, cursors) | `local` or ConversationDO (user picks) | `mini`, `local` or ConversationDO | ConversationDO | `server` or ConversationDO |
| Multi-human conversation | ConversationDO | ConversationDO | ConversationDO | `server` (team-scoped) or ConversationDO |
| Relationship pair state | DM ConversationDO | same | same | same (relationships are account-level, never on a server) |
| Inbox entry of a cloud conversation | UserDO | UserDO | UserDO | UserDO |
| Inbox entry, pin, mute of a non-cloud conversation | the owning daemon's local inbox | the owning daemon (`local` or `mini`) | n/a | the server |
| Directory pointer to a non-cloud conversation (A8) | UserDO table, row written only by the owning host | same | n/a | same, written by the server |
| Chief record (name, parent, `brain_host`, memory placement, thread id) | UserDO | UserDO | UserDO | UserDO (team chiefs in TeamDO later) |
| Chief memory | `local` | `mini` or `local` | hosted memory object | per the chief's record |
| Wake queue for a chief in a cloud conversation | MuxDO; the local brain host subscribes | MuxDO; the mini's brain host subscribes | MuxDO; cloud loop | MuxDO |
| Wake for a chief in a non-cloud conversation | the owning daemon, in process (chief-mac.md) | the owning daemon; a brain on another Mac subscribes over the overlay | n/a | the server's own wake queue |
| Search index | daemon SQLite FTS5 for local, PlanetScale for cloud | same per owner | PlanetScale | the server's Postgres for its conversations |
| Push decision | UserDO for cloud; macOS notification from the daemon for local | UserDO; the mini calls `push.relay` for its conversations | UserDO | the server calls `push.relay` |
| Invite and address state | AddressDO only | same | same | AddressDO through `invite.relay` |
| PlanetScale | projections of cloud owners only; never a read path for rendering | same | same | the server's own Postgres; nothing reaches PlanetScale |
| Clients (Swift app, TUI, CLI, iOS, web) | mirror + intent log (A7 says where it lives on a Mac) | same | same | same |

## A4. A conversation with participants on different placements

Example: Lawrence (MacBook, chief memory on his Mac mini), Austin (hosted), Austin's chief (hosted)
and Lawrence's chief in one group.

- Owner: ConversationDO (R2). Participants are principals: `user_lawrence`, `user_austin`,
  `agent_<lawrence chief>`, `agent_<austin chief>`.
- Lawrence's MacBook daemon holds one cloud link and relays his app's ops (A7).
- Lawrence's chief: ConversationDO emits `mux.wake` to its MuxDO; the brain host on the Mac mini
  subscribes to `mux:<agent>`, reads its memory locally, runs the turn and posts with its agent
  token. If the mini is offline, MuxDO keeps the wake queue (an owner-side queue, which the
  principles allow) and the brain catches up on reconnect through `mux.ack`.
- Austin's chief runs in the cloud loop with hosted memory.
- No message is ever stored at Lawrence's placements except as projections (daemon cache, chief
  memory, which logs what the chief saw, under the chief owner's control).

The memory copy deserves one sentence of policy: a chief's memory logs messages from other humans in
a shared conversation. That copy follows the chief owner's placement. RECOMMEND the join screen of a
group with chiefs says "chiefs in this group remember what they read", and `history_visible` plus
retraction do not reach into memory logs (stated, not hidden). This is a product disclosure, not an
owner question.

## A5. Promotion: `conversation.import` from the daemon side

home-messaging.md section 22 specifies the cloud side. The daemon (the local owner and the source)
adds this protocol:

1. Trigger: the user picks "Move to cloud", R3 refused an add, or the user changes the thread's
   placement to hosted.
2. `conversation.promote.begin {target: cloud}` on the local owner: state `promoting`. Reads work;
   every write is refused with `promoting` (a client shows "Moving to cloud"; nothing queues).
3. The daemon maps ids: `user_local` to the account's `user_<id>`; each local agent to its cloud
   principal (the chief record's `agent_<26>`). A local agent with no cloud principal blocks the
   import until the user registers it or picks the fallback in DECISION D9.
4. The daemon sends the first `conversation.import` call, then batches of at most 500 messages and
   1 MiB, then `conversation.import.commit`. Attachments: blobs go to R2 by hash before the batch
   that references them (gap in section 22; follow-up C-13).
5. `conversation.promote.finish {cloud_id}` on the local owner: the local conversation becomes
   read-only with a pointer; its local inbox entry turns into a pointer row; the UserDO bump at
   import commit puts the cloud row in every device's inbox; the chief's wake source switches to
   MuxDO.
6. Crash and retry: the cloud id is deterministic (`importConversationId(user, host, local_id)`), and
   a repeated first call returns `last_seq`, so the daemon resumes after the last committed batch.
   `conversation.promote.abort` returns the local conversation to `active` when no commit happened.
   The cloud reaps an object left in `importing` with no batch for 7 days (follow-up C-12).
7. Authority: section 22 allows the promoting user's session or app install, never an agent and
   never a daemon install. The daemon does the transfer, so it carries an app-signed authorization
   for this import (A7, DECISION D3).

Size: a p99 chief thread of 1M messages at 2 KB is about 2 GB, so 2,000 batches. At an assumed
5 batches per second (A1) the import takes about 7 minutes, writes about 10M SQLite rows in the
ConversationDO (about 10 USD at the row-write price in B11) and 1M search rows (drained in batches
of 500).

Demotion (cloud to local) is allowed only for one-human conversations and is the same protocol in
reverse (`conversation.export` then a local import). Not needed for launch.

## A6. Offline behavior

| What is down | Local conversation (MacBook owner) | Mini-owned conversation | Cloud conversation | Server conversation | Chief turns |
| --- | --- | --- | --- | --- | --- |
| MacBook offline | works | refused on the MacBook (owner unreachable); works on iPhone if it reaches the mini | MacBook: read-only from the daemon cache, writes refused | refused on the MacBook | a MacBook brain stops; MuxDO keeps its cloud wakes |
| Mac mini offline | works | refused everywhere; shown as "Mac mini offline" | works | n/a | a mini brain stops; MuxDO keeps its cloud wakes |
| Cloud unreachable | works | works over the overlay | read-only from cache, writes refused | works if the overlay is up; push and invites wait in the server's own outbox | cloud-loop chiefs stop; local brains in local conversations work |
| Server offline | n/a | n/a | works | refused for every member | the server's chiefs stop |

On reconnect a client resends only the intents it sent before the disconnect, with their keys
(OWNERSHIP-PRINCIPLES). The daemon cache is a projection: it shows the last confirmed state, marked
stale, never pending changes.

Agent actors are the one place where "nothing queues" is a real loss: a chief turn that ends while
the owner is unreachable has output that a human did not type and cannot retype. chief-mac.md
already gives the brain a durable outbox. DECISION D6 asks to confirm that an agent actor may keep a
bounded durable outbox (24 h, then dropped and logged in its memory), because the rule exists to
stop optimistic UI copies of human intents, not to throw away agent work.

## A7. The daemon proxy for cloud conversations (G2)

Rule: the Swift app talks only to the Rust daemon over the Unix socket. The daemon talks to the DOs.

Shape:

- One cloud link per (account, Mac). It holds the UserDO gateway socket (`user:<id>`, `inbox:<id>`)
  and one `GET /v1/wire/conv/<id>` socket per conversation that any local client has open; it closes
  a conversation socket 60 s after the last local subscriber leaves. All local clients (Mac windows,
  TUI, CLI) share these sockets.
- Owner picker: one function maps a conversation id to its owner from the summary's `owner` field
  (`local:<host>`, `cloud`, `server:<id>`); nothing assumes the local store. The same relay serves a
  mini-owned conversation over the overlay WebSocket.
- Mirror and intent log: RECOMMEND they live in the daemon (state lives in Rust), one per account
  per Mac. The Swift `HomeSource` renders the daemon's visible state (mirror + pending intents) and
  keeps only gesture state. This moves the intent log that home.md section 3 placed in Swift
  (DECISION D2). The daemon never acknowledges an op itself: it forwards the client's idempotency
  key and `origin` unchanged and returns the cloud's result, `transaction`, events and
  `request-settled` as they are.
- Cache: the daemon keeps the inbox snapshot and the tails of recent conversations on disk, keyed by
  stream seq, so the app starts with content and shows cloud conversations read-only while offline.
- Resume: after a drop the daemon resumes each stream with `after_seq`, not a full snapshot (B5).

Identity. Every request must carry an authenticated client identity, and some ops are limited to an
owner's app install acting for no agent: `mux.confirm.decide`, `user.text_confirm.level.set`,
`conversation.import` (sections 19, 21, 22). Any same-uid process can talk to the daemon, so the
daemon's own install must not satisfy those rules. RECOMMEND an app-signed envelope: the Mac app
holds its own install key (Secure Enclave, no presence prompt) and signs `{op, params_hash,
idempotency_key, install, issued_at}` for the ops that need an app install; the daemon forwards the
signature; the Worker verifies it against the app install's registered key. The daemon still owns
the transport and cannot forge app-only ops. Presence-signed ops (`user.text_confirm.lower`) are
already end-to-end and relay as they are. DECISION D3 lists the alternatives.

Capacity effect: one upstream per Mac instead of one per window lowers the count of DO sockets and
incoming WebSocket messages (B11 counts incoming messages as billed requests).

iOS and web have no daemon. They talk to the cloud directly and, for a conversation owned by one of
the user's Macs, to that Mac's daemon over the overlay WebSocket (HostDO relay when no direct path).

## A8. Finding non-cloud conversations from other devices

An iPhone must list a chief thread that the Mac mini owns without connecting to every host first.
RECOMMEND a UserDO table `hosted_conversations {conversation, owner_host, kind, rev}` with one
writer per row: the owning host's install. It carries no title, preview or message text (those
stay on the host); the iPhone shows the row as "on Mac mini" and fetches the rest from the host when
reachable. This is a new table in an existing DO, not a new class.

## A9. A self-hosted owner: what it means for push and invites

The server keeps conversations, cursors and search on its own SQLite and Postgres (section 11).
APNs keys, mail and SMS provider keys and the suppression list stay with cmux, so:

Push (`push.relay`, host install token of the server):

- Params `{user, collapse_id, kind: message|approval|mention, badge, payload}`. `payload` is either
  content-free ("New message in a team conversation") or encrypted to the user's devices with keys
  each device got when it paired with the server; the iOS notification service extension decrypts
  it. cmux never sees the text (DECISION D7).
- The cloud accepts a relay only for users who are members or guests of the server's team, applies
  device selection, the foreground check and per-user caps (B10), and keeps the server's last badge
  count per user so the device badge equals cloud unread plus each server's count. Mute and unread
  for server conversations are the server's (it owns them); the cloud does not re-check them.
- Limits: 100 relayed pushes per second per server, 60 per hour per user from servers (approvals
  exempt).

Invites (`invite.relay`):

- An address outside the team cannot reach a server on the team's private network. So an external
  invite into a server conversation is two things: a team guest invite (`org.invite`, role `guest`,
  section 16.5) and the conversation membership on the server. Team policy
  `home.external_invites` gates it (DECISION D8).
- The server generates the invite secret, stores only its hash, and stashes the secret in AddressDO
  for rendering (the section 17 Q1 pattern). The cloud runs `address.ensure`, the inviter's
  `invite.quota.take` on their UserDO, suppression and per-recipient windows, and sends. Acceptance:
  the cloud page signs the person in and runs the guest join on TeamDO; the app then connects to the
  server, which verifies the secret and adds the participant.

# Part B: hosted capacity at 100k MAU, headroom to 1M

## B1. Assumptions

From home-messaging.md section 6, plus derived values.

| Id | Quantity | 100k MAU | 1M MAU | Basis |
| --- | --- | --- | --- | --- |
| A2 | daily active users | 40k | 400k | 40% of MAU (section 6) |
| A3 | sends per day | 9.2M (1.2M human, 8.0M chief) | 92M | 30 human + 200 chief per DAU |
| A4 | work-card edits per day | 20M | 200M | section 6 |
| A5 | read-cursor ops per day | 5M | 50M | about 1 per 4 received messages in a foreground conversation, client-debounced to 1 per 2 s |
| A6 | committed ops per day (A3+A4+A5) | 34M | 340M | |
| A7 | mean / peak committed ops per second | 400 / 2,000 | 4,000 / 20,000 | peak = 5x mean (section 6) |
| A8 | concurrent WebSockets at peak | about 23k | about 230k | 25% of DAU online, 1.5 devices each, 1 gateway + 0.5 conversation socket per device |
| A9 | message size | human 300 B, chief 2 KB | same | section 6 |
| A10 | indexed text per search row | follows A9: human rows about 300 B, agent rows about 2 KB (truncated at 16 KiB); about 10M rows per day | 100M rows per day | section 6, made consistent with A9 |
| A11 | conversations per user | p50 30, p99 2,000 | same | section 6 |
| A12 | SQLite rows written count each index entry written as one more row | | | Cloudflare documents this for D1; assumed for DO SQLite. Measure (C-4) |
| A13 | DO duration is billed only while an object handles work; hibernated sockets cost nothing | | | pessimistic case in B11 |
| A14 | a row-mode commit takes 1 to 2 ms of DO time | | | not measured; C-4 measures it |

## B2. DO key per entity

| Entity | Key | Why |
| --- | --- | --- |
| ConversationDO | `idFromName(conversation id)`; group id = hash(user + client key), DM id = hash of the sorted pair, import id = hash(user, host, local id) | one writer per conversation; deterministic ids make retries land on the same object; no shard key is needed because one conversation peaks at 20 ops/s, about 2 to 4% of one object (A14) |
| UserDO | `idFromName(user id)` | one inbox writer per user; the heaviest user receives about 2,300 bumps per day |
| MuxDO | `idFromName(agent id)` | one wake queue per chief |
| AddressDO | `idFromName(addr_<26>)` (HMAC of the normalized address) | one writer for suppression and per-recipient windows |
| TeamDO | `idFromName(team id)` | never on the per-message path: ConversationDO keeps the team policy it needs in its head with the policy revision |
| AccountIndexDO | lookup only (sign-in, link, alias) | must never be on the per-message path; one object would cap the system at its own throughput |

Placement: an object lives near the colo of its first request. A DM between continents pays one
cross-region round trip for one side, which is acceptable. EU data residency later uses a
jurisdiction-scoped namespace per team (follow-up C-26), chosen at conversation creation.

Size per object: the DO SQLite limit is 10 GB. A p99 chief thread holds about 1M messages, about
2 GB of message rows, plus 30 days of events (B4 shows when events dominate). A chief thread above
5M messages starts a new thread per period (open in section 6; RECOMMEND per calendar quarter, with
a link to the previous thread).

## B3. Fan-out per message

Per committed op, today (code at 6e067991310) and after the changes in this document (target).

| Op | DO-to-DO items | Postgres statements today | Postgres statements target | Socket frames | Push candidates |
| --- | --- | --- | --- | --- | --- |
| DM send | 2 `inbox.bump` | 2 (conversation row + search row) | about 1 (search row; conversation row coalesced, B6) | up to 3 | 1 |
| Group send, p50 4 humans | 4 bumps, `mux.wake` per mentioned chief | 2 | about 1 | up to 6 | up to 3 |
| Group send, 64 humans (cap) | 64 bumps | 2 | about 1 | up to 96 | up to 63 |
| Chief thread, human send | 1 bump, 1 wake | 2 | about 1 | up to 2 | 0 |
| Chief thread, chief send | 1 bump | 2 | about 1 | up to 2 | 1 per turn end (B10) |
| Work-card edit of the last message | 1 bump per human (fanout.ts bumps every human when the edited message is the last one) | 1 (a `home.message.delete` for a text-less card, which matches no row) | 0 (no bump unless the preview or a mention count changes; no search row unless the text body changes) | up to 96 | 0 |
| Read cursor | 1 bump (self) | 0 | 0 | up to 3 | 0 |

The work-card row is the biggest single lever: 20M edits per day today create about 20M useless
Postgres deletes and, in groups, up to 64 inbox bumps each.

## B4. Hot conversations

Case: a chief streams work-card edits at 20 ops/s into a group of 64 humans with 96 open sockets.

Today, per second: 20 commits; 1,280 bump items (20 x 64), coalesced per user per drain to about
256 UserDO deliveries if a drain runs every 250 ms, each committing as a system op; 20 Postgres
statements; 1,920 socket frames per second. A row-mode event carries the row AND the full
conversation head (participants, cursors, settings): 15 to 30 KB per event in a 64-member group,
not 2 KB (backend lead review, 2026-10-03). At about 20 KB that is about 38 MB/s out of one object,
which no client link or object memory budget survives; head diffs (C-7) are a precondition for
large groups, not an optimization. One hour of this also writes about 17M SQLite rows across the
UserDOs (about 17 USD, B11) for content nobody keeps.

Target:

- Work-card progress becomes ephemeral, like typing (DECISION D4): the brain sends a non-op frame
  `work.progress {message_id, part_index, state}`; ConversationDO keeps the latest state per card in
  memory and broadcasts at most 4 frames per second per card; it never stores or projects them. The
  brain commits one `message.edit` with the final card state at turn end (and at most one every
  10 s for a long card, so a reconnecting client sees recent state). A client that reconnects sees
  the last committed card plus the next progress frame.
- Owner-enforced limits: `conversation_busy {retry_after_ms}` above 50 committed ops/s per
  conversation (about 5 to 10% of one object, A14); `agent_edit_rate` above 1 committed edit per
  second per message. The existing agent turn budget still stops loops.
- Lagging sockets: when a socket's buffered output passes 256 KB, the object stops sending it events
  and marks it for resync; when it drains, it gets one snapshot (the existing `SnapshotBatcher`
  resync path). Progress frames to a lagging socket are dropped (latest wins). Without this, 96
  sockets at 1 MB each approach the 128 MB object memory limit, and an out-of-memory reset drops
  every socket of the conversation at once.
- Events: row-mode events carry the row (`effects`) and the full head, so each edit stores another
  15 to 30 KB copy in a large group (about 2 KB plus the head in a chief thread). A chief thread
  with 50k events per day at about 20 KB writes about 1 GB of events per day and would pass the 10 GB
  object limit in about 10 days under 30-day retention. RECOMMEND events carry a head diff instead
  of the head (C-7), and row-mode owners keep 7 days or 10,000 events, whichever is more. Resume
  today replays at most 1,000 events; a client further behind takes a snapshot (E3).

Per-object throughput: one object is single-threaded. At 1 to 2 ms per commit (A14) the ceiling is
500 to 1,000 commits per second; the 50 ops/s cap keeps a hot conversation under 10% and leaves room
for drains, reads and resyncs.

## B5. UserDO inbox

- Size: p99 2,000 entries at about 600 B is about 1.2 MB of rows; no limit is needed at that size.
- Paging: today `inbox.list` loads and sorts every entry, then slices (`inbox/reducer.ts`). Target:
  pages of 200 with a keyset cursor (pinned first, then `last_at` desc, then conversation id), never
  an offset; the `rows` order column `n` holds `last_at` in ms (gap G4, branch
  feat-cmux-next-home-inbox).
- Gateway snapshot: RECOMMEND the `inbox:` snapshot carries pinned entries plus the newest 200, and a
  reconnect resumes with `after_seq` (only changes). Sending all 2,000 rows on every mobile reconnect
  costs 1.2 MB per reconnect and multiplies a reconnect storm (B12, rank 3).
- Unread totals: NOT in the inbox head today. `InboxHead` holds only `user` and `next_pin`, and
  `commitOutbox` passes no counts, so a badge needs a scan. Target: running sums (unread, mentions)
  in the head, updated by each bump's delta, so the badge is O(1) (backend lead fixes the code,
  C-28).
- Load: the heaviest users receive about 2,300 bumps per day, peaking near 20 per second while
  several chiefs stream. Chief-thread bumps tolerate 2 s of delay (push for chief messages waits for
  turn end, B10), so their coalesce window can be 2 s; human-message bumps go at once because push
  latency follows them.
- Batch commit: today each delivered item is a separate system op with its own ledger and event
  rows. RECOMMEND one `inbox.bump_many` commit per delivery batch, and no ledger row for `inbox.bump`
  (it is idempotent by its max-merge on `rev`). This removes about 6 rows written per bump (B11).

## B6. Outbox drain

Today (`owner-do.ts` alarm): after every commit the alarm is set to now; each due channel reads up
to 100 rows; target channels are delivered one after another; the projection channel opens a new
`pg` client through Hyperdrive and runs one statement per row inside one transaction; sent rows are
marked `sent_at` and never deleted; a failing channel backs off exponentially to 5 minutes, without
jitter; after 12 tries (about 24 minutes) a row is dead-lettered, so a Postgres outage longer than
that silently loses projection rows (search and conversation index), and nothing replays them.

Changes, in priority order:

1. Delete outbox rows when they are sent (or prune `sent_at` rows in the same alarm). Today every
   message leaves 3 to 70 rows forever, including a copy of its search text (up to 16 KiB).
2. Deliver target channels in parallel, at most 16 at a time, with a 5 s timeout per RPC. A 64-human
   group today makes 64 serial RPCs; at 50 to 150 ms per cross-colo call the last inbox updates 3 to
   10 s late, and one slow UserDO delays all later ones.
3. Projection channel: run at most once per second per object (search freshness target is p95 2 s);
   coalesce rows by (kind, entity), last one wins (upserts are already guarded by `source_seq`); write
   each kind as one multi-row statement (`INSERT ... SELECT * FROM unnest(...) ON CONFLICT ...`),
   up to 500 rows per statement. This turns about 2,000 small transactions per second at peak into a
   few hundred larger ones.
4. Jitter every backoff (x0.5 to x1.5). When Postgres recovers from an outage, every object with a
   pending projection retries; without jitter they retry in waves at the same backoff steps.
6. No dead letter for transient errors: network errors, timeouts, Hyperdrive or Postgres
   unavailability and 5xx retry indefinitely with the capped, jittered backoff. Only a permanent
   error (a row the target rejects for schema or validation, which no retry can fix) is
   dead-lettered, counted and alerted. A replay tool re-drains dead-lettered rows and can rebuild a
   projection for one object or a time range from the owner's rows (upserts are idempotent by
   `source_seq`). The backend lead fixes the code (C-27).
5. Keep the target channels immediate for human messages (push latency); allow the 2 s window for
   chief-thread bumps (B5).

## B7. PlanetScale projection

Write rate (statements, not transactions):

| | Today | Target |
| --- | --- | --- |
| Per day at 100k MAU | 38.4M (9.2M conversation rows, 9.2M search rows, 20M deletes from edits) | about 14M (about 11M search upserts for sends and text-changing edits, about 3M coalesced conversation rows) |
| Mean / peak per second at 100k MAU | 444 / 2,200 | 160 / 810 |
| Peak per second at 1M MAU | 22,000 | 8,100 |
| Transactions per second at 100k MAU peak | about 2,000 (one per drain) | about 300 (one per active object per second, A15) |

A15: at the 100k peak, about 300 objects per second have new projection rows. Not measured.

What to skip or coalesce:

- Skip: a search row for an edit whose text body did not change (all work-card edits); a delete for a
  message that never had a search row; a conversation row change that only moves `last_seq` within
  the same second.
- Coalesce: conversation rows (last per drain), participant rows, search rows of a message edited
  twice in one drain.
- Do not project: typing, work progress, read cursors (unread comes from UserDO).

Storage and indexes. `0006_home.sql` stores a generated `tsvector`, a GIN on `(conversation_id,
tsv)`, a trigram GIN on `body` and a btree, in 64 hash partitions. The search query today uses only
`ILIKE`, so the `tsvector` column and its GIN cost write load and storage and serve no query: either
move the query to `tsvector` matching or drop them (C-11). Assumed footprint per raw text
byte (A16): heap with the stored `tsvector` 1.2x, `tsvector` GIN 0.6x, trigram GIN 2.5x, total about
4.3x. At 10 GB raw per day that is about 43 GB per day, about 15.7 TB per year on the primary, and
again on each replica. Section 6's 3.5 TB per year is the raw text only.

Target layout (a revision of `0006_home.sql`, applied by the backend lead through the label flow):

- Two tables: `home_message_search_human` and `home_message_search_agent`. Human rows are 13% of
  sends but are what people search for most.
- An expression GIN on `to_tsvector('simple', body)` instead of a stored column (saves about 1x).
- Trigram GIN (substring and CJK search) on human rows only. Agent rows match by `tsvector`; the
  client's in-conversation search covers substrings in loaded pages.
- Agent rows truncated at 4 KiB of text (today 16 KiB).
- Monthly `RANGE (created_at)` partitions instead of 64 hash partitions. Hash pruning does not help:
  a p99 user's 2,000 conversations touch all 64 partitions. Monthly partitions serve "newest first"
  (scan the newest month, stop at the limit) and let retention drop a partition instead of deleting
  rows. A scheduled job creates partitions 3 months ahead (C-10; check if PlanetScale Postgres
  allows `pg_partman`, UNVERIFIED).
- Retention: agent rows stay 90 days in the global index (drop the oldest monthly partition);
  older chief history is searchable inside its conversation (ConversationDO search over its own
  rows; FTS5 in DO SQLite is UNVERIFIED). DECISION D5. Human rows follow team retention through a new
  projection kind `home.message.delete_through {conversation_id, seq}` (one statement per
  conversation per day instead of one per message).

Result (A16 factors): human rows about 0.36 GB raw per day x 3.6 = 1.3 GB per day, about 475 GB per
year kept; agent rows about 8 GB raw per day x 1.1 = 8.8 GB per day, about 790 GB steady at 90 days.
About 1.3 TB on the primary after the first year at 100k MAU instead of 15.7 TB. At 1M MAU: about
4.75 TB per year of human rows plus about 7.9 TB of agent rows, which is past what one primary should
hold with GIN write load (C-11).

## B8. Replicas and read paths

| Read | Path | Never |
| --- | --- | --- |
| Open conversation, history pages | ConversationDO socket snapshot (`tail` 50), then `conversation.history` from DO rows | PlanetScale |
| Inbox, unread, badge | UserDO gateway (`inbox:` stream) | PlanetScale |
| Search | Worker, read-only role, Hyperdrive to a replica; no Hyperdrive query cache (results are per user); `statement_timeout` 2 s | the primary |
| Admin and analytics | replica | the primary |
| Projection drains | primary | |

Replica lag adds to search freshness (assumed under 1 s, A17); the open conversation's client-side
search over loaded pages covers "I just sent it". RECOMMEND an HA cluster of one primary and two
replicas at 100k MAU; the read-only binding `HYPERDRIVE_RO` already exists for this path. Search
reads are small: at 3 searches per DAU per day, 1.2M per day at 1M MAU, about 14 per second mean.

## B9. Rate limits

Two mechanisms: Cloudflare rate-limit bindings (keyed, per-colo approximate, periods of 10 s or
60 s) for burst limits in the Worker, and counters in the owner (UserDO or ConversationDO) for exact
and daily limits.

| Limit | Value | Where | Reject |
| --- | --- | --- | --- |
| All ops per human user | 20/s sustained, 50 burst | Worker binding, key user | `rate_limited {retry_after_ms}` |
| Human `message.send` per user | 3/s sustained, 10 burst; 2,000 per day (p99 is 300) | binding + UserDO daily counter | same |
| Committed ops per conversation | 50/s | ConversationDO | `conversation_busy` |
| Committed edits per message | 1/s | ConversationDO | `agent_edit_rate` |
| Chief ops | existing turn budget (`agent_budget`, `agent_rate`), plus 10 ops/s per chief | ConversationDO, binding key agent | existing codes |
| `conversation.create` | 60 per hour per user | UserDO | `rate_limited` |
| `home.search` | 2/s, 60 per minute per user; 120 per minute per IP | binding | `rate_limited` |
| History and inbox reads | 20/s per user | binding | `rate_limited` |
| WebSocket connects | 30 per minute per user, 60 per minute per IP | binding | 429 before the upgrade |
| Invites, `dm.open` by address, `invite.preview` | section 9 (unchanged) | existing | existing |
| Unauthenticated `/v1/ops` | refused before any DO call | Worker | 401 |
| `push.relay` | 100/s per server, 60 per hour per user | binding + UserDO | `rate_limited` |

## B10. Push volume

- Human messages: 1.2M sends per day, about 1.5 other humans per send, about 60% not in the
  foreground: about 1.1M pushes per day.
- Chief messages: push only at turn end, for an `approval` part or a mention, never per streamed
  message. At about 50 turns per DAU per day and 50% not in the foreground: about 1M pushes per day.
- Total about 2.1M per day at 100k MAU (peak about 125 per second), about 21M per day at 1M MAU (peak
  about 1,250 per second). APNs has no per-message price.
- Controls: `apns-collapse-id` = conversation id, so a burst shows one notification; at most one
  push per conversation per 10 s while unread grows (later ones update the badge only); at most 60
  pushes per hour per user (approvals exempt). Each push is one subrequest from the UserDO.

## B11. Cost per 1M messages

Unit: 1M sends together with what comes with them at the section 6 mix: 2.17 work-card edits and
0.54 read-cursor ops per send; 13% human and 87% chief sends.

Prices (A18, UNVERIFIED list prices, Workers Paid): DO requests 0.15 USD per million (incoming
WebSocket messages count 1/20 of a request; alarms and RPC calls count as requests); DO duration
12.50 USD per million GB-s at 128 MB per active object; SQLite rows written 1.00 USD per million,
rows read 0.001 USD per million, storage 0.20 USD per GB-month; Worker requests 0.30 USD per
million; no Cloudflare egress charge; Hyperdrive included. PlanetScale Postgres is priced by
cluster, not per write (A19: an HA cluster of 3 nodes at about 2,500 USD per month at 100k MAU,
about 0.50 USD per GB-month of storage per node). Included monthly allowances are ignored.

SQLite rows written per op (A12, from the schema in `ownership/src/schema.ts`): a commit writes
the head (1), message rows in the generic `rows` table with two indexes (3 per row; `msg` and
`msgkey`), a ledger row with two indexes (3), an event with one index (2), each outbox item (2) and
its later `sent_at` update (2), and later prunes (ledger 3, event 2). Each UserDO bump is another
commit (about 18 rows).

| Op | Rows written today | Target | Main target changes |
| --- | --- | --- | --- |
| Human send (DM and group average) | 80 | 40 | `inbox.bump_many` without ledger, delete-on-send outbox, a dedicated `msg` table keyed by seq |
| Chief send | 51 | 25 | same, plus the 2 s bump coalesce |
| Work-card edit | 40 | 12, and only 1 in 3 edits is committed | no bump, no search row, ephemeral progress (D4) |
| Read cursor | 33 | 10 | no ledger row (monotonic max), client debounce |
| Per send, with its edits and cursors | 159 | 41 | |

| Cost item per 1M sends | Today | Target | Notes |
| --- | --- | --- | --- |
| SQLite rows written | 159 USD | 41 USD | dominant item; C-4 measures it |
| DO requests | 0.80 USD (about 5.3M) | 0.38 USD (about 2.5M) | ops over WebSocket; over HTTP `/v1/ops` add about 1.67 USD |
| DO duration | 0.61 USD (about 0.38 s active per send) | 0.24 USD | pessimistic A13: if each wake bills 10 s of idle time, today is about 64 USD |
| DO storage | 2.20 USD per month kept (about 11 GB: messages, 30 days of event copies, unpruned outbox) | 0.68 USD per month (about 3.4 GB) | message rows alone are 0.38 USD per month kept |
| PlanetScale storage | about 7 USD per month kept (4.7 GB x 3 nodes) | about 1.8 USD per month, agent part expires after 90 days | A16, A19 |
| PlanetScale compute share | about 9 USD | about 6 USD (smaller cluster or more headroom) | 276M sends per month at 100k MAU |
| Egress, push | 0 | 0 | Cloudflare egress free; APNs free |
| Total, first month | about 179 USD | about 50 USD | |

At 100k MAU (about 276M sends per month): about 49,000 USD per month today, about 14,000 USD per
month at target. At 1M MAU, about 490,000 and 140,000 USD per month. SQLite row writes stay the
largest item at target, so the next lever after this document is the engine's per-commit write set
(ledger, events, outbox) for high-volume ops. These figures depend on A12 and A13 more than on any
other assumption; measuring them is the first follow-up.

Invites (email and SMS provider fees) are per invite, not per message, and are outside this table.

## B12. What breaks first, ranked

| Rank | Failure | When | Mitigation |
| --- | --- | --- | --- |
| 1 | SQLite row-write cost grows with work-card edits and bumps (cost, not availability) | from launch; about 49k USD per month at 100k MAU | B3, B5, B6 and D4 changes; measure rows written per op kind (C-4) |
| 2 | Postgres primary saturates on projection writes (small transactions, GIN and trigram upkeep); drains back up in every object; recovery comes in synchronized retry waves | near 100k MAU peak today (2,200 statements/s) | skip no-op rows, coalesce, multi-row statements, 1 s drain interval, jitter, partial trigram index; a separate search cluster before about 500k MAU |
| 3 | Reconnect storm: a DO code deploy or a Cloudflare incident drops every socket (A20, verify); every client reconnects and asks for full snapshots | each deploy; 23k sockets at 100k MAU, 230k at 1M | client reconnect jitter of 0 to 30 s, resume with `after_seq`, inbox snapshot first page only, one upstream per Mac (A7), deploy at low traffic |
| 4 | A hot conversation runs out of memory from lagging sockets and drops all members | any large group with a streaming chief | 256 KB per-socket cap with resync, ephemeral progress, `conversation_busy` |
| 5 | DO storage grows from unpruned outbox rows and 30-day event copies; heavy chief threads approach 10 GB | months after launch | delete-on-send, 7-day event window for row-mode owners, quarterly chief threads |
| 6 | Large-group fan-out is serial, so inbox and push arrive seconds late and a slow UserDO delays the rest | groups above about 20 humans | parallel delivery (16) with timeouts |
| 7 | Search storage (15.7 TB per year today) and GIN write cost | within the first year | B7 layout and retention (D5) |
| 8 | Runaway agents and abusive senders | any time | B9 limits, the turn budget, `agent_edit_rate` |
| 9 | Push storms from chiefs; APNs throttling and user annoyance | from launch if chief messages push | push at turn end only, collapse ids, caps |
| 10 | Hyperdrive connection churn (a new client per drain) | near peak | fewer, larger drains (B6) |
| 11 | One heavy UserDO (a user with many streaming chiefs) | rare | 2 s coalesce for chief-thread bumps, `inbox.bump_many` |
| 12 | `installGrant` is one hot key in the owner's UserDO that every chief op of that user reads, so many active chiefs serialize on it | a user with many chiefs | cache the grant in each MuxDO or ConversationDO head with its revision, pushed by UserDO on change (C-29) |
| 13 | `bind()` creates an object for any id a caller names, so random ids create empty objects (storage and billing abuse) | any time | derive or verify ids before `get()`: deterministic ids from authenticated inputs, or an existence check in the owning UserDO; refuse unknown ids in the Worker (C-30) |

## B13. From 100k to 1M MAU

The DO side scales by object count, so the per-object limits in B4 and B5 do not change. What
changes: Postgres (B7: split search off the primary onto its own cluster or shard by conversation
hash across databases; keep the conversation id as the shard key now so the move needs no schema
change), push rate (about 1,250 per second at peak; one APNs connection per UserDO call is fine),
reconnect storms (230k sockets), and the absolute cost of row writes (B11).

# C. Follow-up tasks

| Id | Task | Owner area |
| --- | --- | --- |
| C-1 | Delete outbox rows on send (or prune `sent_at` rows in the alarm) | backend lead (`ownership`, `owner-do.ts`) |
| C-2 | Parallel target delivery (16), 5 s RPC timeout, jittered backoff | backend lead |
| C-3 | Projection channel: 1 s minimum interval, coalesce by (kind, entity), multi-row statements | backend lead (`projection.ts`) |
| C-4 | Measure rows written per op kind (`SqlStorageCursor.rowsWritten`) and DO active time per alarm on staging; confirm A12, A13, A14, A20 | backend lead |
| C-5 | Per-socket output cap with resync; ephemeral frame channel (typing, `work.progress`) with latest-wins per card | backend lead |
| C-6 | Row-mode event retention: 7 days or 10,000 events | backend lead (E3) |
| C-7 | Dedicated `msg` table keyed by seq for row-mode conversations; ledger-less system ops for max-merge targets; `inbox.bump_many`; events carry a head diff instead of the full head (15 to 30 KB per event in a 64-member group today) | backend lead (engine) with lane 15 (inbox reducer) |
| C-8 | Rate-limit bindings and owner counters of B9 | backend lead |
| C-9 | `fanOut`: search intent only when the text body changes; edit bumps only when the preview or a mention count changes; no delete for a message without a search row; corpus cases | lane 15 (`home-core`) |
| C-10 | `conversation_busy`, `agent_edit_rate`, `work.progress` frame rules; corpus cases (cloud and the Rust owner where it applies) | lane 15, then cmux-tui (`cmux-conversation`) |
| C-11 | Revise `0006_home.sql` before it reaches production: two tables, expression GIN, partial trigram, monthly range partitions, partition job, `home.message.delete_through`; replica Hyperdrive for search; plan the search split for 1M | backend lead (migrations through the label flow) |
| C-12 | Reap ConversationDOs left in `importing` for 7 days | backend lead |
| C-13 | Attachment blobs in `conversation.import` (upload by hash before the batch) | lane 15 + backend lead |
| C-14 | Push: turn-end rule for chief messages, collapse ids, per-user caps, `push.relay`, external badge counts | backend lead (UserDO, `push/`) |
| C-15 | Gateway: inbox snapshot = pinned + 200, resume by `after_seq`; client reconnect jitter contract | backend lead + clients |
| C-16 | Brain: commit work cards at turn end (and at most every 10 s), send progress as `work.progress` | chief lane (P1 and the TypeScript brain) |
| C-17 | Daemon cloud link (G2): one upstream per account per Mac, op relay, mirror + intent log in the daemon, disk cache, owner picker | cmux-tui daemon |
| C-18 | Promotion source side: `conversation.promote.begin/finish/abort`, id mapping, batched upload, resume | cmux-tui (`cmux-conversation`, daemon) |
| C-19 | `needs_shared_owner` reject in the local owner; corpus case | cmux-tui (`cmux-conversation`) + lane 15 corpus |
| C-20 | `hosted_conversations` table in UserDO and its writer in the daemon; `push.relay` client for mini-owned conversations | backend lead + cmux-tui daemon |
| C-21 | App-signed op envelope (app install key, Worker verification) | identity lane + backend lead |
| C-22 | `HomeSource` reads the daemon's visible state for cloud conversations (additive, data side only) | Mac Home data side (CmuxHomeCore / HomeSource; no UI files) |
| C-23 | iOS: reach mini-owned conversations over the overlay; notification service extension decrypts relayed pushes | iOS lane |
| C-24 | `invite.relay` with team guest join for self-hosted servers | backend lead + enterprise lead |
| C-25 | Join-screen disclosure that chiefs remember what they read | Home product (copy, localized) |
| C-26 | Jurisdiction-scoped DO namespaces for EU teams | enterprise lead (later) |
| C-27 | Outbox: no dead letter for transient errors (retry with capped jittered backoff); dead letter only permanent errors, with alerts; replay tool that re-drains dead letters and rebuilds a projection per object or time range | backend lead (`ownership`, `owner-do.ts`, `projection.ts`) |
| C-28 | Unread and mention totals as running sums in `InboxHead`, with deltas passed through `commitOutbox` | backend lead with lane 15 (inbox reducer) |
| C-29 | Cache `installGrant` per chief in MuxDO or ConversationDO heads with its revision; UserDO pushes changes | backend lead |
| C-30 | Verify or derive DO ids before `bind()`/`get()`; refuse unknown ids in the Worker | backend lead |

# D. Decisions needed

| Id | Question | Recommendation and the strongest objection |
| --- | --- | --- |
| D1 | May a user's own Mac mini own conversations with other humans? | No for now: cloud or a team server. Objection: some users want no cloud custody for a two-person chat; the team-of-one server path can serve them later. |
| D2 | Where does the intent log for cloud conversations live on a Mac? | In the daemon (state in Rust). Objection: it moves state that home.md section 3 put in Swift, and an app crash then shows pending intents from the daemon on relaunch, which the UI must render. |
| D3 | How do app-only ops pass through the daemon? | App-signed envelope. Alternatives: the app talks directly to the cloud for those ops (breaks the daemon-only rule) or the daemon install counts as an app (any same-uid process could then approve a chief's risky action). |
| D4 | May work-card progress be ephemeral, with only the final state committed? | Yes. Objection: a client that joins mid-turn sees a card up to 10 s old until the next progress frame. |
| D5 | Global search over chief messages older than 90 days? | No; in-conversation search only. Objection: "what did my chief say in March" becomes a per-thread search. |
| D6 | May an agent actor keep a bounded durable outbox while the owner is unreachable? | Yes, 24 h. Objection: it is a queue, which the offline rule forbids for clients. |
| D7 | Relayed push content for local and self-hosted conversations | Encrypted to devices, content-free fallback. Objection: more key management on iOS. |
| D8 | External invites into self-hosted conversations | Allowed only as a team guest invite, gated by team policy. Objection: the invitee joins a team, which is heavier than a chat. |
| D9 | Promotion of a local agent with no cloud principal | Require registering it as an agent principal first. Alternative: import its messages under a read-only stub participant that cannot act. |
| D10 | Rate-limit values in B9 | Start with B9 and tune from telemetry. Objection: the 2,000 human sends per day cap may hit scripted human accounts (they should use agent principals). |
