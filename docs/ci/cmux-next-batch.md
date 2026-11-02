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
3. **Validate once.** The stack is pushed to `next-batch/<run>-<n>`. `cmux-next.yml` is dispatched there, and every tier runs. The batch creates no helper publisher refs. Missing trees publish through the trusted feat-cmux-next push after reviewed changes land; a fleet app build can bundle its own daemon without publishing the tree. At the same time, a mini submits a fleet `--production` build of the stack, and the first stack's batch validates feat-cmux-next alone the same way, on `next-batch/<run>-base`. Base pushes skip `cmux-next checks`, and base dispatches (DEV daily, same-tree) route jobs away, so neither can say what a stack would find red on the base. A check that is red in that base run doesn't count against the batch. When the probe gives no result, the jobs that failed outright in the base's newest push run stand in. `cmux-next checks` counts check by check, from the list its last step prints. Every other red job counts by its failed steps and failing tests (its error lines when no test failed), the comparison `scripts/ci/base_red_excuse.py` makes. So one base red never hides another, and a swift test red on the base doesn't excuse a stack that breaks a different test. Failed jobs get one rerun before any PR is blamed.
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

## Groups

A group is a set of PRs validated together on one combined run and landed in order: label each with the same `batch:<name>` (for example `batch:sidebar-polish`). The group's run tests the members on top of each other, with the union of their checks and UI tours, and lands them in order. A member's own checks count, more strictly than a single PR's: a member with any failed check (heavy tier and a trusted `queue: known base red` label included) holds the whole group until it is fixed, rather than stranding the members before it at landing. Each check (a workflow's job) counts by its newest run on the head, so a rerun that passed clears an earlier failure; a cancelled newest run gives way to the newest run of that check that finished. Risk evidence, which the merge itself requires, is checked for every member before any lands, like the freezes. The members are checked again just before landing, since a pending check may have failed during validation. A red the base shares holds groups until the base is fixed. It follows the same switches as the batch: nothing runs while `CMUX_NEXT_BATCH_ENABLED` is unset unless a local `serve` runs it, and `--dry-run` or a receipt-only `serve` merges nothing.

1. **Members.** The open PRs into feat-cmux-next that carry the label. Each one passes the batch's rules, the red-check rule included: not a draft, same repository, a batch author or opted in, no hold label, no workflow change, no conflict with the base, a fresh head. A PR with two `batch:` labels (an empty `batch:` counts) is held until one goes. Group members never join the ordinary batch. If any member fails a rule, or any member lacks an independent review of its current head ([Review gate](#review-gate)), the whole group waits and nothing is validated.
2. **Order.** Stack order first: a member whose head contains another member's head comes after it. Otherwise members go in the order the label was put on, then by PR number.
3. **Validate once.** The members stack on the base head as in a batch, on `next-batch/<run>-<n>`. That head runs the union of what each member's paths route to, as if each were its own PR:
   - `cmux-next.yml`, dispatched, which runs every tier, a superset of each member's `cmux_next_route.py` tiers;
   - the fleet `--production` build;
   - `cmux-next-web.yml` when any member touches a web subarea (`web_subareas.py`). A web job red on the base's own web run (at the stack's base, else the newest on an ancestor of it) doesn't count, and a web run that failed with no failed job (cancelled, startup failure) blames nobody;
   - `cmux-next-media.yml` with `base_sha` set to the stack's base when any member maps to a tour (`scripts/cmux-next/media/path_map.py`). The tour maps the combined diff, so each UI member's own tour runs. Its verdict is the capture receipt (`ok` or `no-ui-paths`), since the capture step is continue-on-error. A dispatch counts as same-repository (an owned Mac takes it, with the PR Xcode pin), uses the `ci-media-batch` tag, and posts nothing; the queue reads the `cmux-next-media` artifact. A tour job that failed before the recorder did (the base app's build, setup) blames nobody.

   Lanes route on each member's full diff from the stack's base, not the PR's first 100 files. The receipt and the sticky report list each member's tiers, web subareas and tours (`next_batch_groups.check_plan`).
4. **Land or bisect.**
   - Green: the queue checks every member against open merge freezes first (`scripts/ci/merge_freeze.py check`), then merges the members in order through GitHub's merge API, each pinned to its validated head, like every batch merge (step 4 of the batch). It lands nothing when the base has since changed a file the group changes (the next cycle revalidates), and stops at the first member that closed, moved or was refused, so a member never lands without what it was tested on. GitHub's "Base branch was modified" refusal right after the previous member lands is retried (3 times, pinned to the same head).
   - Red: the same halving bisect as a batch finds the first red prefix. Its last member is the culprit and gets a comment, and the rest validate again without it, for at most 3 culprits. A lane that never ran (no gui runner took the tour, a timeout) or a failed fleet build blames nobody; the group waits for the next cycle.
5. **Then the next group, or the batch.** When a group lands, the cycle stops: the next group and the ordinary batch validate next cycle on the new base. When no group lands and feat-cmux-next moved meanwhile, the ordinary batch drops the groups' base and its probe and stacks on the current head.
6. **No repeats.** A group validated at the same member heads within the hour is not validated again (a non-blaming failure, a freeze, receipt mode); a push to any member makes it new.

Faster UI checks plug in at `Controller.start_group_lanes` / `finish_group_lanes`: a lane is a workflow dispatched on the group branch plus a judge for its verdict. The next one to add is a headless web render of the webviews UI on Linux (the Markdown, agent pane and settings pages in a browser, no macOS runner), selected by the same `check_plan` when a member touches `webviews/`. Its result would join `lanes`, so it gates and bisects like the tour.

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
| label `batch:<name>` on PRs | members of a [group](#groups) |
