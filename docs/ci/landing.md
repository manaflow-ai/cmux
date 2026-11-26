# Landing a cmux PR

Moved here from the root CLAUDE.md on 2026-11-19 (docs audit), with the review and merge rules brought up to date; the root keeps a short summary.

## Contributions and publication

Before fixing a bug or adding a feature, search open upstream PRs by symptom or
issue number. Prefer landing an outside contributor's existing PR; push fixups
only when maintainer edits are allowed, and explain the changes. If using their
approach in your own PR, credit them in every such commit with `Co-authored-by`
using their commit email, link your PR from theirs and thank them. Let a human
close it; never close an outside PR without a human-written explanation.

The server directories listed in [LICENSE](../../LICENSE) (`web/`, `workers/ci-artifacts/`,
`workers/iroh-v2/`, `workers/presence/`, `workers/device-hub/`, `services/iroh-relay-minter/`,
`cmux-tui/relays/cloudflare-do/`, `backend/`) use the Business Source License, which needs
every outside author's CLA grant. Do not merge a PR that changes those
directories while CLA Assistant is red, and do not copy an outside
contributor's work there under a `Co-authored-by` trailer unless that person
has signed the CLA. Keep code that ships in the macOS or iOS app out of those
directories.

Read [STYLE.md](../../STYLE.md) before drafting or revising issues, PR descriptions,
RFCs or progress updates. Fill the PR's `## Changelog` section with one
`Added`/`Changed`/`Fixed`/`Removed` line for user-visible changes, otherwise `none`.
Do not edit `CHANGELOG.md` in feature PRs; release tooling owns it.

## CI runners and nightlies

For `feat-cmux-next` compile and build work, use fast checks first, then any
free compatible owned Mac through the controller, and Blacksmith macOS only as
the last resort. A compile or build must never depend on a single-host
reservation without a fallback. The nightly app builder remains dedicated;
Release gates do not share it. Signing, notarization and GUI steps that truly
require macOS run on owned Macs first and Blacksmith macOS last, in parallel
with the fast checks. Keep the target at zero queue.

**Nightlies never use Blacksmith, ever** (Lawrence, 2026-10-30). Every job of
every nightly workflow (`.github/workflows/*nightly*.yml`,
`*notarization*.yml`, the nightly appcast repair) runs only on our own Mac
minis, for cmux-next and classic alike. This covers every path: the primary
label, fallbacks, re-runs and rescue attempts, twin/backup signing jobs, the
cloud overflow switch, and any input or repository variable a nightly
`runs-on` reads. Never add a Blacksmith label (or a variable that may hold one,
such as `LINUX_RUNNER` or `MACOS_RUNNER_*`) to a nightly job; when owned
capacity is short, fix the owned pool. `tests/test_ci_nightly_off_blacksmith.py`
enforces this.

