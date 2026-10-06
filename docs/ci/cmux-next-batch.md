# cmux-next batch queue

Open a PR into `feat-cmux-next` and let the queue land it. You don't stack, rebase or rerun anything by hand. `.github/workflows/cmux-next-batch.yml` runs `scripts/ci/next_batch.py`.

## What makes a PR eligible

- It isn't a draft, and its branch is in this repository.
- It's by a batch author (the `CMUX_NEXT_BATCH_AUTHORS` variable, default `teamleaderleo`), or anyone else labels it `batch-queue`.
- It has none of the labels `hold`, `exploration`, `needs a call`, `default call`, `do-not-merge` or `wip`.
- Its head commit is less than 5 days old.
- No check is red outside the heavy tier. Pending checks are fine. The heavy tier is swift test, the Release and scheme compiles, daemon tests, generated files and the cmux-tui wait. The batch runs it once on the stack, so the PR's own copy may be red or still running.

To keep a PR out, add `hold`. A PR the queue dropped at its current head stays out until you push.

## One batch

1. **Trigger.** A PR event or a feat-cmux-next push starts `debounce`. Each new event cancels the waiting run. The batch is dispatched after 2 minutes of quiet, and never later than 10 minutes after the first event. A running batch is never cancelled. A newer dispatch waits for it.
2. **Stack.** Starting from the feat-cmux-next head, the batch merges up to 12 eligible PRs in PR-number order.
   - A conflict in a generated file keeps the stack's copy, and the generator rebuilds it once at the end:
     - Web bundles: `scripts/cmux-next/regenerate-web-bundles.sh`.
     - SDK bindings: `cmux-tui/bindings/codegen/generate.py --write`.
     - Swift exports such as action contracts, the settings schema and MDM: `scripts/cmux-next/regenerate-swift-exports.sh`, on a mini.
   - `cmux-tui/spec/*.json` merges key by key.
   - String catalogs and the Xcode project merge as in `scripts/merge-main.sh`.
   - Any other conflict drops that PR from the batch and comments on it.
3. **Validate once.** The stack is pushed to `next-batch/<run>-<n>`. `cmux-next.yml` is dispatched there, and every tier runs. If the stack changes cmux-tui, `cmux-tui-artifacts.yml` is also dispatched on a `cmux-tui-pin-*` ref. At the same time, a mini submits a fleet `--production` build of the stack. A job that is red on feat-cmux-next itself doesn't count against the batch. Failed jobs get one rerun before any PR is blamed.
4. **Land or bisect.**
   - Green: each PR lands with `gh-merge-green --squash`, using main's copy, after a comment that links the batch. If the PR's own heavy check is red, `--override` names the batch run.
   - Red: the batch tests prefixes of the stack by halving. The last PR of the smallest red prefix is the culprit. It gets a comment with the failing jobs, and the batch reruns without it, for at most 3 culprits per batch.
5. **Report.** The job summary, and the sticky comment on `CMUX_NEXT_BATCH_STICKY` when set (an HQ issue), list each PR's outcome, every validation with its wall time, the heavy-tier run and the build link.

The job token merges and pushes, and GitHub starts no workflows for its events. After landing, the batch dispatches `cmux-next.yml` and `cmux-tui-artifacts.yml` on feat-cmux-next, plus the next batch.

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
| `CMUX_FLEET_CONTROLLER` (variable) | the build controller URL the mini's build job submits to |
| `CMUX_NEXT_BATCH_STICKY` (variable) | `owner/repo#issue` for the sticky report |
| `CMUX_NEXT_BATCH_AUTHORS` (variable) | authors whose PRs need no opt-in label |
