#!/usr/bin/env bash
# PROBE: cold attach perf at 1M and 1G.
set -uo pipefail
out="${FAST_CHECKS_OUT:-/tmp}"
mkdir -p "$out/cold"
command -v perf >/dev/null || sudo -n apt-get install -y -q linux-tools-common "linux-tools-$(uname -r)" >/dev/null 2>&1 || sudo -n apt-get install -y -q linux-perf >/dev/null 2>&1 || true
sudo -n sysctl -w kernel.perf_event_paranoid=-1 kernel.kptr_restrict=0 2>&1 || true
echo "perf: $(command -v perf) $(perf --version 2>&1)"
cat /proc/sys/kernel/perf_event_paranoid
ACPMUX_GOD_COLD_PROBE="$out/cold" bash scripts/measure/chat-size-sweep.sh "${1:-1M,1G}"
code=$?
for f in "$out"/cold/perf-*.data; do
  [ -f "$f" ] || continue
  echo "=== $f"
  perf report -i "$f" --no-children --comm acpmux --sort sym --stdio 2>/dev/null | grep -v '^$' | head -60
  echo "--- by thread"
  perf report -i "$f" --no-children --comm acpmux --sort tid --stdio 2>/dev/null | grep -v '^#' | grep -v '^$' | head -20
  echo "--- callers"
  perf report -i "$f" --children --comm acpmux --sort sym --stdio -g none 2>/dev/null | grep -v '^$' | head -80
  rm -f "$f"
done
exit $code