**Nightlies run on one signing Mac, end to end, and nobody cancels them** (Lawrence,
2026-11-04; Leo, 2026-11-12, hq#10366: one primary signer and one standby signer).
The whole nightly (build, sign, notarize, verify and publish, for cmux-next on
`nightly-next` and classic on `main`) runs on one signing Mac, a host whose runners
carry `glaeda-trusted-next-signing` (cmuxterm-hq
`build-fleet/mini-fleet.json` `runner.trustedNextSigning`). This applies to humans,
Leo and every agent:

- Never move a nightly job to Blacksmith, a GitHub-hosted runner or a Mac without
  that label, and never split one nightly across Macs, also not "only for this run".
- Never cancel a nightly run, a nightly job or the nightly queue to make room or
  to speed up a proof. A queued nightly waits its turn.
- When a signing Mac is short of capacity or a nightly is slow, report it and
  fix that Mac or the workflow on it. Do not reroute the nightly.

## Review and merge

- Commit the failing behavioral regression before its fix; record the same
  focused command's red and green results ([testing policy](../../skills/cmux-testing/SKILL.md#reproduce-and-repair)).
  A bug-fix PR body names that command, its failure on the base and its pass on the head,
  then an `### Observed / Not run` section: what you ran and saw, then what you only read
  or didn't run.
- Check executed tests on the current SHA; green skipped jobs do not establish coverage.
  Add `full-ci` only for an agreed broad validation plan, naming the extra lanes and why
  ([CI coverage](../../skills/cmux-testing/references/pr-ci-coverage.md)); never for a rerun or extra confidence.
- Keep branches current locally with `scripts/merge-main.sh`; follow
  [the merge-main guide](merge-main.md) and never force-push over its merge.
- `gh pr merge` saying "base branch policy prohibits the merge" means the token lacks the `workflow`
  scope or GitHub timed out, not a rule: run `gh auth refresh -h github.com -s workflow` and retry once. If
  GitHub still refuses, say so on the PR and stop. Never `--admin` or the API merge path.
- A first implementation pass ends with passed scoped verification and an open PR;
  do not watch CI or run speculative reviews by default.
- Never hand-edit or hand-merge generated files (`settings-schema.json`,
  `docs/mdm/*`). On a conflict take either side; the PR or base autofix regenerates them (#21946, #21985).
- Webview UI screenshots come from the gallery advisory run: add a gallery entry with fixture states.
  For a before/after in a minute or two, push and run `scripts/gallery-compare.sh [--open]`: it prints a
  tailnet URL that shows each gallery state your change reaches at the merge-base and at your branch, side
  by side (no Swift build). A `Visual-change: <state id or *>: <why>` line in the PR body says a difference is
  wanted; the status comment marks every other changed, new or removed state "unjustified" (warn only).
  Mac captures (the `cmux-next media` tours) are only for native/AppKit UI or real end-to-end flows.
- A native UI change shows a real capture in its description (`pr-capture-check` warns otherwise; a missing capture never blocks a land, since Leo tries the build):
  `cmux-ci capture <head sha> --state scene:NAME|tour:NAME --pr N [--video]` builds that commit, drives the
  real app on a capture mini, takes light and dark stills, refuses any that show private text, and prints
  the Markdown to paste. Or add the `media-tour` label, or write `No capture: <why>`. Never mock stills.
- Every `feat-cmux-next` PR gets a `risk:low|normal|high` label ([risk tiers](risk-tiers.md)).
  Low (docs, copy, generated, tests) and normal (most UI and logic) never wait for a person:
  agent review and the relevant checks, then merge. High (auth, socket and relay policy,
  migrations, release/signing/updater, the risk gate and its enforcers (`gh-merge-green`,
  `next_batch.py`), a new delete of user data, a new
  `pull_request_target` or `workflow_run` trigger) lands on an independent review receipt
  `Review (<reviewer>): SHIP at <full head sha>` on the exact head plus a green compile; the SHIP
  counts from any reviewer, the PR's own agent included (format: [risk tiers](risk-tiers.md)). Any tier is held while it takes back a
  change merged in the last week, until the description has `Takes back #N: <why>`. Ship
  user-visible high-tier behavior behind a default-off setting; revert with
  `gh-merge-green --revert` if it breaks nightly-next and the fix misses the next cut. Agents never
  add `risk:human-ok` or `risk:waived`.
- Before opening a PR and before merging, check it against "In a cmux PR: what review keeps catching" in the private
  [before-you-ship checklist](https://github.com/manaflow-ai/cmuxterm-hq/blob/main/docs/handbook/before-you-ship.md),
  the mistakes our review history keeps catching.
- Before designing a change or fixing a bug, read [design-lessons.md](../cmux-next/design-lessons.md):
  the causes our fix history keeps repeating, each with its rule and cost.
- Start a [review subagent](../../skills/cmux-review/SKILL.md), correctness first, when the PR is up.
  It runs beside CI and does not gate a merge into `feat-cmux-next`: a SHIP counts from any reviewer and
  any model family, the PR's own agent included (Leo, 2026-11-14: "this is no longer a requirement"), and
  findings fix forward in follow-ups. A BLOCK posted at the exact head still holds the PR until a new head.
  Disclose skipped verification on the PR. `main` is nightly: fix forward, do not revert.
- A PR merges when its checks pass and it causes no red of its own; base reds and flakes don't hold it
  (Leo, 2026-11-12). Ship risky user-visible behavior behind a setting or Debug toggle and fix a bad default
  in the next nightly. Only the `risk:high` tier, the take-back hold (above), a `HOLD:` line or hold label,
  a BLOCK at the head and merge freezes hold it. Follow
  [dogfood, re-dogfood and merge receipts](../../skills/cmux-review/SKILL.md#dogfood-and-merge).
  Notify with `cmux notify` when a socket is available.
- To skip `update_branch` re-tests, add the `merge-train` label to a ready `feat-cmux-next` PR. next-autoland
  stacks up to 12 labelled PRs onto the base and pushes the combined tip to `lane/merge-train`. That branch's
  standing PR ("merge-train: combined tip (never merged)") runs CI once for all of them. On green, each member
  lands pinned to its head. On red, the train bisects, the culprit gets a `merge-train` failure status and the
  rest land. A PR that changes `.github/workflows/` can't board.
  Source: `tools/fleet-reconcilers/merge_train.py` in cmuxterm-hq. `MERGE_TRAIN=0` turns it off.
- A red base (it doesn't compile, or CI is red on every PR) is priority zero: fix it directly in
  its own PR, which lands at once; don't note it and leave it for an owner. Two fixes that are
  each red on the other's red get combined into one PR. A base lint red also skips the tests
  after it in the same job (#22197), which is why it goes first.
- Classify each non-green check on the current head before changing source: a changed-file
  defect (fix it), a base finding (the same check red at the base tip or on several unrelated PRs
  at once: link it in a PR comment; it does not block), a wrapper such as `Web status` (follow its root check), or a
  cancelled or infrastructure run (rerun the same SHA). A push supersedes earlier CI and review
  results. Gallery captures and full webview sweeps are advisory
  ([check progression](../contributor-verification.md#pr-check-progression)).
  `scripts/ci-why` does this classification for you ([below](#is-this-red-mine)).

## Is this red mine?

`scripts/ci-why [PR]` (no PR: the current branch's) reads your PR's head once with your own `gh` login
and prints what is red and what is still running. For each red it asks `scripts/ci/base_red_excuse.py`,
the same classifier the merge tooling uses, whether that check fails the same way on the base branch:

```
manaflow-ai/cmux#48655 at bd0c091020 into feat-cmux-next: 195 green, 6 red (2 base, 2 yours to act on), 12 waiting
  base red  tooling-tests: feat-cmux-next run 44879637435 at 5b8a9aec2c (the newest feat-cmux-next verdict ...) fails the same way ...
  yours     cmux-next CI guard group: guard steps red on this change and not on feat-cmux-next run 44878773973 ...
  not yet   fast gates: has no feat-cmux-next verdict at or after this PR's merge-base yet ...
  waiting   web / react-apps-check (x10)
```

| Verdict | Meaning | What to do |
|---|---|---|
| `base red` | The same job fails with the same failed steps and tests on the base | Nothing: it is not yours and does not hold your PR |
| `yours` | It fails only on your PR | Fix it; the link is the failing job |
| `rerun` | Cancelled, timed out, lost its runner or refused at setup | Rerun the same commit (`gh run rerun RUN --failed`) |
| `update` | The base has fixed it since you branched | Merge the base (`scripts/merge-main.sh`) |
| `not yet` | The base has no run to compare with yet, or a read was cut short | Ask again later |

It exits 1 when something is yours to act on, else 0. `--status` skips the base comparison (green, red
and waiting only, a few requests); `--json` prints one object. Reads are conditional (ETag) and kept under
`~/.cache/cmux-ci-why`, so asking again about an unchanged PR costs almost nothing against your rate limit.
It never polls, comments, labels, reruns or merges: run it when you want an answer. A full comparison takes
a few minutes on a PR with several reds, since each is compared against the base's recent runs.

Where things are:

- Checks: `cmux-next checks (...)` and `cmux-next CI guard group` are the repo's lint and policy guards;
  `tooling-tests` the script tests; `web / ...` the webview typecheck and test shards; `cmux-next/compile`
  the app compile. Which suites run is chosen from your diff ([PR CI coverage](../../skills/cmux-testing/references/pr-ci-coverage.md)).
- Runners: most Linux jobs on our own branches run on the one `cmux-linux` label since 2026-11-22
  (cmux#48644; fork PRs use `CI_FORK_LINUX_RUNNER` or `ubuntu-24.04`), and the rest pick from the fleet's
  Linux pool (`RUNNER_POOLS`). Mac jobs on our own Mac minis by
  capability label ([runner labels](../ci-runner-capability-labels.md), [runners](../ci-runners.md)).
  A job queued for long is a capacity problem, not your PR's.
- Rerun one job from its page or with `gh run rerun RUN --failed`. Don't push an empty commit to rerun CI.
- Merging: the rules below. Agents merge pinned to the head (`--match-head-commit`) through a check that
  refuses only the PR's own red (base reds and flakes never hold it); you can merge the same way.
- Ask in the team's engineering channel when a red is `yours` but your diff can't cause it: that is often
  a new base red the classifier has not seen yet.
- **Waiting on CI is never the goal.** "NEVER AGAIN" guards what gets published (shipped builds, the
  nightly, releases, public text): a change that reaches those runs the CI that tests it. Stopping on a
  stuck, irrelevant or trivial check is the failure (Leo, 2026-11-19). The agents' merge gate already
  skips a pinned docs-only PR in any repo (`docs_only`); for any other stuck or irrelevant check, merge
  past it with `LAND_JUDGE_OVERRIDE="<reason>" gh pr merge N --squash --match-head-commit <full head sha>`.
  The override is logged and stays pinned; never `--admin`. `MERGE_HOLD_OVERRIDE` is the same switch
  under its old name.
- **Into `feat-cmux-next`, merge it yourself** with a squash pinned to the head
  (`gh pr merge N --squash --match-head-commit <full head sha>`). The `ready-to-land` label is only a
  fallback hand-off for a PR its owner can't land: a label older than the head's last push doesn't count.
  `ci.yml`'s `ci-status` does not run here; a red `risk evidence` or `merge freeze` keeps the PR out. A
  freeze can open after that check ran, so right before you merge, run
  `scripts/ci/merge_freeze.py check --repo manaflow-ai/cmux --pr N --base feat-cmux-next` and merge only
  on exit 0 (1 is frozen, 2 is unknown, which counts as frozen). Don't wait for, rerun or fix base reds in
  your PR; a red it causes keeps it out until you fix it. Don't merge with `gh-merge-green` here
  (`--revert` still works), and never with `--admin`.
- **Into `main`, a PR needs a review SHIP at its exact head** (any reviewer, any model family; no one's
  by-name approval, Leo, 2026-11-15: "why are you guys still asking me to approve things") and merges
  through `gh-merge-green` and main's rulesets, which wait for the checks main requires (main is the
  nightly, which "NEVER AGAIN" guards; never get around them with `--override` or the API merge path).
  `gh-merge-green` refuses a PR that touches a path an open
  `merge-freeze` issue freezes, or when the freeze state can't be read; only the freeze owner's
  `freeze-ok` label lets that PR through ([merge freezes](merge-freeze.md)).
