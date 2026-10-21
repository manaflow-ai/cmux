#!/usr/bin/env bash
# perf100 on a fleet Mac (plans/cmux-next/perf100/README.md). Builds a tagged Debug app at this
# checkout (reload.sh, as perf-10x-idle.sh does) and runs the perf100 runner, alone on the worker:
#
#   cmux-ci run --class exclusive --measurement --label measure --script scripts/measure/perf100.sh \
#     --ref SHA --artifact artifacts/perf100/results.json [--arg=mode=headless|app|all] [--arg=gate=1] \
#     [--arg=seed=1] [--arg=quick=1] [--arg=host_class=NAME]
#
# mode=headless (default): the bundle's cmux-tui (S0, S1, S3, S4) and acpmux (S2 at 10 and 100 sessions);
#   any worker, including the AWS Macs (no console login needed).
# mode=app: the GUI scenarios S0-S4; needs a logged-in console (the bench worker: --label bench).
# gate=1: exit 1 when a budget in scripts/perf100/budgets.json for this host class is broken.
# Output: the Markdown report in the log; every run JSON in artifacts/perf100/results.json.
set -euo pipefail
mode=headless
gate=0
seed=1
quick=""
host_class=""
for arg in "$@"; do
  case "$arg" in
    mode=headless|mode=app|mode=all) mode="${arg#mode=}" ;;
    gate=0|gate=1) gate="${arg#gate=}" ;;
    seed=*) seed="${arg#seed=}"; [[ "$seed" =~ ^[0-9]+$ ]] || { echo "perf100.sh: seed=N" >&2; exit 2; } ;;
    quick=1) quick="--quick" ;;
    host_class=*) host_class="${arg#host_class=}"; [[ "$host_class" =~ ^[a-z0-9-]+$ ]] || { echo "perf100.sh: host_class=[a-z0-9-]+" >&2; exit 2; } ;;
    *) echo "perf100.sh: unknown argument $arg" >&2; exit 2 ;;
  esac
done
cd "$(git rev-parse --show-toplevel)"
work=".build/perf100"
rm -rf "$work" artifacts/perf100
mkdir -p "$work" artifacts/perf100
sha="$(git rev-parse HEAD)"
host="$(scutil --get ComputerName 2>/dev/null || hostname -s)"
# Host class for the budgets: aws-m4pro-* hosts share one class.
if [ -z "$host_class" ]; then
  case "$host" in
    aws-m4pro-*|*aws*) host_class="aws-m4pro" ;;
    *) host_class="$(echo "$host" | tr '[:upper:] ' '[:lower:]-')" ;;
  esac
fi
echo "PERF100-MACHINE host=$host class=$host_class sha=$sha model=$(sysctl -n hw.model) cores=$(sysctl -n hw.ncpu) ram_gb=$(( $(sysctl -n hw.memsize) / 1073741824 )) macos=$(sw_vers -productVersion) load=\"$(uptime | sed 's/.*load averages*: //')\""
# A fleet step checks out no submodules: the app build needs Ghostty's headers, the ghostty-next tree
# and GhosttyKit.xcframework (perf-idle-power.sh does the same).
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
tag="perf100m"
CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag "$tag" > "$work/reload.log" 2>&1 || { tail -n 80 "$work/reload.log"; exit 1; }
app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$work/reload.log" | tail -n 1)"
[[ -n "$app" && -d "$app" ]] || { echo "perf100.sh: reload printed no app path" >&2; tail -n 40 "$work/reload.log"; exit 1; }
bin="$app/Contents/Resources/bin"
out="$work/out"
mkdir -p "$out"
common=(--seed "$seed" --out "$out" --tag "$tag" --sha "$sha" --host-class "$host_class" $quick)
scratch="$(mktemp -d /private/tmp/p100.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT
status=0
if [ "$mode" = app ] || [ "$mode" = all ]; then
  python3 scripts/perf100/perf100.py app --app "$app" "${common[@]}" > "$work/app.log" 2>&1 || status=$?
  tail -n 20 "$work/app.log"
fi
if [ "$mode" = headless ] || [ "$mode" = all ]; then
  python3 scripts/perf100/perf100.py tui --tui "$bin/cmux-tui" --root-dir "$scratch" "${common[@]}" > "$work/tui.log" 2>&1 || status=$?
  tail -n 20 "$work/tui.log"
  python3 scripts/perf100/perf100.py acpmux --acpmux "$bin/acpmux" --root-dir "$scratch" "${common[@]}" > "$work/acpmux.log" 2>&1 || status=$?
  tail -n 20 "$work/acpmux.log"
fi
python3 - "$out" artifacts/perf100/results.json <<'PY'
import json, os, sys
runs = [json.load(open(os.path.join(sys.argv[1], n))) for n in sorted(os.listdir(sys.argv[1])) if n.startswith("S") and n.endswith(".json")]
json.dump({"schema": "perf100.bundle.v1", "runs": runs}, open(sys.argv[2], "w"))
PY
python3 scripts/perf100/perf100.py report "$out"
if [ "$gate" = 1 ]; then
  python3 scripts/perf100/perf100.py budget --results "$out" --host-class "$host_class" || status=1
fi
exit "$status"
