# cmux perf sheriff

Status: building (2026-10-26). Owner: PL-perf-lab ([OWNERS.md](OWNERS.md)). The lab itself:
[perf-lab-DESIGN.md](perf-lab-DESIGN.md). Program spec: [chrome-parity/p12-perf-process.md](chrome-parity/p12-perf-process.md)
section 3.7.

The perf sheriff is the agent session that takes each verified regression from the perf lab to a fix, a flag-off or an
accepted reason. It is the cmux copy of Chrome's perf sheriff rotations (`docs/speed/chrome_speed_operations.md`) and of the
policy in `docs/speed/addressing_performance_regressions.md`: "If you make a change that regresses
measured performance, you will be required to fix it or revert."

The sheriff is not a CI gate. It never holds a merge, never adds a CI job, a check or a budget row, and never needs a
person for a normal-tier fix.

The commands below run `scripts/perf-lab/sheriff.py` and `scripts/perf-lab/alerts.py` directly. When these modules
declare `LAB_COMMANDS`, the same commands also run as `lab.py sheriff` and `lab.py alerts`. `sheriff.py` reads the
lab store from `--db` or `$CMUX_PERF_LAB_DB`. `alerts.py` needs `--db`; it does not read the environment. labd makes
and migrates the store. The commands never make one.

## 1. Rotation

- One sheriff session at a time works the queue. It runs `.claude/workflows/perf-sheriff.js` (task 020) in a loop
  over the MQ10 queue: `python3 -I scripts/perf-lab/alerts.py groups --db DB --state new,triaged,culprit --json`.
- A shift is 12 h, the longest SLO below, so one shift can close each group it takes. At the end of the shift the
  session writes one handoff line for each group it holds (`sheriff.py list`). The next session takes them.
- The sheriff takes a group before it works on it (`sheriff.py take <group>`). One group has one holder. A take is a
  lease of 2 h (`TAKE_LEASE`), and each state change by the holder starts the lease again. When the lease ends,
  another session can take the group. Only the Performance Lead's session can change a group that a different session
  holds. A fixer agent that the sheriff starts works for the sheriff, and the group stays with the sheriff.
- The acting session comes from the environment (`CMUX_AGENT_SESSION`, else `CLAUDE_CODE_SESSION_ID`, else
  `CODEX_THREAD_ID`). It is never an argument.
- A `lab-drift` group goes to the lab owner (PL-perf-lab), not to the sheriff. A `harness-broken` group goes to the
  story owner in `scripts/perf-lab/stories.d/<id>.json`.
- When no sheriff session runs, the SLO clock still runs. `sheriff.py --slo --since-live` shows the misses.

## 2. States

`new -> triaged -> bisecting -> culprit -> assigned -> fixed | flag-off | accepted | invalid | lab-drift`
(`scripts/perf-lab/store.py` `ALERT_GROUP_STATES`). Each change is one row in `sheriff_history`, with its time, the
session that made it and the reason (task 019). The store checks each change against `sheriff.TRANSITIONS` in the same
transaction, so two sessions cannot both move a group.

| State | Meaning | Who sets it |
| --- | --- | --- |
| `new` | The lab made the group. No one has looked at it. | `alerts.py detect` |
| `triaged` | A sheriff took it and confirmed the step with a try job. | sheriff |
| `bisecting` | The Pinpoint job runs. | Pinpoint (task 016), or the sheriff until it lands |
| `culprit` | A bisect named one commit. `verify.py` judged it, and `culprit_verified` records the verdict: strict DIFFERENT (p <= 0.01) in the regression direction. The issue opens only for a verified culprit. | `verify.py`, or the sheriff with `--culprit SHA` |
| `assigned` | A fix PR is in progress. Needs a reason. | sheriff |
| `fixed` | The series recovered: the 2 newest judged batches after each regression alert of the group are on the good side of the step. The store refuses `fixed` before that. A merged PR alone is not enough. | sheriff, from `assigned` only |
| `flag-off` | The culprit's feature is off on the branch. Needs a reason. | sheriff, from `culprit` or `assigned` |
| `accepted` | The regression stays. Needs a reason and the Performance Lead's session (the file `perf-lead-session` beside the store). | Performance Lead |
| `invalid` | Not a real change (for example a story bug). Needs a reason. The sheriff opens a story fix task. | sheriff |
| `lab-drift` | The reference series moved in the same window. No bisect. Needs a reason. | the lab (task 146), or the sheriff before `culprit` |

Two changes go back, and each needs a reason: `bisecting -> triaged` (the bisect failed) and `culprit -> bisecting`
(the culprit did not hold).

## 3. SLOs

Counted from the alert, for groups made since the lab went live (`sheriff.py` `TRIAGE_SLO`, `CULPRIT_SLO`,
`FIX_SLO`).

| Step | Limit |
| --- | --- |
| Alert to `triaged` | <= 1 h |
| Alert to `culprit` | <= 4 h (median; a group still before `culprit` counts with its age) |
| Alert to `fixed` or `flag-off` | <= 12 h |
| Groups older than 12 h in `new`, `triaged`, `bisecting` or `culprit` | 0 |

`sheriff.py --slo --since-live` reports them (`--since 24h` for a shorter window). Done check 12 in
p12-perf-process.md section 6 asks for 100 % triaged within 1 h, a median of <= 4 h to the culprit, and 0 groups
older than 12 h in those states.

## 4. Decision table

Do the first row that applies.

