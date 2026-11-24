#!/usr/bin/env bash
# Measure the four RFD 0077 D4 share bounds over the daemon's existing fake room.
#
# Run from a hosted Rust test step at a pushed head:
#   scripts/measure/share-latency.sh
#
# The Rust harness prints one SHARE-LATENCY JSON record per case and load. This
# wrapper keeps the largest observed value for the live record and each access
# cut, so a slow sample remains visible even when it makes the test fail.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
log="$(mktemp "${TMPDIR:-/tmp}/cmux-share-latency.XXXXXX")"
trap 'rm -f "$log"' EXIT

cd "$root/cmux-tui"
status=0
cargo test --locked -p cmux-tui-core --lib \
  'shares::room::tests::latency::' -- --nocapture 2>&1 | tee "$log" || status=$?

python3 - "$log" <<'PY'
import json
import sys

log = sys.argv[1]
cases = {
    "live": "live_ms",
    "revoke.guest_closed": "revoke_ms",
    "kick.guest_closed": "kick_ms",
    "uninvite.guest_closed": "uninvite_ms",
}
maximums = {}
with open(log, encoding="utf-8", errors="replace") as stream:
    for line in stream:
        prefix = "SHARE-LATENCY "
        if not line.startswith(prefix):
            continue
        try:
            sample = json.loads(line[len(prefix):])
        except json.JSONDecodeError as error:
            raise SystemExit(f"share-latency: invalid measurement line: {error}")
        key = cases.get(sample.get("case"))
        if key is None:
            continue
        maximums[key] = max(maximums.get(key, 0.0), float(sample["max_ms"]))

missing = [key for key in cases.values() if key not in maximums]
if missing:
    raise SystemExit("share-latency: missing measurements: " + ", ".join(missing))

summary = {key: maximums[key] for key in cases.values()}
print("SHARE-LATENCY-SUMMARY " + json.dumps(summary, separators=(",", ":")))
for key in cases.values():
    print(f"{key}={maximums[key]:.1f} ms")
PY

exit "$status"
