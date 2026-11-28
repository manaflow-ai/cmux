#!/usr/bin/env bash
# Goal dev-loop-ceiling, loop web_swap: N saves of the agent pane's ComposerFoot.tsx through the Vite dev server
# a person runs for live web code (`cmux live start --worktree` -> web-overlay.sh server --local -> `vp dev`),
# swapped in place by React Fast Refresh, each split into stages (fs_event, hmr_send, transform, apply, paint,
# unattributed) with each stage's floor measured on its own. Writes OUT/web_swap.json
# (schema dev-loop-ceiling/loop/v1); exits 0 when it measured.
#   scripts/measure/dev-loop/web_swap.sh OUT [N=5]
# The page runs in a WKWebView (web_swap/host.swift) on macOS and in Playwright Chromium elsewhere (fleet Macs
# take no Playwright). Edits go to a copy of the sources in a temporary directory; the checkout is never
# touched. Every process it starts it stops by PID.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../../.." && pwd)"
out="${1:?usage: web_swap.sh OUT [N]}"
n="${2:-5}"
[[ "$n" =~ ^[0-9]+$ && "$n" -ge 1 ]] || { echo "web_swap.sh: N must be a positive integer" >&2; exit 2; }
mkdir -p "$out"
out="$(cd "$out" && pwd)"
json="$out/web_swap.json"

# A json with `error` whenever the measurement could not start.
fail() {
  python3 - "$json" "$1" "$root" <<'PY'
import json, os, socket, subprocess, sys, datetime
path, error, root = sys.argv[1:]
commit = subprocess.run(["git", "-C", root, "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
json.dump({"schema": "dev-loop-ceiling/loop/v1", "loop": "web_swap", "commit": commit, "host": socket.gethostname(),
           "measured_at": datetime.datetime.now(datetime.timezone.utc).isoformat(), "target": "", "error": error,
           "rounds": [], "floors_ms": {}, "graph": {}, "notes": []}, open(path, "w"), indent=2)
PY
  echo "web_swap.sh: $1" >&2
  exit 1
}

work="$(mktemp -d "${TMPDIR:-/tmp}/dev-loop-web-swap-sh.XXXXXX")"
trap 'rm -rf "$work"' EXIT

cd "$root/webviews" || fail "no webviews/ in $root"
command -v bun >/dev/null || fail "bun is not on PATH"
command -v node >/dev/null || fail "node is not on PATH"
# As web-overlay.sh server --local prepares a tree for `vp dev`.
[[ -d node_modules ]] || bun install --frozen-lockfile >"$work/install.log" 2>&1 || fail "bun install failed: $(tail -5 "$work/install.log")"
bun scripts/pages/gen-strings.mjs --best-effort >/dev/null 2>&1

args=("$json" "$n")
if [[ "$(uname -s)" == Darwin ]]; then
  swiftc -O -parse-as-library "$here/web_swap/host.swift" -o "$work/host" >"$work/swiftc.log" 2>&1 ||
    fail "host.swift did not compile: $(tail -5 "$work/swiftc.log")"
  args+=(--engine webkit --host "$work/host")
else
  [[ -n "${PLAYWRIGHT_CHROMIUM_EXECUTABLE:-}" ]] || for chrome in google-chrome chromium chromium-browser; do
    command -v "$chrome" >/dev/null && export PLAYWRIGHT_CHROMIUM_EXECUTABLE="$(command -v "$chrome")" && break
  done
  args+=(--engine chromium)
fi
# measure.mjs stops its own server and page host by PID and deletes its copy on any exit; the cap is a
# backstop for a hung page.
cap=$((600 + 60 * n))
node "$here/web_swap/measure.mjs" "${args[@]}" &
pid=$!
# sleep-ok: the watchdog's cap itself, a backstop for a hung page
( sleep "$cap"; kill -TERM "$pid" 2>/dev/null ) >/dev/null 2>&1 &
watchdog=$!
wait "$pid"
status=$?
kill "$watchdog" 2>/dev/null
wait "$watchdog" 2>/dev/null
[[ -s "$json" ]] || fail "measure.mjs exited $status without a json"
# The loop's own row from bound.py (bound, simulated bound, ratio, per-stage gap) under the key bound, so a run of this
# loop alone reads its ratio without a full dev-loop-ceiling.sh report; bound.py ignores the key.
python3 -I - "$json" "$here" <<'PY'
import json, sys
path, here = sys.argv[1:]
sys.path.insert(0, here)
import bound
d = json.load(open(path))
d["bound"] = bound.judge(d)
json.dump(d, open(path, "w"), indent=2)
b = d["bound"]
print(json.dumps(d.get("p50_ms")), d.get("error"))
if b.get("measured"):
    print(f"web_swap: p50 {b['end_to_end_p50_ms']} ms, simulated bound {b['simulated_bound_p50_ms']} ms, ratio {b['ratio']}x, biggest gap {b['biggest_gap']}")
PY
exit "$status"
