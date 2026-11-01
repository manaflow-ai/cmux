# Background service start: where the seconds go

2026-10-20. Lawrence: "Why is starting a background service so slow?"
Target: under 100 ms from start to a socket that answers.

cmux-next runs two background services that a person waits on:

- **acpmux**: the agent host. It runs every Chief and agent chat.
- **cmux-tui server**: the terminal server. It owns every terminal, workspace and pane.

## Measured on the Chief's Mac (read-only)

Source: `~/.cmux/chief/default/acpmux/daemon.log`, the last 5 acpmux starts on 2026-10-20. Local times are UTC.

| Start | Listening → ready | Ready → agents may spawn | Total |
|---|---|---|---|
| 06:22:46 | 25.7 s | 12.8 s | 38.5 s |
| 07:24:26 | 18.6 s | 8.6 s | 27.2 s |
| 08:02:35 | 27.6 s | 11.2 s | 38.8 s |
| 08:46:27 | 24.9 s | 17.9 s | 42.8 s |
| 09:48:50 | 26.8 s | 11.9 s | 38.7 s |

The 09:48 start, step by step:

| Time | Event | Step cost |
|---|---|---|
| 09:48:05.6 | shutting down | |
| 09:48:22.9 | agents did not stop within 5 s; exiting anyway | 17.3 s |
| 09:48:29.5 | stopped | 6.6 s |
| 09:48:49.8 | next start begins | 20.3 s (gap) |
| 09:48:49.9 | listening | |
| 09:49:01.7 | loaded 5633 sessions from store | **11.8 s** |
| 09:49:12.9 | first "restored queued prompts" | **11.2 s** |
| 09:49:16.7 | acpmux ready | 3.9 s |
| 09:49:28.6 | startup complete; agents may spawn | **11.9 s** |

From "shutting down" to "agents may spawn" took 83 s.

The store on this Mac:

| Status | Sessions | Event log bytes |
|---|---|---|
| closed | 5660 | 0.13 GB |
| idle | 248 | 2.52 GB |
| ready | 56 | 0.68 GB |
| running | 50 | 0.70 GB |

Other timings:
- `acpmux status`: 0.91 s the first time (cold), then 50 to 150 ms.
- `cmux --version`: under 10 ms.
- The cmux-tui server has 471 live terminal hosts on this Mac.

## Causes, worst first

1. **acpmux reads every chat log in full, twice, before it says ready.**
   - `Hub::load_from_store` (`cmux-tui/crates/acpmux/src/hub/mod.rs`) calls `store.events(id, last_seq, 1_000_000)` for each of the 5633 sessions to catch up a log that ran ahead of its saved meta. The file store's `events` reads and JSON-parses every line of every segment, and keeps only the lines past `last_seq`. That is all 3.9 GB, and almost always it finds 0 new records. Cost: 11.8 s.
   - `Hub::restore_queues` (`hub/queue.rs`) then calls `store.scan(id, 0, …)` for each open session. It parses every record from the first, one session after another, to find its few `queued` / `dequeued` / `turn_started` records. Most bytes are agent output. Cost: about 15 s.
2. **The app gives acpmux 20 s to say ready, and acpmux needs 19 to 28 s.** `AcpmuxDaemonLauncher.launch` (`Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/AcpmuxDaemonLauncher.swift`) reads the ready line with a 20 s deadline. Most starts above miss it, so the app's start fails and it tries again. This likely explains the 20 s gap before the 09:48 start; it is not proven yet. Cause 1's fix brings acpmux back under the deadline.
3. **Agents cannot spawn for 9 to 18 s after ready.** `finish_startup` (`hub/startup.rs`) holds spawns until the login environment (3 s timeout per round, `login_env.rs`) and `verify_launchers` finish. In the 09:48 start, launcher verification ended at 09:49:27.9, 11.2 s after ready.
4. **Shutdown waits 5 s for agents, then about 7 s more.** A restart pays this before the new start begins.
5. **The cmux-tui server re-adopts every terminal host one at a time before it answers.** During restore it parks all clients (`server/restoring.rs`). Adoption (`mux/terminal_adoption.rs`, `adopt_terminal_hosts`) runs serially, with SQLite lifecycle commits and a socket handshake per host. A live host is cheap, but a slow host costs up to 1 s of connect retries plus 2 s of handshake (`terminal_host_runtime/sys/unix.rs`). With 471 hosts this grows with every terminal. The guard test `restart_with_many_live_terminals_answers_within_budget` measures it; the numbers are below once the Mac-mini run ends.
6. **The app starts its services one after another.** For acpmux, `AgentPaneHost.findOrStart` runs, in order: `adoptBuildHomes` (up to 300 s), status, version handoff, person-key enroll, status again, launch, then status and enroll again. On a DEV build, the person-key check restarts a daemon that another launch started, with a 15 s exit wait. The Chief path makes a second `server ensure` after its adoption backup.

## Fixes

| # | Fix | State |
|---|---|---|
| 1a | Catch-up reads each log backward from its end and stops at `last_seq` (`Store::tail_after`). Cost is the new records, not the log. | Landed |
| 1b | Queue restore parses only the 12 queue record kinds (`Store::scan_kinds`); the kind is read from the line without parsing it. Sessions restore on up to 8 threads. | Landed |
| 1c | Guard: `acpmux/tests/startup_load.rs` loads 24 sessions of 4,000 output records (about 70 MB) under a 1.5 s budget, and checks that the queued prompt and the log tail survive. | Landed |
| 5a | Guard: `cmux-tui/tests/terminal_host_recovery.rs` `restart_with_many_live_terminals_answers_within_budget` (60 live terminals, 250 ms to the first answer). | Measurement run |
| 2 | Next: the launcher's ready deadline should follow the daemon's own progress, not a fixed 20 s. | Not started |
| 3 | Next: say "ready" before the queue restore, and let agents spawn while launcher checks run. Each one waits only for its own launcher. | Not started |
| 5b | Answer clients while terminal hosts adopt (each tab shows "adopting" until its host is back); hosts adopt on their own threads, at most 8 replaying at once. Guards: `answers_before_adoption.rs`, and the 60-terminal guard at 250 ms. | In review |

The 100 ms target needs fixes 3 and 5b: the daemon must answer before it has restored every chat and every terminal. Fixes 1a and 1b remove the bulk of the work; they do not make the restore lazy.

## How to measure

- acpmux on a Mac: `grep -E "listening on|loaded .* sessions|acpmux ready|startup complete" ~/.cmux/chief/default/acpmux/daemon.log`
- Fleet:
  - `cmux-ci run --class isolated --script scripts/ci/cmux-tui-rust-check.sh --ref SHA --os macos --arg test --arg a_restart_over_long_chats_loads_within_budget_and_keeps_queues_and_tails`
  - The same command with `--arg restart_with_many_live_terminals_answers_within_budget`.
  - Each test prints one JSON line (`acpmux-start:` or `service-start:`).

## Owners and overlap

- a286 (server updates): owns when a restart happens. This document covers only how long a start takes.
- a248 / a185 (sessions survive updates, turn retry): need a fast acpmux start; fix 1 helps both.
- a323 (idle CPU): its chat-index merge is a different pass. No overlap with `load_from_store`.
- a338 (create/close speed): no overlap.
- a341 (update check): no overlap.
