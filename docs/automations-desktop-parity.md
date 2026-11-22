# Automations: desktop app comparison and gaps (2026-11-19)

Ask (Lawrence, Chief msg 40399): find how the Claude desktop app and the ChatGPT and Codex desktop
apps do automations, how they make them reliable, visible and monitorable, and build the same in
cmux-next. The longer target design is [automations-platonic-ideal.md](automations-platonic-ideal.md);
this page is the short comparison and the gap list that drove the work of 2026-11-19.

Sources, read 2026-11-19:

- Claude Cowork scheduled tasks: <https://support.claude.com/en/articles/13854387-schedule-recurring-tasks-in-claude-cowork>
- Claude Code Desktop local scheduled tasks: <https://code.claude.com/docs/en/desktop-scheduled-tasks>
- ChatGPT and Codex scheduled tasks (desktop app, web): <https://learn.chatgpt.com/docs/automations?surface=app>
  (was developers.openai.com/codex/app/automations)
- ChatGPT help: <https://help.openai.com/en/articles/10291617-scheduled-tasks-in-chatgpt> (plan limits via search excerpts)
- Codex app changelog: <https://developers.openai.com/codex/changelog?type=codex-app> (run history bulk read/archive, thread automations)
- Codex issue on scheduled runs failing where manual runs work: <https://github.com/openai/codex/issues/21995>

## Comparison

| | Claude (Cowork and Code Desktop) | ChatGPT and Codex desktop | cmux before 2026-11-19 | cmux after |
| --- | --- | --- | --- | --- |
| Create from chat | yes: describe it, Claude asks, shows name, schedule, prompt, then Schedule | yes: ChatGPT drafts prompt and destination; skills can make tasks | yes: Chief runs `cmux automation create` (prompt rule) | same |
| Create with a form | yes: name, prompt, approval mode, frequency, model, folder | yes: custom schedule controls, RRULE | no (CLI only) | New and Edit form on the Automations page |
| Triggers | hourly, daily, weekdays, weekly, manual, cron (≥1 h in form), one-shot from chat; cloud: API and GitHub events | standalone or in-chat (minute loops); Gmail, Slack, GitHub events (web) | presets, cron+tz, every, at, in, manual, watch, `--when` events | same |
| Where it runs | Cowork: cloud by default; Code Desktop local: app open and computer awake | desktop: local checkout or new worktree, app running; web/team: cloud | launchd runner on this Mac (no app needed); `--target cloud`: a prompt in the Cloud Chief, a command on a team Cloud machine | same, prompt runs pinned to this Mac; Cloud commands run while the Mac sleeps |
| Missed runs | local: one catch-up for the latest miss in 7 days, older discarded, notification | not stated | catch-up `latest` (24 h), `all`, `none`; every miss kept as a skipped row | same |
| Overlap | skipped, reason shown | not stated | one live run; skipped `previous_run_running` | same |
| Retries | none stated | "retry failed tasks" button (26.224); connector start failures reported (#21995) | none | automatic retry of start failures, 30 s / 2 min / 8 min |
| Timeout | not stated | not stated | per automation, default 30 min, SIGTERM then SIGKILL | same |
| Unattended permissions | per-task permission mode; stalled prompt waits in the run's session | sandbox read-only / workspace-write / full; `approval_policy=never` when allowed | `--on-permission fail` | a run that asks becomes "needs you" (its own reason, notified) |
| Runner health | app must be open | app must be open | lock only; a stopped runner was silent in the app | heartbeat file; page says "Automations are off on this Mac" with Turn On |
| List | Scheduled page; detail page per task | Scheduled in sidebar: active, paused, completed, recent runs | Automations page (list, next run, last result), buttons not wired | list with next run, last result, unread failures; Run now, Pause/Resume, Edit, Delete |
| Run history | every run incl. skipped with reason on hover, Show more | recent runs; archive; bulk mark read | CLI `history`, page showed none | per-automation history on the page, skipped reasons in words |
| Each run as a chat | yes: history row opens the run's session | yes: standalone run is a new chat; in-chat run returns to its chat | prompt runs were agent sessions, not linked | a run opens its chat (prompt) or its log (command) |
| Inbox / unread | Cowork review like any task | Scheduled is the inbox; unread marker on runs needing attention | none | unread failed and needs-you runs; badge; seen when opened |
| Notifications | catch-up start | push/email (ChatGPT), unread marker | none | a failed or needs-you run posts a cmux notification |
| Logs | the run's session | the run's chat | `cmux automation logs` | same, plus the log on the page (`show-page --name` opens it) |
| Pause / resume / delete | yes | paused status; auto-pause when the chat is deleted | CLI | page buttons and CLI |
| Limits | cloud ≥ 1 h; local none | 3 to 15 active tasks by plan; once per hour | local: none; Cloud free plan 1 | same |

## Gaps found in cmux (code at feat-cmux-next cd315657d2e7)

Read: `cmux-tui/crates/cmux-automations`, `cmux-tui/crates/cmux-tui/src/cli/automation.rs`,
`Packages/macOS/CmuxNext/Sources/CmuxNextCloudUI/Automations`, `CmuxNextApp/TopPages/TopPages.swift`.
Tried: `cmux automation list`, `runner status`, `history` on the nightly 4427140699701.

1. The Automations page had no working buttons: `AutomationsPageHost.makeView` passed only Sign In,
   so Run now, Pause, Edit and New were hidden, and there was no form.
2. The page loaded no run history (`AutomationRow.local` set `runs: []`), so a failure showed only
   as a dot, with no reason and no log.
3. A run did not link to its chat: prompt runs are agent sessions named `auto-<id>-<run>`, but the
   run record did not keep the name, and the page could not open it.
4. A stopped runner was invisible: on this Mac `runner status` says it is not running, and nothing in
   the app said so; a hung runner holding its lock read as running. No heartbeat.
5. No retry: a run whose process could not start failed at once and stayed failed.
6. A run that stopped on a permission prompt failed as `exit_5`, the same as any other failure.
7. No unread state and no notification: a failed run was seen only by opening the page.
8. A prompt run with no folder let the agent launcher place it on another machine (interactive Macs
   send sessions away unless a folder here is named), and a run started from inside an agent chat
   became that chat's child.
9. The page loaded once when shown and never refreshed.

## Commands on cmux Cloud

Before: a Cloud automation could run a prompt only, so a command job (for example `models-scout`,
every 6 h) had to run on this Mac's runner and stopped while the Mac slept. Now
`cmux automation create NAME --command CMD --target cloud` makes the same automation on cmux Cloud:

- It runs on a team Cloud machine (`--machine NAME` or a `vm_` id; with one machine, that one).
- In `--folder DIR`, or with `--repo OWNER/NAME --ref BRANCH` in a checkout kept on the machine
  that moves to the newest head of the branch before each run (fetch, then a detached checkout of
  it); the run writes the commit it used.
- The body is the Cloud's journaled `steps` body: one step starts the command in the background
  (a replay never starts it twice), then wait steps of up to 280 s each cover `--timeout` (up to
  228 min), each within the provider's 300 s exec (cmux-vm sends an exec past 60 s as a provider
  background request, so the provider's edge no longer cuts it at about 120 s). The exit code is the run's result (`exit 3` fails with the last log lines); a run that
  passes its time limit is stopped and fails as a timeout.
- Concurrency 1, skip when one runs (no overlap); `--catch-up latest|all|none`; `--every` becomes a
  cron (minutes that divide 60, or hours that divide 24).
- `cmux automation history --target cloud` lists every Cloud run with its reason;
  `cmux automation logs RUN --target cloud` reads the run's log from its machine; the page shows
  Cloud runs, reasons and logs the same way as runs on this Mac.

- `cmux automation secret set AUTOMATION NAME --target cloud` keeps a value (from a hidden prompt,
  stdin or `--secret-file`, never an argument) that each machine step of a `--command` run gets as
  the environment variable NAME; `secret list` shows names and a 4-character hint, never a value.
  The value is sealed by cmux Cloud and sent on the step's stdin, never on its command line.
- A failed Cloud run (exit 3: a check failed; 1 or other: it crashed; or it timed out) posts one
  notice to its creator's Feed, pushed to their devices; skipped runs post nothing.
- Before a run's first step on a machine, a paused machine is started and waited for (up to 5
  minutes). A machine that does not come up skips the run with reason `machine_not_running`: it is
  not a failure, does not notify and does not count toward auto-pause.

