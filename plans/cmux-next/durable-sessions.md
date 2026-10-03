# Durable sessions: terminals and agents survive app, daemon and acpmux restarts

Status: plan by the durable-sessions lead, 2026-10-02, code read at `origin/feat-cmux-next`
b1a69a45621. Requirement: decision U1 (cmux-next-spec decisions.md): app and daemon updates keep as
much as possible, running terminals and running agent (ACP) sessions included. Lawrence's priority:
give agent harnesses the same decoupling that PTYs have. R41 (false "Process exited", recover action)
is section 7. Related: ownership-v2.md (process map; its slice 2 moves the acp hub into the daemon,
which makes this plan a precondition), cmux-tui/spec/terminal-host.md, docs/cloud-guest-upgrades.md.

## 1. Today's truth

Processes on a Mac: the app; the cmux-tui daemon (`cmux-tui --headless --session cmux-app[-tag]`),
started by `server ensure`, which spawns it with `setsid` and exits (`cmux-tui/src/local_owner.rs:447-520`);
one `__terminal-host` process per PTY, spawned by the daemon with `setsid`
(`cmux-tui-core/src/terminal_host_runtime.rs:1955-1981`); acpmux (`acpmux daemon run --ready-fd 3`),
spawned by the app through a throwaway `/bin/sh` with `POSIX_SPAWN_SETSID`, so launchd adopts it
(`CmuxNextAgentPane/AcpmuxDaemonLauncher.swift:23-80`); agent harness processes, children of acpmux on
stdio pipes in their own process group (`acpmux/src/agent.rs:136-152`).

| Event | Terminals | Agents (ACP) |
| --- | --- | --- |
| App quit or crash | survive: the daemon is not the app's child; `applicationWillTerminate` only closes the connection (`AppDelegate.swift:215-226`); only "End Sessions" sends `shutdown-daemon end_terminals` | survive: acpmux is not the app's child and the app never stops it |
| Sparkle update and relaunch | survive, but the OLD daemon keeps running: `updaterWillRelaunchApplication` only logs (`UpdaterService.swift:203-217`), `server ensure` never compares builds (`local_owner.rs:280-325`), and `DaemonLauncher.isStale`/`restartDaemon` (`DaemonLauncher.swift:293-319`) have no caller outside a test | survive, OLD acpmux keeps running: no version check anywhere (`AgentPaneHost.swift:43-131`, `mux/host/src/acpmux-daemon.ts:67-87`) |
| Daemon restart (SIGTERM, `shutdown-daemon`, crash, SIGKILL) | survive: hosts outlive the daemon; the new daemon re-adopts them from `terminal-hosts-<token>/*.json` records (`mux.rs:3518-3780`); tested by `terminal_host_survives_sigkill_and_is_adopted_with_io_and_size`, `fenced_daemon_shutdown_acks_then_preserves_and_re_adopts_terminal_host`, `terminal_host_survives_daemon_process_group_hangup` | n/a (acpmux is a separate process) |
| acpmux restart (SIGTERM, `_acpmux/shutdown`) | n/a | LOST: `shutdown_all` cancels pending permissions and SIGTERMs then SIGKILLs every harness process group (`hub/turns.rs:854-880`, `daemon.rs:159`) |
| acpmux crash (SIGKILL) | n/a | LOST: the harness loses its stdin and stdout; the running turn dies with it |
| acpmux start after either | n/a | every non-closed session becomes `idle` (`hub/mod.rs` `load_from_store`); an open turn gets `turn_result failed outcome_unknown` "the daemon restarted before this turn settled" (`mark_unknown_outcomes`); queued prompts (memory only) are gone; the next prompt respawns the harness and resumes its own history (`session/load`, or `claude --resume`) |

What survives an agent restart is the transcript (`$ACPMUX_HOME/sessions/<id>/session.json` +
`events/NNNNNN.ndjson`) and the harness's own resume. What is lost: the turn in flight (tool calls
mid-run, background shells under the harness process group, streamed output not yet produced),
pending permission prompts, queued prompts, and the Claude stdio translator state (pending ACP
request map, control-request map: `claude_stdio/mod.rs:147-165`).

Gaps on the PTY side (it is the model, but not complete):
1. An updated app never moves onto the new daemon build, so a fix in the daemon or host reaches a
   user only after a manual "End Sessions" or a reboot.
