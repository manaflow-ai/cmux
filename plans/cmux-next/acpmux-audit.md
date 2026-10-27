# acpmux performance audit (rules D1-D8, A1-A3)

Status: audit landed 2026-10-23 (session cmux-4f, PL-acpmux); fixes in progress in the same
session (the lead moved acpmux ownership here: nobody in cmux-b6 owns acpmux code). Rules and
targets: [perf-lead.md](perf-lead.md), "Daemon and acpmux targets". Every acpmux op < 2 ms p95
send to reply, light and STRESS; 0 idle CPU.

Scope: the agent session daemon `cmux-tui/crates/acpmux` (201k lines: hub, server, store, agent
hosts, MCP helpers) and its app-side client (`Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane`,
`webviews/src/agent-session`). Code citations are `file:line` at `eef9f48b4fb` (base of this
audit), paths under `cmux-tui/crates/acpmux/` unless they say otherwise.

## Measurement

Bench: `cmux-tui/crates/acpmux/tests/perf_ops.rs` (new). It runs the real daemon binary, its file
store and its agent hosts with a streaming stand-in agent (`tests/fake_stream_agent.py`: no
model; each token is stamped on `CLOCK_UPTIME_RAW` when written). It fails when a budget is
missed, and prints `ACPMUX-PERF` lines plus `.build/acpmux-perf/perf_ops.json`.

- **light**: one chat, one attached client. Six ops timed 100 times each, send to reply:
  `_acpmux/status`, `_acpmux/sessions`, `_acpmux/draft_set`, `_acpmux/rename`, `_acpmux/attach`
  (50 records), `_acpmux/events` (50 records). Also prompt to `_acpmux/prompt_accepted`,
  `session/new`, and token to client for 400 tokens at 500/s.
- **STRESS** (the daemon's share of the app's STRESS session): 16 chats streaming at once
  (300 tokens at 200/s each, 3,200 tokens/s) to two attached clients (app and viewer) while a
  third connection times the six ops.
- **many**: 72 chats (more than the store keeps open, `OPEN_LOGS` 64; an agent chat in each of 60
  workspaces) streaming 40 tokens at 40/s each at once.
- **idle**: after STRESS, every agent alive, both clients attached: daemon context switches and
  CPU per 5 s window (median of 3), and the same for its agent hosts and agents.
