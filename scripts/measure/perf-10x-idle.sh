#!/usr/bin/env bash
# perf-10x idle bench (msg 1628): CPU %, wakeups/s, RSS and physical
# footprint per process kind for an idle cmux-next app and an idle headless
# cmux-tui, at 1, 10 and 50 terminal workspaces, each idle for 60 s.
#   app:    builds a tagged app at this checkout (reload.sh), launches it with
#           a scratch HOME (scripts/cmux-next/bench_memory.py --measure).
#   daemon: the app bundle's cmux-tui, headless, one terminal per workspace,
#           no output (cmux-tui/scripts/bench-scale.py --busy-fraction 0).
# Run alone on a worker (it launches an app):
#   cmux-ci run --class exclusive --measurement --label measure \
#     --script scripts/measure/perf-10x-idle.sh --ref SHA [--arg=counts=1,10,50] [--arg=measure=60] \
#     [--arg=agents=2,6,21] [--arg=agents_settle=370]
# agents: workspace counts including the launch workspace (2,6,21 opens 1,5,20
# chats). Also measure idle agent chats (one workspace each, on the
# acpmux test agent cmux-tui/crates/acpmux/tests/fake_agent.py, its first turn
# answered), as PERF-IDLE app-agents lines (resource-efficiency-DESIGN.md).
# Output: PERF-IDLE lines; JSON under .build/perf-idle.
set -euo pipefail
counts="1,10,50"
measure=60
agents=""
agents_settle=20
reload_config=()
for arg in "$@"; do
  case "$arg" in
    --config=*) reload_config=(--config "${arg#--config=}") ;;
    counts=*) counts="${arg#counts=}" ;;
    measure=*) measure="${arg#measure=}" ;;
    agents=*) agents="${arg#agents=}" ;;
    agents_settle=*) agents_settle="${arg#agents_settle=}" ;;
    *) echo "perf-10x-idle.sh: unknown argument $arg" >&2; exit 2 ;;
  esac
done
[[ "$agents_settle" =~ ^[0-9]+([.][0-9]+)?$ ]] || { echo "perf-10x-idle.sh: agents_settle must be nonnegative seconds" >&2; exit 2; }
root="$(git rev-parse --show-toplevel)"
cd "$root"
work="$root/.build/perf-idle"
rm -rf "$work"
mkdir -p "$work"
echo "PERF-IDLE-MACHINE host=$(scutil --get ComputerName 2>/dev/null || hostname) sha=$(git rev-parse HEAD) cores=$(sysctl -n hw.ncpu) ram_gb=$(( $(sysctl -n hw.memsize) / 1073741824 )) macos=$(sw_vers -productVersion) load=\"$(uptime | sed 's/.*load averages*: //')\""
# A fleet step checks out no submodules (only their empty gitlink directories): the app build needs
# Ghostty's headers and the ghostty-next tree, and GhosttyKit.xcframework (a prebuilt download).
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
tag="perfidle"
CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag "$tag" ${reload_config[@]+"${reload_config[@]}"} 2>&1 | tee "$work/reload.log" || { tail -n 80 "$work/reload.log"; exit 1; }
app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$work/reload.log" | tail -n 1)"
[[ -n "$app" && -d "$app" ]] || { echo "perf-10x-idle: reload printed no app path" >&2; tail -n 40 "$work/reload.log"; exit 1; }
tui="$app/Contents/Resources/bin/cmux-tui"
[ -x "$tui" ] || { echo "perf-10x-idle: no bundled cmux-tui at $tui" >&2; exit 1; }
status=0

