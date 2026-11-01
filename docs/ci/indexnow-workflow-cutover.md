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
`indexnow-state-` cache prefix. The original `indexnow.yml` stays as an
**inert manual-only placeholder** until cutover: GitHub may reject
disable requests after a workflow path is deleted and its registration
becomes `state: deleted`. An authorized operator disables the original
workflow ID **after** verifying the replacement.

## One-time transition (operator)

1. Merge the PR adding `indexnow-hourly.yml` and replacing the
   original `indexnow.yml` with a manual-only, skipped-job placeholder
   on `main`. Check the PR's IndexNow unit tests and workflow lint
   first. The NEXT branch backport (#30697) is independent.
2. Confirm the new workflow is present and enabled, and the old ID is
   still registered as `active` (if it is already `deleted`, stop and
   escalate the registration issue rather than attempting a blind disable):

   ```sh
   gh workflow list --all -R manaflow-ai/cmux
   gh api repos/manaflow-ai/cmux/actions/workflows/315117949 --jq '{id,path,state}'
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

If the replacement fails **before** step 4, repair the new hourly
workflow or revert the PR to restore `indexnow.yml`'s hourly schedule.
The original ID is still enabled, so its old ref event noise remains
until a safe replacement is live.

If a problem is discovered **after** step 4, repair or manually rerun
`indexnow-hourly.yml`. An emergency rollback requires reenabling ID
315117949 **and restoring its old hourly implementation on `main`**;
that reopens the `deployment_status` flood on historical branches.
If old ID remains registered as `deleted` or old-ref event noise
continues despite `disabled_manually`, collect run IDs and its API
state and escalate to GitHub Support.
Preserve the original cache key prefix across a rollback so
`(URL,lastmod)` pairs are not repeatedly submitted.

This workflow uses public `https://cmux.com/sitemap.xml` and the
published IndexNow key. No deployment secret, forced merge, branch
rewrite or backfill of unrelated PR branches is required.
