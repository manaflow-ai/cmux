#!/usr/bin/env bash
set -u

# Keep provider/network evidence in the job log without failing the original
# operation. These commands are intentionally read-only and emit no tokens.
echo "== network diagnostics (runner=${RUNNER_NAME:-unknown}) ==" >&2
if command -v scutil >/dev/null 2>&1; then
  scutil --dns 2>&1 || true
fi
if command -v route >/dev/null 2>&1; then
  route -n get default 2>&1 || true
fi
if command -v ifconfig >/dev/null 2>&1; then
  ifconfig 2>&1 || true
fi
if command -v dscacheutil >/dev/null 2>&1; then
  dscacheutil -q host -a name github.com 2>&1 || true
fi
if command -v curl >/dev/null 2>&1; then
  curl --connect-timeout 5 --max-time 10 --silent --show-error --head https://github.com/ 2>&1 || true
fi
echo "== end network diagnostics ==" >&2