- Run: `cmux-ci run --class isolated --script scripts/ci/cmux-tui-rust-check.sh --ref SHA
  --arg test --arg acpmux_ops_and_streaming --artifact .build/acpmux-perf/perf_ops.json`
  (AWS M4 Pro minis, macOS 27; the step's worker is named in the numbers below).

Numbers: section "Results". The ranked list below gives each finding's measured number where the
bench covers it, else the cost read from the code (marked "est.").

## Ranked findings

| # | Rule | Finding (evidence) | Number | Principled fix | Owner (git log) | Status |
|---|---|---|---|---|---|---|
| 1 | D1 | Every session-record save is a durable in-place write on the request path: `Hub::save_meta` (`src/hub/mod.rs:1131`) runs `LocalStore::save`, `config::write_atomic` (`src/config.rs:1214`): `sync_all` (F_FULLFSYNC on macOS, `:1234`), rename, folder `sync_all` (`:1258`), plus two ancestor-walk checks (`private_state_dir`). 46 callers, on tokio workers: `_acpmux/draft_set` (`set_composer_draft`, `:949`), rename, tag, archive, side, rules, policy, bookmarks, mark-unread and attach (`hub/seen.rs:57,73`), every status change (`set_status`: prompt start and end, `turns.rs`), mode/model changes (2 saves). `settle_permission` (`hub/permissions.rs:595`) holds the session's permissions lock across it, so the agent's permission answer and every summary of that chat wait | see Results (light.op.draft_set, light.op.rename) | One background record writer: the request takes a versioned snapshot under the meta lock and returns; the thread writes the newest snapshot of each session (a burst is one write; an older snapshot never replaces a newer one, which two racing saves could do before); a purge drops the queued save and waits out a write in flight; flush at shutdown and before a restart reads | Lawrence (agents) 102, Leo 97 (`hub/mod.rs`); Leo 25, Lawrence 23 (`store.rs`) | fix written, batch 1 (`hub/meta_writer.rs`) |
| 2 | A1, D1 | Each streamed token is a `write(2)` on the agent's reader task under ONE store-wide mutex (`store.rs:991`, `:1023`, from `hub/mod.rs:886`): every chat's tokens serialize on it. Past 64 written logs (`OPEN_LOGS`), each append that opens a log first closes the least recently written one with `sync_data` (F_FULLFSYNC) under that same lock (`store.rs:665`): with more than 64 chats streaming, nearly every token pays a device-wide flush and stalls every other chat. Each host entry is then acked by one frame per token (`agent.rs:971`) | see Results (many.token_to_client) | One log-writer thread: an append queues its line; each session's queue is one write; nothing syncs on the write path (closed and evicted logs stay dirty and `flush` syncs them all). A read of a log first waits for that session's queue. A host entry is acked once its record is written (ticket against the writer's per-session progress), one ack per batch | Leo 25, Lawrence 23 (`store.rs`); Lawrence 41 (`agent.rs`) | fix written, batch 1 (`store/log_writer.rs`, `agent::WriteTicket`) |
| 3 | D1 | `config.json` saves hold the config write lock across two fsyncs: model and effort picks (`hub/start_defaults.rs:242`), mode picks (`hub/start_mode.rs:547,712`, plus `start-mode.json`), default policy and defaults (`server/requests.rs:700,836`), presets. Every `config.read()` (a prompt's `child_for`, `session/new`, permission answers, `_acpmux/harnesses`) waits behind it | est. 20-50 ms per pick, on every reader | Make the bytes under the lock, write them on a config writer thread (newest bytes per file); a catalog reload drains it before reading the file back. Web-token rotation and peer add/remove stay synchronous: their callers read the file back at once | Lawrence 56, lawrencecchen 34 (`config.rs`) | fix written, batch 1 (`hub/config_writer.rs`) |
| 4 | D5 | A full connection queue (4,096 lines) drops replies and notifications silently: `Conn::send` ignores `try_send`'s error (`server/mod.rs:159`). A slow client loses tokens with no notice, and a dropped reply leaves its caller waiting forever | correctness | A reply waits for room (only its own request task waits); a dropped notification is counted and reported as `_acpmux/lagged {dropped}` once room returns, and the clients (app page, TUI, iOS, cmux-tui) already read again on it | Lawrence 47, Leo 36 (`server/mod.rs`) | fix written, batch 1 |
| 5 | D6 | Idle polling: each watched transcript polls every 400 ms forever (`hub/watch.rs:35`): open, fstat, two meta clones, 2.5 wakes/s per watched chat; `_acpmux/wait` re-reads every 1 s (`server/wait.rs:156`) and re-evaluates on EVERY hub event, building every session's summary (`:117`) once per streamed token while an orchestrator waits; each direct agent's reader polls `try_wait` every 500 ms (`agent.rs:309`; direct agents: `ACPMUX_AGENT_HOSTS=0`, Windows, model probes) | idle daemon with 20 hosted chats: ~0.1 wakes/s (default hosts on); +2.5/s per watched chat, +1/s per waiter, +2/s per direct agent | Watched chats follow file events on their folder and end on a take-over/close signal; `wait` evaluates only its sessions and wakes only on their state records (a peer session keeps a bounded 1 s re-read while waited for); direct readers wake on SIGCHLD | lawrencecchen, Leo (`watch.rs`); Lawrence 5 (`wait.rs`, `agent.rs`) | fix written, batch 1 |
| 6 | D1, D8 | `session/new` replies only after the harness started and initialized (`hub/lifecycle.rs:230-231`), after a synchronous `store.save` fsync (`:201`) and `canonicalize` on the worker (`:108`). `session/fork` copies the parent's whole log record by record before its reply (`hub/fork.rs:360`) and spawns before it (`:400`) | see Results (light.op.session_new) | Reply after the in-memory create with a client-minted id (D8); the spawn and the first durable write follow in the background (the pool claim path does this already); fork copies on a background job and replies with a copying state | Lawrence 73, Leo 26 (`lifecycle.rs`) | open (batch 2) |
| 7 | D2 | Session lists are O(all sessions) per request: `all_session_summaries` (`hub/peers.rs:763`) clones every session's full `SessionMeta` (`hub/views.rs:266`: drafts up to 1M characters, tool and model lists, config options), clones the parent's meta for `spawnedBy`, sorts, then pages. `_acpmux/sessions`, `_acpmux/watch`, and each watcher's `session_changed` per state record | see Results (op.sessions); est. 5-50 ms at hundreds of chats | One summary value per session, rebuilt when its state version changes (the record write already bumps `state_seq`); page before building; readers take the cached values | Leo 38, Lawrence 16 (`views.rs`) | open (batch 2) |
| 8 | D1 | Each prompt from the app or Web reads and parses `~/.claude.json` (often MBs), the Codex `config.toml` and the trust record, canonicalizes the cwd and walks `.git`, three times per prompt (`server/trust_gate.rs:264,292`, `web_control.rs`), in `spawn_blocking` but on the reply path; a cold chat adds folder-profile reads under the config read lock (`hub/worktree_care.rs:280`) | est. 2-5 ms x 3 per prompt | Cache the trust verdict per (cwd, harness family), invalidated by a file watch on the three files | Lawrence 6, Leo 5 (`trust_gate.rs`) | open (batch 2) |
| 9 | D7 | Start reads every open session's whole log twice and gates attach, prompts, queue edits and host adoption on it: `load_logs` (`hub/mod.rs:622`) runs `mark_unknown_outcomes` (one session after another, `:639`) and `restore_queues` (`:640`); `_acpmux/attach` waits for it (`server/requests.rs:995`). Before the ready line `LocalStore::list` runs twice, with two ancestor walks per session | est. 26.8 s for 3.9 GB of logs (the code's own note) | Keep the open-turn marker and the queue in the session record; start applies only the tail past `lastSeq` (`catch_up` reads it already); load a session's state on its first open or prompt (a per-session gate, not one global gate); adopt hosts in parallel; one `list` | Lawrence, Leo (`hub/mod.rs`, `hub/queue.rs`: Leo 21) | open (batch 2) |
| 10 | A3 | No process per tool call (A3 holds). Per chat: 5-8 processes and ~40-80 threads: the agent host (3 threads: runtime, a `waitid` thread, a record-watch thread, `agent_host/host.rs:931`), the harness, `cmux mcp serve`, and one `acpmux *-mcp` process each for forum, subsessions, secrets, offers, each a multi-thread tokio runtime (12-16 idle threads) started eagerly at the harness's first `tools/list` (`agent_tools.rs`), each opening a new daemon connection per call | see Results (stress.tree: processes and threads per chat) | One MCP helper per chat with a single-thread runtime (or `cmux mcp serve` calls the daemon socket itself), fixed tool lists in the server spec, a server starts on its first call; one daemon connection per helper; host exit and record watch on the runtime (kqueue), no extra threads | Lawrence 25, Leo 11 (`agent_tools.rs`); `cmux mcp serve` is cmux-tui (cmux-b6 PL-daemon) | open (batch 3; the cmux-tui side routed to cmux-b6) |

Further findings (smaller, or app side):

| # | Rule | Finding | Fix | Owner | Status |
|---|---|---|---|---|---|
| 11 | A1 | Per token per connection: the record's params are deep-cloned, `sessionId` and `_meta` set and the line encoded again for every attached connection (`server/mod.rs:946`); `append_at` deep-clones each record for the broadcast. Every connection's fan-out task wakes for every record of every session (one hub broadcast of 8,192, `hub/mod.rs:449`, `server/fanout.rs:10`) | Encode the standard `session/update` line once per record and share it among raw connections; route records to the connections subscribed to that session | Leo (`fanout.rs`), Lawrence 47 (`server/mod.rs`) | open (batch 2) |
| 12 | A1 | Tool calls: `add_canonical_paths` runs `realpath` and one `getattrlist` per path part for every `tool_call`/`tool_call_update` on the agent's reader (`hub/tool_paths.rs:14`, called at `hub/mod.rs:872`) | Cache per (session folder, path), resolve on a blocking thread | Leo (`tool_paths.rs`) | open |
| 13 | A1 | Claude workflow progress re-reads up to 4 MiB of the journal per progress line (`claude_stdio/workflows.rs:17`): quadratic in the run's length | Read from the last offset | Leo, Lawrence (`workflows.rs`) | open |
| 14 | D6 | The pool's RSS cap runs `ps -A` (fork, exec, full table) once per pooled entry every 60 s while the pool is warm (`hub/pool/reaper.rs:23`); the idle reaper re-arms 300 s for every attached chat (`hub/idle.rs`); 6 h and 24 h timers (catalog fetch, harness `--version` probes, upload sweep) | `proc_pidinfo`/`/proc` for the known pids, measured on pool events; arm the idle deadline only when the last client detaches | Lawrence 5 (`reaper.rs`) | open |
| 15 | A2 | The WebSocket handshake runs in each connection's own task (A2 holds: a slow client never blocks another), but `accept_hdr_async` has no deadline after the 5 s peek (`server/mod.rs:489`): a client that stalls mid-upgrade holds a task and a descriptor forever | One handshake deadline | Lawrence, Leo (`server/mod.rs`) | open |
| 16 | D1 | `_acpmux/status` locks each session's child mutex in turn and may wait for a host-pressure sample (`hub/views.rs:423`); close and kill scan the process table and `remove_dir_all` on the worker | Status reads a snapshot; the scans and the delete run off the worker (the purge's delete moved off it in batch 1) | Leo 38 (`views.rs`) | partly (batch 1) |
| 17 | A1 (app) | `AcpmuxPaneSocket` decodes and re-encodes every `session/update` on its inbound queue (`Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/AcpmuxRequestIds.swift:94-131`); the main thread JSON-escapes each batch, up to 4 MB, into the bridge script (`AgentPaneTransport.swift:328-350`, `AgentPaneTransportTypes.swift:77-80`); the page parses each frame twice (`webviews/src/agent-session/acpmux/wire.ts:118`, `direct.ts:1703`) and rebuilds the whole snapshot each frame (`direct.ts:3566`, `App.tsx:5921`, about 15 row-wide memos). Swift already coalesces to one main-thread hop per display frame (`AgentPaneFramePacer.swift`) | Pass the checked bytes through; build the batch script off main with raw JSON objects; parse once; a per-row store for the streaming row so the app component does not re-render each frame | Lawrence Chen 19, Leo 9 (Swift); Leo 29 (`App.tsx`), Leo 26 (`direct.ts`) | open (app batch) |
| 18 | D5, D6 (app) | `direct.ts:2535` keeps every token chunk in `this.events` for the attached chat (no cap; a rebuild replays all); the page writes its whole snapshot to `sessionStorage` every 250 ms while streaming (`App.tsx:547-569`); hidden panes keep reconnecting with no end (`direct.ts:1688`) and tick 1 Hz timers (`ActivityLine.tsx`, `WorkingFor.tsx`); each pane open does two libproc scans of every socket of every process (`AcpmuxServerPeer.swift:100-192`) and an extra unix-socket connection | Fold chunks into rows; save on hide or turn end; stop timers and reconnects while hidden; cache the peer check per daemon pid | Leo, Lawrence Chen | open (app batch) |

## Results

Filled from the bench runs (host, macOS, build sha). Light and STRESS side by side; ms, p50 / p95.
The nextest runs time the daemon as the dev profile builds it (acpmux at opt-level 0, its
dependencies at 3), so CPU-bound costs (a summary's build) read high; release numbers come from
`scripts/measure/acpmux-overhead.sh bench=daemon` (exclusive class, queued).

After batch 1 (`8649b1f6f95`, aws-m4pro-1, M4 Pro, macOS 27, nextest dev profile, run twice;
second run in brackets where it differs):

| Op | light (1 chat) | STRESS (27 chats, 16 streaming, 2 clients) | many (88 chats, 72 streaming) | Budget |
|---|---|---|---|---|
| `_acpmux/status` | 0.09 / 0.10 | 0.16 / 0.22 | 0.25 / 0.31 | ok |
| `_acpmux/sessions` | 0.14 / 0.15 | 4.03 / 4.19 | 13.3 / 13.8 | over: O(chats), finding 7 |
| `_acpmux/draft_set` | 0.03 / 0.04 | 0.04 / 0.09 | 0.05 / 0.06 | ok |
| `_acpmux/rename` | 0.15 / 0.18 | 0.26 / 0.33 | 0.33 / 0.38 | ok |
| `_acpmux/attach` (50 records) | 0.72 / 0.76 | 0.89 / 1.04 | 1.07 / 1.15 (max 11.2) | ok |
| `_acpmux/events` (50 records) | 0.52 / 0.54 | 0.77 / 0.89 | 0.82 / 0.86 (max 26.7) | ok |
| prompt to `prompt_accepted` | 0.11 / 0.15 | - | - | ok |
| `session/new` | 37.6 / 40.4 | - | - | over: spawn before reply, finding 6 |
| token to client | 0.32 / 0.41 | 1.14 / 2.33 (app), 1.14 / 2.39 (viewer) | 0.22 / 2.14 [1.99] | STRESS over by 0.3-0.4 ms |
| idle (5 s, 16 live agents, 2 clients) | - | daemon 0 switches, 0 ms CPU; hosts and agents 0, 0 | - | ok |
| processes / threads per chat | - | 54 processes for 27 chats (host + agent each), 108 threads; daemon 28-30 threads | 166 processes, 337 threads; daemon RSS 76 MB, processes 2.1 GB | stand-in agent: real harnesses add their MCP helpers (finding 10) |

Before (`f5e344a64bf`, the same bench without batch 1): queued on the fleet; filled in when it
lands.

## Decisions made here

- Session records, settings files and event logs become best-effort background writes, as the
  lead's daemon decision does for the journal: a crash can lose the last few milliseconds of a
  record; the log stays the source of truth (`catch_up`), and agent host entries are acked only
  once written, so a hosted agent's output is never lost.
- Web-token rotation and peer add/remove keep their synchronous `config.json` save: their callers
  (ssh peers, `cmux host add`) read the file back at once, and they are rare.
- `session/new` (finding 6) is not changed in batch 1: replying before the spawn changes the
  create contract for every client and needs D8 ids end to end.

## Notice to PL-acpmux: new chat typing prewarm (2026-10-27)

Landed 16a6e86a783..f1e15ab50ab (Lawrence 2026-10-26, "warm it up while the person types").
- `pool.hintedPerHarness` (default 1): at most that many hinted entries per harness across
  folders; the newest hint wins (`hub/pool/policy.rs` `cap_hinted`).
- `_acpmux/prewarm` `release: true`: takes the hint back for that harness and cwd, and ends the
  entry unless last-used wants it. It starts nothing, so the trust gate skips it.
- The pane (`webviews/.../newChatPrewarm.ts`) hints on the first typed character of a
  sessionless chat or the New Tab page. It releases after 3 s empty, on a harness or folder
  change, and on pagehide.
- Bench: `scripts/measure/acpmux-overhead.sh --arg=bench=prewarm`. Enter-to-first-output numbers
  are pending: the M4 Pro measure mini (cmux7s) was offline.
- Base debt seen: `_acpmux/typing` is in Swift `knownParams` but not in
  `cmux-agent-pane-policy/policy.json`.
