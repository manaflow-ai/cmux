# prepare-nightly-variant: pick-nightly-sign-runner:

Where: the `prepare-nightly-variant` job in `.github/workflows/nightly.yml`, above `pick-nightly-sign-runner:`.

The owned Macs the verify jobs (`owned`) and the signing and publication jobs (`sign_owned`,
`sign_owned_pool`) take, read right before they queue. Nightlies run only on our own minis
(Lawrence, 2026-10-30): every pick is a glaeda label, and an empty pick falls to the nightly pools.
