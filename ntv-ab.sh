#!/usr/bin/env bash
# Interleaved A/B of Experiments nativeTranscript on scripts/measure/replay-under-load.sh (one harness).
set -uo pipefail
root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$root"
out="${FAST_CHECKS_OUT:-/tmp/ntv-ab}"; mkdir -p "$out"
echo "host_cores=$(nproc) mem=$(free -m | awk '/Mem:/ {print $2}')MB cpu=$(awk -F: '/model name/ {print $2; exit}' /proc/cpuinfo)"
command -v stress-ng >/dev/null || sudo -n apt-get install -y stress-ng >/dev/null 2>&1 || (sudo -n dpkg --configure -a; sudo -n apt-get install -y stress-ng >/dev/null 2>&1)
bash scripts/ci/ensure-system-chrome.sh 2>&1 | tail -2
shell="$(ls -d "$HOME"/.cache/cmux-ci/chrome-headless-shell-*/chrome-headless-shell-linux64/chrome-headless-shell 2>/dev/null | tail -1)"
[ -n "$shell" ] && export CMUX_CHROME_HEADLESS_SHELL="$shell"
export CMUX_STRINGS_BEST_EFFORT=1
(cd webviews && bash ../scripts/ci/bun-install.sh --frozen-lockfile 2>&1 | tail -1)
cores=8; [ "$(nproc)" -lt 8 ] && cores="$(nproc)"
run() { # name painter [extra...]
  local name="$1" painter="$2"; shift 2
  scripts/measure/replay-under-load.sh --cores "$cores" --seconds 60 --painter "$painter" --out "$out/$name.json" "$@" >"$out/$name.log" 2>&1
  python3 -I - "$out/$name.json" "$name" <<'PY'
import json, sys
try: d = json.load(open(sys.argv[1]))
except Exception as e: d = {"error": str(e)}
keys = ("painter","history_rows","frame_p95_ms","frame_p50_ms","frame_p99_ms","frames","react_frame_p95_ms","renderer_main_busy_pct","long_tasks","longest_task_ms","load_per_core","cores","records","commit")
print("RESULT", sys.argv[2], json.dumps({k: d.get(k) for k in keys} | ({"error": str(d["error"])[:400]} if d.get("error") else {})), flush=True)
PY
}
for i in 1 2 3; do run "before-$i" react; run "after-$i" native; done
run "profile-after" native --profile; echo "== profile (top self time, flag on)"; grep -v "^\[BABEL\]" "$out/profile-after.log" | tail -45
for i in 1 2; do run "hist100k-before-$i" react --history-rows 100000; run "hist100k-after-$i" native --history-rows 100000; done
for f in "$out"/hist100k-*.log; do echo "== $f"; tail -5 "$f"; done
exit 0
