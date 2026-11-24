#!/usr/bin/env bash
# goal dev-loop-ceiling, loop startup_loop: an edit the running cmux NEXT app cannot take live (one line of
# CmuxNextApp Swift), the tagged Debug rebuild developers run (scripts/reload.sh --tag), the relaunch, and the
# relaunched app's first interaction (launch-ready.swift `type`: a key typed into the restored terminal, its echo).
#
#   scripts/measure/dev-loop/startup_loop.sh OUT [N]     (N rounds, default 5; from the repo root on a fleet Mac)
#   cmux-ci run --class exclusive --os macos --measurement --display --script scripts/measure/dev-loop/startup_loop.sh \
#     --ref <sha> --arg=.build/dlc-startup_loop --arg=5 --artifact .build/dlc-startup_loop ...
#
# Writes OUT/startup_loop.json (schema dev-loop-ceiling/loop/v1) every time, with `error` null only when every round
# and every floor was measured; exits 0 then, nonzero otherwise. The round logic is startup_loop/run.py; this wrapper
# keeps a copy of the one file the rounds edit and puts it back on every way out, and writes the json itself when
# run.py died before it could.
set -uo pipefail

out="${1:-.build/dlc-startup_loop}"
n="${2:-5}"
mkdir -p "$out"
out="$(cd "$out" && pwd)"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
edited="Packages/macOS/CmuxNext/Sources/CmuxNextApp/AppDelegate.swift"
backup="$out/AppDelegate.swift.orig"

restore() {
  if [[ -f "$backup" ]]; then cp "$backup" "$edited" && rm -f "$backup"; fi
}
trap restore EXIT
trap 'restore; exit 130' INT TERM

if [[ -f "$edited" ]]; then cp "$edited" "$backup"; fi

rc=0
/usr/bin/python3 -I "$here/startup_loop/run.py" --out "$out" --rounds "$n" --repo "$PWD" --edit "$edited" || rc=$?

if [[ ! -s "$out/startup_loop.json" ]]; then
  /usr/bin/python3 -I - "$out/startup_loop.json" "$rc" <<'PY'
import json, sys, datetime, socket
json.dump({"schema": "dev-loop-ceiling/loop/v1", "loop": "startup_loop", "commit": None, "host": socket.gethostname(),
           "measured_at": datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"), "target": None,
           "error": "run.py exited %s before writing its json" % sys.argv[2], "rounds": [], "floors_ms": {}, "graph": {},
           "notes": []}, open(sys.argv[1], "w"), indent=1)
PY
  [[ "$rc" != 0 ]] || rc=1
fi
exit "$rc"