Not yet on Cloud: editing the body (delete and make it again).

## Proof

- Rust: `cmux-tui/crates/cmux-automations/tests/reliability.rs` (retry with backoff, heartbeat
  health, unread failures, needs-permission, run chat names; red first) and
  `cmux-tui/crates/cmux-tui/tests/automation_cli_journey.rs` (history rows, `seen`, runner health,
  a prompt run that cannot start is retryable).
- Swift: `AutomationsPageActionTests` (runs joined to their automation, button words, refusals,
  form words, show by name, rendered PNGs of the page and the form).
- Live: three capture tours in `scripts/cmux-next/media/tours` run a real runner in a terminal of
  the app, in the capture slot's own home (or `CMUX_AUTOMATIONS_DIR` under tour.py), and end on
  the page: `automations-scheduled` (a run fires at its minute), `automations-catch-up` (the
  runner is off for two and a half minutes, the page says automations are off; it starts again,
  runs the latest missed minute once, late, and skips the older one with its reason) and
  `automations-failure` (a failed run with its reason and log). `cmux automation show-page --name
  NAME` opens one automation with its newest log.
- Live, on a fleet Mac (2026-11-19, `tests/automation_live_journey.rs`, fleet step key
  `a-auto7-automation-live`, 211 s, real runner, real clock): `Every minute` ran at its minute
  (succeeded, 0 s late); the runner was off for 150 s, then on again: the newest missed minute ran
  once, 31 s late, and the older one was recorded as skipped `superseded`; `Nightly build` failed
  with reason `exit_3`, its log holds `building` and `error: 2 tests failed`, and the list shows one
  unread failure.

Not built here (next): worktree-per-run, saved "always allow" per
automation, failover between machines (platonic ideal section 4), archive and bulk mark-read.
