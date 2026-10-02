# cmux-next Tasks

Status: draft 1, 2026-10-02 (Tasks lead). Spec: cmux-next-spec `spec/tasks.md` (only the coordinator edits the spec; this plan is the spec proposal), `spec/team-vm.md`, `spec/cloud-and-automations.md`, decisions D17 (rebuild, internal first, forkable core), S4 (one team VM), D20 (muxes operate on everything), D31 (zero-loss tier). Binding: OWNERSHIP-PRINCIPLES.md.

Tasks is the team's issue tracker inside cmux: our own data model and service, the `cmux task` CLI, MCP tools, palette actions and mux code mode from one catalog, and a native macOS pane. Product copy and docs name no other tracker.

## 1. Roles and owner

| Entity | Owner | Role |
| --- | --- | --- |
| task, status, project, label, relation, comment, agent session, team task settings, activity | the team's **Tasks service** (process `tasks` in the team VM; locally `cmux-tasks serve` in dev mode) | single writer |
| idempotency ledger, op log, snapshots | Tasks service, on the team VM zero-loss tier | single writer |
| VM id, wake lease, routing | `TeamVmDO` (team VM lead) | router |
| search and cross-team projections, inbox counts while the VM sleeps | PlanetScale `cmux-next` via outbox | projection |
| automation definitions and runs | `SchedulerDO` (automations lead) | consumer of task events |
| list filters, grouping, selection, scroll, layout variant, drafts | each client | client view state |

