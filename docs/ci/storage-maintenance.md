# Storage maintenance

`storage-maintenance.yml` replaces five storage entry points with one dispatcher.
The jobs retain their individual permissions, environments, runners, timeouts,
prune scripts and main-only guards. Release, nightly and promotion workflows do
not call this workflow and are unchanged.

| Task | Schedule (UTC) | Jobs | Manual input |
| --- | --- | ---: | --- |
| `actions-artifacts` | hourly at :37 | 1 | `delete` |
| `r2-cache` | daily at 05:23 | 1 | `delete` |
| `r2-binaries` | daily at 07:53 | 1 | `delete` |
| `r2-census` | Monday at 06:41 | 3 | read-only |
| `pr-media` | Monday at 06:41 | 1 | `apply` |

Dispatch on `main`, for example:

```sh
gh workflow run storage-maintenance.yml --ref main -f task=r2-census
gh workflow run storage-maintenance.yml --ref main -f task=r2-cache -f delete=false
```

The default task is the read-only census. A manual dispatch selects one task;
the weekly schedule selects both census and media jobs. Unrecognized tasks and
non-main refs run no jobs. The hourly schedule does not run the daily or weekly
jobs. No extra routing job consumes a runner.

Deletion policies are unchanged. Artifact, cache and binaries manual dispatches
use only `delete`; their repository variables control scheduled deletion. Media
uses `apply` **or** `CI_PR_MEDIA_PRUNE_APPLY`, including on manual dispatch. Thus
`apply=false` does not force a media dry run when that variable is enabled.

Each pruning job keeps its original concurrency group with cancellation disabled.
The census uses one group per credential/bucket job. A group shared by three
sibling jobs would evict pending siblings; the separate groups serialize repeated
reads of each bucket while allowing different buckets to run independently.

The main-first migration removes five workflows and adds one: **241→237** files
at base `c65db5eec438d6ad2c92a92f5bc44282d0727435`, an area reduction of **5→1**.
Measure the total with `git ls-tree --name-only HEAD .github/workflows/ | wc -l`.
The paired NEXT migration follows after main and preserves NEXT's existing job
payloads and runner expressions.

Scheduled jobs stay **26.5714/day→26.5714/day** (`24 + 1 + 1 + 4/7`). Scheduled
workflow invocations fall from `26 + 2/7` to `26 + 1/7`, because two Monday runs
share one dispatcher. **Runner-minute savings: 0/day** from this consolidation;
no jobs are removed and no measured CPU reduction is claimed. Actual total runner
minutes require duration telemetry and are not established by a filename count.

Validation covers the four cron routes, all five manual tasks, invalid tasks,
non-main refs, the existing prune safety contracts, and job payload comparison
against the base. It uses no live cleanup dispatch or release build.
