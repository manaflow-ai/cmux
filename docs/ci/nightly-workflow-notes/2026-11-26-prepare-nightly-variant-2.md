# 2026-11-26-prepare-nightly-variant-2

Above `pick-nightly-sign-runner:` (job `prepare-nightly-variant`) in `.github/workflows/nightly.yml`.

The owned Macs the verify jobs (`owned`) and the signing and publication jobs (`sign_owned`,
`sign_owned_pool`) take, read right before they queue. Nightlies run only on our own minis
(Lawrence, 2026-10-30): every pick is a glaeda label, and an empty pick falls to the nightly pools.