echo "PERF-IDLE-LOAD daemon $(uptime | sed 's/.*load averages*: //')"
state_root="$(mktemp -d /private/tmp/pidl.XXXXXX)"
trap 'rm -rf "$state_root"' EXIT
# One daemon per count: bench-scale makes every workspace (one terminal each)
# before its first step, so a single run with several counts measures the
# largest count at every step.
IFS=, read -r -a daemon_counts <<< "$counts"
for n in "${daemon_counts[@]}"; do
  python3 cmux-tui/scripts/bench-scale.py --bin "$tui" --counts "$n" --busy-fraction 0 \
    --per-workspace 1 --fill sequential --idle-seconds "$measure" --settle-seconds-min 15 \
    --latency-samples 20 --latency-terminals 5 --topology-samples 20 \
    --root-dir "$state_root" --out "$work/daemon-$n.json" > "$work/daemon-$n.log" 2>&1 || status=$?
done
python3 - "$work"/daemon-*.json <<'PY' || status=$?
import json, sys
for path in sys.argv[1:]:
  data = json.load(open(path))
  for step in data.get("steps", []):
    for role, t in (step.get("roles") or {}).items():
      print(f"PERF-IDLE daemon N={step.get('target')} role={role} n={t.get('count')} cpu_pct={t.get('cpu_pct_window')} "
            f"wakeups_per_s={t.get('wakeups_per_s')} rss_each_mb={round((t.get('rss_per') or 0) / 1048576, 2)} "
            f"footprint_each_mb={round((t.get('pss_per') or 0) / 1048576, 2)} threads={t.get('threads')}")
  print(f"PERF-IDLE-STOP daemon {path} {data.get('stopped')} teardown={json.dumps(data.get('teardown') or {})[:300]}")
PY

echo "PERF-IDLE-LOAD app $(uptime | sed 's/.*load averages*: //')"
python3 scripts/cmux-next/bench_memory.py --app "$app" --workspaces "$counts" --mix terminal \
  --settle 20 --measure "$measure" --top 8 --out "$work/app.json" > "$work/app.log" 2>&1 || { status=$?; tail -n 60 "$work/app.log"; }
python3 - "$work/app.json" <<'PY' || status=$?
import json, sys
data = json.load(open(sys.argv[1]))
for s in data.get("samples", []):
    for kind, e in s["kinds"].items():
        print(f"PERF-IDLE app {s['label']} workspaces={s['workspaces']} kind={kind} n={e['count']} cpu_pct={e.get('cpu_pct')} "
              f"wakeups_per_s={e.get('wakeups_per_s')} rss_mb={e['rss_mb']} footprint_mb={e['footprint_mb']}")
PY
if [[ -n "$agents" ]]; then
  echo "PERF-IDLE-LOAD agents $(uptime | sed 's/.*load averages*: //')"
  python3 scripts/cmux-next/bench_memory.py --app "$app" --workspaces "$agents" --mix terminal+chat \
    --fake-agent cmux-tui/crates/acpmux/tests/fake_agent.py \
    --settle "$agents_settle" --measure "$measure" --top 8 --out "$work/agents.json" > "$work/agents.log" 2>&1 || { status=$?; tail -n 60 "$work/agents.log"; }
  python3 - "$work/agents.json" <<'PY' || status=$?
import json, sys
data = json.load(open(sys.argv[1]))
for s in data.get("samples", []):
    chats = s.get("chats", {})
    print(f"PERF-IDLE-CHATS {s['label']} workspaces={s['workspaces']} chats={chats.get('count')} "
          f"rendered={chats.get('rendered_count')} engines={','.join(chats.get('engines', []))} "
          f"observed_renderer_pids={chats.get('observed_webkit_renderer_pids', [])} "
          f"surviving_renderer_pids={chats.get('surviving_webkit_renderer_pids', [])} "
          f"webkit_webcontent_count={chats.get('webkit_webcontent_count')} settle_s={data.get('settle_s')}")
    for kind, e in s["kinds"].items():
        print(f"PERF-IDLE app-agents {s['label']} agents={chats.get('count')} workspaces={s['workspaces']} kind={kind} n={e['count']} cpu_pct={e.get('cpu_pct')} "
              f"wakeups_per_s={e.get('wakeups_per_s')} rss_mb={e['rss_mb']} footprint_mb={e['footprint_mb']}")
PY
fi
exit "$status"
