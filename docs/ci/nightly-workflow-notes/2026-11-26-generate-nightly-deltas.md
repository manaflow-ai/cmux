# nightly.yml: job `generate-nightly-deltas`

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

The kept clone remembers the last checkout's sparse mode. After the signer's pattern checkout
(core.sparseCheckout=true, no cone setting) git reads the cone request below as the one pattern
`scripts`, so the root .xcode-version stays out and Select Xcode fails here (runs 42819750253,
42829570644: no deltas). The warm checkout's manual sparse test runs this step.
