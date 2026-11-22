#!/usr/bin/env bash
# nightly.yml pick-nightly-sign-runner: "Leave notarization to a newer published build".
# Moved out of the workflow to keep nightly.yml under its size budget
# (tests/test_workflow_file_size.py); the step's env: still sets every input.
#
# When the cmux NEXT feed already lists a build above this run's, publish-nightly
# can only call this build superseded (nightly_version.py check: publication is
# latest-wins), so its notarizations would be spent for nothing. Apple caps
# notarizations per day, and running into the cap (429 RATE_LIMIT, 2026-11-03)
# failed every nightly for hours. overtaken=true skips signer-app and
# build-sign-notarize-nightly, as resolve's superseded does. Only a published
# newer build counts, never a newer push alone: a newer run that then fails must
# not leave the feed with nothing (#28961). A feed that cannot be read signs as
# before.
set -euo pipefail
[[ "$RUN_ID" =~ ^[0-9]+$ && "$RUN_ATTEMPT" =~ ^[0-9]+$ ]] || { echo "invalid run id or attempt" >&2; exit 1; }
# CFBundleVersion: the run id, then the attempt in two digits (nightly_version.py).
build="${RUN_ID}$(printf '%02d' "$RUN_ATTEMPT")"
overtaken=false highest=""
if feed="$(curl -fsSL --retry 1 --max-time 15 -A "cmux-nightly-sign-pick/1" "${NIGHTLY_NEXT_FEED_BASE}/appcast-arm64.xml")"; then
  highest="$(sed -n 's#.*<sparkle:version>\([0-9][0-9]*\)</sparkle:version>.*#\1#p' <<<"$feed" | sort -n | tail -1)"
else
  echo "::warning::could not read the cmux NEXT feed; signing as usual"
fi
if [[ "$highest" =~ ^[0-9]{1,18}$ ]] && (( highest > build )); then
  overtaken=true
  echo "::notice title=Overtaken::the cmux NEXT feed already has build $highest, above this run's $build; this build would not publish, so it spends no notarization"
else
  echo "the cmux NEXT feed's highest build is ${highest:-unknown}; this run's is $build"
fi
echo "overtaken=$overtaken" >> "$GITHUB_OUTPUT"
