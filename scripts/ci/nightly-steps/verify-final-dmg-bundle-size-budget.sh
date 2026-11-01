#!/usr/bin/env bash
# nightly.yml verify-final-dmg-nightly: "Bundle size budget". Moved out of the workflow to keep nightly.yml under
# GitHub's workflow file size limit; the step's env: still sets every input.
# Size of the app in the final DMG, by component, against
# scripts/cmux-next/bundle-size-budget.json (plans/cmux-next/bundle-size-DESIGN.md).
# Writes the job summary. It does not block the publish yet: a red step
# means a cap was crossed; cut the size or raise the cap with a reason.
# It does not block the publish; a slow runner must not hold the job
# (run 39481846284: 13 min, then the job hit its limit).
#
# The step's notes, moved from nightly.yml:
# Chromium on demand ships no engine in the app (bundle-size-DESIGN.md 6).
set -euo pipefail
# The Linux checks job skips this macOS-only test of the release strip.
/bin/bash tests/test_strip_release_bundle_atom_info.sh
release="final-dmg/${CHANNEL_DMG_PREFIX}-${NIGHTLY_VARIANT}.dmg"
mnt="$RUNNER_TEMP/bundle-size-mnt"
mkdir -p "$mnt"
hdiutil attach -nobrowse -readonly -mountpoint "$mnt" "$release" >/dev/null
trap 'hdiutil detach "$mnt" -force >/dev/null 2>&1 || true' EXIT
app="$(find "$mnt" -maxdepth 1 -name '*.app' -print -quit)"
{
  echo '### Bundle size'
  echo '```'
  python3 -I scripts/cmux-next/bundle-size.py report "$app" --dmg "$release"
  echo '```'
} >> "$GITHUB_STEP_SUMMARY"
python3 -I scripts/cmux-next/bundle-size.py check "$app" --dmg "$release" \
  --budget scripts/cmux-next/bundle-size-budget.json --variant "$BUDGET_VARIANT"
