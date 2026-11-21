#!/usr/bin/env bash
# The UI shell's edit loop, timed (Leo, ask-8bdd370f5f: "literally the shell, like you literally just ship the shell"):
# build the shell (Prototypes/UiLayerHost, cmux-ui-layer) and shoot a scene, then change one UI source file in a leaf
# module, rebuild and shoot again. Prints and writes OUT/timings.json with each phase's seconds; the edit-to-PNG time
# is the rebuild plus the second shoot, the number an agent waits after changing a UI file. Never the app build.
#
#   scripts/measure/ui-shell-edit-shoot.sh [OUT] [SCENE]
#   cmux-ci run --class light --script scripts/measure/ui-shell-edit-shoot.sh --ref SHA --display \
#     --artifact Prototypes/UiLayerHost/.build/ui-shell-edit.tar
#
# OUT defaults to Prototypes/UiLayerHost/.build/ui-shell-edit; SCENE to tabs (the edit below is a tabs title).
# On a fleet step the Xcode is chosen the way run-swift-testing-suites.sh chooses it. The edit is made in the step's
# own checkout and put back on exit.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
package="$repo/Prototypes/UiLayerHost"
out="${1:-$package/.build/ui-shell-edit}"
scene="${2:-tabs}"
edited="$repo/Packages/macOS/CmuxNext/Sources/CmuxNextTabs/Playground/TabBarPlaygroundSection.swift"
before='defaultValue: "Crowded Tabs"'
after='defaultValue: "Crowded Tabs (edited in the shell)"'

if [ -n "${CMUX_CI_STEP_KEY:-}" ] && [ -z "${DEVELOPER_DIR:-}" ]; then
  xcode_env="$(mktemp)"
  GITHUB_ENV="$xcode_env" CMUX_CI_SKIP_XCODE_SELECT=1 "$repo/scripts/select-ci-xcode.sh" >&2
  DEVELOPER_DIR="$(sed -n 's/^DEVELOPER_DIR=//p' "$xcode_env" | tail -n 1)"
  rm -f "$xcode_env"
  [ -n "$DEVELOPER_DIR" ] || { echo "error: select-ci-xcode.sh selected no Xcode" >&2; exit 1; }
  export DEVELOPER_DIR
fi

grep -qF "$before" "$edited" || { echo "error: $edited no longer has $before; pick another edit" >&2; exit 1; }
original="$(mktemp)"
cp "$edited" "$original"
trap 'cp "$original" "$edited"; rm -f "$original"' EXIT

rm -rf "$out"
mkdir -p "$out/before" "$out/after"
now() { python3 -c 'import time; print(time.monotonic())'; }
since() { python3 -c "import sys; print(round(float(sys.argv[2]) - float(sys.argv[1]), 2))" "$1" "$(now)"; }

t=$(now); swift build --package-path "$package" --product cmux-ui-layer 2>&1 | tail -n 3; first_build=$(since "$t")
bin="$(swift build --package-path "$package" --show-bin-path)/cmux-ui-layer"
t=$(now); "$bin" --shoot "$out/before" --scene "$scene"; first_shoot=$(since "$t")

python3 - "$edited" "$before" "$after" <<'PY'
import sys
path, old, new = sys.argv[1:]
text = open(path, encoding="utf-8").read()
open(path, "w", encoding="utf-8").write(text.replace(old, new, 1))
PY
edit_start=$(now)
t=$(now); swift build --package-path "$package" --product cmux-ui-layer 2>&1 | tail -n 3; rebuild=$(since "$t")
t=$(now); "$bin" --shoot "$out/after" --scene "$scene"; second_shoot=$(since "$t")
edit_to_png=$(since "$edit_start")

python3 - "$out/timings.json" "$scene" "$first_build" "$first_shoot" "$rebuild" "$second_shoot" "$edit_to_png" <<'PY'
import json, sys
path, scene, *values = sys.argv[1:]
keys = ["first_build_s", "first_shoot_s", "rebuild_s", "second_shoot_s", "edit_to_png_s"]
report = {"scene": scene, "edited": "CmuxNextTabs/Playground/TabBarPlaygroundSection.swift", **dict(zip(keys, map(float, values)))}
json.dump(report, open(path, "w"), indent=2, sort_keys=True)
print("ui-shell-edit:", json.dumps(report, sort_keys=True))
PY
tar -cf "$package/.build/ui-shell-edit.tar" -C "$out" .
