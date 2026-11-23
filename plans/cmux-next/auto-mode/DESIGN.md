# Auto mode: a session keeps running when the laptop goes away

Status: building on branch `cloud-cmux-mode`, one integration PR into `feat-cmux-next`. Off by default
(setting `cloud.autoMode`); the store is unbound in production until it ships there, as hand-offs are.

Builds on cloud work mode (`backend/apps/api/src/handoffs`, Leo 2026-10-27): there the person sends a chat to a
Cloud machine by hand. Auto mode makes the same move happen by itself when the laptop goes away, and back when
it returns.

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

## Cloud API

`/v1/auto-sessions`, in `backend/apps/api/src/auto-sessions/` beside `handoffs/` and in its shape:
`AutoSessionDO` (one per chat: record, lease alarm, events, chunks, inbox, assignment) and `AutoSessionIndexDO`
(one per owner: the list, the Auto machine). Errors are `{error: {code, message}}`. Routes answer 404 where
`AUTO_SESSION_DO` is unbound.

Callers: **owner** (a signed-in session or a person's install: the laptop's daemon, the Mac app, the phone) and
**machine** (the bearer of a VM install bound to the chat's Auto machine; its `holder` is `vm:<that machine>`).

| Route | Caller | Body | Answer |
|---|---|---|---|
| `GET /v1/auto-sessions/machine` | owner | | `{team, machine}` or 404 `auto.no_machine` |
| `PUT /v1/auto-sessions/machine` | owner | `{team, machine}` | `{team, machine}` |
| `PUT /v1/auto-sessions/:id` | owner | `{auto, title, harness, device, keepInCloud?, repo?: {remote, branch}}` | `{session}`; first call makes it with holder `device:<device>`, epoch 1. `auto: false` closes it: 409 `auto.held_in_cloud` while a machine holds it |
| `POST /v1/auto-sessions` | owner | `{title?, harness, repo: {remote, branch}, firstMessage: {id, text}}` | 201 `{session}`: holder the Auto machine, assignment `create`, machine started; 409 `auto.no_machine` |
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
