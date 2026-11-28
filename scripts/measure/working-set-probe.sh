#!/bin/bash
# Measures `acpmux host working-set` against a known working set (RFD 0182 B11).
#
# Runs a load in its own slice under this user's acpmuxsessions.slice: 1.5 GiB of file pages
# read once (cold) and 512 MiB read in a loop (hot). It then probes that slice and prints the
# report. A right answer is about 512 MiB plus the interpreter, stopped by `refaults`.
# 2026-11-28 on a Linux 6.1 lane VM with no swap: 563728384 bytes (537.6 MiB), 37 steps, 37.6 s.
#
# Needs Linux with cgroup v2 and a systemd user manager; no root. Writes 2 GiB under a temp dir
# it makes and removes.
#   scripts/measure/working-set-probe.sh [path/to/acpmux]
set -euo pipefail
BIN=${1:-acpmux}
DIR=$(mktemp -d "${TMPDIR:-/tmp}/working-set-probe.XXXXXX")
UNIT=working-set-probe-$$
SLICE=acpmuxsessions-wsprobe$$.slice
trap 'systemctl --user stop "$UNIT.service" 2>/dev/null || true; rm -rf -- "$DIR"' EXIT

cat >"$DIR/load.py" <<'PY'
import os, sys, time
d = sys.argv[1]
def mk(name, mib):
    p = os.path.join(d, name)
    with open(p, 'wb') as f:
        for _ in range(mib): f.write(os.urandom(1 << 20))
    return p
cold, hot = mk('cold', 1536), mk('hot', 512)
def read(p):
    with open(p, 'rb', buffering=0) as f:
        while f.read(1 << 22): pass
read(cold)
open(os.path.join(d, 'ready'), 'w').close()
while True:
    read(hot); time.sleep(0.2)
PY

systemd-run --user --quiet --unit="$UNIT" --slice="$SLICE" python3 -I "$DIR/load.py" "$DIR"
for _ in $(seq 1 180); do [ -e "$DIR/ready" ] && break; sleep 1; done
[ -e "$DIR/ready" ] || { echo "load never became ready" >&2; exit 1; }
sleep 3
CG=$(systemctl --user show -P ControlGroup "$SLICE")
timeout 300 "$BIN" host working-set --cgroup "$CG"
