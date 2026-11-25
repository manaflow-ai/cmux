# AutoCloud: a chat keeps running when the laptop goes away

Named AutoCloud since 2026-11-24 (Austin): this is the keep-running half of the feature whose other half is
the place picker's Auto (where a new chat starts). One name, one switch (`cloud.autoCloud`). In the code the
parts keep the names they were built under: `auto_session`, `cmux-auto-session`, `/v1/auto-sessions`, and this
folder. "Auto mode" below means AutoCloud's keep-running half.

Status: building on branch `cloud-cmux-mode`, one integration PR into `feat-cmux-next`. Off by default
(the hidden switch `cloud.autoCloud`); the store is unbound in production until it ships there, as hand-offs are.

Builds on cloud work mode (`backend/apps/api/src/handoffs`, Leo 2026-10-27): there the person sends a chat to a
Cloud machine by hand. Auto mode makes the same move happen by itself when the laptop goes away, and back when
it returns.

Beside Auto chat placement (Leo 2026-11-18, open as https://github.com/manaflow-ai/cmux/pull/45820,
https://github.com/manaflow-ai/cmux/pull/45834 and https://github.com/manaflow-ai/cmux/pull/45838): that work
is the decision of where a new chat starts (This Mac, a joined machine or Cloud) and when a running chat should
move, and it moves a chat while the Mac is still there to carry the move out (it hears `willSleep`). This work
is what holds when the Mac is not there to do anything: the Cloud keeps a lease and a copy, so a chat goes on
after a closed lid, a dead battery or a lost network, and the phone reaches it with no Mac. Neither needs the
other to land, and nothing here reads `placement` tags or calls `_acpmux/place_chat`. Both are AutoCloud now: one switch (`cloud.autoCloud`) turns on the picker's Auto and this store's
keep-running, so a chat placed on Auto is also kept running.

## What the person sees

One setting, **Auto** (Settings > Cloud; per chat in the chat's menu). With Auto on:

- A chat runs on the laptop while the laptop is there.
- When the laptop sleeps, closes or loses its network mid-task, the chat keeps going on the person's Cloud
  machine. Nothing to click.
- The phone opens any Auto chat, sends to it, or starts a new one with the laptop off. Those chats are on the
  laptop when it comes back.
- When the laptop comes back, a chat the Cloud is running stays there until its turn ends, then comes home by
  itself, files included.
- The Cloud machine is paused whenever no Auto chat needs it. The only trace is a short "Resuming" state.

No surface says lease, epoch, mirror or pause.

## Measured: can a turn cut off mid-reply be retried? (2026-11-23)

Claude Code 2.1.322 and Codex CLI, headless; the agent's whole process group SIGKILLed at a chosen moment, then
resumed by session id with "Continue." Harness and raw results: [`turncut/`](turncut/).

| Cut during | Claude Code | Codex |
|---|---|---|
| Streaming text | The partial reply is not in the transcript. Resume wrote the whole reply again (300 of 300 lines). | Same (400 of 400 lines). |
| A shell command | The transcript has the `tool_use` and no result. On resume Claude Code adds "Tool call interrupted: the session ended before this call's result was recorded", and the model read the file instead of running the command again. | The transcript has the call, no output and no marker. On resume Codex **ran the command again**: the file read `start, start, end`. |
| Either | The tool's shell **outlives** the agent (a detached `zsh -c`, still running after the kill). | Same. |

Rules this design enforces:

1. **A takeover runs the cut turn again from its last user message**, on the new holder. Partial text is never
   carried.
2. **The continuation tells the agent what was cut off**, naming the tool call that was in flight, so no harness
   repeats a side effect blindly. acpmux already does this for a daemon restart (`hub/restart_resume.rs`: one
   continuation at the head of the queue that quotes the cut prompt and says to check what finished). A takeover
   uses the same path with `reason: "machine_takeover"`.
3. **A laptop that wakes stops its Auto chats before they do anything**, then asks the Cloud whether it still
   holds them. On a real sleep the processes freeze and go on at wake, detached tool shells included. If the Cloud
   took a chat, the laptop kills that chat's whole process tree and keeps what it wrote after the last
   acknowledged copy as a leftover patch, never merged silently.

## Model

Every Auto chat has one **holder**, recorded in the Cloud and on no machine: `device:<id>` (a laptop),
`vm:<machine>` (a Cloud machine) or `parked` (nobody; the next message picks one). The holder runs the agent;
everyone else views.

The record has an **epoch** that only grows. It grows by one at every change of holder. Every write to the
chat's Cloud state names the writer's holder and epoch and is refused `auto.stale_epoch` when they are not
current. This is acpmux's `ownership_epoch` (`hub/session.rs`, `transfer_out.rs`) held where a sleeping laptop
cannot ignore it.

### Lease

- The holder renews every `RENEW_MS = 10_000`; the lease lasts `LEASE_MS = 45_000` from the last renewal. A
  laptop back within 45 s lost nothing.
- When the lease runs out (the store's alarm):
  - **`needsRun`** at the last renewal (a turn running, a prompt queued, a background task at work:
    `Hub::sessions_at_work`'s rule for this chat): epoch + 1, holder `vm:<the owner's Auto machine>`, an
    assignment `takeover`, and the machine is started (`cloud.machine.start` as the owner, the way
    `mux-machine-wake.ts` does it, with its backoff; the assignment stays until the machine acks it).
  - **idle**: epoch + 1, holder `parked`. No machine starts.
- A message for a `parked` chat makes the Auto machine its holder (assignment `takeover`) and starts it.
- No Auto machine set: the chat stays `parked` with `blocked: "no_machine"`; the clients offer to make one.

### Copy (the chat's state in the Cloud)

While a laptop holds an Auto chat its daemon sends, at every turn end, tool end and queue change, and at most
every 5 s while a turn streams:

- **Events**: the chat's log records in order, `seq` from 1 (the records `acpmux.transfer.v2` carries). Any
  device reads them to show the chat.
- **Snapshot**: what a new holder needs besides the events. One manifest naming content-addressed chunks
  (at most 1 MiB each, 512 MiB a chat; past that the chat shows "Too large to keep a Cloud copy" and stays
  local). A snapshot is whole or absent: the manifest is accepted only when every chunk it names is stored.

```json
{ "v": 1, "at": 0, "lastSeq": 0,
  "harness": "claude", "harnessSessionId": "…",
  "cwd": { "kind": "git", "remote": "https://…", "branch": "…", "base": "<sha the remote has>",
           "bundle": ["<chunk sha256>"], "patch": ["<chunk sha256>"] },
  "queue": [ { "id": "…", "text": "…" } ], "draft": "…",
  "openTurn": { "turnId": "…", "promptId": "…", "tool": { "name": "Bash", "args": "…" } } }
```

`cwd.kind: "folder"` (no repository) carries `tar: [chunks]` instead. The git form is `session_move_carry`'s:
the base the remote already has, a bundle of local commits past it, and one binary patch of uncommitted work;
untracked files that look like secrets stay behind (`secret_scan.rs`).

### Assignments

A Cloud machine's daemon reads its assignments at start, at resume and while it runs (a held request, 25 s):

- `takeover`: import the events and the newest snapshot (the `transfer_in` path, a fresh worktree from the
  manifest), settle the open turn `outcome_unknown` and queue the `machine_takeover` continuation, then renew
  as holder.
- `create`: a chat started with no laptop: a worktree of the repository and branch, the harness, the first
  message.
- `deliver`: inbox messages that arrived while nobody ran the chat.

The idle pause still applies (RFD 0016, `auto-pause.ts`, `daemon/cloud_activity.rs`): holding a chat keeps no
machine up, only work does. A `vm` holder that goes quiet keeps the chat (a paused machine is not a lost one);
its lease does not lapse to another holder.

### Inbox

Every device sends to an Auto chat through the Cloud. The holder drains it: the laptop on its renew, the
machine through `deliver`. The sender sees "Resuming" until the holder acks.

### Handback

A laptop that is online and not the holder renews as `standby`. At the holder's next turn end with nothing
queued, and unless the chat is kept in the Cloud, the store moves the lease to the standby laptop (epoch + 1).
The laptop imports the snapshot (the three-way folder merge `cmux cloud bring-back` uses) and goes on locally.
The machine, with nothing at work, pauses by itself.

### Laptop wake

Before an Auto chat's processes do I/O after a sleep (a wall-clock jump past `LEASE_MS` seen by the daemon, or
the app's wake notice relayed to it), the daemon:

1. Stops every Auto chat's process tree (SIGSTOP).
2. Renews. Still holder at the same epoch: SIGCONT.
3. Otherwise: SIGKILL the tree, detached tool shells included; write the folder's changes since the last
   acknowledged snapshot as a leftover patch beside the chat; mark it held elsewhere; renew as standby.

### A laptop that cannot reach the Cloud stops by itself

A laptop with no network keeps running, so the Cloud's takeover alone would leave two copies at work. A
holder that has had no renewal answered for `SELF_STOP_MS = 35_000` (under `LEASE_MS`, so it always stops before
the Cloud takes over) stops its Auto chats' process trees (SIGSTOP) and shows them as waiting for the network.
The next answered renewal decides as a wake does: still holder at the same epoch, or holder again of a chat the
store had `parked` (the store answers `holder` with the new epoch): SIGCONT. Taken by a machine: kill, leftover
patch, standby.

## Daemon surface (acpmux, for the Mac app and the web UI)

- `_acpmux/auto_session/set {sessionId, auto, keepInCloud?}` answers `{autoSession}`.
- `_acpmux/auto_session/wake {}`: the app relays the system's wake; the daemon also sees a clock jump itself.
- `_acpmux/auto_session/leftover {sessionId, action: "show" | "apply" | "discard"}`.
- Every session row carries `autoSession: {auto, state, here, keepInCloud, blocked?, leftover?: {files}}`.
  `state` is the Cloud view's; `here` is whether this machine holds it; `blocked` is `no_machine`,
  `too_large` or `offline`. A change goes out as the row's ordinary change notice.
- An Auto chat this laptop does not have (started on the phone, or on another laptop) is a row read from
  `GET /v1/auto-sessions`; opening it reads its events and waits on `/wait`; a send goes to its inbox.
- AutoCloud's switch `cloud.autoCloud` (hidden, default off) is the default for new chats: with it on, a chat
  that starts on this Mac has Auto on.

## Cloud API

`/v1/auto-sessions`, in `backend/apps/api/src/auto-sessions/` beside `handoffs/` and in its shape:
`AutoSessionDO` (one per chat: record, lease alarm, events, chunks, inbox, assignment) and `AutoSessionIndexDO`
(one per owner: the list, the Auto machine). Errors are `{error: {code, message}}`. Routes answer 404 where
`AUTO_SESSION_DO` is unbound.

Callers: **owner** (a signed-in session or a person's install: the laptop's daemon, the Mac app, the phone) and
**machine** (the bearer of a VM install bound to the chat's Auto machine; its `holder` is `vm:<that machine>`).

| Route | Caller | Body | Answer |
|---|---|---|---|
| `GET /v1/auto-sessions/machine` | owner | | `{team, machine}`: the machine the owner named, else one of their own Cloud machines in the caller's team that the store picks and keeps for that team; 404 `auto.no_machine` when they have none there |
| `PUT /v1/auto-sessions/machine` | owner | `{team, machine}` | `{team, machine}`; optional, one per owner for every team's chats: it replaces the store's picks, and no pick replaces it |
| `PUT /v1/auto-sessions/:id` | owner | `{auto, title, harness, device, keepInCloud?, repo?: {remote, branch}}` | `{session}`; first call makes it with holder `device:<device>`, epoch 1. `auto: false` closes it: 409 `auto.held_in_cloud` while a machine holds it |
| `POST /v1/auto-sessions` | owner | `{title?, harness, repo: {remote, branch}, firstMessage: {id, text}}` | 201 `{session}`: holder the Auto machine, assignment `create`, machine started; 409 `auto.no_machine` only when the owner named no machine and has none of their own |
| `GET /v1/auto-sessions?limit=&cursor=` | owner | | `{sessions, nextCursor}` |
| `GET /v1/auto-sessions/:id` | owner, machine | | `{session}` |
| `GET /v1/auto-sessions/:id/wait?after=<version>&timeoutMs=` | owner | | `{session}` once its version passes `after`, or at the deadline (at most 25 s) |
| `POST /v1/auto-sessions/:id/lease` | owner, machine | `{holder, epoch, needsRun, standby?}` | `{session, role: "holder" \| "standby" \| "lost", leaseMs}` |
| `POST /v1/auto-sessions/:id/release` | holder | `{holder, epoch}` | `{session}`: holder `parked`, or the standby laptop |
| `POST /v1/auto-sessions/:id/events` | holder | `{holder, epoch, events: [{seq, record}]}` (at most 256, 1 MiB) | `{lastSeq}`; a repeat of stored seqs is accepted, a gap is 409 `auto.seq_gap` with `lastSeq` |
| `GET /v1/auto-sessions/:id/events?after=<seq>&limit=` | owner, machine | | `{events, lastSeq}` |
| `PUT /v1/auto-sessions/:id/chunks/:sha256` | holder | bytes (at most 1 MiB), headers `x-cmux-auto-holder`, `x-cmux-auto-epoch` | 204; 400 `auto.chunk_mismatch` when the hash differs |
| `GET /v1/auto-sessions/:id/chunks/:sha256` | owner, machine | | bytes |
| `POST /v1/auto-sessions/:id/snapshot` | holder | `{holder, epoch, manifest}` | `{snapshot}` (its number); 409 `auto.snapshot_incomplete` naming the missing chunks |
| `GET /v1/auto-sessions/:id/snapshot` | owner, machine | | `{snapshot, manifest}` or 404 `auto.no_snapshot` |
| `POST /v1/auto-sessions/:id/inbox` | owner | `{id, text}` | `{state: "delivered" \| "resuming" \| "queued", session}`; the same `id` again answers the same |
| `GET /v1/auto-sessions/:id/inbox?after=<n>` | holder | | `{messages: [{n, id, text, at}]}` |
| `POST /v1/auto-sessions/:id/inbox/ack` | holder | `{holder, epoch, through}` | `{session}` |
| `POST /v1/auto-sessions/:id/keep` | owner | `{keepInCloud}` | `{session}` |
| `GET /v1/auto-sessions/assignments?timeoutMs=` | machine | | `{assignments: [{kind: "takeover" \| "create" \| "deliver", session}]}`, held until one exists or the deadline |
| `POST /v1/auto-sessions/:id/assignment/ack` | machine | `{holder, epoch}` | `{session}` |

`session` (the view every route answers):

```json
{ "id": "…", "title": "…", "harness": "claude", "team": "…", "owner": "…",
  "auto": true, "keepInCloud": false,
  "holder": "device:… | vm:… | parked", "epoch": 1,
  "state": "local | cloud | resuming | parked | coming_back", "blocked": null,
  "needsRun": false, "standby": ["device:…"],
  "lastSeq": 0, "snapshot": 0, "inbox": 0, "inboxAcked": 0,
  "repo": { "remote": "…", "branch": "…" },
  "version": 1, "createdAt": 0, "updatedAt": 0, "leaseExpiresAt": 0 }
```

`state` is what a client shows: `local` (a laptop holds it), `cloud` (a machine holds it and acked), `resuming`
(a machine holds it and has not acked), `parked`, `coming_back` (a handback is due at the next turn end).

Codes: `auto.stale_epoch`, `auto.not_holder`, `auto.no_machine`, `auto.held_in_cloud`, `auto.seq_gap`,
`auto.snapshot_incomplete`, `auto.no_snapshot`, `auto.chunk_mismatch`, `auto.too_large`, `auto.closed`.

## The store's rules as built (2026-11-23)

The Cloud store landed first. Where it is more exact than the sections above, it is the contract: the pure
rules are `backend/apps/api/src/auto-sessions/lease.ts` (every move of the record) and `model.ts` (the record,
the view, the limits). `FakeAutoCloud` follows the same rules, and the conformance vectors (slice F) hold the two
together.

Lease (`POST lease`) answers a role and never `auto.stale_epoch`:

- `holder` to a renewal that is not a standby's: go on, at the answer's epoch.
- `holder` to a standby's renewal: the chat is yours now. Import the Cloud copy, then hold at the answer's epoch.
- `standby`: remembered as waiting (a standby counts for `LEASE_MS` from its last renewal; at most 8).
- `lost`: what you run is not the chat any more. Stop it, then renew as standby. The holder device naming an old
  epoch gets `lost` too, except the repeat of its own retake of a parked chat.
- A parked chat: the laptop whose lease ran straight into `parked` takes it back as it is with a non-standby
  renewal naming epoch − 1. Any other laptop, or that laptop after a machine ran the chat, takes it with a standby
  renewal (import first), unless the chat is kept in the Cloud.

Takeover and parking:

- A laptop's lease that runs out gives the chat to the Auto machine when `needsRun` was set **or an inbox message
  is unacked**; otherwise it is parked. No machine set: parked, `needsRun` kept, `blocked: "no_machine"`; setting
  the machine later moves it.
- A message alone moves a chat to a machine only once the store has a snapshot of it (`snapshot > 0`): at the
  lease's end, for a parked chat, and at a laptop's `release`. Before that the laptop has the only chat there
  is. A machine cannot import events without a snapshot, and one given an empty copy would start a second chat
  from the repository. So the chat is parked without `blocked`, the sender is told `queued`, and the laptop reads
  the message when it takes the chat back. `needsRun` needs no such check: a laptop says it only once its
  snapshot is stored.
- Setting the Auto machine also moves a chat given to another machine that was never heard from since: no
  renewal, no ack of its assignment and no ack of a message (`leaseExpiresAt` still 0). A machine that was heard
  from keeps the chat even with its assignment unacked, because a message it acked is in its log alone until its
  next copy. An inbox ack by a machine counts as hearing from it.
- A machine's start is retried while it has something unacked (every 5 s while it starts and for its first
  120 s, then every 60 s, for up to 6 h).

Handback:

- At a machine's renewal the chat goes to the newest live standby only when the renewal says `needsRun: false`,
  no inbox message is unacked, its assignment is acked, the chat is not kept in the Cloud, and the newest
  snapshot covers the chat's `lastSeq`. So a machine posts its events, then the snapshot that covers them, then
  renews. The machine's answer is `lost`. `release` hands back without the snapshot check.
- A machine that renewed last with `needsRun: false`, has everything acked and copied, and then stopped renewing
  for `LEASE_MS` (it is paused) gives the chat to a standby at the standby's renewal. This is the one case where
  a machine's lease lapses to another holder.

Assignments, release and inbox:

- `assignment/ack` with an unread inbox leaves a `deliver` assignment: ack the inbox first.
- `release` with an unread message never strands it: released by the Auto machine, the chat stays with it at the
  same epoch with a `deliver`; released by a laptop, it goes to the Auto machine as a `takeover`; no machine,
  parked with `blocked: "no_machine"`.
- Inbox `state`: `delivered` for a laptop holder or an acked machine with a live lease; `resuming` while a
  machine is being started; `queued` when no machine is set, or for a parked chat with no snapshot (it waits for
  its laptop).

`PUT :id`:

- `auto: false` is refused `auto.held_in_cloud` while a machine holds the chat, for a parked chat a machine ran
  last, and for a parked chat with an unread message. A laptop takes it as standby first.
- `auto: true` on a closed chat reopens it, empty, at the next epoch. Closed chats are not listed.
- `auto: true` from the laptop a parked chat was parked from takes the chat back as it is, at the next epoch, as
  that laptop's renewal would (nobody ran it since). A registration whose first answer was lost and whose retry
  came after the lease ran out so answers that laptop as the holder; before this it read as a chat another
  holder ran, and the laptop killed its own chat and imported an empty copy over it.

Wire:

- A refusal is `{error: {code, message}, session?, lastSeq?, missing?}`. Status: 413 `auto.too_large`, 400
  `auto.chunk_mismatch`, 404 `auto.no_snapshot` and `auto.no_machine` on `GET machine`, 409 the rest.
- A machine that held the chat last gets `auto.stale_epoch` with `session` on writes and 404 on reads; a machine
  the chat was moved away from gets 404 on both.
- Limits: a chat id is `[A-Za-z0-9_.:-]{1,128}` (`machine` and `assignments` are reserved; ids the Cloud makes
  are `as_<20 hex>` from the owner and `firstMessage.id`, so a repeated `POST` answers the same chat); events
  `GET` 256 events or 1 MiB a page; inbox `GET` 64 messages; inbox text 256 KiB; 256 unacked messages; a
  manifest is 1 MiB and 4096 chunks at most and names a numeric `lastSeq`; 512 MiB is per snapshot, with events
  capped at 512 MiB apart.
- The view: `standby` lists live standbys only; `leaseExpiresAt` is 0 for a parked chat and for a machine before
  its first ack; times are milliseconds.

Rules added after the correctness review (2026-11-23):

- A laptop that is given a chat it did not hold last (a hand-back, the paused-machine rule, a standby taking a
  parked chat another holder ran) owes an import (`owesImport` on the record, not in the view). Its first
  accepted snapshot clears it; the laptop stores one right after its import. Until then Auto off answers
  `auto.held_in_cloud`, and a lease that runs out parks the chat as the Cloud's (`parkedFrom` empty): that
  laptop comes back as a standby and imports again, it does not take the chat back "as it is".
- A `PUT` with Auto on from the laptop that holds the chat is also a renewal: the lease runs from it. The laptop
  reads a registration's answer as a lease's, so a registration answered late no longer leaves it running past
  a lease the store already ended.
- The store finds the Auto machine itself; no client has to name one (`machine-pick.ts`, and `autoMachine` in
  `index-do.ts`, the one lookup every reader calls: the lease alarm, `POST /v1/auto-sessions`, the inbox post,
  `release`, `GET machine`). With none named, the owner's index reads the team's machines as the owner
  (`cloud.machine.list` on the platform's CloudDO) and picks one the owner made that is not being deleted, failed
  or still on Cloud classic: a running one first, then the most recently used or made. The team is the chat's
  (`team` on its record, set from the caller's at the first `PUT`); with no chat yet, the caller's; the owner's
  personal team when neither is known. A team the owner may not use is never read. With no machine the chat is
  `blocked: "no_machine"` as before, and gets its machine with no further step once the owner has one: at the
  owner's next `GET` or `wait` of that chat, at their list, at the next lease end, message or `POST`, and from
  the index's alarm (15 s later, then twice as long each time up to 10 minutes, for 6 hours). A renewal never
  looks, and two looks in one team that find nothing are at least 10 s apart. `lease.ts` is unchanged: this is
  where `machine` comes from, not what the rules do with it.
- A pick is per team (`machine-store.ts`). The store keeps one pick for each team and answers it only for a chat
  of that team: a chat of team T with no pick for T looks in T only, so a personal chat never goes to a shared
  team's machine (with its events and its folder) because a work chat needed a machine first, nor the other way
  round, and a pick never changes a chat's `team`. `GET machine` answers for the caller's team. The machine the
  owner named (`PUT machine`) stays one per owner: it is for every chat of theirs, it wins over every pick, and
  the picks are dropped when it is set. A named machine that lands while a pick is being sent to the waiting
  chats wins for all of them: the send stops, and a chat that sits unpicked on a machine that is not the one
  stored for it is sent to the stored one at its next index write.
- A pick is read again at most once a minute, and at once when its start is answered
  `cloud.machine.not_found`; a named machine never is. A pick that is gone is replaced by another of the owner's
  machines in the team, and the chats it never picked up move there. With none left the pick is dropped and
  those chats are parked at the next epoch with `blocked: "no_machine"` (`machine-gone.ts`: only a chat the
  machine was never heard from on, the test `machineSet` uses; parked as the Cloud's, so a laptop takes it as a
  standby), and a machine made later reaches them through the same look. "Gone" is a fact only when the team's
  machines were read whole: a failed read, or a list still paged after 5 pages of 100 with none of the owner's
  among them, changes nothing.
- The alarm's look reads at most 3 teams with a chat that waits, by their oldest such chat, counting only teams
  the owner may still use: a team they left takes no place, and with no other team waiting the look ends.

Moving a chat by hand, as built (2026-11-24):

The store's side of "Modes and moving a chat by hand" below. The pure rules are `move.ts` (`move`, `give`); the
Rust mirror is `cmux-auto-session/src/fake/moves.rs`, and the conformance vectors replay both.

- `POST :id/move` (owner; a machine is answered 403) `{to: "cloud" | "local", device?: "device:<id>"}` ->
  `{session}`. `device` is taken only with `to: "local"` (400 `validation.invalid` otherwise). A chat with Auto
  off is refused `auto.off`.
  - To the Cloud. A machine holds it already (any of the owner's): the wish is dropped, `keepInCloud: true`, no
    machine is looked up. No Auto machine: `auto.no_machine`. Parked: `auto.not_copied` with no snapshot, else a
    `takeover` for the Auto machine at the next epoch with `keepInCloud: true`. A laptop holds it: the wish and
    `keepInCloud: true` in one write, and the Auto machine is started now so it is up at the give.
  - To a laptop. A laptop holds it and none is named, or the holder is named: the wish is dropped,
    `keepInCloud: false`. Otherwise the target is the named laptop when it stands by, or with none named the
    standby that renewed last; without one, `auto.no_laptop`. Parked: the target holds it at the next epoch with
    `needsRun: false`, owing an import unless it is the laptop the chat was parked from. A machine or another
    laptop holds it: the wish and `keepInCloud: false` in one write; a machine that holds it is started, since
    it may be paused and has to read the wish.
  - Asked again while it waits, a wish's time starts again. A move that changes nothing writes nothing.
- The wish is `session.move: {to, device?, at}` in the view (left out when there is none). The lease answer
  carries `move: "cloud" | "local"` only to the holder (`role: "holder"`), never to a standby or a `lost` caller,
  and with it `moveAt`: the wish's `at`. Asking again starts `at` again, so a holder that sees another `moveAt`
  knows the person asked again.
- `POST :id/give` (the holder, laptop or machine) `{holder, epoch}` -> `{session}`. The checks, in order: the
  fence (`auto.closed`, `auto.not_holder`, `auto.stale_epoch`); `auto.no_move` with no wish; `auto.not_copied`
  unless a snapshot exists and `snapshotSeq >= lastSeq`. To the Cloud the Auto machine is looked up at the give
  (`auto.no_machine`) and gets a `takeover`. To a laptop the target is found again at the give (the named
  standby, else the newest; `auto.no_laptop` when it stopped standing by): it holds the chat at the next epoch,
  owing an import, with `needsRun` as the giver last said it, so work the giver stopped still counts as work if
  that laptop never renews.
- All four new codes answer 409: `auto.off`, `auto.no_laptop`, `auto.no_move`, `auto.not_copied`.
- The wish goes at every change of holder (a give, a takeover, parking, a hand-back, a standby taking the chat)
  and at the alarm once `at + MOVE_MS` (120 s) has passed. `keepInCloud` stays as the move set it: a wish that
  runs out leaves the chat where it is, in the mode the person chose.
- A wish that names a laptop also steers a hand-back that happens before the give: the machine's idle renewal
  and `release` go to the named laptop when it stands by, else to the newest standby, and a paused machine's
  chat goes only to the named laptop's renewal.
- Parked take-back: the laptop a chat was parked from does not take it back, by `PUT` or by renewal, when the
  chat is kept in the Cloud and has a snapshot. A `PUT` is judged with `keepInCloud` as that `PUT` leaves it, so
  a `PUT` that stops keeping the chat takes it back. With no snapshot the laptop has the only chat there is and
  takes it back whatever the chat is kept as.
- `POST /v1/auto-sessions` takes `keepInCloud` (a chat made in Cloud mode). The Rust `CreateRequest` has no
  such field yet; the fake store takes it through `FakeAutoCloud::create_kept`.
- Storage: the wish is one added column (`move_wish`, JSON) on the chat's record, and the machine a wish waits
  on is one added column (`wake_machine`) on the owner's index, which starts it once per wish. Both are added
  with `ALTER TABLE` when an older object starts.
- Rust: the wire types are in `cmux-auto-session/src/wire/moves.rs` (`MoveTo`, `MoveRequest`, `MoveWish`,
  `MoveRefusal`), `SessionView.moving` and `LeaseAnswer.move_to` read the two `move` fields, and `AutoCloud`
  has `move_` and `give`. The four new codes are not in `ErrorCode`: an error carries one as its raw code and
  `AutoCloudError::move_refusal()` reads it (`code()` is None for them).

Known limits of the store's rules:

- A chat whose machine cannot run it has a way back only when the machine was never heard from: the owner sets
  another Auto machine, or the machine was the store's pick and is found gone (the rule above). A named machine
  whose start is refused or given up (deleted, the owner left its team, six hours of failed starts), and a pick
  that exists and cannot start, keep the chat's `takeover`, and a laptop that returns stands by with nothing
  coming home.
  The fix is a second `blocked` reason (the machine is unavailable) that parks the chat for a standby laptop or a
  new machine; it adds a value to the wire's `blocked` and to both apps, so it is not in this change. `PUT
  machine` also takes any well-formed id without reading the machine.

- A chat past the size cap. The laptop finds this before it uploads, so the store only sees copies stop. If the
  laptop then goes away and a message arrives, the machine goes on from the last snapshot that fit, with the log
  up to date and the folder as old as that snapshot. What the laptop wrote since is kept as its leftover patch
  when it returns. Telling the store that its copy is frozen needs one more field on the lease; not built.
- A machine that was heard from and then deleted keeps its chat: a machine's lease never runs out to another
  holder while it has work or something uncopied. Nothing moves that chat today.
- A machine whose copy is past the size cap keeps the chat: it never says it is idle with a copy missing, and it
  does not try that copy again until the folder changes. The laptop sees `coming_back` and Auto off is refused.
- What a laptop did after the last copy that reached the store is not in a takeover: the machine goes on from the
  store's copy, and the laptop's later folder changes are kept as its leftover patch when it returns. Its later
  conversation records are not in the chat: the machine never had them, and the laptop's log is replaced by the
  store's copy when the chat comes home. The exception is a prompt the person queued there that had not started:
  the laptop sends it to the chat's Cloud inbox when it learns another holder has the chat, and once more before
  it brings the Cloud's copy in, under the prompt's own id, so the holder runs it once. A prompt that waits
  behind a turn that failed is sent too: a laptop with no network fails its turn, and losing the chat kills the
  turn that ran. The holder refuses an id its log already has, so a prompt the store did have is not run twice.
  Only the prompt's text is sent: an image or a file attached to it is not. Not sent: a prompt whose turn had
  started on the laptop (its work is in the leftover patch), one with no text, one the store refuses (over
  256 KiB, or an id it does not take; the prompts behind it still go), an inbox message the laptop had taken
  and acked moments before it dropped off, and anything queued after a laptop daemon restart before the store
  first answered it as the chat's holder (until then the daemon does not know what the store has).
- `delivered` to a laptop holder means the store took the message for a holder whose lease is live. A laptop that
  has just gone to sleep reads it when it wakes, or the machine does after the takeover.

## The daemons and the core crate as built (2026-11-23)

Where the code differs from the sections above, the code is right and this section says how.

Core crate (`cmux-auto-session`):

- There is no `Release` effect and no `HandingBack` or `Releasing` state. A machine that finished its work
  renews idle (`needsRun: false`) once the newest copy is stored; the store hands the chat back at that renewal
  and answers the machine `lost`.
- A machine's order after an assignment: import the copy, drain the inbox, ack the assignment, then renew at
  work. The daemon sends `Changed` to the state machine after `DrainInbox`.
- A laptop sends `needsRun: true` only once the store holds a snapshot and the chat is not too large, so the
  store never gives a machine a chat it cannot import.
- A clock that went back by more than one second (`CLOCK_SLACK_MS`) is treated as a wake.
- Turning Auto off is `Effect::Close` and the chat stays Auto until `Event::Closed`, which carries the chat's
  epoch in the store's answer. A stopped tree is continued on Auto off only at the epoch one past the laptop's
  own (a close moves the epoch by one, so nobody else held the chat since); at any other epoch, or with none in
  the answer, the tree is killed and what it wrote is kept as the leftover patch.
- A 404 is never a laptop's answer to a renewal: it is read as no answer, so the chat stays stopped and the
  self-stop applies. Only `auto.closed` closes a laptop's chat. (A 404 can come from another account's sign-in,
  a Worker that does not serve the routes, or a proxy, while a machine runs the chat.) A registration answered
  404 still turns Auto off: nothing was registered and the chat runs as any chat does. A machine takes only the
  store's own `not_found` as "the chat was moved to another machine".
- A laptop sends a failed copy again at its next renewal, at work or idle, unless the chat is too large.
- A laptop stores a copy of its own right after an import (see `owesImport` in the store's rules).
- `ImportReason` and the `SessionImporter` trait (its `import` returns a boxed future) live in the core crate;
  a streamed turn is copied every 5 s (`STREAM_COPY_MS`).
- Refusals carry the store's `session`, `lastSeq` and `missing` as typed fields.

Inbox (laptop and machine, `acpmux/src/auto_session/runtime/inbox.rs`):

- A message is made durable before the store is told it was taken: it is written into the chat's own log as an
  `auto_inbox` record and flushed, then the store is acked, then it is delivered as a prompt whose id is the
  message's id (a repeat is the same prompt, not a second one). A daemon that restarts after the ack
  redelivers what its log still owes (`Hub::auto_inbox_owed`).

Daemon surface (`acpmux/src/auto_session/surface.rs`, `server/auto_gate.rs`):

- `set` is answered from the store's answer. Auto on waits for the first registration's answer; with none in
  about 9 s (under one renewal period; the pane waits 15 s) it answers the row as it is, Auto on and not in the
  Cloud yet, and the daemon goes on registering. A refusal is the request's error. A refusal that would be the
  same next time (an HTTP answer other than 408, 425, 429 or 5xx) also turns Auto off for the chat again and
  sends one close, so the row never says Auto is on for a chat the store will not take. `keepInCloud` changes
  nothing on the row until the store answered.
- Who may call: none of the three methods is served to a remote connection or a peer. `set`, and `leftover`
  with `apply` or `discard`, need the person (the app's pane, a connection that proved it is the person, or the
  local socket with no agent behind it: the line `_acpmux/set_turn_cap` draws). `wake` is refused from an
  agent's connection. `leftover` with `show` only reads.
- Apply merges the kept patch three ways on scratch indexes (`export/apply.rs`): the person's index is never
  written, a change already in the folder counts as applied, and a conflict writes nothing, keeps the patch
  and answers `auto.leftover_conflict`.
- What runs git in a chat's folder (cutting the leftover patch, an import, Apply, Discard) takes that chat's
  turn (`turns.rs`), one at a time.

In-memory store (`cmux-auto-session` feature `test-support`, `fake/`):

- `fake/rules.rs` is `lease.ts` function for function. Not mirrored: machine start lifetimes and backoff, team
  access (403), the rate limit on create (429), 405s, `auto.unavailable`, `owner.unreachable`, a revoked
  machine install (401), the owner index's lag, the list cursor's encoding, small-body size limits and alarm
  timing. `fixtures/conformance.json` is replayed against both stores.

## Modes and moving a chat by hand (2026-11-24, to build)

Asked for by Austin after the demo (`cloud-cmux-mode-demo`, `plans/cmux-next/auto-mode/demo/`) moved a real
Claude Code chat between a Mac and a VM and back. This section is the contract for that work; where it differs
from the sections above, it wins.

### One picker: the place mode decides where a chat starts and where it runs

Revised 2026-11-24 (later the same day). The base landed a place mode for new chats
(`cmux-tui/crates/acpmux/src/place_mode.rs`, https://github.com/manaflow-ai/cmux/pull/53459): each chat has one
of Auto, Cloud or one machine, picked in the composer's place picker (`_acpmux/chat_place_set`) or with
`cmux chat --on`, and a chat nobody picked for is Auto. It decides where a new chat starts. This branch does
not add a second picker, a second set of words or a setting beside it. The same pick also decides where the
chat runs after it started:

| Place mode (the picker row) | Where it starts (the base, unchanged) | Where it runs afterwards (this branch) | Auto record |
|---|---|---|---|
| Auto | This Mac when it has room, else a new Cloud VM | Started on this Mac: on the Mac while it is there, on the Cloud machine when it is not, home again at a turn end. Started in a Cloud VM: it stays there, as today. | `auto: true`, `keepInCloud: false` |
| Cloud | A new Cloud VM | In the Cloud, always. Picked for a chat that already runs on this Mac: the chat is moved to the Cloud machine now and never comes home by itself. | `auto: true`, `keepInCloud: true` |
| This Mac (machine = this Mac) | This Mac | This Mac only. Nothing is copied to the Cloud. | `auto: false` |
| Another machine | That machine | That machine only (the Auto rules do not apply to it). | none |

- The record's fields stay the truth for a started chat (`auto`, `keepInCloud`); the place mode is read from
  them, never stored twice. The daemon's in-memory pick (`server/chat_place.rs`) stays what it is: the pick of
  a chat that has not started yet. For a started chat that has an Auto record, `_acpmux/chat_place` answers the
  mode from the record, and `_acpmux/chat_place_set` applies it: Auto is `auto: true, keepInCloud: false` (the
  chat then comes home by the handback rule), Cloud is `keepInCloud: true` and a move to the Cloud in one store
  write, This Mac is a move to the laptop when a machine holds the chat, and Auto goes off once the laptop has
  stored its own snapshot (the `owesImport` rule already refuses it earlier).
- AutoCloud's switch `cloud.autoCloud` (the base's, hidden until it ships) is the switch for the whole
  feature: while it is off, a chat that started on this Mac runs here and is not copied, exactly as on the
  base. This branch's own `cloud.autoMode` setting is gone, and there is no `cloud.chatMode`. With the switch on
  and no store to reach (production until the store is bound there), a chat runs here as before: the laptop
  keeps asking to register and never stops the agent for it (`holder/laptop.rs` `registering`).
- The switch is one an agent may set (`schemas/settings/source/agent-policy.json`, the base's choice for the
  picker). Keep-running copies a chat and its folder to the person's Cloud machine, which this branch's own
  setting kept for the person alone to turn on. Whether the one switch should be the person's alone is an open
  decision for Leo.
- A chat started in a new Cloud VM (the base's Cloud, or Auto with a busy Mac) lives on that VM and needs no
  Auto record. The Cloud machine an Auto chat is taken over by is the team's one Auto machine
  (`machine-pick.ts`), not a new VM per chat. Both are "Cloud" to the person; making them one machine policy is
  not part of this pull request.
- Any surface shows the mode and where the chat runs now as two facts, in the picker's own words: "Auto · This
  Mac", "Auto · Cloud", "Cloud", "This Mac". No surface says lease, epoch, give or wish.

### Move now

A person can move an Auto chat between the laptop and the Cloud machine at any moment, also in the middle of a
turn, without waiting for a lease to run out.

- `POST /v1/auto-sessions/:id/move` (owner) `{to: "cloud" | "local", device?: "device:<id>"}` -> `{session}`.
  It writes a wish on the record, `move: {to, device?, at}`, and in the same write sets `keepInCloud` (`true`
  for `cloud`, `false` for `local`). Refused: `auto.off` (the chat is not Auto), `auto.no_machine` (to the
  Cloud with no machine to be found, by the same lookup a takeover uses), `auto.no_laptop` (to a laptop when no
  laptop stands by, or the named one does not). A chat already where it is asked to go has its wish cleared and
  answers as it is.
- A parked chat has no holder to give it: to the Cloud it is assigned as a `takeover` at once (refused
  `auto.not_copied` with no snapshot); to a laptop it goes to that standby at once, owing an import.
- The holder learns the wish from its lease answer (`move: "cloud" | "local"`, absent when there is none) and
  from the chat's view (`session.move`). A machine is woken by the index as for an assignment. The lease answer
  names the wish's time beside it (`moveAt`, the record's `move.at`; absent with no wish).
- `POST /v1/auto-sessions/:id/give` (holder) `{holder, epoch}` -> `{session}`. Fenced like every holder write.
  Refused `auto.no_move` with no wish, and `auto.not_copied` unless a snapshot exists and
  `snapshotSeq >= lastSeq`: a chat never changes hands ahead of its copy. On success: epoch + 1, the wish is
  cleared, and the chat goes to the Auto machine as a `takeover` assignment (`to: "cloud"`) or to the standby
  laptop with `owesImport` (`to: "local"`).
- A wish does not outlive its holder: any other change of holder clears it, and a wish the holder has not acted
  on for `MOVE_MS = 120_000` is cleared by the lease alarm. The lease rules still cover a holder that is gone.
- The parked take-back rules respect `keepInCloud`: a chat kept in the Cloud that has a snapshot is not taken
  back by its laptop's `PUT` or renewal; it stays parked until work arrives, which starts the machine.
- `POST /v1/auto-sessions` (a chat started with no laptop) accepts `keepInCloud`.

The holder's side (core crate and daemons):

- On a wish, the holder stops its agent now (the interrupt `transfer_begin` uses), sends its last events,
  stores a snapshot, then calls `give`. `auto.not_copied` means store the copy and ask again. After the give it
  is a standby (laptop) or has lost the chat (machine).
- The store's answer to a give is true whenever it arrives. The person may take the move back while the give is
  on its way (a renewal then answers `holder` with no wish, and the turn goes on here) and ask again; when the
  first give then lands, the store has another holder. So a holder told that the store took a give, at an epoch
  past the one it holds, has lost the chat at once in every state where it holds it (holding, serving, stopped,
  any step of a give), as on a renewal answered `lost`: the tree is killed and what it wrote since its last
  stored copy is kept. An answer at the holder's own epoch or below is to a give from before it got the chat,
  and means nothing.
- A give the store refuses (`auto.no_laptop`, `auto.no_machine`) leaves the chat at its holder and the wish in
  the store. The person is told once, and the holder does not try that wish again while renewals still tell it.
  The person asking again is a new wish and is tried again: the holder knows it by the wish's time (`moveAt`
  in the lease answer, `move.at` in the answer to a move asked from this daemon), which asking again starts
  again. An older store names no time; then a refused wish is tried again only once an answer comes without it.
- The new holder imports as for a takeover or a handback. A turn that was running is settled once and continued
  with the moved-chat text that exists (`Cut::Move`), not the "machine went away" text.

### The agent's own session goes with the copy

The demo's first finding that the product lacks: Claude Code and Codex keep each conversation in a file of
their own, and a new holder that resumes `harnessSessionId` without that file starts with no memory of the chat.
The manual move carries those files (`hub/transfer.rs`, `native::locate`); the Auto copy did not.

- The snapshot manifest gains `native: [{label, path, chunks: [sha256]}]` (default empty, so an older manifest
  still reads). The laptop and the machine put the harness's session files in every snapshot, the same files
  `native::locate` names for a manual move.
- An import puts them where the harness on this machine looks (`transfer_in`'s placement, which rewrites the
  folder-dependent part of the path), before the first resume.
- One chat's copy never changes another chat's agent memory. Whoever holds a chat writes its copy, so the import
  does not take the copy's word for whose a file is (`auto_session/import/bundle.rs` `agent_side`):
  - A file that is here already is replaced (the old one kept beside it as `.before-cloud-copy`) only when it is
    this chat's own: the chat is on this machine and the agent session it has here is the one the copy names.
    For a chat that is new here, or whose agent session here is another, a file that is here is left as it is,
    as a move by hand leaves it, and the import goes through. The same holds for cmux-harness's journal.
  - When another chat of this daemon keeps the agent session the copy names, none of the copy's agent files are
    placed and the chat goes on with the agent session it has here.
  - A Codex rollout is a session's only when its name is `rollout-…-<session id>.jsonl`, for the carry
    (`native::locate`) and for the placement alike; an id that is merely part of a name matches nothing.

### Daemon surface

- `_acpmux/auto_session/set` takes `mode: "local" | "auto" | "cloud"` (`auto` and `keepInCloud` stay accepted).
  These are the record's three states; the place picker's rows map to them as in the table above
  (This Mac = `local`).
- `_acpmux/auto_session/move` `{sessionId, to: "cloud" | "local"}`: the wish, sent to the store.
- `_acpmux/chat_move` `{sessionId, on: "local" | "cloud" | "auto"}` (the base's, 2026-11-25,
  https://github.com/manaflow-ai/cmux/pull/56018: `cmux chat move --on`, `acpmux session place`, the agent's
  `move_chat`) is `set` by `mode` behind `chat_place::consent`, so `cloud` moves the chat now and `local`
  brings a chat the Cloud has home before Auto goes off. As the base landed it the request set `auto` and
  `keepInCloud` only, which moved nothing and could not bring a chat home from the Cloud.
- A chat's row gains `autoSession.mode` and `autoSession.moving` (`"cloud" | "local"`, absent when not moving).
- `_acpmux/chat_place` and `_acpmux/chat_place_set` (the base's) stay what they are: the pick for a chat that
  has not started. Nothing on the page calls the two requests above yet. As the base ships it (2026-11-24,
  https://github.com/manaflow-ai/cmux/pull/53938), the Where menu's pick decides where the page starts the
  chat; a chat it starts on this Mac is made on this laptop's daemon and gets Auto on when `cloud.autoCloud`
  is on, and a chat it starts on a Cloud machine never reaches this laptop's holder loop. The daemon cannot
  tell "Machine…, this Mac" from Auto's "this Mac has room", so both get Auto on: a control for "this Mac
  only" and for "move now" on a started chat is the picker's to add, calling `set {mode}` and `move`.

As built (2026-11-24, `acpmux/src/auto_session/runtime/moves.rs`, `surface.rs`, `record.rs`,
`server/auto_gate.rs`):

- `move` is answered once the store took the wish, with the row (`moving` set). A laptop that holds the chat
  starts the give from that answer, without waiting for its next renewal; a chat the machine holds is given
  at the machine's next renewal. A refusal is the request's error: one plain sentence, the store's code as
  `data.reason`, `data.retryable`, and nothing changes.
- `set {mode: "cloud"}` on a chat with Auto off registers it kept in the Cloud, then moves it; on an Auto chat
  it is the move alone (the store keeps it in the Cloud from the same write). `set {mode: "auto"}` is Auto on,
  not kept. `set {mode: "local"}` on a chat that is here is Auto off; on a chat the Cloud has, the chat is
  moved home first and Auto goes off once it is here and this laptop stored a copy of its own (the record's
  `local_wanted`; the row says `mode: "local"` from the moment it was asked). Asking for Auto or Cloud again
  ends that.
- `move` and `set` are the person's only, as `set` was: not an agent's connection, not a remote connection or
  a peer. A Cloud machine's daemon refuses `move` (a chat is moved from the person's own devices).
- Neither request is in the pane's policy (`cmux-agent-pane-policy/policy.json`): the page sends neither yet.
- A laptop that wakes, or whose network changes, while its give is asked of the store (`giving`, step
  `asking`) only renews: the store may have taken the chat, so the chat stays frozen until the give or the
  renewal answers, and the turn the give stopped does not go on here meanwhile. Before the store was asked
  (steps `stopping`, `copying`) a wake ends the give as before: stop, ask, and a wish in the answer starts
  another. A laptop without an answer for 35 s stops itself in the middle of a give at any step. Either way, a
  stopped laptop that is answered "holder" with the wish still set continues its tree and begins the give
  again in that same step: the turn the first give stopped does not go on here between the two, and its
  continuation stays the one owed here if the chat ends up staying (`runtime/give.rs` `turn_stopped`).
- A give's copy waits for the chat's lane (`runtime/effects.rs` `copy`, `lane_done`). A holder caught in the
  middle of taking its inbox writes the message into the log and then acks it; a copy read between the two
  would hand the chat over with the message in neither the copy nor the inbox. Nothing new starts in the lane
  of a chat that is given, so the wait ends with the one thing that was running.

### Surfaces: none of its own (the place picker's work owns them)

What exists on the base and in open pull requests (read 2026-11-24), so this branch builds no control beside it:

- The web composer's Where menu (`webviews/src/agent-session/acpmux/EnvironmentPicker.tsx`): the Auto row opens
  Auto, Cloud only, Machine. New chats only, behind the hidden key `cloud.autoCloud`.
- The setting `agentPane.newChatsIn` (This Mac or Cloud) is already the default place of new chats: "everything
  in the Cloud" and "everything on this Mac" for new chats are that setting, not a new one.
- `cmux chat --on auto|here|cloud|vm:new` for a new chat.
- Open: https://github.com/manaflow-ai/cmux/pull/53449 (the pick moves an existing chat and is kept on disk),
  https://github.com/manaflow-ai/cmux/pull/52230 (a three-state control: Hybrid, Only in Cloud, Only on This
  Mac), https://github.com/manaflow-ai/cmux/pull/52043 (a Cloud button per chat),
  https://github.com/manaflow-ai/cmux/pull/51824 (move progress). Whichever control lands is the one control.

What this branch gives that control:

- The two daemon requests above are the seam: a control that sets a started chat to Auto, Cloud only or This
  Mac calls `_acpmux/auto_session/set {mode}`; "move it now" is `_acpmux/auto_session/move`. The row's
  `autoSession.mode`, `autoSession.moving` and holder are what it draws.
- Until such a control lands, the chat menu keeps this branch's two rows (Auto, Keep in Cloud), which set the
  same fields. They are removed when the picker covers started chats.
- No new CLI verb here: `cmux chat place` or the like belongs to the pull request that makes the pick apply to
  a started chat. The journey test drives the daemon requests directly.

### Known gaps this section does not close

- A store that was down reads the gap as every lease running out (demo finding 11).
- Two lost answers in a row to the parked take-back (demo finding 3, `tenure`).
- A laptop that wakes is stopped at the daemon's next step, not within a quarter second (finding 4).
- A view of a chat coming home does not yet say its files are being brought in (finding 13).

## Slices

| | Owns | Where |
|---|---|---|
| K. Core | Wire types, the holder's state machine as one pure `step` with its table (RFD 0026's shape), the manifest, the constants. Sans-I/O. | new crate `cmux-tui/crates/cmux-auto-session` |
| A. Cloud | `AutoSessionDO`, `AutoSessionIndexDO`, every route, the lease alarm, machine start, tests | `backend/apps/api/src/auto-sessions/`, `test/auto-sessions*.test.ts`, `wrangler.jsonc`, `env.ts`, `index.ts` |
| B. Laptop daemon | Auto flag per chat, renew loop, events and snapshot upload, inbox drain, wake stop-and-check, process-tree kill, standby and handback import | `cmux-tui/crates/acpmux/src/auto_session/` (laptop side) |
| C. Cloud machine daemon | Assignments, takeover import and the `machine_takeover` continuation, `create`, `deliver`, renew and upload while it holds; the VM install's calls go through the machine's Cloud agent | `cmux-tui/crates/acpmux/src/auto_session/` (machine side), `cmux-tui/crates/cmux-host/src/cloud/auto_session.rs` |
| D. Mac app and web UI | The setting (`SettingsSchema`), the chat menu item, the states in the chat list and header, Cloud-started chats in the list, the leftover-patch notice, the wake notice to the daemon | `Packages/macOS/CmuxNext`, `webviews/` |
| E. iPhone | List, open, send to and start Auto chats through the Cloud with no Mac | `cmux-next-ios/` |
| F. End to end | One simulated journey over real daemons and the real store: run, laptop gone mid-tool, takeover, phone message, laptop wake, handback | `cmux-tui/crates/acpmux/tests/`, `backend/apps/api/test/` |
