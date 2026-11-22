# Cloud Chief on a placed machine (cx-ebm.7)

Status: design for decision CLOUD-CHIEF-ON-A-MACHINE (coordinator, 2026-10-07):
no Durable Object brain; the cloud Chief is the same optchat-chief, headless on a
machine. (1) The user's paired server is the shipped path first. (2) A user
without one gets one per-user cmux Cloud VM, created only through the cmux VM
API (workers/cmux-vm, owner hq-ff; never Freestyle directly), at most one per
user (enforced in the backend), asleep within minutes of no activity, woken by
MuxDO wake rows, with a cost line per user per day in the admin view, behind a
flag limited to the manaflow team. optchat-lab pi-durable stays an experiment.
Nothing here is built yet beyond what section 1 lists.

## 1. Shape

One brain binary everywhere: `optchat-chief host` (Native/OptChat/optchat-chief),
the Rust OptChat Chief that the Mac app runs today (H8 resolution, decisions.md).
The cloud Chief is that host on a machine the user's account places the Chief on:

| placement | machine | awake |
| --- | --- | --- |
| Mac (today) | the user's Mac, one Chief home per macOS user | while the Mac runs |
| server | a paired server (`brain_place {host, install}`, brains/DESIGN-cmux-lawrence.md section 11) | always |
| cloud VM | one per-user cmux Cloud VM (cmux VM API) for a user without a server, behind the manaflow-team flag | woken by a wake row, sleeps when idle |

What exists: `HomeChief.brain_place` and `chief.update` from the app's Add Server
sheet (CloudChiefs.swift), the server pairing path, MuxDO as the wake queue
(`mux.bind`, `mux.wake`, `mux.ack`, `mux.configure {brain, brain_host}`,
home-core mux/domain.ts), cloud machines with pause/start/idle policy
(`cloud.machine.*`, CloudDO), and the shared behavior corpus that keeps the
brains equal (mux/packages/brain/conformance).

## 2. Conversation and identity

The placed Chief answers in its cloud main conversation (ConversationDO), not in
a Mac's local owner. On a server or VM, optchat-chief runs with `Source::Cloud`:
it reads and writes the conversation through the API Worker with the chief token
its install mints (`agt` = the chief; `mutate-shared` only for that token, G8).
The same wake rule, remote-origin gate, approval policy and harness routing apply
(cmux_chief::rules, cmux_chief::policy).

## 3. Wake path

1. A message in a conversation the Chief is in commits in ConversationDO; its
   outbox sends `mux.wake {conversation, seq, reason}` to the chief's MuxDO.
2. MuxDO stores the wake row. With `brain: "cloud"` and a `brain_host` that is a
   Chief VM, a new row arms an alarm (one per burst, not per row) that starts
   the VM through the cmux VM API when it is paused or stopped (the backend
   holds the user's VM id; the API's tenant scoping applies; a refused start
   leaves the rows and posts one notice in the conversation).
3. The VM boots, runs `optchat-chief host --source cloud` from its unit, takes
   its host lock, subscribes to `mux:<agent>`, reads each queued conversation
   from its agent read cursor (rows are hints; history is the truth), handles
   the messages with the shared wake rule and acks per conversation
   (`mux.ack {conversation, seq}`).
4. A server placement never sleeps: the brain stays subscribed and the alarm is
   not armed (`brain_host` names a server, not a cloud machine).

Bound: a cold wake is VM start plus host start plus the first settle. Measure on
staging before promising a reply time; until then the conversation shows the
existing "Organizing Chief history" status and a "starting" notice.

## 4. Idle sleep

The host reports idle when all of these hold for the idle period (default
10 min, the machine's idle policy): no pending wake rows, no turn running or
settling, no child or subagent running, the outbox empty. It then checkpoints
the memory (`memory.sqlite3` checkpoint, already saved every 256 messages and at
shutdown) and reports `cloud.vm.status.report {state: idle}`; CloudDO pauses the
machine through the cmux VM API (pause, else stop) within minutes. The disk (memory, Chief home, acpmux sessions)
survives a pause; a snapshot schedule covers loss of the machine.

## 4a. Identity after a snapshot restore

A Chief VM may be created or resumed from a memory snapshot, so two VMs can wake
with the same RNG state and the same identifiers. Before it serves, the boot
unit reseeds the kernel RNG and regenerates `/etc/machine-id` and the SSH host
keys; the brain, at start, regenerates its ephemeral state (acpmux session ids,
the host lock's start nonce, the turn and compactor session names it derives
from a fresh value) and refuses to start from a Chief home whose install key is
already in use by another VM (the one-VM record names the VM that owns it).

## 5. Placement handoff (one history, one writer)

The commit point is `chief.update {brain_place}`; a Chief answers from exactly
one place.

Mac to cloud (VM or server):
1. The app stops the Mac Chief host and its acpmux (End Sessions path).
2. The Mac history moves: the local Chief conversation's messages go into the
   cloud main conversation with their authors and times through a cloud import
   op (the cloud twin of cmux-tui `conversation-import`: local callers only,
   owner keeps seq and time authority, idempotent by message key; needs the
   backend lead), and the OptChat memory goes as its text export
   (`optchat-chief memory export --text`, then `memory import` on the target),
   so the target's logged_seq matches the imported conversation.
3. `chief.update {brain_place}` and `mux.configure {brain: "cloud", brain_host}`.
4. The target host starts, finds the memory and the conversation in step, and
   answers. The Mac's Home shows the placed Chief (HomeChiefSource already
   prefers a placed chief; the rule changes from "local has no history" to
   "placed wins" once the import exists).

