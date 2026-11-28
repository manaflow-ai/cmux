# 2026-11-26-prepare-nightly-variant-2

Above `pick-nightly-sign-runner:` (job `prepare-nightly-variant`) in `.github/workflows/nightly.yml`.

The owned Macs the verify jobs (`owned`) and the signing and publication jobs (`sign_owned`,
`sign_owned_pool`) take, read right before they queue. Nightlies run only on our own minis
(Lawrence, 2026-10-30): every pick is a glaeda label, and an empty pick falls to the nightly pools.

## nightly.yml: job `prepare-nightly-variant`

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

Never skipped: a skipped fallback skips signing and publishing (runs 40154003204,
40155340212). After a primary success it finds that result and does nothing.
