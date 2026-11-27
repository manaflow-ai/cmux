#!/usr/bin/env bash
# Time one OptChat Chief import (the synthetic 2,020-message corpus, 16
# compactor sessions) on a quiet Mac, to separate host contention from the
# compactor's own cost. Run alone on a worker:
#   cmux-ci run --class exclusive --script scripts/measure/chief-import.sh --ref SHA \
#     --arg=base_url=http://HOST:PORT [--arg=claude=2.1.295] [--arg=sessions=16] \
#     [--arg=timeout=5400] --timeout 9000
# base_url= is a Claude route that needs no credential (a router that signs
# requests itself); Claude Code gets only that base URL and a placeholder key,
# so no credential file reaches the worker.
# Builds acpmux and optchat-chief at this ref (scripts/cmux-next/build-*.sh)
# and takes cmux-tui from the published tree of this ref (else builds it),
# installs Claude Code at the pinned version under the step (npm), then runs
# Native/OptChat/optchat-chief/measure/chief_driver.py --scenario import.
# Output: CHIEF-IMPORT lines (summary, timing, host load and Claude Code
# process counts sampled every 30 s); files under .build/chief-import.
set -euo pipefail
base_url=""
claude_version="2.1.295"
sessions=16
import_timeout=5400
for arg in "$@"; do
  case "$arg" in
    base_url=*) base_url="${arg#base_url=}" ;;
    claude=*) claude_version="${arg#claude=}" ;;
    sessions=*) sessions="${arg#sessions=}" ;;
    timeout=*) import_timeout="${arg#timeout=}" ;;
    *) echo "chief-import.sh: unknown argument $arg" >&2; exit 2 ;;
  esac
