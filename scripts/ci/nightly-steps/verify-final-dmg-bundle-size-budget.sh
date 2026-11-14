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
budget=scripts/cmux-next/bundle-size-budget.json
# The tool from this workflow's commit: an older build commit's copy has no `summary`.
tool="$(dirname "$0")/../../cmux-next/bundle-size.py"
# The DMG the feed serves now is the previous nightly (this one is not published yet): its size
# is the change's baseline. Public download, headers only; none (a fork, no network) skips it.
previous="$(curl -sfIL --max-time 20 "https://github.com/${GITHUB_REPOSITORY}/releases/download/${TRACK}/${CHANNEL_DMG_PREFIX}-${NIGHTLY_VARIANT}.dmg" 2>/dev/null \
  | tr -d '\r' | awk 'tolower($1) == "content-length:" { n = $2 } END { print n }' || true)"
# No array: macOS /bin/bash 3.2 under `set -u` fails on an empty one.
case "$previous" in ''|*[!0-9]*) previous_arg="" ;; *) previous_arg="--previous-dmg-bytes=$previous" ;; esac
# Size and change on every run, at the top of the run's summary: an over-budget DMG went
# unseen for weeks while this step only failed quietly (ask-76dfaf2363, 285 MB against 216 MB).
python3 -I "$tool" summary "$app" --dmg "$release" --budget "$budget" --variant "$BUDGET_VARIANT" \
  ${previous_arg:+"$previous_arg"} --json "$RUNNER_TEMP/bundle-size-summary.json" > "$RUNNER_TEMP/bundle-size-summary.md"
headline="$(head -1 "$RUNNER_TEMP/bundle-size-summary.md" | tr -d '*')"
if python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1]))["over_budget"] else 1)' "$RUNNER_TEMP/bundle-size-summary.json"; then
  echo "::warning title=Bundle size over budget::$headline"
else
  echo "::notice title=Bundle size::$headline"
fi
{
  echo '### Bundle size'
  cat "$RUNNER_TEMP/bundle-size-summary.md"
  echo
  echo '```'
  python3 -I "$tool" report "$app" --dmg "$release"
  echo '```'
} >> "$GITHUB_STEP_SUMMARY"
python3 -I "$tool" check "$app" --dmg "$release" --budget "$budget" --variant "$BUDGET_VARIANT"
