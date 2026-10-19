#!/usr/bin/env bash
# Day-to-day feel baseline for cmux-next: one tagged DEBUG build, then the everyday flows in turn.
#   startup  bench-startup.py, realistic profile (full sidebar, terminal and agent pane restored),
#            cold and warm launch to the first terminal frame and the agent pane handshake, with
#            main-thread stalls over 50 ms (debug.hangs)
#   create   instant-new-surfaces-bench.py: Cmd-N (new workspace) and Cmd-T (new tab), key to
#            the visible frame, idle only
#   switch   bench_tab_switch.py: next workspace and next tab at key-repeat speed, frame
#            intervals and main-thread stalls
# Runs alone on a worker because it launches an app:
#   cmux-ci run --class exclusive --label measure --script scripts/measure/perf-feel.sh --ref <sha>
#     [--arg=parts=startup,create,switch] [--arg=runs=5]
set -euo pipefail
parts="startup,create,switch"
runs=5
for arg in "$@"; do
  case "$arg" in
    parts=*) parts="${arg#parts=}" ;;
    runs=*) runs="${arg#runs=}" ;;
    *) echo "perf-feel.sh: unknown argument $arg" >&2; exit 2 ;;
  esac
done
case "$runs" in [1-9]|[1-9][0-9]) ;; *) echo "perf-feel.sh: runs must be 1-99" >&2; exit 2 ;; esac
cd "$(git rev-parse --show-toplevel)"
tag="perffeel"
out="$(mktemp -d)"
echo "PERF-FEEL-MACHINE host=$(scutil --get ComputerName 2>/dev/null || hostname) macos=$(sw_vers -productVersion) rev=$(git rev-parse HEAD) load=$(sysctl -n vm.loadavg)"
CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag "$tag" 2>&1 | tee "$out/reload.log" | tail -n 20
app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$out/reload.log" | tail -n 1)"
if [[ -z "$app" || ! -d "$app" ]]; then
  echo "perf-feel: the tagged reload printed no app path" >&2
  exit 1
fi
status=0
has() { [[ ",$parts," == *",$1,"* ]]; }
if has startup; then
  echo "PERF-FEEL part=startup"
  python3 scripts/cmux-next/bench-startup.py --app "$app" --profile realistic --mode cold --mode warm \
    --runs "$runs" --hangs 50 --json "$out/startup.json" || status=$?
fi
if has create; then
  echo "PERF-FEEL part=create"
  python3 scripts/cmux-next/instant-new-surfaces-bench.py --tag "$tag" --app "$app" --runs "$((runs * 2))" \
    --phases idle --out "$out" --json "$out/create.json" || status=$?
fi
if has switch; then
  echo "PERF-FEEL part=switch"
  python3 scripts/cmux-next/bench_tab_switch.py --tag "$tag" --app "$app" --tabs 12 --workspaces 8 --seconds 8 \
    --scenarios workspace-repeat,tab-repeat --out "$out/switch.json" || status=$?
  python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1])), indent=1)[:6000])' "$out/switch.json" || true
fi
exit "$status"