done
[[ "$base_url" =~ ^https?://[A-Za-z0-9.-]+(:[0-9]{1,5})?$ ]] || { echo "chief-import.sh: base_url=http://HOST[:PORT] is required" >&2; exit 2; }
[[ "$claude_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "chief-import.sh: claude=X.Y.Z" >&2; exit 2; }
[[ "$sessions" =~ ^[1-9][0-9]?$ && "$sessions" -le 64 ]] || { echo "chief-import.sh: sessions must be 1-64" >&2; exit 2; }
[[ "$import_timeout" =~ ^[0-9]{2,5}$ ]] || { echo "chief-import.sh: timeout is seconds" >&2; exit 2; }
root="$(git rev-parse --show-toplevel)"
cd "$root"
work="$root/.build/chief-import"
rm -rf "$work"
mkdir -p "$work/bin" "$work/home/.local/bin"
echo "CHIEF-IMPORT-MACHINE host=$(scutil --get ComputerName 2>/dev/null || hostname) cpu=\"$(sysctl -n machdep.cpu.brand_string)\" cores=$(sysctl -n hw.ncpu) ram_gb=$(( $(sysctl -n hw.memsize) / 1073741824 )) macos=$(sw_vers -productVersion) rev=$(git rev-parse HEAD)"
curl -fsS -m 10 -o /dev/null "$base_url/_subrouter/ready" || { echo "CHIEF-IMPORT the route $base_url is not reachable from this worker" >&2; exit 1; }

# The build scripts run Cargo only on a build host; this step is one. The
# step's checkout has empty submodules; cmux-tui crates build libghostty-vt
# from ghostty-next.
export CI=1
git submodule update --init --depth 1 ghostty-next
scripts/cmux-next/build-acpmux.sh --output "$work/bin/acpmux"
scripts/cmux-next/build-optchat-chief.sh --output "$work/bin/optchat-chief"
key="$(python3 scripts/ci/cmux_tui_tree_key.py HEAD)"
tree="${CMUX_TUI_PIN_BASE:-https://files.cmux.com/cmux-tui}/tree/$key"
if curl -fsSL --proto '=https' "$tree/cmux-tui-aarch64-apple-darwin" -o "$work/bin/cmux-tui"; then
  sum="$(curl -fsSL --proto '=https' "$tree/cmux-tui-aarch64-apple-darwin.sha256" | awk '{print $1}')"
  [[ "$(shasum -a 256 "$work/bin/cmux-tui" | awk '{print $1}')" == "$sum" ]] || { echo "CHIEF-IMPORT cmux-tui sha256 mismatch ($key)" >&2; exit 1; }
  echo "CHIEF-IMPORT-BIN cmux-tui published tree $key"
else
  echo "CHIEF-IMPORT-BIN cmux-tui tree $key not published; building it"
  (cd cmux-tui && CARGO_TARGET_DIR="$work/target" cargo build --release --locked -p cmux-tui)
  cp "$work/target/release/cmux-tui" "$work/bin/cmux-tui"
fi
chmod 755 "$work/bin/"*
git rev-parse HEAD > "$work/bin/REV"

# Claude Code at the pinned version, under the step only; a fresh HOME keeps
# the worker's own settings and logins out of the run.
npm install --prefix "$work/cc" --no-fund --no-audit "@anthropic-ai/claude-code@$claude_version" >/dev/null
ln -s "$work/cc/node_modules/.bin/claude" "$work/home/.local/bin/claude"
echo "CHIEF-IMPORT-BIN claude $(HOME="$work/home" "$work/home/.local/bin/claude" --version)"
# A worker keychain login could reach Claude Code outside HOME; the env key and
# the route win over it, and the config dir below stays in the step. Report
# whether one exists (the item's presence only, never its content).
if security find-generic-password -s "Claude Code-credentials" >/dev/null 2>&1; then echo "CHIEF-IMPORT-KEYCHAIN login item present (not used: env key + route)"; else echo "CHIEF-IMPORT-KEYCHAIN no login item"; fi

# Claude Code processes on the worker: this run's (acpmux starts the
# $work/home/.local/bin/claude link; npm may run it under node) and all.
claude_count() { echo "$(pgrep -f "$work/(home/\.local/bin/claude|cc/)" 2>/dev/null | wc -l | tr -d ' ') $(pgrep -f '(^|/)claude( |$)' 2>/dev/null | wc -l | tr -d ' ')"; }
sampler() {
  while true; do
    echo "$(date +%s) $(sysctl -n vm.loadavg | tr -d '{}') $(claude_count)" >> "$work/host.txt"
    sleep 30
  done
}
sampler >/dev/null 2>&1 &
sampler_pid=$!
driver_pid=""
# A cancelled step (SIGTERM, SIGINT, SIGHUP) stops the driver with SIGTERM, so
# its own cleanup runs (it stops the brain's acpmux daemon and checks that
# nothing holds that home's locks), and waits for it.
stop_driver() {
  if [[ -n "$driver_pid" ]] && kill -0 "$driver_pid" 2>/dev/null; then
    kill -TERM "$driver_pid" 2>/dev/null || true
    wait "$driver_pid" 2>/dev/null || true
  fi
}
trap 'stop_driver; kill "$sampler_pid" 2>/dev/null || true' EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
trap 'exit 129' HUP
echo "CHIEF-IMPORT-LOAD start $(sysctl -n vm.loadavg) claude_procs=$(claude_count)"
status=0
HOME="$work/home" python3 Native/OptChat/optchat-chief/measure/chief_driver.py --scenario import \
  --out "$work/run" --bins "$work/bin" --import-timeout "$import_timeout" \
  --env "ANTHROPIC_BASE_URL=$base_url" --env "ANTHROPIC_API_KEY=sk-ant-placeholder-the-route-signs" \
  --env "OPTCHAT_COMPACTOR_SESSIONS=$sessions" --env "CLAUDE_CONFIG_DIR=$work/home/.claude" > "$work/driver.log" 2>&1 &
driver_pid=$!
wait "$driver_pid" || status=$?
driver_pid=""
echo "CHIEF-IMPORT-LOAD end $(sysctl -n vm.loadavg) claude_procs=$(claude_count)"
tail -5 "$work/driver.log"
# The driver's cleanup line: a daemon still holding the run's acpmux home fails the step.
if ! grep -q "acpmux cleanup: .*no process holds its locks" "$work/driver.log"; then
  echo "CHIEF-IMPORT acpmux cleanup not confirmed: $(grep "acpmux cleanup" "$work/driver.log" || echo 'no cleanup line')" >&2
  status=1
fi
python3 - "$work" <<'EOF' || status=$?
import glob, json, os, statistics, sys
work = sys.argv[1]
def lines(f):
    for l in open(f):
        try:
            yield json.loads(l)
        except ValueError:
            pass  # a line cut by the stop
ev = [e for f in glob.glob(os.path.join(work, "run", "traces", "*.jsonl")) for e in lines(f)]
n = [e for e in ev if e.get("ev") == "node"]
if not n:
    sys.exit("CHIEF-IMPORT no node in the trace")
t0, t1 = min(e["ts"] - (e.get("ms") or 0) for e in n), max(e["ts"] for e in n)
tok = {k: sum((e.get("usage") or {}).get(k) or 0 for e in n) for k in ("input", "cache_write", "cache_read", "output")}
tm = [e.get("timing") or {} for e in n]
def q(v):
    v = sorted(v)
    return {"p50": v[len(v) // 2], "p90": v[int(len(v) * 0.9)], "max": v[-1]} if v else None
first = [t["ttft_ms"][0] for t in tm if t.get("ttft_ms")]
later = [x for t in tm for x in (t.get("ttft_ms") or [])[1:]]
host = [l.split() for l in open(os.path.join(work, "host.txt"))] if os.path.exists(os.path.join(work, "host.txt")) else []
print("CHIEF-IMPORT " + json.dumps({
    "minutes": round((t1 - t0) / 60000, 1), "nodes": len(n), "failed": sum(1 for e in n if not e.get("ok")),
    "prompts_per_node": round(sum(e.get("prompts") or 0 for e in n) / len(n), 2),
    "cache_read_pct": round(100 * tok["cache_read"] / max(1, tok["cache_read"] + tok["cache_write"] + tok["input"]), 1),
    "output_tokens": tok["output"],
    "session_start_ms": q([t["session_start_ms"] for t in tm if "session_start_ms" in t]),
    "slot_wait_ms": q([t["slot_wait_ms"] for t in tm if "slot_wait_ms" in t]),
    "ttft_first_ms": q(first), "ttft_later_ms": q(later),
    "load1": q([float(h[1]) for h in host]) if host else None,
    "claude_procs_run": q([int(h[4]) for h in host]) if host else None,
    "claude_procs_all": q([int(h[5]) for h in host]) if host else None}))
EOF
exit "$status"
