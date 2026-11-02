#!/usr/bin/env bash
# Fleet self-check of hid_inject (no input posted): compiles it and runs its plan mode on a 120 Hz, 250 ms drag and a
# 1 s, 240 Hz drag. Passes when each drag's achieved rate is at least 95 % of its target. A Mac step:
#   cmux-ci run --os macos --class light --script scripts/journeys/hid_inject_selfcheck.sh --ref SHA
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/hid-inject.XXXXXX")"
trap 'rm -rf "$work"' EXIT
xcrun swiftc -O -swift-version 5 "$here/hid_inject.swift" -o "$work/hid_inject"
cat > "$work/script.json" <<'JSON'
{"start_delay_ms": 100, "rate_floor": 0.95, "steps": [
 {"do": "key", "key_code": 2, "modifiers": ["cmd"]},
 {"do": "drag", "from": [100, 100], "to": [420, 100], "duration_ms": 250, "hz": 120},
 {"do": "wait", "ms": 50},
 {"do": "drag", "from": [420, 100], "to": [100, 100], "duration_ms": 1000, "hz": 240}]}
JSON
status=0
"$work/hid_inject" plan "$work/script.json" "$work/log.json" || status=$?
/usr/bin/python3 - "$work/log.json" "$status" <<'PY'
import json, sys
log, status = json.load(open(sys.argv[1])), int(sys.argv[2])
for step in log["steps"]:
    print(json.dumps(step))
drags = [s for s in log["steps"] if s["do"] == "drag"]
ok = status == 0 and log["rate_ok"] and len(drags) == 2 and all(s["achieved_hz"] >= 0.95 * s["target_hz"] for s in drags)
times = [e[0] for e in log["events"]]
ok = ok and times == sorted(times) and len(log["events"]) == 2 + (1 + 1 + 30 + 1) + (1 + 1 + 240 + 1)
print(f"hid_inject selfcheck: events {len(log['events'])}, exit {status}: {'PASS' if ok else 'FAIL'}")
sys.exit(0 if ok else 1)
PY