| # | Condition | Action | Final state |
| --- | --- | --- | --- |
| 1 | The group is `new`, `triaged` or `bisecting`, and the `.ref` series moved in the same window | Give the group to the lab owner. Do not bisect. | `lab-drift` |
| 2 | The group is `culprit` or `assigned`, and the `.ref` series moved in the same window | `sheriff.py` refuses `lab-drift` after `culprit`. Tell the lab owner, and set `invalid` with the drift as the reason. | `invalid` |
| 3 | The story fails, or the step is a story or harness bug | Open a story fix task for the story owner. Do not change budgets or thresholds. | `invalid` |
| 4 | The culprit is not verified (`culprit_verified` is false: strict not DIFFERENT, or not in the regression direction) | Verify the culprit again with more attempts (`verify.py` `plan` and `run` with a larger `attempts`, through the Pinpoint executor). If it is still not strict DIFFERENT, move the group back to `bisecting` with the reason, or set `invalid` when the step itself did not hold. No issue opens. | `culprit` when verified; else `bisecting` (bisect again) or `invalid` (the step did not hold) |
| 5 | The culprit is behind a `perfPath` feature | Flag-off first: a PR that sets the feature's branch default to off in `schemas/features/features.d/<name>.json`, with the generated files from `python3 scripts/cmux-next/gen-features.py`. Then the owner fixes the code and turns it on again with a try receipt that shows both arms. | `flag-off` |
| 6 | The culprit is a `killSwitch` feature or needs an off between nightlies | Same as row 5. A remote off with `scripts/features/publish-flags.py` needs decision D2; until then use the branch default. | `flag-off` |
| 7 | The culprit is not behind a feature | Fix forward. A fixer agent works from the stored traces (task 157). 2 adversarial reviewers check the fix against [REVIEW-STANDARD.md](REVIEW-STANDARD.md). A try job (`lab.py try`) shows the recovery. | `fixed` |
| 8 | Row 7, and the regression breaks nightly-next, and the fix will not land before the next cut | Revert with `gh-merge-green --revert manaflow-ai/cmux#<number>` (CLAUDE.md, [risk tiers](../../docs/ci/risk-tiers.md#ship-risky-behavior-dark)). Then fix forward. | `fixed` |
| 9 | The cost is on purpose: a net win on other series, a correctness or security fix, or a wrong metric | Write the reason on the issue with the numbers (Chrome's justification cases in `addressing_performance_regressions.md`). Only the Performance Lead sets `accepted`. | `accepted` |

## 5. Fix-or-revert policy

- Fix forward is the default. `main` is nightly: fix forward, do not revert (CLAUDE.md). On `feat-cmux-next`, a
  revert is only row 8, and only with `gh-merge-green --revert`. Never `--admin`, never `--override`, never the API
  merge path to get around `gh-merge-green`.
- A flag-off PR and a revert PR take back a change. When that change merged in the last week, the PR description has
  the line `Takes back #N: <why>` (the take-back hold, CLAUDE.md). It also has a `risk:` label
  ([risk tiers](../../docs/ci/risk-tiers.md)). The sheriff never adds `risk:human-ok` or `risk:waived`.
- A fix PR names the alert group, the culprit sha and the try receipt lines, before and after. It follows the testing
  policy: commit the failing regression test first, then the fix.
- Never edit a budget, a threshold, a target or an expectation to clear an alert. The fixer prompt says this. A noisy
  series gets a de-noise task (MQ11, `lab.py aa --cv-over 0.05 --json`, task 024). The threshold does not get wider.
- `scripts/perf-lab/expectations.json` can disable a story x host pair only with an issue link and an expiry of at
  most 7 days (task 023). It is for a broken host or story, not for a regression.
- Tell the owner of the culprit's area ([OWNERS.md](OWNERS.md)) in the issue. `attribution.py` (task 022) tells the
  culprit's author with one PR comment that links this file.

## 6. Tools

| Command | Use |
| --- | --- |
| `python3 -I scripts/perf-lab/alerts.py groups --db DB --state new,triaged,culprit --json` | The queue (MQ10). |
| `python3 -I scripts/perf-lab/sheriff.py list [--state S,...]` | Groups with state, age and holder. |
| `python3 -I scripts/perf-lab/sheriff.py take <group>` | Take a group (2 h lease). |
| `python3 -I scripts/perf-lab/sheriff.py set <group> <state> [--reason TEXT] [--culprit SHA]` | Change the state. |
| `python3 -I scripts/perf-lab/sheriff.py history <group>` | The state history of a group. |
| `python3 -I scripts/perf-lab/sheriff.py --slo --since-live` | The SLO report. |
| `python3 -I scripts/perf-lab/lab.py try --base SHA --head SHA --stories <id>` | Confirm a step, or prove a fix ([perf try receipts](../../skills/cmux-testing/SKILL.md#perf-try-receipts)). |
| `python3 -I scripts/perf-lab/lab.py aa --cv-over 0.05 --json` | Noisy series (MQ11). |
| `python3 scripts/cmux-next/gen-features.py` | Regenerate the feature files after a default flip. |

`lab.py try` (task 018), `lab.py aa` (task 024), the workflow (task 020) and a command that verifies a culprit again
(`verify.py` has no command line; the Pinpoint executor, task 016, runs it) are not on the branch yet. Until the lab
owns measurement (task 026), the perf cron (`scripts/cmux-next/perf-cron.py`) and its single issue
"cmux-next perf regression" are the regression report.
