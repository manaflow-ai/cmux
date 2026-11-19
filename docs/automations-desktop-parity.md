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
| Where it runs | Cowork: cloud by default; Code Desktop local: app open and computer awake | desktop: local checkout or new worktree, app running; web/team: cloud | launchd runner on this Mac (no app needed); `--target cloud` | same, prompt runs pinned to this Mac |
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
| Logs | the run's session | the run's chat | `cmux automation logs` | same, plus the log on the page |
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

Not built here (next): Cloud run history on the page, worktree-per-run, saved "always allow" per
automation, failover between machines (platonic ideal section 4), archive and bulk mark-read.
