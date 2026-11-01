# cmux automations: the platonic ideal

Status: design, 2026-10-30 (a908). Ask (Lawrence, chat 18009 and 18014): parity with ChatGPT
automations and Claude Code Desktop scheduled tasks, super reliable scheduled tasks, every place a
task can run (this Mac, a Mac mini, a self-hosted box, cmux Cloud), the `cmux` CLI runs all of it,
and a UI that is not overwhelming.

This document is the target. It builds on what already exists and does not replace it:

- `plans/cmux-next/automations-plan.md`, `automations-runtime.md`, `cloud-automation.md`: the Cloud
  scheduler (SchedulerDO per team, one `AutomationRunWorkflow` per run, run history, retries,
  deadlines, delivery dedupe, budgets, `TargetPolicy {host, fallback}` in the schema).
- `plans/cmux-next/chief-automations-DESIGN.md`: Cloud Chief jobs (`chief-auto add|ls|run|rm`, body
  `{type: chief}`), the free-plan gate (1 job) and the Stripe test checkout.
- `backend/packages/protocol/src/automations.ts`: the shared schema (`Automation`, `Run`, triggers,
  bodies, `TargetPolicy`, `Concurrency`, `Budget`).
- `docs/automations.md`: the classic app's event rules (`~/.cmuxterm/automations.json`). These are
  local event reactions, not schedules; section 9 says how they fold in.

## 0. Summary

One automation model, many runners. An automation is a named prompt (or command, or code) plus
triggers plus a run-target list. A **schedule owner** decides *when* a run is due and writes the run
record first; a **runner** (this Mac, a Mac mini, a Linux host, cmux Cloud) claims the run with a
lease and does it. The schedule owner is cmux Cloud when the person is signed in, and the local
store on the machine when they are not. Every run has a deterministic id
(`automation + trigger + scheduled_at`), so a fire that two machines see is one run.

What cmux adds over both references:

1. **Run anywhere, fail over.** "Run on my Mac, else my Mac mini, else Cloud" is one setting. Neither
   ChatGPT (cloud only) nor Claude Desktop (local XOR cloud, chosen at create) does this.
2. **Never silently skipped.** Claude Desktop skips runs while the Mac sleeps and keeps only the latest
   of 7 days; cmux records every due time as a run row (succeeded, failed, skipped *with a reason*,
   or caught up), and fails over before it skips.
3. **Every action on every surface.** UI, Cmd+Shift+P, `cmux automation …`, MCP, and Chief chat call
   the same op set, so an agent can do everything a person can.
4. **Quiet by default.** Successful runs that found nothing do not ping you. Only failures, "needs
   you", and runs whose prompt says to report reach Home.

## 1. What the references do

ChatGPT scheduled tasks ("automations"): read at https://learn.chatgpt.com/docs/automations on
2026-10-31. Claude Code Desktop: read in full at https://code.claude.com/docs/en/desktop-scheduled-tasks
on 2026-10-30. Where the ChatGPT page says nothing, the cell says "not stated".

## 2. Parity table

Legend: ✅ have, 🟡 partial, ❌ missing. "cmux today" was feat-cmux-next at dfaa79eb0f4c; section 12 lists what landed since.

