#!/usr/bin/env bash
# nightly.yml publish-nightly: "Require every DMG to match a tested digest". Moved out of the workflow to keep
# nightly.yml under GitHub's workflow file size limit; the step's env: still sets every input.
set -euo pipefail
cat tested/*.sha256 > "$RUNNER_TEMP/tested.sha256"
count=0
for dmg in nightly-out/*.dmg; do
  [ -f "$dmg" ] || continue
  count=$((count + 1))
  actual="$(shasum -a 256 "$dmg" | awk '{print $1}')"
  if ! grep -Fxq "$actual  $(basename "$dmg")" "$RUNNER_TEMP/tested.sha256"; then
    echo "$(basename "$dmg") ($actual) is not a DMG that a verify job tested" >&2
    exit 1
  fi
done
[ "$count" -gt 0 ] || { echo "no DMG to publish" >&2; exit 1; }
echo "All $count DMGs match the digests the verify job tested."
