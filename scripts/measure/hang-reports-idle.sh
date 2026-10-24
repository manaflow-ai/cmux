#!/usr/bin/env bash
# Idle cost of opt-in hang reports (plans/cmux-next/hang-reports-DESIGN.md section 6): builds a
# tagged cmux-next app at this checkout, then runs scripts/cmux-next/bench-idle.sh twice on it,
# with hang reports off (the default) and on (the DEV opt-in, cmux.json diagnostics.hangReports
# true, a consent record in the tag's defaults, an unreachable endpoint so nothing leaves the
# host). Each run measures CPU % and wakeups/s of the app at rest (terminals, minimized).
# Runs alone on a worker (it launches an app):
#   cmux-ci run --class exclusive --measurement --label measure --label macos-27 \
#     --script scripts/measure/hang-reports-idle.sh --ref SHA [--arg=measure=60] --artifact hang-reports-idle.json
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
tag="hridle"
measure=60
for arg in "$@"; do
  case "$arg" in
    measure=*) measure="${arg#measure=}" ;;
    *) echo "hang-reports-idle: unknown argument $arg" >&2; exit 2 ;;
  esac
done
for sub in ghostty ghostty-next; do
  [ -e "$sub/.git" ] || git submodule update --init --depth 1 "$sub"
done
if [ ! -f GhosttyKit.xcframework/Info.plist ]; then
  rm -rf GhosttyKit.xcframework
  if [ -z "${GHOSTTYKIT_ARCHIVE_CACHE_DIR:-}" ] && [ -n "${CI_SHARED_CACHE_DIR:-}" ]; then
    export GHOSTTYKIT_ARCHIVE_CACHE_DIR="$CI_SHARED_CACHE_DIR/ghosttykit-archives"
  fi
  ./scripts/download-prebuilt-ghosttykit.sh
fi
out="$(mktemp -d)"
account_home="$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
for tool_dir in "$account_home/.bun/bin" "$account_home/.local/node/bin"; do
  [ -n "$account_home" ] && [ -d "$tool_dir" ] && export PATH="$tool_dir:$PATH"
done
RUNNER_TEMP="$out" GITHUB_PATH="$out/bun-path" ./scripts/cmux-next/private-bun.sh
PATH="$(tail -n 1 "$out/bun-path"):$PATH"
export PATH
CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag "$tag" 2>&1 | tee "$out/reload.log" | tail -n 40
app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$out/reload.log" | tail -n 1)"
if [[ -z "$app" || ! -d "$app" ]]; then
  echo "hang-reports-idle: the tagged reload printed no app path" >&2
  grep -E "error:|BUILD FAILED" "$out/reload.log" | head -n 60 >&2 || true
  exit 1
fi
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")"
common=(--app "$app" --scenarios terminals,minimized --measure "$measure" --settle 20 --out "$out/bench" --no-fail --fresh)
status=0
defaults delete "$bundle_id" cmux.next.hangReports.consentedAt >/dev/null 2>&1 || true
scripts/cmux-next/bench-idle.sh "$tag" "${common[@]}" --label hang-reports-off || status=$?
# On: this Mac's consent (the card's yes), the setting, the DEV opt-in, an endpoint nobody answers.
defaults write "$bundle_id" cmux.next.hangReports.consentedAt -date "$(date -u '+%Y-%m-%d %H:%M:%S +0000')"
scripts/cmux-next/bench-idle.sh "$tag" "${common[@]}" --label hang-reports-on \
  --env CMUX_NEXT_DEV_HANG_REPORTS=1 --env CMUX_NEXT_HANG_REPORTS_URL=https://localhost:9/ \
  --setting diagnostics.hangReports=true || status=$?
defaults delete "$bundle_id" cmux.next.hangReports.consentedAt >/dev/null 2>&1 || true
python3 - "$out/bench" "$PWD/hang-reports-idle.json" <<'PY'
import glob, json, os, sys
runs = {}
for path in sorted(glob.glob(os.path.join(sys.argv[1], "*-idle-*.json"))):
    report = json.load(open(path))
    runs[report.get("label", os.path.basename(path))] = report
json.dump(runs, open(sys.argv[2], "w"), indent=2, sort_keys=True)
for label, report in runs.items():
    for name, scenario in report.get("scenarios", {}).items():
        app = next((row for row in scenario.get("processes", []) if row.get("kind") == "app"), {})
        print(f"HANG-REPORTS-IDLE {label} {name} app_cpu={app.get('cpu_percent')} app_wakeups={app.get('wakeups_per_s')}")
PY
exit "$status"
