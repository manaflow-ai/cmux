# 2026-11-26-prepare-nightly-variant-primary-4

Above `prepare-nightly-variant:` (job `prepare-nightly-variant-primary`) in `.github/workflows/nightly.yml`.

The fallback preparation, and the preparation result every later job reads
(needs.prepare-nightly-variant): success after a primary success (a no-op leg) or after
its own preparation. Until 2026-10-31 a separate prepare-nightly-variant job only echoed
that result, one more queued hop on the signing path (4.8 min queued for a 0 s job in
run 41187578702 attempt 2).