| Feature | ChatGPT scheduled tasks | Claude Code Desktop scheduled tasks | cmux today | cmux target |
| --- | --- | --- | --- | --- |
| Create from chat in plain words | ✅ ChatGPT or Codex drafts the prompt, picks where it runs, updates it later; skills can make tasks too | ✅ ("set up a daily code review at 9am"), one-shot too | 🟡 Cloud Chief `chief-auto add`; the local Mac Chief has none | ✅ Chief on every target; confirm card shows parsed schedule + target before it saves |
| Create with a form | 🟡 "custom schedule controls"; no form described | ✅ name, instructions, folder, trigger, permission mode, model | 🟡 web dashboard `routes/automations.tsx` only | ✅ one form in the app, the same form the Chief fills |
| Presets: hourly, daily, weekdays, weekly | ✅ preset cadences | ✅ | ❌ (cron only) | ✅ |
| Custom cron with time zone | 🟡 RFC 5545 RRULE (`FREQ=MONTHLY;BYMONTHDAY=1;BYHOUR=9`), not cron | ✅ local time, numbers only, ≥ 1 h in the form | ✅ Cloud `cron {expr, tz}` | ✅ plus names (`mon`), `@daily`, preview of the next 5 fires |
| Interval ("every 30 min") | 🟡 minute intervals only for in-chat tasks (follow-up loops) | 🟡 only when Claude sets it (min 1 min) | 🟡 `continue` trigger, cooldown ≥ 60 s | ✅ `every 30m`, floor 1 min local, 5 min Cloud free plan |
| One-shot ("tomorrow at 3pm") | not stated | ✅ disables itself after it fires | ❌ | ✅ `at <time>`; the automation ends `done` and stays in history |
| Manual only (saved prompt, Run now) | 🟡 Run now processes pending events; manual-only not stated | ✅ | ✅ `manual` trigger | ✅ |
| Webhook / URL trigger | ❌ (the Agents API has its own scheduled automations page) | 🟡 cloud tasks only ("API calls") | ✅ Cloud `webhook` (ingress `automation-hook.ts`) | ✅ signed URL per automation; local runner gets it relayed from Cloud |
| GitHub / integration events | ✅ Gmail, Slack channels, GitHub PR activity (web and mobile, eligible plans, admin permission); events close together batch into one run; cannot mix with a time schedule | 🟡 cloud tasks only | ✅ Cloud `event {source: integration}` | ✅ |
| File, git, local events | ❌ | ❌ | 🟡 classic event rules (`docs/automations.md`), not in cmux-next | ✅ `on file`, `on git push/branch`, `on agent.needs_input`, `on login` (local runner) |
| Presence ("when I'm back") | ❌ | ❌ | 🟡 schema `presence`, `not_yet_supported` | ✅ later |
| Runs with my Mac asleep / off | ✅ web and team tasks run in the cloud (no local folder); desktop tasks need the computer on and the app running | ❌ local; ✅ cloud tasks (fresh clone) | ✅ Cloud Chief jobs | ✅ failover to a Mac mini or Cloud |
| Access to local files and tools | ✅ desktop: local project directory, several projects per task | ✅ | ❌ no local scheduler in cmux-next | ✅ this Mac or a paired machine with that folder |
| Own worktree per run | ✅ desktop: local checkout or a new worktree (frequent schedules make many worktrees) | ✅ opt-in "Worktree" | 🟡 `agent_prompt.workspace.mode fresh_worktree` in schema | ✅ default on for git folders |
| Pick model / agent / effort | ✅ model and reasoning effort; a retired model must be replaced | ✅ model + permission mode | 🟡 `agent_prompt.model/effort` | ✅ harness (Claude, Codex, OpenCode, Hermes), model, effort |
| Permission mode per task, saved "always allow" | 🟡 default sandbox (read-only, workspace-write, full access), `approval_policy = "never"` when allowed, admin `requirements.toml` | ✅ per task, revocable | ❌ | ✅ per automation; a stalled prompt becomes "needs you", never a silent hang |
| Missed runs after sleep | not stated | 🟡 one catch-up for the latest miss in 7 days, older discarded, notification | ❌ | ✅ policy per automation (section 5.3) + failover first |
| Staggered start | not stated | ✅ deterministic offset of a few minutes | ❌ | ✅ deterministic jitter, 0–90 s, off for `at` |
| Overlap (previous run still going) | not stated | ✅ skipped, reason shown | ✅ `concurrency {max, on_limit: queue|skip}` | ✅ |
| Run history with skipped runs and reasons | 🟡 recent runs in Scheduled; skips not stated | ✅ "Show more" paging | ✅ Cloud `automation.runs.list`, states incl. `skipped`, `dead` | ✅ one history across all runners |
| Open the session a run made | ✅ a standalone run is a new chat; an in-chat run returns to its chat | ✅ History row opens it | 🟡 Cloud Chief posts in its chat | ✅ run → its transcript, diff, logs; "Open as workspace" |
| Results inbox, archive when nothing to report | ✅ Scheduled is the inbox, unread marker on runs that need attention, archive runs (pinned runs keep worktrees) | ❌ (sessions list) | ❌ | ✅ quiet success; findings go to Home (section 8) |
| Notifications | 🟡 the unread marker; nothing else stated | ✅ catch-up start; prompts stall | 🟡 Chief chat message | ✅ failure, needs-you, report; iPhone + Mac; digest option |
| Alerts on repeated failure | not stated | ❌ | 🟡 planned (slice 5: failed, dead, 3 consecutive, 80% budget) | ✅ |
| Retries with backoff | not stated (a sandbox overstep fails the tool call) | ❌ | ✅ Workflow step retries | ✅ on infra errors only, never re-runs a finished agent turn |
| Timeouts and budgets | not stated | ❌ | ✅ deadline, `Budget` (wall clock, VM minutes, model spend) | ✅ |
| Pause / resume / delete | 🟡 paused status; delete not stated | ✅ delete archives sessions, leaves SKILL.md | ✅ `enabled`, delete | ✅ delete keeps run history 30 days |
| Edit the prompt as a file | ❌ | ✅ `~/.claude/scheduled-tasks/<name>/SKILL.md` | 🟡 Cloud code bodies in code.storage | ✅ `~/.config/cmux/automations/<slug>/automation.md` (frontmatter + prompt), synced |
| Task edits itself while running | ❌ | ✅ `update_scheduled_task` MCP tool | ❌ | ✅ `automation.update` from inside a run, scoped to itself |
| CLI | ❌ "CLI and IDE extension: no Scheduled interface" | ❌ (`/loop` is session-only) | 🟡 classic `cmux automation` = event rules only; Cloud `chief-auto` in the Chief VM | ✅ `cmux automation create/list/show/run/pause/resume/logs/history/edit/delete` |
| MCP / agent tools | ❌ | ✅ list, create, edit, pause (no delete) | 🟡 `chief-auto` | ✅ same op set as the CLI |
| Limits | not stated | none stated locally; cloud ≥ 1 h | ✅ free plan 1 Chief job; 50 active per team | ✅ local: unlimited; Cloud: plan quota, shown before create |
| Teams / shared automations | ✅ Team Tasks run on the team's service account and app connections | ❌ | ✅ owner team in schema | ✅ team automations, run as the creator, transfer on leave |

