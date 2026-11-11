# One queued run per cron workflow; nightly builds never deduped

**Detector:** `tests/test_ci_cron_concurrency.py` (ci-guards, `ci` group). The rule is in
`scripts/ci/cron_concurrency.py`. The cleanup pass is `find_superseded_queued()` in
`scripts/ci/queue_janitor.py`. The measurement is `scripts/ci/backlog_drain_replay.py`.

## The incident

GitHub Actions stopped starting jobs from 20:17Z to about 20:49Z on 2026-11-11, and fully recovered
by 21:38Z. At 22:51Z manaflow-ai/cmux still had 683 runs queued over about 40 workflows. Short
pull request checks such as risk tier and PR body checks went unreported for two hours. The queue
janitor had 18 runs queued and the owned-pool rescue had 21.

The feed shows what the backlog was made of. Runs that GitHub did start were back to normal within
about 21 minutes of the resume. The 684 runs created during the stall that were still queued at
22:52Z and 23:20Z had no jobs at all. GitHub never created jobs for them. No runner, label or
concurrency group ever starts or replaces such a run. Before this change only the janitor's orphan
pass ended them, and only after a day (`GHOST_QUEUED_RUN_AGE`).

## The class

A workflow that runs on a timer or after another workflow (`schedule`, `workflow_run`) can pile up
behind itself after an outage. The fix has three parts.

1. **One queued run per cron or maintenance workflow.** Every job that can run on `schedule` or
   `workflow_run` is covered by a concurrency group that has the same value on all of those runs.
   `cancel-in-progress` is false, so a running sweep is never cut short. GitHub keeps at most one
   pending run per group and replaces an older pending run with a newer one, so it does the dedupe.
   A `workflow_dispatch` with its own inputs may keep its own key. Only the scheduled and
   `workflow_run` values are checked.
2. **Some workflows handle one source run each.** In those, each `workflow_run` run rescues,
   retries or guards one specific source run, so a shared group would drop that run's work. They
   are listed in `PER_SOURCE_RUN`, each with its reason (the owned-pool and hosted-queue rescues,
   the artifacts retry, the merge-group watch, the PR media renderer, the manual-dispatch guard).
   Their scheduled runs still share a group.
3. **Runs GitHub never started.** On every sweep, the queue janitor cancels a run that has been
   `queued` for 30 minutes with no job started in two cases, up to 30 a sweep:
   - a `pull_request` or `pull_request_target` run whose pull request has moved to another head
     or closed. A run at an open pull request's head is never touched.
   - an older cron or maintenance run, when a newer run of the same workflow and branch exists.
     The newest one is always kept. Workflows whose group is keyed by the source run's workflow
     or pull request (`SOURCE_KEYED`) are left alone.

Trivial pull request checks are seconds-long Linux checks: every job has `timeout-minutes` of 10 or
less and no macOS runner. The detector derives this set and prints it. Each check in it must cancel
its superseded runs, using a group keyed by the pull request and `cancel-in-progress: true` on
pull request events. The exceptions are in `TRIVIAL_NO_SUPERSEDE`, each with its reason (CLA
comments, one-shot opened/closed hooks, label sync, deploys).

## Never cancel a nightly, dev or promote build

The rule above never applies to the workflows that `cron_concurrency.EXCLUDED_GLOBS` matches.
These are the delivery globs of `scripts/ci/delivery_workflows.py` (nightly, DEV and promote
builds) plus release, publish, stable-next, dev-build, TestFlight and App Store, notarization,
appcast, deploy and Homebrew workflows.

The detector fails in two cases:

- One of these workflows gains `cancel-in-progress` outside a pull request test run.
- One of these workflows gains a group that is shared on a `schedule` or `workflow_run` event.

The groups these workflows share today are listed in `EXCLUDED_SHARED`, each with its reason. The
janitor's new pass never collapses their runs either (`collapsible_run()`).
`tests/test_nightly_delivery_concurrency.py` still holds the stricter per-run rule for the delivery
set.

## Why superseding, not a separate runner label for the trivial checks

The trivial checks run on the trusted Linux pools. During the outage window, 437 of the 1,254 runs
on the 2-vCPU pool and 205 of the 711 runs on the 4-vCPU pool were
trivial checks. The waits came from somewhere else:

- 195 of the 642 trivial-check runs created during the stall never started.
- The ones that did start waited a median of 0.7 minutes, with a 95th percentile of 12.7 minutes.

The replay serves the same arrivals at each pool's measured start rate. Serving trivial checks
first moves their median wait from 0.3 to 0.1 minutes, and their 95th percentile hardly at all (30.4
to 29.9 minutes). A lane of their own cannot start a run that GitHub never created. Ending
superseded runs can.

The trusted checks pick their runner from `CI_TRUSTED_RUNNER`, which already allows `ubuntu-24.04`.
Moving them to a hosted runner is a variable change, not a workflow change.

## Measuring

```
curl -s 'http://<controller>/v1/github/actions?repo=manaflow-ai/cmux&recent=0&since=808300000' > feed.json
python3 scripts/ci/backlog_drain_replay.py feed.json
```

The replay reports four things:

- the measured depth curve (waiting runs, how many of them never started, and how many are left
  once the policy's removals are applied);
- the measured drain;
- the trivial checks' wait (p50 and p95);
- a capacity replay of the same arrivals with and without the policy.

The script's docstring states its assumptions.

## Still open

The pass leaves 112 trivial-check runs alone. GitHub never started them, and each sits at its pull
request's newest head. Such a run needs to be cancelled and then re-run at the same head, like the
janitor's open-head failover for lost jobs (category e). Until that exists, a new push or a manual
re-run clears it.
