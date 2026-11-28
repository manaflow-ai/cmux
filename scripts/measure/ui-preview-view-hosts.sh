#!/usr/bin/env bash
# Path B for the NEXT view modules, timed: each of CmuxNextAgentPane, CmuxNextMacScreen, CmuxNextBrowser and
# CmuxNextLayout has its own scene host in Prototypes/UiLayerHost (cmux-ui-agentpane, cmux-ui-screen, cmux-ui-browser,
# cmux-ui-layout), so a push that touches one of them gets a before/after look without the app build. This builds
# every host once (cold) and shoots its scene, then for each module appends one declaration to a source file of the
# module, rebuilds that host (warm .build) and shoots again. The warm push-to-shot time per module is the rebuild
# plus the shoot: the number the UI preview worker (scripts/cmux-next/ui-preview-worker.py) waits for that push.
#
#   scripts/measure/ui-preview-view-hosts.sh [OUT]
#   cmux-ci run --class light --script scripts/measure/ui-preview-view-hosts.sh --ref SHA --display \
#     --artifact Prototypes/UiLayerHost/.build/ui-preview-view-hosts.tar
#
# OUT defaults to Prototypes/UiLayerHost/.build/ui-preview-view-hosts. Writes OUT/timings.json, prints
# UI-PREVIEW-VIEW-HOST {json} per module. The edits are made in the step's own checkout and put back on exit.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
package="$repo/Prototypes/UiLayerHost"
out="${1:-$package/.build/ui-preview-view-hosts}"
src="$repo/Packages/macOS/CmuxNext/Sources"
# module product scene edited-file
rows=(
  "CmuxNextAgentPane cmux-ui-agentpane agentpane-native CmuxNextAgentPane/AgentPaneActAsMeCard.swift"
  "CmuxNextMacScreen cmux-ui-screen mac-screen-home CmuxNextMacScreen/MacScreenUiScene.swift"
  "CmuxNextBrowser cmux-ui-browser browser-chrome CmuxNextBrowser/UI/BrowserUiScene.swift"
  "CmuxNextLayout cmux-ui-layout layout-columns CmuxNextLayout/Views/LayoutUiScene.swift"
)

if [ -n "${CMUX_CI_STEP_KEY:-}" ] && [ -z "${DEVELOPER_DIR:-}" ]; then
  xcode_env="$(mktemp)"
  GITHUB_ENV="$xcode_env" CMUX_CI_SKIP_XCODE_SELECT=1 "$repo/scripts/select-ci-xcode.sh" >&2
  DEVELOPER_DIR="$(sed -n 's/^DEVELOPER_DIR=//p' "$xcode_env" | tail -n 1)"
  rm -f "$xcode_env"
  [ -n "$DEVELOPER_DIR" ] || { echo "error: select-ci-xcode.sh selected no Xcode" >&2; exit 1; }
  export DEVELOPER_DIR
fi

backup="$(mktemp -d)"
restore() {
  for row in "${rows[@]}"; do
    set -- $row
    [ -f "$backup/$1" ] && cp "$backup/$1" "$src/$4"
  done
  rm -rf "$backup"
}
trap restore EXIT
for row in "${rows[@]}"; do
  set -- $row
  [ -f "$src/$4" ] || { echo "error: $src/$4 is gone; pick another edit for $1" >&2; exit 1; }
  cp "$src/$4" "$backup/$1"
done

rm -rf "$out"
mkdir -p "$out"
now() { python3 -c 'import time; print(time.monotonic())'; }
since() { python3 -c "import sys; print(round(float(sys.argv[2]) - float(sys.argv[1]), 2))" "$1" "$(now)"; }
build() { swift build --package-path "$package" --product "$1" >"$out/build-$1-$2.log" 2>&1 || { tail -n 80 "$out/build-$1-$2.log" >&2; exit 1; }; }
pngs() { find "$1" -name '*.png' -size +1k | wc -l | tr -d ' '; }

echo "UI-PREVIEW-VIEW-HOSTS-MACHINE sha=$(git -C "$repo" rev-parse HEAD) model=$(sysctl -n hw.model) cores=$(sysctl -n hw.ncpu) macos=$(sw_vers -productVersion) load=\"$(uptime | sed 's/.*load averages*: //')\""
bindir=""
results="$out/rows.jsonl"
: >"$results"
for row in "${rows[@]}"; do
  set -- $row
  module=$1 product=$2 scene=$3
  t=$(now); build "$product" cold; cold=$(since "$t")
  [ -n "$bindir" ] || bindir="$(swift build --package-path "$package" --show-bin-path)"
  mkdir -p "$out/$scene/before" "$out/$scene/after"
  t=$(now); "$bindir/$product" --shoot "$out/$scene/before" --scene "$scene"; first_shoot=$(since "$t")
  printf '\nfunc uiPreviewViewHostProbe() -> Int { 1 }\n' >>"$src/$4"
  start=$(now)
  t=$(now); build "$product" warm; warm=$(since "$t")
  t=$(now); "$bindir/$product" --shoot "$out/$scene/after" --scene "$scene"; shoot=$(since "$t")
  push_to_shot=$(since "$start")
  cp "$backup/$module" "$src/$4"
  line="$(python3 - "$module" "$product" "$scene" "$4" "$cold" "$first_shoot" "$warm" "$shoot" "$push_to_shot" \
    "$(pngs "$out/$scene/before")" "$(pngs "$out/$scene/after")" <<'PY'
import json, sys
module, product, scene, edited, *v = sys.argv[1:]
keys = ["cold_build_s", "first_shoot_s", "warm_rebuild_s", "warm_shoot_s", "push_to_shot_s"]
row = {"module": module, "product": product, "scene": scene, "edited": edited, **dict(zip(keys, map(float, v[:5]))),
       "pngs_before": int(v[5]), "pngs_after": int(v[6])}
print(json.dumps(row, sort_keys=True))
PY
)"
  echo "UI-PREVIEW-VIEW-HOST $line"
  echo "$line" >>"$results"
done
python3 - "$results" "$out/timings.json" <<'PY'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1])]
json.dump({"rows": rows, "max_push_to_shot_s": max(r["push_to_shot_s"] for r in rows),
           "all_shot": all(r["pngs_before"] and r["pngs_after"] for r in rows)}, open(sys.argv[2], "w"), indent=2)
PY
cat "$out/timings.json"
tar -cf "$package/.build/ui-preview-view-hosts.tar" -C "$out" .