## 3. Use cases (who wants what)

| Use case | Example | Needs | Best target |
| --- | --- | --- | --- |
| Morning brief | "8:30 weekdays: summarize mail, calendar, PRs, Slack" | sign-ins, no local files | Cloud (runs before the laptop opens) |
| Repo hygiene | "nightly: update deps, run tests, open a PR if green" | the repo, CI | Cloud fresh clone or a Mac mini |
| Local-machine chores | "every hour: clean DerivedData over 50 GB", "back up ~/notes" | this Mac's disk | this Mac only, catch up on wake |
| Watchers | "when a PR on cmux gets a review, address it" | webhook + repo | Cloud, fail over to Mac mini |
| Long build/test farm | "every 2 h: soak test on the fleet" | a Mac with Xcode | Mac mini pool (fleet), never a laptop |
| Reminders | "remind me at 3pm to check the deploy" | nothing | Cloud (one-shot, notification) |
| Ops checks | "every 10 min: is cmux.com up; page Lawrence if not" | reliability above all | Cloud, alert on failure |
| Agent babysitting | "every 30 min: unblock my stuck agents" | the local acpmux sessions | this Mac, else skip with reason |
| Enterprise | "our runners only, our network" | self-hosted Linux, no cmux Cloud data path | self-hosted `cmux server` automations host |
| Reports to others | "Friday 5pm: post the week's changelog to #eng" | Slack sign-in | Cloud |

## 4. Run targets and failover

### 4.1 Targets

