# Updates keep terminals and agent sessions

Status: 2026-10-19, a248. User (msg 4603): "ensure that updating does not stop any terminals or
acpmux sessions". Builds on durable-sessions.md (agent hosts, daemon handoff) and
updates-and-announcements.md (UpdateFlow). a185 owns the Chief's "connection lost" side (session/new
retry, turn resume, 502 backoff); this doc does not change it.

## 1. What an update does today (code read at feat-cmux-next ea0892a84de)

| Step | Code | Terminals | Agents (acpmux) |
| --- | --- | --- | --- |
| Sparkle relaunch, Install Now, apply-if-available | `UpdaterService.updaterWillRelaunchApplication` records `QuitOrigin.explicit(.keep)`, so a remembered "End Sessions" quit choice never applies | kept | kept |
| Install on quit | the user's own quit; its choice applies | as the user chose | as the user chose |
| Channel switch | opens the other app; this one keeps running | kept | kept |
| Bundle replaced under running daemons | each running binary keeps its deleted inode; new spawns use the new file; PTY and agent-host handshakes are versioned | kept | kept |
| cmux-tui daemon of another build | `DaemonLauncher.handOffIfStale`: fenced `shutdown-daemon`, hosts adopted | kept (NIGHTLY/release hosts have no orphan grace, `host_orphan_policy.rs`) | n/a |
| acpmux of another build or a replaced bundle | `AcpmuxVersionHandoff` / `AcpmuxChiefHandoff`: `_acpmux/shutdown` only when it runs agent hosts; the next daemon adopts every host | n/a | kept, but see 2.1 |
| Chief host (optchat-chief) on a handed-off Chief acpmux | `HomeBrainHost.start` stops the host (`ChiefHostStop.stop`, SIGTERM) and launches a new one | n/a | see 2.2 |

## 2. What died on the 2026-10-19 22:34 nightly update (this Mac, logs and process table)

Evidence: app pid 14047 started 22:34:01; 139 terminal hosts from Oct 18 and agent hosts from 17:40
still run; `~/.cmux/chief/default/host.log` 22:41:36 "signal 15: stopping"; acpmux session logs under
`~/.cmux/chief/default/acpmux/sessions/<id>/events/`.

1. **Steered turns were settled as finished (fixed here).** 11 subagents (a185, a191, a195, a197,
   a202, a206, a207, a208, a210, a217, a233) each had a turn that had taken a Chief `tell` (a steer).
   After the Chief acpmux handoff, the new daemon logged `host_adopted`, then at once
   `turn_end {stopReason: steered}` and `turn_result`, while the agents kept working (up to 367 events
   after it). The Chief read them as finished and took partial reports. The one adopted agent with no
   steer (a187) was fine. Cause: `hub/hosts.rs` `open_work` took the last `out session/prompt` of the
   turn as the turn's own prompt; a steer is also a `session/prompt` (`_meta.steer`), and Claude Code
   answers it `steered` at once, so recovery settled the turn on the steer's answer.
2. **The Chief host restarts on an update (open, a185's area).** The Chief-home acpmux ran from the
   replaced bundle, so `AcpmuxChiefHandoff` stopped it and `HomeBrainHost.start` SIGTERMed the Chief
   host. Lost: the Chief's turn in flight ("subagent a187: the tell did not reach it: acpmux is not
   connected") and ~23 s of Chief downtime. Its subagents (agent hosts) kept running.
3. **The Chief's cmux-tui daemon never upgrades (not a loss).** `cmux-chief-2e448bc2` (pid 1389) has run
   since Oct 16; only the app's daemon is handed off. Its terminals are kept, but daemon fixes never
   reach it until it restarts.

Terminals: no loss found. Shells, PIDs and scrollback live in `__terminal-host` processes that outlive
the app and both daemons.

## 3. Design

- Daemons and hosts outlive the app: already true for PTY hosts, agent hosts, both daemons and the
  Chief host. An update never sends an end (`end_terminals`, `endAgents`).
- Daemon upgrade = handover, never an end: the old daemon detaches its hosts, the new one adopts them
  (exists). The adopted state must equal the live state: a turn stays open until the agent ends it.
  Fix 1: `open_work` keeps the turn's own prompt and its steers apart. A steer answered `steered`
  never settles the turn; a steer answer with another stop reason does (codex-acp answers only the
  last prompt, `steer_end.rs`). Recovery waits for the turn's own answer or such a steer answer.
- The Chief host restart (2.2) moves to "when idle" (a185, 2026-10-20): `HomeBrainHost.start` no
  longer SIGTERMs a Chief host mid-turn. A host that takes it (`state/host.handoff` names its pid)
  gets SIGUSR1 (`ChiefHostStop.askToHandOffWhenIdle`); the brain lets the running turn (or an
  adopted turn session) end, starts no new turn, posts held replies, saves and exits 0 without
  ending its acpmux; the stale acpmux stays up meanwhile (`AcpmuxChiefHandoff.handOffIfStale`
  `waitFor`, not counted as decided). The exit restarts `start` (`ChiefBrainWatch`), which hands
  the daemon off and launches the next host; it answers what came in meanwhile. A turn past 10 min
  stops the host anyway; the next host adopts the turn session and waits for its end. An older
  host (no mark) is still stopped as before, and its cut turn resumes in the next host (resume
  note, no error in the run record). Tests: optchat-chief `tests/turn_survives_lost_acpmux.rs`
  `a_handoff_when_idle_*`, CmuxNext `ChiefHostIdleHandoffTests`.

## 4. Tests and guard

- `cmux-tui/crates/acpmux/tests/durable_agents.rs`
  `a_steered_turn_stays_open_across_an_update_restart_until_the_agent_ends_it`: a fake agent that steers
  as Claude Code does (`FAKE_CLAUDE_STEER=1`, `tests/fake_agent.py`) runs a gated turn, takes a steer,
  acpmux is stopped as an update stops it (SIGTERM) and started again; the harness PID must be the
  same, and the turn must settle once, with `end_turn`, after the agent's last output. It is red on
  the code before the fix. It runs in every cmux-tui Rust test run, so a change to recovery that
  settles on a steer again fails CI.
- Existing: `agent_turn_survives_a_daemon_crash_and_completes_after_adoption`,
  `queued_prompts_survive_an_update_restart`, the PTY host recovery suite, and
  `scripts/cmux-next/update-e2e.py` (a real Sparkle update keeps terminals: output, shell PID).
- Open: an `update-e2e.py` step with a steered agent turn through a real update.