2. A host record the daemon cannot read (an unknown future `record_version`, e.g. after the Cloud
   upgrade runbook's `ROLLBACK`, or a downgraded app) is skipped silently by
   `load_terminal_host_records` (`terminal_host_runtime.rs:2318-2370`). The terminal is then marked
   ended with `missing-host-record` (`mux.rs:3762-3779`) while the host and its shell keep running,
   unreachable and never cleaned up. Same for a host whose handshake has no common version: it
   loops on adoption retries with no state the UI can show.
3. No test runs an older binary's host under a newer daemon; legacy coverage edits record fields
   under the same binary (`adopted_legacy_host_rejects_clear_history_fallback`).
4. Bytes a host emits while no daemon is attached are recovered as a snapshot, not as exact output
   records (spec/terminal-host.md "Durability boundary"). Accepted for terminals: the screen is the
   product. Not acceptable for agents: the transcript is the product.

The PTY handshake is already versioned: `Bootstrap`/`ClientHello` carry `min_version..max_version`,
the host selects the highest common version, records carry `record_version` 1-4 and additive
capability booleans (spec/terminal-host.md "Handshakes", "Version compatibility").

## 2. Target: agent hosts

One agent host process per running agent session, the same model as a PTY host:
`acpmux __agent-host` (same binary, so host and controller never skew at spawn).

Owns: the harness process (its process group), the harness's stdio pipes, and the ACP transport. For
`ClaudeStdio` harnesses the stream-json translator moves into the host, so every host speaks plain
ACP to its controller and translator state survives a controller restart.

Does not own: session metadata, the event log, policy, permission rules, queue, peers. Those stay in
the controller (acpmux hub today, the daemon's acp actor after ownership-v2 slice 2).

### 2.1 Spawn and discovery

- The controller spawns `acpmux __agent-host --bootstrap-stdio` with `setsid` and null stderr, sends a
  `Spawn` frame (argv, env already resolved with the login environment, cwd, session id, translator
  config, owner token), and reads `Ready` or `SpawnFailed`. The host forks the harness in a new
  process group, binds `<home>/hosts/<session>.sock` (0600, dir 0700), writes
  `<home>/hosts/<session>.json` atomically, then answers `Ready`.
- Record (JSON, `record_version: 1`): session id, host incarnation (UUIDv4), host pid, host start
  nonce + a `.live` lock file held for the process lifetime (the PTY liveness proof, reused),
  harness pid/pgid, owner token (hex), `protocol_min`, `protocol_max`, `host_build`, spool path.
- On controller start: load records; for each, adopt (2.3). Liveness `Dead` with no exit sidecar is
  `host_lost`; with a sidecar it is the harness's real exit. A record that does not parse or whose
  version is unknown is NOT skipped: the session is listed as `unadoptable` (2.4).

### 2.2 Host buffering: the acked entry buffer

- The host numbers every event it moves: `hseq` (u64, contiguous). Entry kinds: `in` (an ACP message
  from the harness, after translation: logged then dispatched), `tap` (log only: a line written to the
  harness, or a raw Claude line kept beside its translation, today's `claude.*` kinds), `err`
  (stderr), `exit`.
- Entries stay in the host's memory until the controller sends `Ack{hseq}`, which it does after it
  appended the matching record to the session event log (a direct `write(2)`, so a controller SIGKILL
  cannot lose it). Each entry becomes exactly one record, carrying `hostSeq` (additive field), so a new
  controller resumes after the largest `hostSeq` of the current host incarnation: no loss, no repeat.
- Cap: 64 MiB of unacked entries, then the host stops reading the harness stdout, which back-pressures
  the harness instead of dropping lines.
- In memory, not on disk (changed from the first draft): the buffer only has to outlive the
  controller. If the host itself dies, the harness loses its pipes and dies too; the transcript up to
  the last ack is in the event log. A disk spool would add fsync cost to every line for that case only.

### 2.3 Controller protocol and adopt handshake

Framing: length-prefixed JSON frames on the Unix socket (`u32 len` + JSON object with `t`).
Versioned independently of the acpmux wire (`agent-host/1`).

1. Controller -> host `Hello{min, max, token, controller_build}`.
2. Host -> controller `HostHello{selected, host_build, incarnation, harness_pid, status, acked_hseq,
   last_hseq, max_out_id}` or `Incompatible{host_min, host_max, host_build}` and close.
3. Controller -> host `Resume{after_hseq}`; host replays spooled lines after it, then live lines.
4. Controller -> host `Line{json}` (to harness stdin; the host assigns the `out` hseq and echoes it),
   `Ack{hseq}`, `Signal{int|term|kill}`, `Terminate{grace_ms}`, `Detach` (host replies `DetachAck`
   after every prior frame, like the PTY `Detach`).
5. One owner connection at a time; a second `Hello` with the owner token takes over and the host
   closes the first with `Superseded` (handles a hung old controller during an upgrade).

`max_out_id` lets the controller continue JSON-RPC ids above every id the harness has seen, so a new
controller never reuses an id that an old pending request still holds.

### 2.4 "Cannot adopt version X"

- No common protocol version, or an unknown record version: the session stays `running` in the
  list, with `host: {state: "unadoptable", host_build, record_version}`. The harness keeps running.
- Allowed actions: End session. Ending does not need the host protocol: the controller verifies the
  record's start nonce through the `.live` lock (the PTY proof) and sends SIGTERM, then SIGKILL, to
  the harness process group and the host. This path is frozen across versions.
- The UI says: "This agent is still running under an older cmux. It cannot be shown until it ends.
  End session". Never "disconnected", never a silent drop.
- Same rule for PTY hosts (section 4).

### 2.5 Controller recovery after adopt

The hub rebuilds the in-memory state that today dies with the process, from the event log plus the
replayed spool:
- Turn: the last `turn_started` without `turn_result` becomes `TurnInfo` again; the `out
  session/prompt` request id in the log is re-registered as pending, and the turn settles when its
  response arrives through the host. `mark_unknown_outcomes` applies only to sessions with no live
  host.
- Permissions: each `permission_request` without `permission_decision` is re-registered under the
  same `permissionId`; the answer goes to the agent's original JSON-RPC request id, now recorded in
  the `permission_request` payload (`agentRequestId`, additive).
- Other agent-to-client requests with no logged answer (fs reads and writes) are handled again as if
  they just arrived; a write asks permission again.
- Queue: prompts that waited behind the turn in the old daemon were never sent to the agent; their
  clients resend them (`_meta.acpmux.resend`, which already looks in the log). Not rebuilt (A3).
- Status: `running` while the recovered turn runs, `waiting` while a recovered prompt is open, else
  `ready`; never forced to `idle` for an adopted agent.

### 2.6 Shutdown semantics

- SIGTERM and `_acpmux/shutdown` detach: every host gets `Detach`, the hub flushes, harnesses keep
  running. Same contract as the cmux-tui daemon ("SIGTERM hands off").
- Ending agents is explicit: session stop/close terminates that host; `_acpmux/shutdown
  {endAgents: true}` (new optional param) terminates all; the app's "End Everything" quit sends it.
- Switch: `ACPMUX_AGENT_HOSTS=1` turns hosts on for new agents (A2-A3); A4 makes it the default with
  `ACPMUX_AGENT_HOSTS=0` as the one-release opt-out. `--memory` stores never use hosts (no log to resume
  from). Hosts already running are adopted whatever the switch says.

### 2.7 Code map (landed in A1-A3)

- `acpmux/src/agent_host/mod.rs`: protocol frames, records, liveness lock, the frozen
  `terminate_unadoptable` path; `host.rs`: the `__agent-host` process; `link.rs`: spawn and connect.
- `acpmux/src/agent.rs`: `ChildAgent::spawn_hosted` / `attach_hosted` (same API as a direct child);
  `harness_command` is the one place that builds a harness's argv, env and cwd (direct or hosted);
  the hook point for launch overrides (acp.trust).
- `acpmux/src/hub/hosts.rs`: `adopt_agent_hosts` at daemon start (before spawns), the log scan for
  open work, turn and permission recovery; `hub/turns.rs` `finish_turn` settles live and recovered
  turns; `shutdown_all` detaches hosted agents.

## 3. Update flow end to end (Sparkle)

1. Sparkle installs and relaunches the app. Hosts (PTY and agent) and both daemons keep running.
2. The new app connects to the daemon and reads `identify.build_commit`; it reads acpmux
   `_acpmux/status.build`. Each is compared with the bundled `cmux-tui.version` commit.
3. On mismatch the app calls the existing `DaemonLauncher.restartDaemon` (fenced `shutdown-daemon`
   with pid + generation, then `server ensure`), and the same for acpmux (`_acpmux/shutdown`, which now
   detaches, then the normal launch). No terminal or agent is ended; the old processes exit only after
   their hosts got `Detach`.
4. The new daemon adopts PTY hosts of any build (protocol negotiation); the new acpmux adopts agent
   hosts the same way and replays their spools.
5. The UI reconnects: terminal views re-attach (one replay each), agent panes re-subscribe and page the
   event log from their last `seq`; a turn that ran through the update keeps streaming.
6. Once the restart is done, the app records `daemon_build_adopted` (debug log + `debug.window_snapshot`
   field) so a tagged build can prove it.

A daemon restart is ~seconds for normal state but data-dependent (journal replay; a 12 GB journal took
~3 min, cloud-guest-upgrades.md); the app shows "Updating terminals…" over views during the restart and
never times them out into "Process exited".

## 4. PTY hosts: same adopt contract

PTY hosts already negotiate versions. Add:
1. Unknown record versions and handshakes with no common version keep the terminal `running` with
   `host_state: unadoptable {record_version | host_protocol}` instead of `missing-host-record`; close
   uses the pid + start-nonce kill path; `list-terminals`/tab JSON expose it. Red test first: a host
   record rewritten to `record_version: 5` after SIGKILLing the daemon must not be reported ended.
2. A real cross-build test: `terminal_host_previous_build_is_adopted_by_this_build` starts the daemon
   from a previous released cmux-tui binary (path from `CMUX_TUI_PREVIOUS_BIN`, fetched by the hosted
   verify workflow from the last nightly artifact), creates terminals with output, stops it with SIGTERM,
   starts this build, and asserts the same terminal id, incarnation, screen and input path. The test
   fails, not skips, when the hosted workflow did not provide the binary.
3. The app-driven restart of section 3 step 3.

## 5. What cannot survive, and what the UI says

| Loss | Why | UI |
| --- | --- | --- |
| Reboot, logout, `kill -9` of a host | the process is gone | terminal: "Session ended: the computer restarted" / "terminal host was killed"; agent: "Agent stopped: its host ended" + Resume (harness resume) |
| Host crash | same | typed reason `host_lost{reason}`, never "Process exited" |
| Agent output emitted while no controller was attached and the spool hit its cap | back-pressure stops the harness, nothing is dropped | "Agent paused: waiting for cmux" until adopted |
| Unadoptable host (older protocol than this build supports, or newer after a downgrade) | no common version | 2.4 text + End session |
| Terminal bytes produced while no daemon tap existed | PTY hosts keep a snapshot, not a byte spool | nothing: the screen is exact; `terminal.output` history has a marked gap |
| acpmux `--memory` sessions, `--agent-hosts=off` | opt-out | today's behavior |
| A running app window's local state (scroll, selection) | the app is replaced | restored from window records where they exist |

## 6. Slices

| # | Slice | Area | Gate |
| --- | --- | --- | --- |
| R41-1 | false "Process exited": client `exited` must not be sticky when the daemon says the terminal lives; typed end reason on the wire and in the banner (section 7) | Swift + cmux-tui | Swift tests on fleet; cmux-tui landing window |
| P1 | PTY unadoptable state + red test (record_version 5) | cmux-tui-core | landing window |
| A1 | `agent_host` module: protocol, spool, record, liveness, `__agent-host` mode; host-level tests (detach, buffer, resume after hseq, incompatible, terminate by nonce) | acpmux | testbox cargo; landing window |
| A2 | `ChildAgent` over a host (same API), translator inside the host, `--agent-hosts` switch default off | acpmux | testbox |
| A3 | Hub adopt + recovery (2.5), SIGTERM detaches (2.6), `agentRequestId`, `dequeued` | acpmux | kill-mid-turn tests: SIGKILL and SIGTERM acpmux during a streaming turn with a pending permission; restart; output contiguous, permission answerable, turn succeeds |
| A4 | default on; app "End Everything" sends `endAgents` | acpmux + Swift | tagged build |
| UP | app restarts stale daemon and acpmux after an update (section 3) | Swift | tagged build, debug socket + `debug.window_snapshot` on a fleet host |
| P2 | previous-build PTY adoption test in hosted verify | cmux-tui + workflow | hosted run |

Wire and session-format changes for Leo's coordinator (section 2): new optional `_acpmux/shutdown`
param `endAgents`; new event kinds `host_adopted`, `host_detached`, `host_unadoptable`, `dequeued`;
`permission_request.agentRequestId`; session summary field `host`; status no longer forced to `idle`
on restart. All additive; no record removed or renamed.

## 7. R41: no false "Process exited"

The banner comes only from `TerminalAttachMachine.processExited`, sent by `TerminalLinkWatch` when the
store's `tab.dead` turns true (tree `dead`, or the `surface-exited` event). Audit of every path:

| # | Trigger | Class | Fix |
| --- | --- | --- | --- |
| C1 | async adoption after a daemon restart/upgrade (slow host, 2 s handshake, `Indeterminate` liveness, fd pressure): the tab has no surface and the tree said `dead: surface.map(is_dead).unwrap_or(true)` | false | daemon keeps pending terminals (keyed by public `term_` id); a surfaceless tab is dead only when its terminal ended; adoption completion pushes `tree-changed` (the app ignores registry events) |
| C2 | any transient `dead=true`: the attach machine's `exited` was permanent, so C1 stuck forever | false | `processRevived` event: the watch sends it when the tab turns live again; an exited view re-attaches, a pending exit is withdrawn |
| C3 | a host record this build cannot validate (newer `record_version` after a rollback) was skipped: terminal ended `missing-host-record`, host orphaned | false | terminal stays `unadoptable`; a watcher thread blocks on the host's live marker and ends the terminal with the host's exit sidecar when it exits; close signals the host only with proof (the exact marker its record names is held + PID) |
| B1-B6 | host died without exit status, died before/during adoption, incarnation mismatch, record missing, signal during logout | real end, wrong words | typed `end` with a stable `host_lost.reason` |
| A1-A5 | the shell exited, exit sidecar at startup, local PTY exit, user "End Sessions" | real | `end.kind = exited / signaled` |

Wire (capability `terminal-state-v1`), on every terminal tab in the tree JSON (`list-workspaces`,
tree pushes):
- `terminal_state`: `running | adopting | reconnecting | failed | unadoptable | exited`. Only
  `exited` means the shell ended.
- `dead`: true only for `exited`.
- `host_record_version`: the unreadable record's version when `unadoptable`.
- `end` (only when `exited`): `{kind: "exited", code}` | `{kind: "signaled", signal, core_dumped}` |
  `{kind: "host_lost", reason, detail}` | `{kind: "launch_failed", detail}`. `reason` is one of
  `missing_record, incarnation_mismatch, dead_before_adoption, died_during_adoption,
  died_without_exit_status, missing_exit_receipt, session_shutdown, unadoptable_host_ended, other`.
  Terminals with a runtime use its end; surfaceless ones use their durable receipt.
- Swift: `TabSnapshot/TabModel.terminalState`, `.end` (`TerminalTabEnd`), `.hostRecordVersion`;
  unknown future values decode as nil / `.other`.

The banner text and the "Restart Shell Here" / "Close" actions belong to the tab.restart agent
(`restart-tab`, `tab-restart-v1`); it reads `TabModel.end` and `terminalState`. Suggested words:
`exited` "Process exited (code N)", `signaled` "Process killed (signal N)", `host_lost` "Terminal
lost: <reason words>", `unadoptable` "Running under an older cmux; close to end it", `reconnecting`
"Reconnecting…", `failed` "Lost connection to the terminal" with Reconnect.

Not covered yet: the `surface-exited` event carries no `end` (clients read it from the next tree);
a handshake with no common protocol version still retries as `adopting` (only unreadable records
become `unadoptable`); `failed` has no daemon-side retry trigger beyond a new adoption.

## 8. Risks and the strongest objection

Risks:
1. Recovery correctness in the hub (2.5) is the hard part: every in-memory structure that a turn
   touches must be rebuilt from the log. Mitigation: the kill tests run at every awaited point of a
   turn (before prompt write, mid-stream, during permission, between tool call and result).
2. Two copies of agent output (spool + event log) until acked: disk use bounded by the spool cap.
3. Ids: a controller that crashes after writing a request to the host but before logging it. The host
   echoes `out` lines with their `hseq`, so the replay carries them and the log catches up.
4. Hosts outliving everything: a harness nobody ends runs forever. Idle sessions with no turn and no
   viewer for N days get an explicit "End idle agents" action, never a silent reap.
5. launchd `KillMode`-like group kills (Cloud systemd units): hosts must stay outside the daemon's
   control group on Linux, as for PTY hosts (cloud-guest-upgrades.md).

Strongest objection: "Harnesses already resume (`session/load`, `claude --resume`). Let the turn die
on an update and resume it; a host process per agent, a second spool and hub recovery code are a lot
of machinery for a weekly event, in a crate another team owns."

Answer: nightly updates daily and RCs weekly, and agent turns run 10-60 minutes; resume restores the
conversation, not the work in flight: tool calls mid-run, background shells in the harness process
group, a permission prompt the user is reading, and the partial answer are all lost, and the user must
notice and re-prompt. U1 asks for exactly that preservation. The machinery is the PTY model already
proven in this repo (setsid host, record, start-nonce liveness, versioned adopt); the new part is the
acked spool, which the transcript needs anyway. The hub change is bounded by the switch
(`--agent-hosts=off`) for one release. Considered and rejected: running harnesses inside terminal hosts
in a pipe mode (one host implementation): terminal hosts keep a bounded replay, not an acknowledged
line spool, and would pull ghostty-vt and cmux-tui-core into standalone acpmux.
