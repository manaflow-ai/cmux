# Bug report triage: design

## Problem

Testers send bug reports as screenshots or photos plus short notes. One report often holds
several bugs. Many of them are already fixed, already in progress, or are polish that should not
interrupt an agent. The Chief needs a fast way to pick the reports that are worth a fix agent now.

## Shape: a skill, not Chief code

A skill is the smaller build. The Chief (or any agent) already reads images, runs Bash and
spawns subagents. What it lacks is a repeatable rule for splitting, dedup, scoring and the task
text. So the skill is:

- `SKILL.md`: the procedure the agent follows (read the images, transcribe, run the script,
  review, spawn).
- `scripts/cmux-bug-triage`: a stdlib-only Python 3 tool for the deterministic part. It never
  reads images and never calls a network service, so its output is testable and repeatable.

## Intake

Three entry points feed the same inbox folder, `~/fun/cmux-bug-inbox` (`CMUX_BUG_INBOX`
overrides it):

1. Home chat: the user pastes text and images to the Chief. The Chief runs
   `cmux-bug-triage add --text - --image PATH...`.
2. CLI: `cmux-bug-triage add` from any terminal (the "cmux bug" entry point; a `cmux bug`
   alias can call it later without a new code path).
3. Folder: drop a `*.md`/`*.txt` file and images into a new subfolder of the inbox.

Each report is one folder: `report.md` (tester text), image files, and after triage
`triage.json` + `triage.md`. Images are copied, never opened by the script.

## Images

The agent reads every image with its Read tool and appends a `## Images` section to
`report.md`: one bullet per visible bug, with the image file name. The script treats those
bullets as bug text like any other. This keeps the image step in the model and the scoring in
code.

## Split

A report splits into bugs on bullet lines (`-`, `*`, `•`, `1.`, `1)`), and else on blank-line
paragraphs. A header line such as `macOS Sequoia 15.6, build 3934171` is context, not a bug: it
sets the report's environment (macOS name/version, build) on every bug.

## Dedup

Each bug is compared against open and recent work:

- `cmux-prompt-commits.md` summary rows (prompt text, status, commits).
- `git log` subjects of `origin/feat-cmux-next` (last 400).
- Open subagents: a text file, one `aN: title/task` line each (the Chief writes it from its view).
- Sentry issues: a JSON file from `sentry-cli issues list` (optional; skipped when absent).

Matching uses normalized keyword sets. Shortcuts (`Cmd+Shift+D`, `Cmd+1/2/3`) become tokens and
must match exactly. A match needs a shared shortcut plus one shared word, or three shared words
that cover at least half of the bug's words. Common words (`app`, `cmux`, `bug`, `the`...) do
not count. A match to landed work means "probably fixed after the tester's build"; a match to an
open agent means "already being fixed".

## Score

- Severity: 3 = crash, hang, freeze, data loss, closes the wrong thing; 2 = broken feature (does
  not work, wrong result, cannot); 1 = polish (overflow, clipped, misaligned, spacing, looks).
- Reach: +1 for global paths (shortcuts, launch, every window, sidebar, terminal); 0 else.
- Effort: 1 small (polish, one view), 2 medium (default), 3 large (redesign, "all", "every").
- Score = severity x 3 + reach - effort.

## Decide

- `skip`: a duplicate of open or landed work, or too vague (fewer than 3 content words).
  Every skip goes to `SKIPPED.md` in the inbox with its reason.
- `fix now`: severity 3, or score >= 6.
- `batch`: everything else. Batch items queue in `BATCH.md`; the agent spawns one batch agent
  when the queue has 3 or more items.

## Output

`triage.md`: one line per bug, `decision — title — reason`. `triage.json`: the same plus, for each
`fix now` bug and for a full batch, a ready subagent task: first line a 2-5 word title (it becomes
the workspace name), a `group` (topic sidebar group from the area: Settings/wallpaper ->
`cmux-next app`, composer/Home/chat -> `Home & chat`, tab/sidebar/workspace -> `Sidebar & tabs`,
pane/split -> `Panes & layout`, browser/omnibar -> `Browser & parity`), the tester text, image
paths, the environment (with "repro on a macOS 15 builder" when the tester is on Sequoia), and
the standing rules (worktree off `origin/feat-cmux-next`, failing-first test, fleet builds only,
plain push, no PR).

## Not in v1

- A `cmux bug` subcommand in the Rust CLI (the script is the CLI for now).
- Automatic Sentry fetch (needs `sentry-cli` login).
- Learning from past decisions.
