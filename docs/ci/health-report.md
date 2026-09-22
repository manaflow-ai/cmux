# CI health report

`.github/workflows/ci-health-report.yml` runs `scripts/ci/ci_health_report.py`
every six hours and on demand. It answers, without anybody querying the Actions
API by hand: where did CI time go, what was waiting rather than working, and
what did we pay for twice.

It only measures. Cancelling wasted demand is the queue janitor's job
(`scripts/ci/queue_janitor.py`, #13721); this workflow's token has
`actions: read` and cannot cancel anything. The two share helpers — the report
imports the janitor's `parse_time`, `is_macos_job` and
`linux_only_workflow_paths` rather than restating them — so "is this a macOS
job" has one answer in the tree.

Related: #13095 (CI cost and capacity) and #13325 (CI waste).

## Output

- **Step summary, always.** Every run writes the whole report to
  `$GITHUB_STEP_SUMMARY`, whether or not an issue is configured.
- **A tracking issue comment, when configured.** Set the repository variable
  `CI_HEALTH_REPORT_ISSUE` to the number of an issue whose title starts with
  `[CI Health]`. The workflow refreshes one marker-delimited comment on that
  issue in place, preserving anything written above or below the markers — the
  same shape as the triage radar's generated section (#13511, #13512). Create
  that issue by hand: **the workflow never opens an issue**, and it refuses to
  write to an issue whose title does not carry the prefix.

## What each number means

### Runner minutes by workflow, job and runner label

Minutes are `completed_at - started_at` per job, summed, and split by
conclusion into success / failure / cancelled / skipped. `timed_out` and
`startup_failure` count as failure, because they cost what a failure costs.

These tables are **sampled**: job listings are the expensive API call, so the
report reads jobs for a bounded number of runs spread across workflows (macOS-
capable workflows first) rather than for all of them. Read them as *shape* —
which workflow, which job, which pool, which conclusion is eating the minutes —
not as a billing total. The header states how many runs were sampled.

Failure and cancelled minutes are the interesting columns. Success minutes are
the price of CI; the rest is the price of CI not working.

### Queue wait (created → started) per runner label

`started_at - created_at` per job, as p50 / p90 / p99 / worst, per runner label.
Labels are joined when a job asks for several, so `self-hosted+macos` is not
silently pooled with `macos`.

**This is the metric that matters for the capped pools.** A macOS pool that
tops out near a dozen concurrent jobs does not make builds slower; it makes
them wait. When p90 climbs while minutes-per-job stay flat, no build regressed
— there was no runner.

### Wasteful patterns

- **Cancelled after ≥5 min of macOS work.** A cancel one minute in costs
  nothing. A cancel forty minutes into a compile burned a slot on the capped
  pool that somebody was waiting for.
- **Same job failing across ≥3 unrelated heads.** Grouping by head SHA is what
  makes this a main signal rather than one author's problem. One PR failing the
  same job ten times is not here; the same job failing on heads that share
  nothing is.
- **Workflows ≥90% skipped** (with at least 20 runs in the window). A shim that
  decides it had nothing to do is cheap per run and expensive per day: it still
  queues, still writes a check, and still fills every list of runs anybody
  reads.
- **Reruns of an unchanged tree.** Both shapes count: a second run created for
  a head that already had one (a bot editing a PR body re-requests required
  checks), and a re-run attempt of the same run. Neither read a different tree.
- **Fork pull requests.** Fork PRs cannot read the repository's Actions cache,
  so their minutes are cache misses somebody pays for twice. The line reports
  sampled fork jobs and their minutes.

### Comparison against the previous window

Every headline number is shown beside the immediately preceding window of the
same length, with the change. A single window tells you a number; two tell you
whether it is a regression.

### Coverage and API budget

One `created:` query returns at most **1000 runs**, however many pages you ask
for. On a repo creating thousands of runs a day that silently turns a six-hour
window into "the newest hour or two", so the report asks for the window in
equal slices (`CI_HEALTH_WINDOW_SLICES`, default half-hour slices) and merges
them. Measured here, an hourly slice still hit the cap in 22 of 24 hours. A slice
that still hits the cap is reported as truncated: the header then says how many
hours of the window are actually covered, and the run counts read as rates over
that covered span rather than as totals for the window. Raise the slice count
when the banner says a slice was capped.

The header also states the API call count. Nothing is cached, and a rate limit
or API error degrades the report to partial data (announced in a banner)
instead of failing the run.

Caps are repository variables, all optional:

| Variable | Default | What it bounds |
| --- | ---: | --- |
| `CI_HEALTH_MAX_RUN_PAGES` | 10 | Pages of 100 runs per slice |
| `CI_HEALTH_WINDOW_SLICES` | two per hour | Slices the window is fetched in (1000-run API cap per slice, 48 max) |
| `CI_HEALTH_MAX_JOB_LISTINGS` | 120 | Runs whose jobs are fetched |
| `CI_HEALTH_JOBS_PER_WORKFLOW` | 3 | Job listings spent on any one workflow |
| `CI_HEALTH_REPORT_ISSUE` | unset | Tracking issue; unset means summary only |

## Thresholds that should trigger action

| Signal | Threshold | Reading | What to do |
| --- | --- | --- | --- |
| macOS queue wait p90 | **> 20 min** | Read it as capacity, not builds | Raise the pool cap, or cut demand: narrow what schedules macOS work, and check the queue janitor is sweeping |
| Cancelled share of runs | **≥ 35%** | People are cancelling work that had already started, or the janitor is sweeping a lot | Find what is being superseded — usually pushes racing a slow queue — and debounce it upstream of the runner |
| Failed share of runs | **≥ 20%** | Sustained red, not flakes | Check the repeated-failure table: if one job fails across unrelated heads, main is broken and every queued run is wasted |
| Same job failing across heads | **≥ 3 heads** | Main-broken signal | Fix or revert before the pool fills with runs that cannot pass |
| Workflow skipped share | **≥ 90%** over ≥20 runs | A shim paying a run to decide nothing | Move the condition into the trigger (path/branch filters) so the run is never created |
| macOS minutes in cancelled jobs | any large column | Work paid for and thrown away | Cancel earlier (janitor threshold) or start later (gate before the expensive step) |
| Reruns of an unchanged tree | any repeated head | Re-running a tree nobody changed | Check what re-requests checks — bot PR-body edits are a known source — and make the required check idempotent per SHA |
| Fork minutes | rising | Fork PRs take the expensive path with no cache | Give fork PRs a cheaper lane, or an explicitly warmed one |

A threshold crossing is a prompt to look, not an automatic verdict. The tables
under it say which workflow, which job and which pool, which is usually enough
to tell a capacity problem from a correctness one.

## Running it by hand

```sh
GH_TOKEN="$(gh auth token)" python3 scripts/ci/ci_health_report.py \
  --repo manaflow-ai/cmux --window-hours 24 --no-issue
```

`--no-issue` keeps a local run read-only. Tests:
`python3 tests/test_ci_health_report.py` (fixtures only, no network).
