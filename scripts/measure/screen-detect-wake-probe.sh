#!/usr/bin/env bash
# PROBE ONLY (never merged): what wakes cmux-agent-screen-detection in an idle app.
set -uo pipefail
root="$(git rev-parse --show-toplevel)"; cd "$root"
work="$root/.build/sd-probe"; rm -rf "$work"; mkdir -p "$work"
rm -f /tmp/cmux-sd-wakes-*.log
for sub in ghostty ghostty-next; do [ -e "$sub/.git" ] || git submodule update --init --depth 1 "$sub"; done
if [ ! -f GhosttyKit.xcframework/Info.plist ]; then
  rm -rf GhosttyKit.xcframework
  if [ -z "${GHOSTTYKIT_ARCHIVE_CACHE_DIR:-}" ] && [ -n "${CI_SHARED_CACHE_DIR:-}" ]; then
    export GHOSTTYKIT_ARCHIVE_CACHE_DIR="$CI_SHARED_CACHE_DIR/ghosttykit-archives"
  fi
  ./scripts/download-prebuilt-ghosttykit.sh
fi
CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag sdprobe 2>&1 | tee "$work/reload.log" >/dev/null || { tail -n 80 "$work/reload.log"; exit 1; }
app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$work/reload.log" | tail -n 1)"
echo "PROBE app=$app"
python3 scripts/cmux-next/bench_memory.py --app "$app" --workspaces 1 --mix terminal \
  --settle 20 --measure 60 --top 8 --out "$work/app.json" > "$work/app.log" 2>&1 &
bench=$!
sleep 50
echo "PROBE ps:"; ps -axo pid,ppid,%cpu,command | grep -i "agent-screen-detection\|cmux-tui" | grep -v grep | cut -c1-300
for pid in $(pgrep -f 'bin/cmux-agent-screen-detection'); do
  echo "PROBE sample $pid"; sample "$pid" 10 -mayDie 2>&1 | sed -n '1,200p' | grep -v '^$' | head -150
done
wait "$bench"; echo "PROBE bench rc=$?"
python3 - "$work/app.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
for s in data.get("samples", []):
    for kind, e in s["kinds"].items():
        print(f"PERF-IDLE app {s['label']} kind={kind} n={e['count']} cpu_pct={e.get('cpu_pct')} wakeups_per_s={e.get('wakeups_per_s')}")
PY
for f in /tmp/cmux-sd-wakes-*.log; do
  [ -f "$f" ] || continue
  echo "PROBE log $f lines=$(wc -l < "$f")"
  echo "PROBE kinds:"; awk '{print $2, $3}' "$f" | sed 's/rev=[0-9]*//; s/prev=[0-9]*//' | sort | uniq -c | sort -rn | head -40
  echo "PROBE last 120:"; tail -n 120 "$f" | cut -c1-400
done
