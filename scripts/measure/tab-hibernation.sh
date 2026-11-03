#!/usr/bin/env bash
# Fleet entry for the tab hibernation bench (smarter hibernation, msg 9103): builds a tagged
# cmux-next DEV app at this checkout, then runs scripts/cmux-next/bench_hibernation.py on 48
# Chromium tabs (40 MB stand-in heap each) plus one page that plays media and one an agent keeps
# calling: footprint awake, frozen and hibernated, wake p50/p95, then critical memory pressure on
# the woken tabs (`debug.hibernation.pressure`): time to hibernate them, pages per second, the
# footprint before and after, and whether the media or driven page ever hibernated (must be 0).
# Runs alone on the worker because it launches an app:
#   cmux-ci run --class exclusive --label measure --script scripts/measure/tab-hibernation.sh --ref <sha> [--arg=--tabs=48]
# To measure an older commit, cherry-pick the harness commits onto it (the script blobs must match the reviewed ones).
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
# A step's checkout has empty submodules: reload.sh needs Ghostty's headers (GhosttyKit itself comes
# from the pinned cache) and ghostty-next for the bundled cmux-tui.
git submodule update --init --depth 1 ghostty ghostty-next >/dev/null
tag="tabhib"
out="$(mktemp -d)"
# --config=<debug|release|bench> picks reload.sh's build configuration (bench: Release optimization with the
# debug.* control commands kept); every other argument goes to the bench.
reload_config=() bench_args=()
for arg in "$@"; do
  case "$arg" in
    --config=*) reload_config=(--config "${arg#--config=}") ;;
    *) bench_args+=("$arg") ;;
  esac
done
set -- ${bench_args[@]+"${bench_args[@]}"}
CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag "$tag" ${reload_config[@]+"${reload_config[@]}"} 2>&1 | tee "$out/reload.log"
app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$out/reload.log" | tail -n 1)"
if [[ -z "$app" || ! -d "$app" ]]; then
  echo "tab-hibernation: the tagged reload printed no app path" >&2
  grep -E "error:|BUILD FAILED" "$out/reload.log" | head -n 60 >&2 || true
  exit 1
fi
echo "tab-hibernation: ref $(git rev-parse HEAD)"
# A fleet step has no LaunchServices session: run the app binary itself (bench_memory.launch).
CMUX_BENCH_LAUNCH=direct python3 scripts/cmux-next/bench_hibernation.py --app "$app" --engines chromium --tabs 48 --heap-mb 40 \
  --pressure --pressure-reuse --out "$PWD/tab-hibernation.json" "$@"
# The run's verdict on the keep rules (Chrome's: only an audible page is kept): a page that plays sound that is
# heard, or an agent-driven page, that slept fails it; a page whose media its own page muted that never slept fails
# it too; an audible page that did not play makes the run unjudged.
python3 - "$PWD/tab-hibernation.json" <<'PY'
import json, sys
report = json.load(open(sys.argv[1]))
pressure = report.get("pressure") or {}
if pressure.get("skipped"):
    sys.exit("tab-hibernation: the pressure phase did not run: " + pressure["skipped"])
audible = pressure.get("playing_audible") or {}
if not audible or not all(value is True for value in audible.values()):
    sys.exit("tab-hibernation: the audible page did not play, so the keep rule was not tested: " + json.dumps(audible))
bad = (pressure.get("playing_hibernated") or []) + (pressure.get("driven_hibernated") or [])
kept = pressure.get("silent_kept") or []
print("PERF-HIBERNATE-VERDICT never_hibernate=" + ("FAIL " + ",".join(bad) if bad else "ok")
      + " silent_hibernates=" + ("FAIL " + ",".join(kept) if kept else "ok"))
sys.exit(1 if bad or kept else 0)
PY
