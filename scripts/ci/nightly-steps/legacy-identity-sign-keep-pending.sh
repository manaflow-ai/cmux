#!/usr/bin/env bash
# nightly.yml sign-nightly-identity-legacy: "Keep the pending cmux NIGHTLY-identity submission". Moved out of the workflow to keep
# nightly.yml under GitHub's workflow file size limit; the step's env: still sets every input.
#
# The step's notes, moved from nightly.yml:
# A new submission still in Apple's queue: keep the exact signed DMG,
# app and submission for a later run (legacy-identity-target continues
# it while it is under 6 hours old). Not a failure.
set -euo pipefail
mkdir -p pending
tar -C legacy-app -czf pending/app.tar.gz "cmux NIGHTLY.app"
cp legacy-out/release.dmg pending/release.dmg
if [ -f legacy-out/release.first.dmg ]; then cp legacy-out/release.first.dmg pending/release.first.dmg; fi
cp "$RUNNER_TEMP/legacy.notarization.state" pending/legacy.notarization.state
submission="$(sed -n 's/^submission_id=//p' pending/legacy.notarization.state)"
[[ "$submission" =~ ^[A-Za-z0-9-]+$ ]] || { echo "pending state names no submission" >&2; exit 1; }
if grep -Fxq stapled_app=true pending/legacy.notarization.state; then
  # The first DMG is accepted (the stapled-app DMG is pending): keep
  # continuing it past 6 h, so its 6 h fallback can run.
  printf '{"build": "%s", "submission_id": "%s", "submitted_epoch": %s, "accepted": true}\n' "$NIGHTLY_BUILD" "$submission" "$(date +%s)" > pending/pending.json
else
  printf '{"build": "%s", "submission_id": "%s", "submitted_epoch": %s}\n' "$NIGHTLY_BUILD" "$submission" "$(date +%s)" > pending/pending.json
fi
cp pending/pending.json pending-meta.json
mkdir -p pending-meta && mv pending-meta.json pending-meta/pending.json
