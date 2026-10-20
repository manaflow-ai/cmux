# cmux-next batch queue

Open a PR into `feat-cmux-next` and let the queue land it. You don't stack, rebase or rerun anything by hand. `scripts/ci/next_batch.py` is the controller. It runs either as `.github/workflows/cmux-next-batch.yml` with a GitHub App, or as `next_batch.py serve` on a workstation under the operator's gh login (see [Serving locally](#serving-locally)).

## What makes a PR eligible

- It isn't a draft, and its branch is in this repository.
- It's by a batch author (the `CMUX_NEXT_BATCH_AUTHORS` variable, default `teamleaderleo`), or anyone else labels it `batch-queue`.
- It has none of the labels `hold`, `exploration`, `needs a call`, `default call`, `do-not-merge` or `wip`.
- Its head commit is less than 5 days old.
- GitHub doesn't report it as conflicting with feat-cmux-next. One that does waits for its owner to merge feat-cmux-next, instead of taking a batch slot.
- It doesn't change `.github/workflows/`. Those PRs land by hand.
- coord-2 doesn't land it itself: every `manaflow-ai/cmux|<pr>|...` entry in the `CMUX_NEXT_BATCH_EXCLUDE` file (coord-2's merge-ready list) stays out. That file exists only on the coordinator's host, so an Actions batch never lands; it validates and posts receipts.
- No check is red outside the heavy tier, except web formatting (`web / react-apps-check`, `web / Web status`) on a PR that changes `webviews/`. Before landing such a PR, the queue runs `bun run check:fix` (formatter and lint autofix) on its head in `regen-linux` and pushes the fix to its branch. That push happens only for a batch author's PR; an opted-in PR by anyone else keeps its red check. The formatted head is new, so it lands in a later batch once its checks rerun and it's reviewed.
- Pending checks are fine. The heavy tier is swift test, the Release and scheme compiles, daemon tests, generated files and the cmux-tui wait. The batch runs it once on the stack, so the PR's own copy may be red or still running.

To keep a PR out, add `hold`. A PR the queue dropped at its current head stays out until you push.

### Overrides

Two labels change what the queue does, but only when a login in `CMUX_NEXT_BATCH_OVERRIDERS` (default `lawrencecchen`; never `teamleaderleo`, the login every lane uses) applied them after the PR's head commit. A label from before a push says nothing about the new code.

- `queue: land alone`: the next batch validates and lands this PR on its own, ahead of the others, once per head.
- `queue: known base red`: a red check outside the heavy tier doesn't keep the PR out of a batch. The batch then judges it like any other PR: a job red on feat-cmux-next itself never counts against the stack. It never waives a red `risk evidence` or `merge freeze`: neither runs on the stack.

## One batch

1. **Trigger.** A PR event or a feat-cmux-next push starts `debounce`. While `CMUX_NEXT_BATCH_ENABLED` is not 1 the job is skipped. Each event's run waits; one that sees a newer event's run exits 0, so no debounce check is cancelled or reads red on a PR. The batch is dispatched after 2 minutes of quiet, and never later than 10 minutes after the first event. A running batch is never cancelled. A newer dispatch waits for it.
2. **Stack.** Starting from the feat-cmux-next head, the batch merges up to 12 eligible PRs in PR-number order.
   - A conflict in a generated file keeps the stack's copy, and the generator rebuilds it once after the stack is pushed:
     - Web bundles: `scripts/cmux-next/regenerate-web-bundles.sh`, on Linux (`regen-linux`).
     - SDK bindings: `cmux-tui/bindings/codegen/generate.py --write`, on Linux (`regen-linux`).
     - Swift exports such as action contracts, the settings schema and MDM: `scripts/cmux-next/regenerate-swift-exports.sh`, on a mini (`regen`).

     Generators run the stack's code, so they never run on the controller's host. Each job has a read-only token and returns its commit as a patch, which the controller applies and pushes.
   - `cmux-tui/spec/*.json` merges key by key.
   - String catalogs and the Xcode project merge as in `scripts/merge-main.sh`.
   - Any other conflict drops that PR from the batch and comments on it.
3. **Validate once.** The stack is pushed to `next-batch/<run>-<n>`. `cmux-next.yml` is dispatched there, and every tier runs. If the stack changes cmux-tui, `cmux-tui-artifacts.yml` is also dispatched on a `cmux-tui-pin-*` ref. At the same time, a mini submits a fleet `--production` build of the stack, and the first stack's batch validates feat-cmux-next alone the same way, on `next-batch/<run>-base`. Base pushes skip `cmux-next checks`, and base dispatches (DEV daily, same-tree) route jobs away, so neither can say what a stack would find red on the base. A check that is red in that base run doesn't count against the batch. When the probe gives no result, the jobs that failed outright in the base's newest push run stand in. `cmux-next checks` counts check by check, from the list its last step prints. Every other red job counts by its failed steps and failing tests (its error lines when no test failed), the comparison `scripts/ci/base_red_excuse.py` makes. So one base red never hides another, and a swift test red on the base doesn't excuse a stack that breaks a different test. Failed jobs get one rerun before any PR is blamed.
4. **Land or bisect.**
   - Green: each PR whose exact head was independently reviewed lands after a comment that links the batch. Landing stops at the first PR that doesn't land (refused, formatted, pushed meanwhile), so what lands is always a validated prefix of the stack; the rest wait for the next batch. See [Review gate](#review-gate) for which PRs are stacked at all. The queue's own `--land` squash-merges each PR through GitHub's merge API, pinned to the head it validated; a PR a merge freeze covers stays out of the stack, and right before each merge the freezes are read again (`merge_freeze.py check`), since one may have opened after the PR's own check ran. A `risk evidence` check on the head must have finished green (an edited description regrades it). When a freeze lapses, a PR whose `merge freeze` check went red needs that check rerun (or a push) before it's eligible again. GitHub's default squash body is kept, with every commit's `Co-authored-by` trailer. A refused merge (the head moved, a conflict) holds that PR until its next push; a transient GitHub error is retried once and leaves the PR for the next batch.
   - Red: the batch tests prefixes of the stack by halving. The last PR of the smallest red prefix is the culprit. It gets a comment with the failing jobs, and the batch reruns without it, for at most 3 culprits per batch.
5. **Report.** The job summary, and the sticky comment on `CMUX_NEXT_BATCH_STICKY` when set (an HQ issue), list each PR's outcome, every validation with its wall time, the heavy-tier run and the build link.

In the workflow, pushes and merges use the `CMUX_NEXT_BATCH_APP_ID` App's token, which needs contents, workflows and pull-requests write. GitHub refuses the job token any branch based on feat-cmux-next. After landing, the batch dispatches `cmux-next.yml` and `cmux-tui-artifacts.yml` on feat-cmux-next, plus the next batch.

## Review gate

Every PR is independently reviewed before it merges, and the queue keeps that rule. It lands a PR only when one of these approves the exact head it validated:

- `CMUX_NEXT_BATCH_REVIEWED`: a file of `<pr> <sha>` lines, written by the reviewer (coord-2 today). `#` starts a comment. The file counts only when this user owns it and nobody else can write it. Every lane on that host is this user too, so the file shows the reviewer's intent rather than proving it; it rests on coord-2 being its only writer.
- A `review/independent` commit status with state `success`, created by a login in `CMUX_NEXT_BATCH_REVIEWERS`. Only a login no lane runs as can mean anything here, such as a review App or bot.

A push makes a new head that neither names, so approval never carries over. When the queue lands, it stacks only reviewed heads, so the stack it validates is exactly what lands; an unreviewed PR waits, with no comment, and joins the batch after its review. The merge is pinned to the validated head (`--match-head-commit`), and a head the queue formatted waits for its own validation and review. With neither source configured, or in a batch that may not land (Actions without coord-2's list, `--no-land`), the queue still validates, but each PR gets a `validated` note instead of a receipt, so it isn't held out of a later batch that can land it. Only a receipt-only `serve` posts receipts, which tell later batches the owner lands that head.

## Serving locally

Until the App exists, the queue runs on a workstation that is on the build tailnet, with a gh login that has `repo` and `workflow` scopes:

```bash
CMUX_NEXT_BATCH_STICKY=manaflow-ai/cmuxterm-hq#1392 \
  python3 scripts/ci/next_batch.py serve --worktree ~/.cache/next-batch-stack
```

It polls the open PRs every minute and uses the debounce job's timing: 2 minutes of quiet, at most 10 minutes. It runs one batch at a time and never interrupts one. Its fleet build uses the host's `cmux-ci`. Regeneration and the heavy tier still run on Actions, and only the controller runs locally. Its pushes and merges start CI like anyone's, so nothing is re-dispatched after landing. Comments link the sticky issue. Keep `CMUX_NEXT_BATCH_ENABLED` unset while a local controller serves, so the two never race.

By default `serve` merges nothing. It posts a receipt on each validated PR (the stack, the fleet job and the heavy jobs that passed), and the owner lands it: a plain `gh pr merge --squash --match-head-commit <sha>` lands it. `--land` makes the queue merge. A receipt says when the heavy tier did not run, which happens when the stack's `cmux-next.yml` predates the next-batch gate.

`run --local` runs one batch the same way, receipts included.

The same poll watches for closes. A batch author's PR that leaves the open set closed and unmerged by someone else goes to `tell-coordinator` (`CMUX_NEXT_BATCH_NOTIFY`), with its number, actor and time. Three or more within 10 minutes send one alert, and later closes in that burst arrive in one summary when it ends. It only reports; it never reopens. Each PR that leaves costs one lookup, and nothing else adds requests.

## Run it by hand

```bash
gh workflow run cmux-next-batch.yml --ref feat-cmux-next -f mode=batch -f dry_run=true   # validate only, no writes
gh workflow run cmux-next-batch.yml --ref feat-cmux-next -f mode=batch -f prs="17505 17508"
python3 scripts/ci/next_batch.py select            # who is eligible, and why the rest aren't
python3 scripts/ci/next_batch.py stack --prs "17505 17508" --no-regen --worktree /tmp/stack
```

## Repository settings

| Setting | Use |
| --- | --- |
| `CMUX_NEXT_BATCH_ENABLED` (variable) | `1` turns the debounce dispatch on |
| `CMUX_NEXT_BATCH_REVIEWED` (env, serve) | file of reviewed `<pr> <sha>` lines; the review gate |
| `CMUX_NEXT_BATCH_REVIEWERS` (variable or env) | logins whose `review/independent` status approves a head |
| `CMUX_NEXT_BATCH_OVERRIDERS` (variable or env) | logins whose override labels count (default `lawrencecchen`) |
| `CMUX_NEXT_BATCH_EXCLUDE` (env, serve) | file whose PR numbers coord-2 lands itself |
| `CMUX_NEXT_BATCH_APP_ID` (variable), `CMUX_NEXT_BATCH_APP_KEY` (secret) | the App that pushes stacks and merges |
| `CMUX_FLEET_CONTROLLER` (variable) | the build controller URL the mini's build job submits to |
| `CMUX_NEXT_BATCH_STICKY` (variable) | `owner/repo#issue` for the sticky report |
| `CMUX_NEXT_BATCH_AUTHORS` (variable) | authors whose PRs need no opt-in label |