Cloud to Mac or to another machine: the reverse export, the same commit point.
A failure before step 3 leaves the old placement answering; after step 3 the
new one answers and the old host is stopped by the app or by its own placement
check (it reads `chief.list` and stops when `brain_place.install` is not its
own).

## 6. Model plane

On the Mac and on Lawrence's server the Chief's turns and compactor run through
acpmux harnesses (`claude-sr` through the team subrouter). A cmux Cloud VM is not
on the tailnet. Options for the decision:

- the cmux Cloud model route the VM gets at create (the coderouter environment
  that Cloud VMs already receive), with `claude` (direct Claude Code login is
  not available on a VM) replaced by a `claude-stdio` profile whose base URL is
  that route: the harness gate already admits a `claude` profile routed to a
  known router (cmux_chief::policy::harness, TEAM_SUBROUTER_URLS would gain the
  Cloud route);
- or the user's own key, stored per user and given to the VM at start.

The compactor follows the turn harness's family (Claude: claude-sonnet-5-5;
Codex: its default), as on the Mac.

## 6a. One Chief VM per user

The backend keeps the user's Chief VM record (user, VM id from the cmux VM API,
state, created_at) and refuses a second create for the same user in one
transaction (a unique key on the user); a create races to one VM and the loser
adopts it. Deleting the placement keeps the VM stopped for a grace period, then
deletes it through the API. The VM's own credentials (its install key and the
chief token it mints) reach only that user's Chief: `mutate-shared` only for the
chief token, no other conversation, no other user's objects.

## 6b. Cost line

Each wake, run and sleep is recorded with the VM's running seconds; the admin
view shows per user per day: running minutes, starts, the VM API's price for
them, and model spend from the Chief's per-node and per-turn usage lines
(already logged by optchat-chief). A user over a daily cap gets a notice and the
VM is not woken until the next day (cap to decide).

## 7. Approvals and tools

Device messages are the normal case in the cloud. `remote.autoApprove` defaults
to true (decision 2026-10-06), so turns run with the configured policy; with it
off, an `ask` turn needs an answer in the conversation, which works from any
device (the approval text answers, brain/approvals.rs). Tools: the VM is a real
machine, so the Chief keeps Claude Code's tools, its subagents and children
(acpmux on the VM), and `cmux` CLI calls reach the VM's own cmux-tui.

## 8. Order of work (once decided)

0. Server path finished (shipped first): placement UI states, honest status
   (CloudChiefStatus: ready, thinking, not answering), and the server answers
   while the app is closed (the brain subscribes to `mux:<agent>`).
1. Cloud source for optchat-chief: read, send and ack through the API Worker
   with the chief token; wake from `mux:<agent>`; corpus inbox cases on this
   source too.
2. One-VM record and create through the cmux VM API (hq-ff); MuxDO alarm that
   starts the VM; idle report and pause; the manaflow-team flag.
3. The cloud import op (backend) and the handoff in the app (Mac to cloud
   first), with the conversation-import and memory export tests.
4. VM image: optchat-chief, acpmux, cmux-tui, the harness profile for the
   chosen model route; per-user VM create on first placement.
5. Cost line in the admin view (backend lead).
6. Staging measurement of the cold wake; then the reply-time promise.

## 9. Decisions

Internal phase (coordinator, 2026-10-07):

- Model route: Chief VMs use the Cloud coderouter route (section 6, first
  option).
- Daily cap: $20 per user per day under the manaflow-team flag; an alert at
  80%, and at 100% no new turns start and the Chief posts a visible notice.
- Who pays after the flag: Lawrence's open decision.
- Backend work (one-VM record, MuxDO wake alarm, cloud import op, admin cost
  line, the flag): routed to hq-ff (Cloud/CloudDO and cmux VM owner).

cmux VM API answers (owner, via hq-ff, 2026-10-07):

- Tenant: the Chief VM belongs to the user's Stack team (the personal team for
  a solo user) and counts in that team's quota, billing and list. The backend
  acts through one `cmuxvm_sk` service key (scopes vm:read, vm:write, vm:exec,
  only VMs labelled `role=chief`), for a team only with an explicit
  `x-cmux-team-id`, a ServiceMayActFor proof and an audit row (a small slice
  after S2).
- Image: a Chief snapshot built by images/cmux-vm with optchat-chief, acpmux,
  cmux-tui and a boot unit running `optchat-chief host --source cloud`; the VM is
  created from that snapshot id.
- Restore identity: after a memory-snapshot restore every clone must reseed its
  RNG and regenerate machine-id and host keys, and the brain must regenerate
  its own ephemeral keys and session ids before it serves (section 4a).
- Price: the provider publishes none; the cost line is VM running seconds from
  the API's start, pause and stop audit times a configured rate (marked
  unverified), plus starts; usage endpoints come in S3b.
- Pause plus the wake alarm is the design; the resume time is unmeasured (the
  owner measures it).
- API state: S1 PR 18194 (preview cmux-vm-preview.debussy.workers.dev), S2 PR
  18199 (create, list, get, start, stop, pause, resume, fork, delete, exec,
  files; idempotency, quotas, audit), S4 PR 18195 (Rust cmux-vm CLI and the
  @cmux/vm SDK). The one-VM record and the wake alarm build against
  workers/cmux-vm/openapi.json on feat-cmux-vm-s2.

Still open: whether a user with a server can also have a VM (one placement at a
time is the rule above).
