# nightly.yml: job `attest-nightly-remote-daemon`

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

The owned nightly-only Mac pool first (the all-nightly reservation, as route-visual-gate-nightly),
then the nightly-only pool variable or label, never Blacksmith (nightlies never use Blacksmith). Its OIDC token only
writes provenance for these assets; the pool already builds the nightly app those assets ship in.
