#!/usr/bin/env bash
# Run COMMAND... with github-egress-direct.sh's route: probe the mini's github.com
# proxy first (a dead one goes direct before the first fetch), and when COMMAND
# fails with a proxy- or tunnel-shaped error, run it once more, direct.
#
# Why: #58915 put the probe and the direct retry on xcodebuild and the SwiftPM
# module guard only. The cmux-next daemon-test and swift-test jobs run
# `swift build --build-tests` straight, so a dead loopback tunnel still failed
# them: run 45866233902 (daemon tests), "Failed to connect to 127.0.0.1 port
# 18434 after 0 ms" on swift-asn1, swift-crypto, swift-atomics, sentry-cocoa
# and Sparkle, 2026-11-26. Every SwiftPM step that fetches packages on a
# self-hosted Mac runs through here (tests/test_ci_swiftpm_egress_route.py).
set -uo pipefail
[ "$#" -gt 0 ] || { echo "usage: github-egress-run.sh COMMAND..." >&2; exit 2; }
# shellcheck source=scripts/ci/github-egress-direct.sh
source "$(dirname "${BASH_SOURCE[0]}")/github-egress-direct.sh"
github_egress_probe
log="$(mktemp "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/github-egress-run.XXXXXX")"
trap 'rm -f "$log"' EXIT
"$@" 2>&1 | tee "$log"
status="${PIPESTATUS[0]}"
if [ "$status" != 0 ] && github_egress_retry_direct "$log"; then
  "$@"
  status=$?
fi
exit "$status"
