# nightly.yml: job `build-nightly-remote-daemon`

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

Pure Go (CGO_ENABLED=0), manifests and uploads do not need the app builder, so it
builds beside build-nightly-app (its `if`), on the Ghostty helper's owned Mac pick,
else the owned nightly-only Mac pool (the all-nightly reservation on NEXT's first attempt; run
41683652930 took blacksmith-32vcpu-ubuntu-2404), else the nightly-only pool: never Blacksmith. Resume already retained these exact assets in build-nightly-app.
