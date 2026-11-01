# IndexNow: cut over from the deployment-event workflow ID

## Why this runbook exists

The original `.github/workflows/indexnow.yml` is registered as GitHub
Actions workflow **315117949**. Its `main` revision became hourly in
cmux#28988, but GitHub's `deployment_status` event runs the workflow
file from the deployed ref. Historical PR and release refs still have
`on: deployment_status` and continue creating skipped workflow runs.

On 2026-11-01 10:03:20–10:06:30 UTC, five consecutive GitHub Actions
100-run pages showed **179** IndexNow deployment_status runs; **107**
came from `feat-cmux-next` and **72** from other refs. These are skipped
runs, not paid compute jobs. PR #30697 removes the trigger from
`feat-cmux-next`, but leaves historical branches unchanged.

The new `.github/workflows/indexnow-hourly.yml` has a separate GitHub
workflow identity. It preserves the hourly trigger, production sitemap
read, `indexnow-notify` concurrency group, and
`indexnow-state-` cache prefix. A repository admin can disable the old
workflow identity **after** confirming the replacement works.

## One-time transition (operator)

1. Merge the PR adding `indexnow-hourly.yml` and deleting
   `indexnow.yml` on `main`. Check the PR's IndexNow unit tests and
   workflow lint first. The NEXT branch backport (#30697) is
   independent, and may land before or after this PR.
2. Confirm the new workflow is present and enabled:

   ```sh
   gh workflow list --all -R manaflow-ai/cmux
   ```

3. Manually run the **new** workflow on `main` once:

   ```sh
   gh workflow run indexnow-hourly.yml -R manaflow-ai/cmux --ref main
   ```

   Inspect the exact resulting run, including the IndexNow response,
   persisted `.indexnow-state/submitted.json` (when changed), and
   absence of private credentials in the notification job. Verify the
   next scheduled occurrence at minute 17; scheduled events may be
   delayed, so use GitHub's actual run records.
4. Only after successful replacement, disable the old identity **globally**:

   ```sh
   gh workflow disable 315117949 -R manaflow-ai/cmux
   ```

   This is a repository-wide operational change: do it through the
   authorized GitHub Actions operator. Record the new workflow ID and
   the time of the disable in the rollout receipt.
5. Observe at least 10 minutes of `deployment_status` events:
   **zero newly created** runs under workflow 315117949, while the new
   scheduled workflow remains enabled. Existing runs may linger; compare
   creation timestamps, not merely `queued` status.

## Failure / rollback

If the replacement fails **before** step 4, leave the old workflow
enabled and repair the new one. The source from `main` can be restored
under `indexnow.yml`; its existing schedule is the fallback.

If a problem is discovered **after** step 4, first try to repair or
manually rerun `indexnow-hourly.yml`. A last-resort rollback can
reenable old workflow 315117949, but that also reopens the
`deployment_status` flood on historical branches; announce the tradeoff.
Preserve the original cache key prefix across a rollback so
`(URL,lastmod)` pairs are not repeatedly submitted.

This workflow uses public `https://cmux.com/sitemap.xml` and the
published IndexNow key. No deployment secret, forced merge, branch
rewrite or backfill of unrelated PR branches is required.
