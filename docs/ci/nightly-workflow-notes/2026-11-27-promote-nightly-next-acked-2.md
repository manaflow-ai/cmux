# 2026-11-27-promote-nightly-next-acked-2

Above `environment: nightly-next-promote` (job `promote-nightly-next-acked`) in `.github/workflows/nightly.yml`.

Holds only the release App credentials (CMUX_RELEASE_APP_*). The approval
was given to release-surface-ack on this run; guard.approvedBy() reads it.
