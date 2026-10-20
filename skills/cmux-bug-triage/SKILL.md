---
name: cmux-bug-triage
description: "Triage tester bug reports (screenshots or photos plus short notes) for cmux: put them in the inbox (~/fun/cmux-bug-inbox), transcribe the images, split each report into separate bugs, dedup against open subagents, cmux-prompt-commits.md, Sentry and the feat-cmux-next git log, score them (crash/data loss > broken feature > polish; reach; effort) and decide fix now / batch / skip with a one-line reason. Fix-now bugs become subagent tasks with a short title line and a topic sidebar group; skips are logged. Use when the user forwards a tester's bug report or asks which reported bugs are worth fixing."
---

# cmux bug triage

`scripts/cmux-bug-triage` does the repeatable part (split, dedup, score, decide, task text). You
do the parts that need a model: reading the images and a last sanity check. Rules and thresholds
are in [DESIGN.md](DESIGN.md).

```bash
T=skills/cmux-bug-triage/scripts/cmux-bug-triage   # or the installed skill's path

# 1. Intake: one folder per report in ~/fun/cmux-bug-inbox (CMUX_BUG_INBOX overrides).
printf '%s\n' "$REPORT_TEXT" | $T add --text - --image ~/Desktop/shot1.png --from "Tester name"
#    Or drop report.md + images into a new subfolder (or a loose .md file) in the inbox.

# 2. Images: Read every image in the new folder and append to its report.md:
#      ## Images
#      - shot1.png: <one bullet per visible bug: what is wrong, where, which control>

# 3. Triage everything new. Pass open subagents as "aN: task" lines from your view.
$T inbox --open-work /tmp/open-agents.txt --repo ~/fun/cmux            # triage.md per report
$T inbox --open-work /tmp/open-agents.txt --repo ~/fun/cmux --json     # tasks for spawn
$T triage ~/fun/cmux-bug-inbox/<folder> --json                          # re-run one report (no logs)
```

Sources: `--open-work FILE`, `--prompt-commits FILE` (default `~/fun/cmux-prompt-commits.md`,
`CMUX_PROMPT_COMMITS=` disables), `--sentry FILE` (JSON from `sentry-cli issues list --json`, when
`sentry-cli` is logged in), `--repo DIR` for the `origin/feat-cmux-next` log (`--no-git` skips).

## Decisions

- **fix now**: crash, hang or data loss (closing the wrong thing counts), or score >= 6. Each one
  has a ready `tasks[]` entry: `title` (2-5 words, first line of `prompt`), `group`, `prompt`
  (tester text, environment, screenshot paths, macOS-version repro note, standing rules).
- **batch**: the rest. Queued in `BATCH.md`; when 3 or more are pending, `inbox` returns one
  `batch_task` and checks them off.
- **skip**: duplicate of an open agent, Sentry issue or landed commit (the reason names it), or
  too vague. Logged in `SKIPPED.md` with the reason.

## After the script

1. Sanity-check each decision against the screenshots. Override a wrong one in your reply
   (say which and why); do not edit the thresholds for one report.
2. Spawn each fix-now task (and a batch task) with its `prompt` as the task text, then move the
   new workspace into its `group`: reuse it from `cmux --json workspace group list`, or create it
   with `cmux workspace group create --name NAME`, then
   `cmux workspace group <grp> add --workspace <ws_…>`.
3. Report to the user: one line per bug, `decision — title — reason`, with the agent id for each
   spawned fix. For a skip as "likely fixed by <sha>", ask the tester to retest on the next nightly.

## Tests

`python3 tests/test_cmux_bug_triage.py` runs the CLI on the tester fixture
`tests/fixtures/bug-triage/sequoia-report` (macOS Sequoia: Cmd+1/2/3 crash, Cmd+D/Cmd+W in
Settings, composer third dropdown, wallpaper text overflow) with temp inboxes. It is fast and
safe to run locally.
