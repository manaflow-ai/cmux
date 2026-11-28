# nightly.yml: job `pick-nightly-sign-runner`

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

The owned Macs the verify jobs (`owned`) and the signing and publication jobs (`sign_owned`,
`sign_owned_pool`) take, read right before they queue. Nightlies run only on our own minis
(Lawrence, 2026-10-30): every pick is a glaeda label, and an empty pick falls to the nightly pools.
