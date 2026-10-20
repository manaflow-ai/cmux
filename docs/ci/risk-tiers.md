# Risk tiers for feat-cmux-next pull requests

Each pull request into `feat-cmux-next` is labeled `risk:low`, `risk:medium` or `risk:high`
from the paths it changes. The label decides what evidence the description needs before merge.
`.github/workflows/risk-tier.yml` sets the label and runs the `risk evidence` check, and
Nothing merges while that check is red on the exact head: `next-autoland` into `feat-cmux-next` and `gh-merge-green` into `main` both refuse it.

Why: in the two weeks to 2026-10-18, 2,049 pull requests merged into `feat-cmux-next`. 932 of them
had a failing check on their merged head that wasn't a review bot or a report-only lane. Pull
requests into `feat-cmux-next` don't run `cmux-next swift test` unless they're labeled `full-ci`,
so a new Swift test usually compiles and never runs before merge. Green CI on a pull request
here says little about runtime behavior. The tiers ask for proof where a regression would hurt.

## Tiers

The classifier is `scripts/ci/risk_tier.py`. A pull request takes the highest tier of any file it
changes. A file it can't place is medium, so a new directory is never graded low by accident.

| Tier | When | Evidence before merge |
| --- | --- | --- |
| low | only docs, `*.md`, tests, skills, plans, `scripts/` tooling, and `.github/` files other than workflows and actions | green CI on the exact head |
| medium | app UI (`Packages/`, `webviews/`, `App/`, `ios/`, `web/`), SDK bindings, workflows that don't route checks, anything unclassified, and a runtime change of 40 lines or fewer | plus a screenshot or clip under `## Proof` (next to the matching [cmux-design-references](https://github.com/manaflow-ai/cmux-design-references) entry when one exists), or `Not UI: <why>` |
| high | any of the four below | plus an independent review and a runtime test that executed the change |

High comes from four places:

- **Always, at any size.** One line here can break shipping or every other merge:
  - signing, release, publish, deploy, nightly, promote and rollback scripts and workflows (in any `scripts/` directory), `scripts/ci/lib/`, update and entitlements
  - migrations, `schemas/defaults/` (the defaults every user gets), the `cmux-tui/spec/` JSON (its Markdown is docs), `plans/cmux-next/daemon-capabilities.json`
  - vendored pins and `Package.resolved`, `ghostty.h`, `homebrew-cmux`, `.xcode-version`
  - the merge gates and check routing: `CODEOWNERS`, `gh-merge-green`, this classifier, `cmux-next.yml`, `ci.yml`, `ci-guards.yml`, `ci-macos.yml`, `cmux-tui.yml`, `merge-*.yml`, `cmux_next_route.py`, and the helpers `gh-merge-green` calls (`merge_freeze.py`, `main_fix_evidence.py`, `vercel_merge_gate.py`), `merge-main.sh` and the god-file check. One line in `cmux-next.yml` stopped feat-cmux-next PRs from running `swift test`.
- **A runtime change over 40 lines.** That's 40 changed lines outside tests and generated files, summed across `cmux-tui/` (daemon, acpmux), `backend/`, `schemas/`, `daemon/`, `server/`, `services/`, `workers/`, and the NEXT targets `Daemon*`, `Control`, `Server*`, `Remote*`, `Mobile`, `Bridge`, `Accounts`, `AppPermissions`, `History`, `Cloud`, `BrowserImport`, `BrowserAutomation`, `BrowserHost`, `ComputerUse`, `CrashReporting`, `CLIInstall`, the terminal input path, and the OptChat agent backend (`Native/OptChat/`, except its inspector UI). A smaller change there is medium, because a reviewer can read it whole.
- **Taking back a change another pull request merged in the last 7 days.** That means deleting most of what it added, and putting back most of what it replaced. The check names the pull request. One stale-base squash (50a0c607aee, #21194) undid #21199, #21234, #21369, #21384 and #21446 this way, and graded only medium by path. If it's on purpose, say so in the description; the review covers it.
- **A medium change over 1,000 lines** outside tests and generated files.

## What the description needs

Medium, under `## Proof` (or `## Screenshots`, `## Demo`, `## Video`, `## Recording`): an embedded image or video, an uploaded attachment, or a link to an
image or video file. A link to a CI run isn't proof. When nothing user-visible changes, write
`Not UI: <why>` in a sentence instead.

High, anywhere in the description, as their own lines:

```
Review: SHIP at 1a2b3c4d5e6f (cmux-review subagent; correctness first)
Runtime test: AgentQueueTests/aFailedTurnHoldsTheQueue() in https://github.com/manaflow-ai/cmux/actions/runs/123
```

- `Review:` names a commit on this pull request that an independent reviewer read
  ([cmux-review](../../skills/cmux-review/SKILL.md)). The author's own agent doesn't count.
  A `Review:` commit older than the head says the later commits went unreviewed; re-review
  anything beyond a merge of the base.
- `Runtime test:` names the test, and the run URL where it executed this change, or the commit of
  this pull request that a tagged build or a Testbox ran. Pull requests here
  skip `cmux-next swift test`, so dispatch it: `gh workflow run cmux-next.yml --ref <branch>`
  runs every tier on that branch. A `cargo test` run on a Testbox, or a tagged build you drove
  with `scripts/cmux-debug-cli.sh`, works too: give the command and the SHA it ran on.

The check re-runs when the description is edited, so adding the lines turns it green.

Until 2026-10-24 00:00 UTC (`ENFORCE_FROM` in `risk-tier.yml`) the check is advisory: a missing
item is a warning and the check passes, so pull requests already in flight have time to add their
evidence. After that it blocks merge. A verdict from the advisory window doesn't count after the
cutover: `gh-merge-green` reads `ENFORCE_FROM` from the base and refuses a `risk evidence` check
whose job started before it, or one that never ran. Edit the description (or push) to re-grade.

## Ship risky behavior dark

A high-tier change that a user would notice lands behind a setting or Debug toggle that defaults
off, unless it fixes a regression. Flip the default in its own small pull request after a
nightly-next has carried it. That flip is high tier too (`schemas/defaults/`), so it needs its
own evidence.

## Canary and revert

nightly-next is the canary. The agent that merged a high-tier pull request checks the first
nightly-next that contains it. When a high-tier change breaks nightly-next and the fix isn't
ready before the next nightly-next is cut, revert it:

```bash
gh-merge-green --revert manaflow-ai/cmux#<number>
```

That opens the revert pull request and lands it through the same checks. Reland with the fix
and a regression test.

## Waiving

A maintainer (admin or maintain role; the check reads who added the label) can add `risk:waived` to accept a pull request without its tier's evidence, for
example a base-red repair that has to land now. Agents never add it. A wrong tier is a bug in
`scripts/ci/risk_tier.py`: fix the rule and its test in `tests/test_risk_tier.py`, instead of
waiving.
