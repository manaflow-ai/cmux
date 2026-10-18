# Risk tiers for feat-cmux-next pull requests

Each pull request into `feat-cmux-next` is labeled `risk:low`, `risk:medium` or `risk:high`
from the paths it changes. The label decides what evidence the description needs before merge.
`.github/workflows/risk-tier.yml` sets the label and runs the `risk evidence` check, and
`gh-merge-green` won't merge while that check is red on the exact head.

Why: in the two weeks to 2026-10-18, 2,049 pull requests merged into `feat-cmux-next`. 932 of them
had a failing check on their merged head that wasn't a review bot or a report-only lane. Pull
requests into `feat-cmux-next` don't run `cmux-next swift test` unless they're labeled `full-ci`,
so a new Swift test usually compiles and never runs before merge. Green CI on a pull request
here says little about runtime behavior. The tiers ask for proof where a regression would hurt.

## Tiers

The classifier is `scripts/ci/risk_tier.py`. A pull request takes the highest tier of any file it
changes. A file it can't place is medium, so a new directory is never graded low by accident.

| Tier | Paths (examples) | Evidence before merge |
| --- | --- | --- |
| low | docs, `*.md`, tests, skills, plans, `scripts/` tooling and `.github/` files other than workflows and actions | green CI on the exact head |
| medium | app UI: `Packages/`, `webviews/`, `App/`, `ios/`, `web/`, SDK bindings; anything unclassified | plus a screenshot or clip under `## Proof`, next to the matching reference from [cmux-design-references](https://github.com/manaflow-ai/cmux-design-references) when one exists |
| high | `cmux-tui/` (daemon, acpmux, protocol, spec), `daemon/`, `server/`, `services/`, `workers/`, `backend/`, `schemas/`, migrations; the NEXT targets `Daemon*`, `Control`, `Server*`, `Remote*`, `Mobile`, `Bridge`, `Accounts`, `AppPermissions`, `History`, `Cloud`, `BrowserImport`, `BrowserAutomation`, `BrowserHost`, `ComputerUse`, `CrashReporting`, `CLIInstall`, `Updater` and the terminal input path; vendored pins and `Package.resolved`; signing, release, publish and entitlements; the merge gates themselves (`CODEOWNERS`, `gh-merge-green`, this classifier) and every workflow and action under `.github/`, since they run with secrets or write tokens and decide what other pull requests skip | plus an independent review and a runtime test that executed the change |

A medium pull request that changes more than 1,000 lines outside tests and generated files is high.

## What the description needs

Medium, under `## Proof`: an embedded image or video, an uploaded attachment, or a link to an
image or video file. A link to a CI run isn't proof. When nothing user-visible changes, write
`Not UI: <why>` in a sentence instead.

High, anywhere in the description, as their own lines:

```
Review: SHIP at 1a2b3c4d5e6f (cmux-review subagent; correctness first)
Runtime test: AgentQueueTests/aFailedTurnHoldsTheQueue() in https://github.com/manaflow-ai/cmux/actions/runs/123
```

- `Review:` names a commit on this pull request that an independent reviewer read
  ([cmux-review](../../skills/cmux-review/SKILL.md)). The author's own agent doesn't count.
- `Runtime test:` names the test, and the run URL where it executed this change, or the commit of
  this pull request that a tagged build or a Testbox ran. Pull requests here
  skip `cmux-next swift test`, so dispatch it: `gh workflow run cmux-next.yml --ref <branch>`
  runs every tier on that branch. A `cargo test` run on a Testbox, or a tagged build you drove
  with `scripts/cmux-debug-cli.sh`, works too: give the command and the SHA it ran on.

The check re-runs when the description is edited, so adding the lines turns it green.

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
