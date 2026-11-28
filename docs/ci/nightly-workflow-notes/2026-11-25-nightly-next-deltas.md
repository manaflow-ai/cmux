# 2026-11-25-nightly-next-deltas

Where: `.github/workflows/nightly.yml`, the nightly-next job's delta steps, before "Refuse stray processes before secrets (deltas)".

The deltas follow the feed in this job, off the critical path to it (the item above was written full-only), and never fail the build: every step here continues on error, and each one's `if` names what it needs. The two that hold the signing key carry no `!cancelled()`, so a failed claim skips them (tests/test_ci_signing_owned_mac.py). The delta build signs what the keyless prebuild made when it finished beside the checks, else builds them. The signing key reaches only the delta build, after a third stray-process check; nothing from the bundle runs in these steps (tests/test_nightly_next_one_job.py). Why: docs/ci/nightly-workflow-notes.md#note-31