| Target | Who runs it | Wakes for a run | Has | Cost to us |
| --- | --- | --- | --- | --- |
| **This Mac** | the `cmux` runner (launchd agent `com.cmuxterm.automations`, part of the `cmux` binary), so the app does not need to be open | only when awake; optional "Wake Mac for automations" (a privileged helper calls `IOPMSchedulePowerEvent` for the next due run, lid open on power) | local files, cmux browser sign-ins, acpmux agents, Keychain | none |
| **My other machine** (Mac mini, Linux box, a teammate's shared mini) | the same runner, paired through `cmux link` / HostDO | always on | its own files and sign-ins | none |
| **Self-hosted** (enterprise Linux / VM) | `cmux server` with the `automations-host` role (automations-runtime.md Tier 2) | always on | the customer's network | none (license) |
| **cmux Cloud** | SchedulerDO + `AutomationRunWorkflow`; agent work on a Freestyle VM or the Cloud Chief | always | fresh clone, connected integrations, the person's Cloud Chief | VM minutes + model spend, plan quota |

### 4.2 Choosing and failing over

An automation stores an ordered target list and requirements, not one machine:

```json
"run_on": {
  "targets": ["this-mac", "host:austins-mac-mini", "cloud"],
  "requires": { "folder": "~/fun/cmux", "signed_in": ["github.com"] },
  "wait_for_preferred_seconds": 600
}
```

- The schedule owner offers a due run to the first target that is reachable *and* meets
  `requires`. A target that is asleep or offline does not hold a lease, so after
  `wait_for_preferred_seconds` (default 10 min, 0 for alerts) the next target gets it.
- `requires.folder` only matches machines that reported that folder (by repo remote + path, not
  just path). `signed_in` only matches runners whose browser profile has that site. Cloud matches a
  repo requirement with a fresh clone and an integration requirement with its connections.
- When no target can take it, the run is `skipped` with the reason ("this Mac asleep, Mac mini
  offline, Cloud not allowed for this automation") and an alert follows section 6.
- Defaults by create path: a folder on this Mac → `["this-mac"]` plus a one-tap "also run on Cloud
  when my Mac is asleep" when the folder is a git repo with a remote; no folder → `["cloud"]` when
  signed in, else `["this-mac"]`.

## 5. Reliability design

### 5.1 Durable schedule store

- **Cloud (signed in):** SchedulerDO is the single schedule owner for the team (already built). It
  holds definitions and next fire times in SQLite, arms one DO alarm for the earliest, and writes the
  run row *before* dispatch. The Mac keeps a read-through cache so the UI and CLI work offline.
- **Local (signed out, or `local_only: true`):** `~/.config/cmux/automations/` on the machine:
  one `<slug>/automation.json` (definition, versioned) + `automation.md` (prompt, editable),
  `state.json` (next fire, last scheduled time handled, pause), and `runs.jsonl` (append-only run
  history; each line is a full run record, the last line for an id wins). Every write goes to a
  temp file, `fsync`, then `rename`, so a crash leaves the old or the new file, never half.
- A machine that goes from signed-out to signed-in uploads its local automations once (by id, so a
  retry does not duplicate) and from then on the Cloud owns the schedule; `local_only` ones stay
  local.

### 5.2 Exactly-once start, at-least-once delivery, idempotent effects

- Run id = `run_` + first 20 base32 chars of `sha256(automation_id, trigger_id, scheduled_at)`. Two
  fires of the same due time (two Macs, a DO alarm retry, a catch-up racing a live fire) produce the
  same id; the store's insert is "create if absent", so there is one run.
- Delivery to a runner is at least once. A runner **claims** a run with a lease
  `{run, runner, fence, expires_at}` (60 s, renewed every 20 s). The fence token increases on every
  claim; every side effect the runner reports carries it and the store refuses a stale fence, so a
  runner that wakes from sleep after its lease expired cannot overwrite the new owner's result.
- Locally, one runner per machine holds an exclusive `flock` on `~/.config/cmux/automations/.runner.lock`;
  a second `cmux automation runner` exits at once. Claims use the same lease record in `state.json`.
- Effects outside cmux (a PR, a Slack post) get the run id as the idempotency key in the agent's
  prompt and in every `cmux` op the run calls; Cloud op steps already journal by step key.

### 5.3 Missed runs (the Mac slept or was off)

Order: **fail over first, catch up second, skip last.** Per automation `catch_up`:

| Policy | Behavior | Default for |
| --- | --- | --- |
| `latest` | one run for the most recent missed time within `catch_up_window` (default 24 h), older due times recorded as `skipped: superseded` | prompts (briefs, reviews): matches Claude Desktop, but with a shorter window and visible skips |
| `all` | one run per missed time, oldest first, capped at 10, sequential | idempotent chores that must not lose a period (billing exports) |
| `none` | record each missed time as `skipped: machine asleep` | time-critical checks ("is the site up") that are useless late |

Every late run gets `CMUX_AUTOMATION_SCHEDULED_AT`, `…_LATE_SECONDS` and a first prompt line ("This
run was due at 09:00 and starts at 23:10 because the Mac was asleep.") so the agent can apply the
prompt's own guardrails. A run that starts after `stale_after` (default: one period) is `skipped:
stale` instead of running.

### 5.4 Retries, timeouts, overlap

- **Retry** only infrastructure failures before the agent started (runner crash, VM create failure,
  network): exponential backoff 30 s, 2 min, 8 min, then `failed`. A run whose agent turn finished
  (success or a real failure) is never retried automatically; "Retry" is a button that makes a new
  run linked by `retry_of`.
- **Timeout** per automation (default 30 min, max 24 h Cloud / none local): the runner cancels the
  agent turn, keeps its transcript, and ends `failed: timeout`.
- **Overlap**: `concurrency {max: 1, on_limit: skip}` by default; history shows "skipped: previous
  run still running" with a link to it.
- **Stuck detection**: no output and no tool call for 10 min while not waiting on a person →
  `needs_you: looks stuck` with the last screen.

### 5.5 Sign-ins and credentials

- Before each run the runner checks the sign-ins the automation needs (`requires.signed_in`, GitHub
  token, model account). An expired one makes the run `waiting: sign-in needed` (not failed), sends
  one "needs you" with a one-tap sign-in, and resumes when it is fixed within `stale_after`.
- 24 h before a known expiry (OAuth refresh failing, a cookie's expiry), one heads-up notification.
- A permission prompt in a run (manual permission mode) becomes `waiting: approval` with the prompt
  inline in Home; "Always allow" is saved per automation and visible/revocable on its page.
- Cloud runs never hold the person's raw credentials: the existing edge-injected credential path and
  per-run tokens (automations-runtime.md 4.2).

### 5.6 Run history, logs, observability

- One run record shape everywhere (protocol `Run`, plus `runner`, `late_seconds`, `skip_reason`,
  `transcript` link, `cost`). Cloud keeps it in SchedulerDO + the `automation_runs` projection;
  local runs upload their records when signed in, so history is one list across machines.
- Logs: the agent transcript (acpmux session export), stdout/stderr tail for command bodies, and the
  runner's own events (claimed, lease renewed, failover). `cmux automation logs RUN --follow`.
- Retention: 90 days of run rows, 30 days of transcripts (Cloud plan may extend).

### 5.7 Alerts

Defaults (editable per automation): notify on `failed`, `dead`, `waiting` (needs you), and after 3
consecutive failures escalate (iPhone push + Home pinned card); a "heartbeat" option alerts when an
automation has not *succeeded* in N periods (catches "the scheduler itself died", which no run can
report). The Cloud also watches local runners: a `this-mac`-only automation whose runner has not
checked in for 2 periods gets one "your Mac has not run X since …" notice.

## 6. Triggers

| Trigger | Syntax (CLI) | Fired by | Notes |
| --- | --- | --- | --- |
| Cron | `--cron "0 9 * * 1-5" --tz America/Los_Angeles` | schedule owner | names allowed, DST: a skipped local hour fires once at the next valid minute, a repeated hour fires once |
| Preset | `--daily 09:00`, `--weekdays 09:00`, `--weekly mon 09:00`, `--hourly` | schedule owner | stored as cron |
| Interval | `--every 30m` | schedule owner | anchored to creation time, not wall clock |
| One-shot | `--at "2026-10-31 15:00"` or `--in 2h` | schedule owner | automation becomes `done` after its run |
| Manual | `--manual` | person, agent, CLI | always available as Run now on every automation |
| Webhook | `--webhook` | Cloud ingress, relayed to the runner | prints a signed URL; body is the run input |
| Integration event | `--on github:pull_request.review_submitted --repo manaflow-ai/cmux` | Cloud ConnectionDO | |
| File / git | `--on file:~/Downloads/*.pdf`, `--on git:push --repo .` | local runner (FSEvents, git hooks) | debounced 5 s |
| cmux event | `--on agent.needs_input`, `--on workspace.created` | local runner (the classic event bus) | replaces classic `automations.json` rules |
| Presence | `--when-back-after 2h` | Cloud (UserDO presence) | later |

## 7. Surface parity: one op set, five entrypoints

Ops (Cloud names already exist where marked ✳): `automation.create`✳, `.update`✳, `.list`✳, `.get`,
`.delete`✳, `.pause` / `.resume` (update `enabled`), `.run` (manual fire)✳, `run.list`✳, `run.get`,
`run.logs`, `run.cancel`, `run.retry`, `run.approve`. Local runs implement the same names over the
cmux socket; the CLI picks local or Cloud by the automation's owner.

| Action | UI | Cmd+Shift+P | CLI | MCP / Chief |
| --- | --- | --- | --- | --- |
| Create | Automations page "New"; Chief confirm card | "New Automation…" | `cmux automation create NAME --prompt … --daily 09:00 [--target this-mac,cloud] [--folder .]` | `automation_create` |
| List | Automations page | "Show Automations" | `cmux automation list [--json]` | `automation_list` |
| Show | detail page | "Open Automation…" | `cmux automation show ID` | `automation_get` |
| Run now | button | "Run Automation Now…" | `cmux automation run ID [--wait]` | `automation_run` |
| Pause / resume | toggle | "Pause/Resume Automation…" | `cmux automation pause|resume ID` | `automation_update` |
| Edit | form; `automation.md` in editor | "Edit Automation…" | `cmux automation edit ID [--prompt …] [--daily …]`; `$EDITOR` with no flags | `automation_update` (a run may edit itself) |
| History | detail page | — | `cmux automation history [ID] [--state failed]` | `run_list` |
| Logs | run row | — | `cmux automation logs RUN [--follow]` | `run_logs` |
| Cancel / retry / approve | run row | — | `cmux automation cancel|retry|approve RUN` | `run_cancel/retry/approve` |
| Delete | menu | "Delete Automation…" | `cmux automation delete ID` | `automation_delete` (agents need the person's yes, as Claude) |
| Runner | Settings › Automations | — | `cmux automation runner install|status|uninstall` | — |

All user-facing text is localized (en, ja). Every op takes an idempotency key.

## 8. UI: where automations live and how not to overwhelm

Mockups (light and dark, three options): `docs/automations-ui-mockups.html`; screenshots in the
landing report.

### 8.1 Principles

1. **Automations are not workspaces.** A daily task makes 365 runs a year; one sidebar row per run
   is noise. A run is a record with a transcript; it becomes a workspace only when you open it or
   it needs you.
2. **Silence is success.** A run that succeeded with nothing to report shows only in history.
3. **One place to manage, Home to be told.** Management lives on one page; news (a finding, a
   failure, a question) arrives in Home from the Chief, where the person already reads.
4. **Show the next thing, not everything.** The list shows each automation's next run and last
   result dot; history is one click away.

### 8.2 Options

- **A. One "Automations" row + page (default).** One system row under Home in the sidebar (calendar
  clock icon, count of active automations, a red badge only when something failed or needs you).
  It opens a page in the main area: a list grouped by "Needs you", "Today", "Later", "Paused", each
  row showing name, schedule in words ("Weekdays 9:00"), where it runs (chips "This Mac → Cloud"),
  next run, last result. Selecting a row shows its detail: prompt, triggers, targets, and the run
  history. Runs never add sidebar rows; "Open as workspace" opens one on demand.
- **B. A sidebar group "Automations".** A collapsible sidebar group with one row per automation;
  each run is a child workspace that auto-archives on success after 24 h. Familiar (it is how
  agents show up today) but grows with every automation and puts runs in the workspace list.
- **C. Home only.** No sidebar entry. Automations are cards in the Chief chat ("Morning brief ·
  weekdays 9:00 · last run ✓") and a "Scheduled" tab at the top of Home. Lowest chrome, but
  managing 10 automations inside a chat is hard and the CLI-created ones have no home.

**Default picked: A**, because it is one fixed row no matter how many automations exist (B grows),
it gives CLI- and MCP-made automations a visible home (C does not), and it matches both references
(Claude Desktop "Scheduled" page, ChatGPT automations page). From B we keep "Open as workspace"; from
C we keep news in Home.

### 8.3 How runs show up

| Run outcome | Sidebar | Home (Chief chat) | Notification |
| --- | --- | --- | --- |
| Succeeded, nothing to report | nothing | nothing | none |
| Succeeded with a report (the prompt asks to report, or the agent calls `automation.report`) | nothing | one compact card: title, 1–3 line summary, "Open run" | default off; per automation "notify me" |
| Waiting: needs you (approval, sign-in, question) | red badge on Automations | card with the question and buttons inline | yes (Mac + iPhone) |
| Failed / timed out / skipped by policy | red badge | card: what failed, last lines, Retry, Open run | yes; 3 in a row escalates |
| Caught up after sleep | nothing | the report card says "ran late (due 9:00)" | the catch-up itself is silent |

Cards from one automation stack (the newest replaces the older in place, "3 earlier" expands), so a
noisy automation never floods Home. A "Digest" option collects reports into one 8:00 card.

### 8.4 Create flow

- **From the Chief (main path):** "every weekday at 9 summarize my PRs" → the Chief answers with a
  confirm card: name, prompt (editable), "Weekdays at 9:00 (Pacific)", next 3 fire times, "Runs on:
  This Mac → Cloud when asleep", model, [Create] [Edit]. Nothing is saved until Create; one-shots
  ("remind me at 3") skip the card and confirm in one line, like Claude Desktop.
- **Form (Automations page "New", Cmd+Shift+P "New Automation…"):** four fields visible: Name, What to
  do (prompt), When (preset picker: Once, Hourly, Daily, Weekdays, Weekly, Custom, Manual, On event),
  Where (folder picker + "Run on" chips). "More" reveals model/agent, permission mode, worktree,
  catch-up policy, timeout, notifications. Defaults fill everything else.
- After Create, a one-tap "Run now to test" so permission prompts surface while the person watches
  (the Claude Desktop advice, made a button).

## 9. Folding in what exists

- Classic `~/.cmuxterm/automations.json` event rules become automations with a cmux-event trigger and
  a `steps` body (notify, rpc, run, webhook); `cmux automation import-classic` converts them.
- Cloud Chief jobs (`chief-auto`) stay as they are; they appear in the list as automations whose
  body is `chief` and target `cloud`. The local Mac Chief gets the same tool, backed by the ops above.
- The web dashboard `routes/automations.tsx` reads the same ops and stays the browser fallback.

## 10. Build order

| Slice | What lands | Proof |
| --- | --- | --- |
| 1 | `cmux-automations` crate: model, schedule math (cron+tz, presets, every, at), deterministic run ids, catch-up policy, atomic local store + `runs.jsonl`, runner lock and leases | unit tests written red first |
| 2 | `cmux automation create/list/show/run/pause/resume/edit/history/logs/delete` (local), `runner` (tick loop, run command and agent bodies through acpmux), `runner install` (launchd) | CLI tests through a temp store; a real run on a fleet Mac |
| 3 | Cloud target from the CLI: the same verbs with `--target cloud` call `automation.*` ops; `chief` bodies for the Cloud Chief | workerd test + staging run |
| 4 | App page (option A), Cmd+Shift+P entries, Home cards, notifications | screenshots light/dark, UI test |
| 5 | Failover between targets (HostDO offers, wait_for_preferred), uploads of local runs, heartbeat alerts | two-machine fleet test with one asleep |
| 6 | Event triggers on the local runner, classic import, wake-for-automations helper | |

## 11. Open product choices (defaults picked, Lawrence may override)

1. UI home: one Automations row + page (A), not a sidebar group (B) or Home-only (C).
2. Missed runs: fail over to another machine first; else one catch-up for the latest miss within 24 h
   (Claude uses 7 days); every miss stays visible in history.
3. Successful runs are silent unless the run reports something; failures and needs-you always notify.
4. Schedule owner: cmux Cloud when signed in (local runners only execute), local store when signed
   out. Local-only automations are possible with `--local-only`.
5. Cloud pricing: keep the existing free-plan cap (1 Cloud automation) and count local runs as free and
   unlimited.
6. Runs never add sidebar rows; "Open as workspace" on demand.
7. Delete by an agent needs the person's yes (as Claude Desktop).

## 12. Status (landed)

- Slice 1 (local): `cmux-automations` crate and `cmux automation create/list/show/run/pause/resume/edit/history/logs/delete/runner` on this Mac.
- Cloud slice: `automation.create` with a `chief` body from the person's clients shares the free plan's one Cloud job (`chief-job-gate.ts`); the app's `cloud.automation` method (`CloudAutomationRelay`) forwards Cloud automation ops as the signed-in user; `cmux automation … --target cloud`; the Mac Chief makes jobs with `cmux automation` (prompt Jobs rule); the Automations page view and model (`CmuxNextCloudUI/Automations`).
- Not yet: the Automations sidebar row, its page provider and the Cmd+Shift+P entries (app wiring; the provider protocol lives in the app target), failover between targets, event triggers on the local runner.
