# 2026-11-27-build-nightly-remote-daemon-1

Above `go-version-file: daemon/remote/go.mod` (job `build-nightly-remote-daemon`) in `.github/workflows/nightly.yml`.

The exact Go of the shipped cmuxd-remote (its go.mod `toolchain` line);
build_remote_daemon_release_assets.sh refuses any other.
