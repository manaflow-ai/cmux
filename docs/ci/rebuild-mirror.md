# Job-input reuse mirror

The cargo fast tier observes a candidate input digest and still executes every
entry it would normally run. `CI_REBUILD_MIRROR=0` stops observation and restores
the existing `CI_NEXT_JOB_REUSE` whole-tree path. Observation is on by default;
candidate keys never skip a job in this rollout.

The job's `rebuild_mirror` row in `.github/warm-sources.json` declares its inputs
and potentially independent roots. The existing input closure and Swift graph
reads override independence. Everything else remains an input, including a new
or unknown directory. Keys include git object identities and modes, toolchain,
flags, the workflow and the planner's policy. Unreadable declarations or missing
toolchain values fall back to executing the full job.

Before execution the mirror looks for a previous same-repository candidate
green. It records this prediction separately from the existing full-tree key.
After execution it validates the fast-tier receipt against the committed
registry, commit and run. Every expected entry must say `PASS`; partial,
quarantined or flaky execution cannot publish a green candidate. Failed jobs
still emit observations. Cancelled, skipped, missing and uncertain results do
not count as successful comparisons.

Receipts keep both the Actions job's `head_sha` and the built `sha`. For a PR,
the latter is the synthetic merge commit. Reconciliation matches the scheduled
job against `head_sha`; full execution is verified against the built `sha`.

Artifacts:

- `ci-rebuild-mirror-<job>-<run>-<attempt>`: full observation, retained three days.
- `job-pass-mirror-<job>-<digest>`: a successful, actually executed candidate.

Download observations through the existing fleet artifact collector, then run
`python3 scripts/ci/rebuild_mirror.py report RECEIPT.json ...`. Duplicate copies
of one attempt count once; conflicting copies are rejected. With no comparable
candidate skips the false-skip rate is unknown, not zero. Reported interval
minutes are estimates of potential savings, not observed runner savings.

Before enforcement, reconcile observations against the authoritative scheduled
jobs for a continuous day, including failed and missing uploads. Require
comparable candidate skips on distinct commits, zero false skips, and no missing
or uncertain outcomes for the policy being promoted. Measure actual runner
start-to-finish minutes per merged PR with the same collector before and after;
include every attempt and mirror overhead. A skipped or cancelled workflow is
never a completed mirror. Publish the sample size, false-skip rate, and measured
machine-minute savings before declaring the rollout complete.

This first change supplies candidate keys and full-run observations. It does
not supply a promotion receipt, enable enforcement, or assert production savings.
The collector, one-day validation and enforcement are subsequent rollout steps.
