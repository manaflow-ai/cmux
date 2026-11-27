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
# The Macs get 403 on anonymous release downloads: with the job's token (GH_DOWNLOAD_TOKEN from the step)
# the size and the DMG come through the API (scripts/ci/github-release-download.sh), else as before.
previous_url="https://github.com/${GITHUB_REPOSITORY}/releases/download/${TRACK}/${CHANNEL_DMG_PREFIX}-${NIGHTLY_VARIANT}.dmg"
release_tools="$(dirname "$0")/.."
previous="$(python3 -I "$release_tools/github_release_asset.py" --size "$previous_url" 2>/dev/null || true)"
[ -n "$previous" ] || previous="$(curl -sfIL --max-time 20 "$previous_url" 2>/dev/null \
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
# What the installed app is made of (CMUX-570). The annotation is one line of JSON that cmuxterm-hq's NOW
# reads from the check run, so the breakdown needs no artifact; a failure here never hides the summary.
python3 -I "$tool" breakdown "$app" --dmg "$release" --json "$RUNNER_TEMP/bundle-size-breakdown.json" \
  > "$RUNNER_TEMP/bundle-size-breakdown.md" || true
if [ -s "$RUNNER_TEMP/bundle-size-breakdown.json" ]; then
  python3 -I -c '
import json, sys
b = json.load(open(sys.argv[1]))
keep = {k: b.get(k) for k in ("schema", "version", "app_bytes", "dmg_bytes", "symbols_bytes", "debug_files_bytes",
                              "unwind_bytes", "duplicate_extra_bytes")}
keep["categories"] = {c["key"]: c["bytes"] for c in b["categories"]}
print("::notice title=Bundle size breakdown::" + json.dumps(keep, separators=(",", ":")).replace("%", "%25"))
' "$RUNNER_TEMP/bundle-size-breakdown.json" || true
fi
# The 20 biggest growers and shrinkers against the previous nightly, per file and per component, so growth
# cannot creep back while the app is cut. The previous nightly is the DMG the feed serves now (the same
# public download as `previous` above: no API call, nothing stored); its app is read for file sizes only.
# A report, never a gate: every failure, a slow download included, leaves this empty and the step as it was.
growers_md="$RUNNER_TEMP/bundle-size-growers.md"
rm -f "$growers_md"
if [ -n "$previous_arg" ] && [ "$SECONDS" -lt 120 ]; then
  (
    set +e
    prev_dmg="$RUNNER_TEMP/bundle-size-previous.dmg"
    prev_mnt="$RUNNER_TEMP/bundle-size-previous-mnt"
    old="$RUNNER_TEMP/bundle-size-previous-files.json.gz"
    new="$RUNNER_TEMP/bundle-size-files.json.gz"
    mkdir -p "$prev_mnt"
    trap 'hdiutil detach "$prev_mnt" -force >/dev/null 2>&1; rm -f "$prev_dmg"' EXIT
    if [ -f "$release_tools/github-release-download.sh" ]; then
      bash "$release_tools/github-release-download.sh" "$previous_url" "$prev_dmg" --max-time 100 2>/dev/null || exit 0
    else
      curl -sfL --max-time 100 -o "$prev_dmg" "$previous_url" || exit 0
    fi
    hdiutil attach -nobrowse -readonly -mountpoint "$prev_mnt" "$prev_dmg" >/dev/null 2>&1 || exit 0
    prev_app="$(find "$prev_mnt" -maxdepth 1 -name '*.app' -print -quit)"
    [ -n "$prev_app" ] || exit 0
    python3 -I "$tool" files "$prev_app" --json "$old" >/dev/null || exit 0
    python3 -I "$tool" files "$app" --json "$new" >/dev/null || exit 0
    python3 -I "$tool" diff "$old" "$new" --top 20 > "$growers_md.tmp" || exit 0
    note="$(python3 -I "$tool" diff "$old" "$new" --top 20 --annotation)" || exit 0
    mv "$growers_md.tmp" "$growers_md"
    echo "::notice title=Bundle size growers::$note"
  ) || true
fi
{
  echo '### Bundle size'
  cat "$RUNNER_TEMP/bundle-size-summary.md"
  echo
  cat "$RUNNER_TEMP/bundle-size-breakdown.md" 2>/dev/null || true
  echo
  if [ -s "$growers_md" ]; then
    echo '#### Growers and shrinkers since the previous nightly'
    echo
    cat "$growers_md"
    echo
  fi
  echo '```'
  python3 -I "$tool" report "$app" --dmg "$release"
  echo '```'
} >> "$GITHUB_STEP_SUMMARY"
python3 -I "$tool" check "$app" --dmg "$release" --budget "$budget" --variant "$BUDGET_VARIANT"
