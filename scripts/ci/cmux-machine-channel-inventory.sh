#!/usr/bin/env bash
# The version inventory of one Cloud machine channel commit, for the ring gate (RFD 0224 phase 3):
# JSON {"commit", "updated", "update_failed"} at OUT, the machines running COMMIT and those whose update to it
# failed (rolledBack or failed, as acpmux_lag.py UPDATE_FAILED).
#
# HOLD (stub): no source records a per-commit Cloud update result yet. cmux-platform's census (Census.ts) keeps
# image_behind and update_ms per spare fill (updater.first_ready), not a failure count per commit, and
# acpmux_lag.py --by-surface has no Cloud surface. Until one exists, vars.CLOUD_MACHINE_INVENTORY_URL is unset, no
# file is written, and `cmux-machine-channel.py step` holds ("no inventory to gate on") and first-pct starts each
# build at vars.CLOUD_MACHINE_FIRST_PCT. Set, the URL is read with COMMIT appended (?commit=SHA) and must answer
# that JSON for that commit; anything else writes no file, so the gate holds.
#
# usage: scripts/ci/cmux-machine-channel-inventory.sh COMMIT OUT
set -euo pipefail
commit=$1 out=$2
url="${CLOUD_MACHINE_INVENTORY_URL:-}"
rm -f "$out"
if [[ -z "$url" ]]; then
  echo "cmux-machine-channel: no Cloud version inventory source (CLOUD_MACHINE_INVENTORY_URL unset): the ring gate holds" >&2
  exit 0
fi
case "$url" in *\?*) sep="&" ;; *) sep="?" ;; esac
tmp="$out.part"
if ! curl -fsS --retry 3 --max-time 60 -o "$tmp" "$url${sep}commit=$commit"; then
  echo "cmux-machine-channel: the Cloud version inventory did not answer: the ring gate holds" >&2
  rm -f "$tmp"
  exit 0
fi
if python3 -c '
import json, sys
v = json.load(open(sys.argv[1]))
ok = v.get("commit") == sys.argv[2] and all(
    isinstance(v.get(k), int) and not isinstance(v.get(k), bool) and v[k] >= 0 for k in ("updated", "update_failed"))
sys.exit(0 if ok else 1)' "$tmp" "$commit" 2>/dev/null; then
  mv "$tmp" "$out"
else
  echo "cmux-machine-channel: the Cloud version inventory is not a count of $commit: the ring gate holds" >&2
  rm -f "$tmp"
fi
