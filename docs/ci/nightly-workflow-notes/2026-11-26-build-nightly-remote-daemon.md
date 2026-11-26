# nightly.yml `build-nightly-remote-daemon`: notes moved out of the workflow

Moved from `.github/workflows/nightly.yml` to keep it under GitHub's 500 KB workflow file limit
(tests/test_ci_workflow_file_size.py). Each section's number is the `#N` in the job's `# Why:` line.

## 1

Above: `needs: [decide, resolve-nightly-cmux-tui-client, pick-nightly-build-runner]`

Pure Go (CGO_ENABLED=0), manifests and uploads do not need the app builder, so it
builds beside build-nightly-app (its `if`), on the Ghostty helper's owned Mac pick,
else the owned nightly-only Mac pool (the all-nightly reservation on NEXT's first attempt; run
41683652930 took blacksmith-32vcpu-ubuntu-2404), else the nightly-only pool: never Blacksmith. Resume already retained these exact assets in build-nightly-app.

## 2

Above: `go-version-file: daemon/remote/go.mod`

The exact Go of the shipped cmuxd-remote (its go.mod `toolchain` line);
build_remote_daemon_release_assets.sh refuses any other.
