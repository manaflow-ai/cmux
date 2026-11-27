# Workflow consolidation

The CI workflow census is being reduced by area. Each area keeps one named
dispatcher or reusable workflow, with release, nightly, promote, development
build, and required-check paths left intact. The target is fewer than 120
workflow files; every deletion must have a static trigger/caller proof and a
dry-run guard that does not dispatch a live job.

The first consolidation is the development end-to-end area:

| Area | Before | After | Change | Scheduled runner minutes/day |
| --- | ---: | ---: | --- | ---: |
| Development E2E | 3 files | 1 file | `machine-vault-e2e.yml` dispatches `billing`, `machine-join`, and `machine-vault` suites | 0 |

The three source workflows were dispatch-only and had no scheduled runs in the
30-day audit. The deleted billing and machine-join workflows had no repository
callers; the retained machine-vault workflow is dispatched by
`real-login-canaries.yml` and keeps that caller working. The combined dispatcher preserves
each suite's jobs, secrets, environment, runner, timeout, evidence, and
existing concurrency behavior. `suite` gating makes the dry-run proof disjoint: one
dispatch can select exactly one suite, and a dispatch without an explicit
selection keeps the former machine-vault default.

The file count for this change is measured from the exact tree with:

```sh
git ls-files '.github/workflows/*.yml' | wc -l
```

This PR changes that tree from 315 to 313 files. Runner minutes/day saved is
zero because these workflows were manual-only; no scheduled runner spend was
removed. Manual dispatch cost remains available to developers through the
single dispatcher.

Next areas use the same audit: group workflows by trigger and job purpose,
prove callers and required checks, merge trivially similar jobs into a
reusable workflow or area dispatcher, and remove only dead or superseded
files. Release, nightly, promote, and development-build workflows are excluded
from deletion.