The Tasks service is a Rust process built from two crates in `cmux-tui/crates/`:
- `cmux-tasks-core`: the pure model. Types, ops, `reduce(state, envelope, ctx) -> Result<Commit, Reject>`, invariant checker, catalog entries. No I/O. Proptests.
- `cmux-tasks`: the service. Op log store, snapshots, group commit, idempotency ledger, event fan-out, the JSON-lines socket server, the client, the CLI verbs (mounted by the `cmux` binary as `cmux task …`; a standalone `cmux-tasks` binary exists until #16174 mounts them).

Forking (spec "fork = a copy of the app") forks these two crates plus the app's extension code. Contract tests are the catalog schemas plus the reducer property suite.

## 2. Data model

Ids are public prefixed strings, client-chosen UUIDv7 for creates (`task_…`, `cmt_…`, `rel_…`, `asess_…`, `lbl_…`, `prj_…`, `st_…`), so a retried create is naturally idempotent and clients can reference an entity before its echo.

```
Team settings { key_prefix: "CMX", next_number, default_status, agent_flow: AgentFlow, review_status? }
Status   { id st_, name, category: triage|backlog|unstarted|started|completed|canceled, position, color: GhosttyColor }
Project  { id prj_, name, state: planned|active|paused|completed|canceled, lead?: Principal, archived }
Label    { id lbl_, name (unique, case-insensitive), color: GhosttyColor, archived }
Task     { id task_, number (allocated at commit, never reused), title (non-empty, ≤ 512),
           description { text, version }, status: st_, priority: none|urgent|high|medium|low,
           assignee?: Principal, delegate?: AgentRef, labels: set<lbl_>, project?: prj_, parent?: task_,
           estimate?, due?, sort_key (fractional index, unique), attention?: needs_input|failed|review,
           created_by, created_at, updated_at, started_at?, completed_at?, canceled_at?, archived, deleted }
Relation { id rel_, kind: blocks|related|duplicate, from: task_, to: task_ }
Comment  { id cmt_, task, reply_to?: cmt_ (one level), author: Principal, body, version, created_at, edited_at?, deleted }
AgentSession { id asess_, task, agent: AgentRef, status: pending|claimed|working|awaiting_input|done|failed|canceled,
               claimed_by?: host, plan: [{content, status: pending|in_progress|completed}],
               links { acp_session?, workspace?, host?, vm?, pr? }, created_by, started_at?, ended_at? }
Principal = user(usr_) | agent(AgentRef)
AgentRef  = { principal: agt_…, class: mux|ordinary, harness: claude|codex|opencode|…, on_behalf_of: usr_ }
GhosttyColor = palette index 0..15 (rendered from the user's Ghostty theme, never hex)
```

Assignee includes agents: `assignee` is the accountable principal (usually a person); `delegate` is the agent doing the work. Assigning an agent in any UI sets `delegate` and, when `assignee` is empty, sets `assignee` to the human on whose behalf the actor works. The UI shows one Assignee control listing people and agents (decision T3).

Activity log: every commit appends events (`task.created`, `task.updated {fields, before, after}`, `task.status_changed {from, to, from_category, to_category, by_agent_flow}`, `comment.created`, `relation.added`, `agent_session.status_changed`, …). Activity is the event stream; there is no separately written activity table. Each event carries `seq` (per team, gapless), `tx` (the request's transaction), `actor`, `origin`, `at`.

### Invariants (checked by the reducer; proptests in `cmux-tasks-core`)

1. Numbers: task numbers are unique, `< next_number`, and never reused (deletion keeps a tombstone).
2. References: a task's status, labels, project and parent exist and are live; relations and comments reference existing tasks; sessions reference existing tasks.
3. Acyclic: the parent forest and the `blocks` graph have no cycles; no self relations; at most one relation per (kind, from, to) and per unordered pair for `related`.
4. Workflow: every team has at least one status in each of backlog, unstarted, started, completed, canceled; deleting a status names a replacement and moves its tasks in the same commit; `completed_at` is set iff the status category is completed (same for `canceled_at`, `started_at` once started).
5. Idempotency: an envelope with an already committed `(actor, key)` and the same fingerprint returns the recorded result and changes nothing; a different fingerprint is rejected `idempotency_conflict`.
6. Determinism: replaying the op log from any snapshot through `reduce` yields the live state (the store's recovery is that replay).
7. Descriptions and comments: updates carry the version they edit; a stale version is rejected, never merged.
8. Labels: names are unique case-insensitively among live labels.
9. Sort keys: unique among a team's live tasks; the owner reassigns on collision.
10. Agent sessions: at most one non-terminal session per (task, agent principal); status changes come only from the session's agent principal, a mux acting for it, or a human cancel; a session claim is compare-and-swap (`pending -> claimed` once).
11. Agent flow is monotonic: an automatic status move never lowers the category rank and never overrides a human status change made after the session started.
12. Deletion cascades at the owner: deleting a task removes its relations and clears its children's parent in the same commit (destructive policy at the owner).

## 3. Ops (catalog family `task`, owner `tasks`)

Every mutation requires an idempotency key, every read forbids one (operation-catalog.md). The actor comes from the connection (token or socket peer), never from params.

| Op | Class | Risk | Notes |
| --- | --- | --- | --- |
| `task.create {id?, title, description?, status?, priority?, assignee?, labels?, project?, parent?, estimate?, due?, sort_key?}` | mutation | mutate-shared | returns `{id, key}` |
| `task.update {task, set{…}, add_labels?, remove_labels?, description?{text, if_version}}` | mutation | mutate-shared | |
| `task.move {task, before?, after?}` | mutation | mutate-shared | sort key between neighbours |
| `task.archive / task.unarchive {task}` | mutation | mutate-shared | |
| `task.delete {task}` | mutation | destructive | tombstone; cascades (inv 12) |
| `task.get {task}` / `task.list {filter, order, limit, cursor}` | read | read | `task` accepts `CMX-12`, `task_…` or unique id prefix |
| `task.subscribe {after_seq?}` | stream | read | events + `request-settled` |
| `task.delegate {task, agent, target?, prompt?}` | mutation | execute | creates a pending agent session |
| `task.session.claim {session, host}` | mutation | mutate-shared | one dispatcher wins |
| `task.session.attach {session, acp_session, workspace?, host?}` | mutation | mutate-shared | pending/claimed -> working |
| `task.session.update {session, status?, plan?, pr?}` | mutation | mutate-own | agent principal only |
| `task.session.cancel {session}` | mutation | mutate-shared | human or mux |
| `task.comment.add / update / delete` | mutation | mutate-shared | update needs `if_version` |
| `task.relation.add {kind, from, to} / remove {relation}` | mutation | mutate-shared | |
| `task.label.create / update / delete`, `task.label.list` | mutation/read | mutate-shared | |
| `task.status.create / update / delete {replacement}`, `task.status.list` | mutation/read | mutate-shared | |
| `task.project.create / update / archive`, `task.project.list` | mutation/read | mutate-shared | |
| `task.settings.get / update` | read/mutation | mutate-shared | key prefix, agent flow |

Every entry declares its surfaces in the catalog (`cli`, `mcp`, `palette`, `code_mode`); `cmux-tasks-core::catalog` is the one source, exported as JSON into the merged catalog. MCP default exposure: `task.list/get/create/update`, `task.comment.add`, `task.session.update`; opt-in: label/status/project admin, `task.delete`. Palette actions are generated from entries with `palette` metadata: Open Tasks, New Task, My Tasks, Start Task, Delegate Task to Agent, Copy Task Key. Mux code mode: `mux.task.create({...})`.

## 4. Storage (decision T1)

Choice: **an append-only op log on the zero-loss tier is the source of truth; state is the fold of the log through the pure reducer.**

```
/srv/team/apps/tasks/data/            (zero-loss tier; locally ~/Library/Application Support/cmux/tasks/<team>/)
  LOCK                                single-writer lock (flock), plus the TeamVmDO lease in the VM
  log/00000000000000000001.jsonl      segments, one committed record per line, rotated at 4 MiB
  snapshots/<seq>.json                full state at seq, written tmp + fsync + rename, every 1,000 commits
/var/cache/team/tasks/                (local tier, rebuildable) search index, later SQLite FTS projection
```

A record is `{v:1, seq, tx, at, actor, origin, key, fingerprint, op, result}`. Group commit: the writer drains the request queue, reduces each op against the working state, appends the batch, `fsync`s once, then answers and publishes events. A torn final line after a crash was never acknowledged and is truncated on open. Recovery loads the newest valid snapshot and replays later records (invariant 6).

Why not SQLite in WAL mode on JuiceFS (the earlier spec): SQLite's durability depends on fsync ordering, shared-memory `-shm` mmap and byte-range locks, which is the network-filesystem configuration SQLite's own docs warn against; one filesystem bug corrupts the whole database instead of one tail record. Random page writes and checkpoints also become many small R2 objects per commit, while a log is sequential appends. The log also gives a clean fallback if the D36 spike finds no FUSE: each group commit becomes one R2 object `log/<seq>` written with a conditional create, which is also a single-writer fence that a restored second VM cannot pass.

**Strongest objection: "you are writing your own database."** Recovery, compaction, a log format that must be readable forever, and queries are now ours. Answer: the reducer exists anyway (OWNERSHIP-PRINCIPLES requires it), so the store adds only append, fsync, snapshot and replay (about 400 lines, property-tested with crash injection at random byte offsets). The record carries a format version and old ops upcast on read. Queries run on the in-memory state (a team's tasks fit in memory: 100k tasks is about 100 MB) and later on a SQLite projection on the local tier, which is rebuildable and never the source of truth. If this proves wrong, moving to SQLite is a projection change, because the log replays into any store.

Second objection (shared with the team VM spec): the Tasks service is unavailable while the VM is down. Lists stay readable from the PlanetScale projection; writes fail with `owner_unreachable` and nothing queues (U5).

## 5. Transport and event stream

- In the team VM: clients reach the service through the API Worker and `TeamVmDO` (wake + route); the Worker forwards ops over the VM link as `cmux.wire/1` frames. The team VM lead owns that path; the Tasks service exposes the same JSON-lines protocol on a Unix socket inside the VM.
- Locally (dev mode, and personal use without a team VM): `cmux-tasks serve` holds `LOCK` and listens on `$XDG_RUNTIME_DIR/cmux/tasks-<team>.sock` (macOS: `~/Library/Application Support/cmux/tasks/<team>/tasks.sock`, 0600 in a user-only directory). The CLI uses the socket when a server holds the lock, otherwise opens the store in-process under the lock (still single writer). The app and agents subscribe for events.
- Protocol: request `{id, op, params, key?, origin?}`; reply `{id, ok: result}` or `{id, err: {code, message}}`; after every request `{settled: {tx, seq}}`; on a subscription `{event: {...}}` lines in `seq` order. A client resumes with `after_seq`; a gap is impossible because `seq` is gapless per team.
- `owner_for(task)`: the team's Tasks owner is the team VM when `TeamVmDO` reports one, else the local service. One function in `cmux-tasks` resolves it (`Owner::resolve`).

## 6. Agent assignment flow

1. A person (or mux) runs `task.delegate {task, agent: {harness: "claude"}, target: "local" | "vm" | host}`. The owner creates `AgentSession {status: pending}`, sets `delegate`, emits `task.delegated`.
2. Dispatchers subscribe to `task.delegated`: the user's Mac daemon for `local`/host targets, the cloud dispatcher (a Workflow) for `vm`. A dispatcher calls `task.session.claim {session, host}`; the owner's CAS lets exactly one win.
3. The winner opens an agent session through the catalog (`acp.session.create` on that host, in a worktree named from the task key, prompt = task title, description and link), then `task.session.attach {session, acp_session, workspace, host}` (status `working`).
4. Attach also works for an existing session: "Link to task" in the agent pane or `cmux task session attach CMX-12 --acp-session …`.
5. The agent (or acpmux hooks for it) reports `task.session.update {status, plan}`: `awaiting_input` sets `attention: needs_input` (the inbox shows it); `done` sets `attention: review` and links the PR; `failed` sets `attention: failed`.
6. Status follows agent activity (team setting `agent_flow`, default `forward`): `working` moves a triage/backlog/unstarted task to the default started status; `done` moves it to `review_status` when the team has one; nothing auto-completes (the PR merge or a person completes it). The rule is in the reducer and is monotonic (invariant 11). Setting `off` disables automatic moves.
7. Who may delegate: people and muxes freely; ordinary agents need a grant (D20); `task.delegate` has risk `execute`.

## 7. Automation triggers

Automations use the existing trigger shape `{type: event, source: task, event, filter?}` (cloud-and-automations.md). Events offered: `task.created`, `task.status_changed`, `task.assigned`, `task.delegated`, `task.labeled`, `task.agent_session.status_changed`, `task.comment.created`. Filter fields: project, label, status category, assignee, delegate, priority. Delivery: the service's outbox (part of the same log commit) is drained to `TeamVmDO`, which calls `SchedulerDO` `automation.deliver` with delivery id `task:<team>:<seq>` (dedupe on redelivery). Locally the daemon's automation runner consumes the same stream. Example: "when a task gets label `agent`, delegate it to Codex on a VM" is an automation whose step is `task.delegate`.

## 8. Clients

- macOS module `CmuxNextTasks` (no daemon import): `TasksModel` holds the confirmed mirror (owner events only) plus one ordered intent log; visible = mirror + pending intents; an intent leaves on its echo (matched by idempotency key) or reject (animates back). `TasksSource` protocol with `MockTasksSource` and `SocketTasksSource` (Unix socket, JSON lines, async with deadlines, event-driven).
- Three layout prototypes behind Debug Settings `tasks.layout` (DEV/NIGHTLY): `list` (grouped by status, dense rows), `board` (a column per status, drag between columns), `inbox` (attention-first: needs input, review, assigned to me, then the rest, with a detail pane). Release uses the picked one.
- Colors: status and label colors are Ghostty palette indices rendered from the terminal theme; selection and hover use subtle grays; no blue. Labels are minimal (glyphs over words), strings localized en and ja (plus the other check-l10n languages as `needs_review`).
- Focus: CLI/MCP/agent changes never move selection or scroll in the pane (origin rule); only user actions do.

## 9. Settings and tunables

User settings (Settings window and `cmux.json`, documented): `tasks.defaultTeam`, `tasks.startCreatesBranch` (true), `tasks.branchFormat` (`{key}-{slug}`), `tasks.agentFlow` (team setting mirrored read-only). Debug tunables: `tasks.layout`, `tasks.rowHeight`, `tasks.boardColumnWidth`.

## 10. Phases

1. This plan (spec proposal sent to the coordinator).
2. `cmux-tasks-core` (model, reducer, invariants, proptests, catalog), `cmux-tasks` (log store, service, socket server, client, CLI), Swift `CmuxNextTasks` with three variants and the mock source. Verified on a Blacksmith testbox (Rust) and `swift build` (Swift).
3. App wiring: palette actions, a Tasks tab kind, `SocketTasksSource` to the local service, daemon supervision of `cmux-tasks serve`.
4. Team VM deployment (team VM lead's app runtime), `TeamVmDO` routing, PlanetScale outbox projection, automation delivery, GitHub PR links, importer.

## 11. Decisions for Lawrence

- T1 storage: (a, rec) op log on the zero-loss tier + in-memory/local projections; (b) SQLite WAL on JuiceFS; (c) SQLite on local disk with Litestream (not zero-loss).
- T2 layout: list, board or inbox as the default (prototypes behind `tasks.layout`); rec: inbox for agent-heavy teams, decide after dogfood.
- T3 assignee: (a, rec) one Assignee picker listing people and agents, stored as accountable `assignee` + working `delegate`; (b) one `assignee` field that may be an agent (no accountable person).
- T4 CLI nouns: (a, rec) everything under `cmux task …` (`cmux task label`, `cmux task project`) to avoid top-level collisions; (b) top-level `cmux project`, `cmux label`.
- T5 agent flow default: (a, rec) `forward` (working -> started, done -> review, never auto-complete); (b) `off`.

## 12. Status (2026-10-02)

Built: `cmux-tasks-core` (model, reducer, invariants 1-12 as `invariants::check`, catalog with 36 ops, exports checked in under `catalog/` with a drift test), `cmux-tasks` (op log store with torn-tail recovery and snapshots, group-commit engine, event ring, Unix socket server, client, catalog-driven CLI, standalone `cmux-tasks` binary), Swift `CmuxNextTasks` (mirror + intent log model, mock and socket sources, three layouts behind `tasks.layout`, palette items from the catalog export, 21-language string table). Verified on a Blacksmith testbox: clippy `-D warnings`, proptests (reducer contract, idempotency, determinism, generator coverage, crash at a random byte), scenario tests, socket end to end, CLI in-process. Swift: `swift build --build-tests`, `swift test --filter CmuxNextTasksTests` (seeded convergence test, decode of owner JSON), snapshot renders of each layout.

CLI grammar agreed with the #16174 owner: nouns nested under `cmux task`, reserved global flags respected (`--json`, `--idempotency-key`, `--socket`, `--session`, …), random idempotency key printed on failure, `KEY = current` from the branch then `$CMUX_TASK`, `task watch --count N --timeout S` for bounded waits. Task-noun exit codes: 0 ok, 1 internal, 2 usage, 3 not found, 4 rejected, 5 owner unreachable or deadline, 6 idempotency conflict (the rest of the CLI exits 1 on owner failures today). Interim mount: `cmux_tasks::cli::run`; target: verbs generated from `catalog/tasks-catalog.json` by the shared generator.

UNVERIFIED or not built: the app does not open the pane yet (no Tasks tab kind, no palette registration, no daemon supervision of `cmux task serve`); `SocketTasksSource` against a live server from the app; team VM routing through `TeamVmDO` (`Owner::TeamVm` returns unreachable); authenticated actors (the local socket trusts the `hello` actor like the control socket trusts the uid); PlanetScale outbox, automation delivery to `SchedulerDO`, GitHub PR links, search projection; the agent dispatcher (claim + `acp.session.create`) is designed, only the owner side exists; TLA+ model of the intent protocol for Tasks (the generic ownership model covers the shape); MCP server wiring (tool definitions export only).

Shortcuts taken: queries scan the in-memory state (no index); the Swift socket source writes on the main thread (small local writes); the client move overlay predicts sort keys approximately (the echo corrects it); ja and the other 19 languages are machine translations (`needs_review`).

## 13. Tasks as a first-party app (Lawrence, 2026-10-02)

Decision: Tasks is an official first-party app on the app platform (like calendar and agent messages), with a persistent server side that runs on the team VM or on a user's "cmux server" machine. The Rust Tasks service stays as that server. Proposed shape, for the app platform lead (plans/cmux-next/app-platform.md does not yet define server-side apps or native panes):

- App id `dev.cmux.tasks`, publisher cmux, tier first-party, `cmux-app.json` in `apps/tasks/` beside the two crates.
- New manifest block `server` (proposal): `{"kind": "native", "binary": "cmux-tasks", "args": ["serve"], "catalog": "catalog/tasks-catalog.json", "hosts": ["team-vm", "cmux-server", "local"], "data": "durable"}`. The daemon on the chosen host supervises the binary (the same supervisor as the app host processes); `data: durable` maps to the zero-loss tier on the team VM and to the app's data directory elsewhere. A server app is the single writer of its entities (OWNERSHIP-PRINCIPLES), so exactly one host runs it per team; the team record names that host (team VM by default, or a member's cmux server when the team has no team VM).
- Catalog ownership: `task.*` entries get owner `app:dev.cmux.tasks`; `owner_for` routes them to the host that runs the server (TeamVmDO for the team VM, the host relay for a cmux server, the local socket in dev). Scopes for other apps derive from the entries as usual (`task:read`, `task:write`, `task:execute` for `task.delegate`).
- `contributes`: `commands` from the catalog's `palette` metadata plus UI commands (Open Tasks, My Tasks, Start Task, Copy Task Key), `menus` placements (task row context menu: status, priority, assignee, delegate, archive), so the pane's hand-built status menu goes away (review finding); `paneKinds: [{"id": "tasks", "renderer": "native"}]` for first-party apps whose pane is a native module (CmuxNextTasks) rather than a scene tree; `sidebarSections` (inbox count, my open tasks) as scene trees; `automationTriggers` from `TRIGGER_EVENTS`; `mcp: {"group": "task"}`.
- The forkable-core idea of spec/tasks.md maps onto app forks: a team's fork is another build of the same app id on its own host, held to the catalog contract tests.

Open for the app platform lead: whether `server` and `paneKinds: native` enter the manifest schema now (my recommendation) or first-party apps get a private registration path; and the supervisor API the daemon exposes for server apps.
