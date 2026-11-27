# 2026-11-27-build-nightly-app-12

Above `NIGHTLY_PUBLISH_PEERS: resolve-nightly-ghostty-cli-helper build-nightly-ghostty-cli-helper build-nightly-remote-daemon` (job `build-nightly-app`) in `.github/workflows/nightly.yml`.

Jobs publish-nightly needs that run beside this one; derived from the
needs graph by tests/test_nightly_stop_if_publish_doomed.py.
