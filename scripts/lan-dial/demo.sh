#!/usr/bin/env bash
# lan-dial demo: from a background job on a fleet Mac, reach a LAN machine directly (before) and through the
# lan-dial relay (after), with a Python that is not Apple's.
#
#   scripts/lan-dial/demo.sh HOST PORT [PATH] [ROUNDS]     HOST:PORT an HTTP service on a LAN address
#
# Env: LAN_DIAL_PY (the Python to use; default the first
# python3 that is not /usr/bin/python3), LAN_DIAL_DEMO_OUT (where the receipt goes, default
# .build/lan-dial-demo), LAN_DIAL_DEMO_KEEP=1 leaves the relay loaded afterwards.
#
# Exit 0 when every relay round got an HTTP answer from the LAN host; the receipt (demo.json) also holds every
# direct round, so "direct refused, relay through" is read from one run on one host.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
host="${1:?usage: demo.sh HOST PORT [PATH] [ROUNDS]}"
port="${2:?usage: demo.sh HOST PORT [PATH] [ROUNDS]}"
path="${3:-/}"
rounds="${4:-5}"
out="${LAN_DIAL_DEMO_OUT:-$PWD/.build/lan-dial-demo}"
mkdir -p "$out"

pick_python() {
  if [[ -n "${LAN_DIAL_PY:-}" ]]; then echo "$LAN_DIAL_PY"; return; fi
  local c
  for c in "$HOME"/.local/bin/python3.1[3-9] "$HOME"/.local/bin/python3 /opt/homebrew/bin/python3 \
    /usr/local/bin/python3 "$HOME"/.local/python-*/bin/python3 "$(command -v python3 || true)"; do
    [[ -x "$c" ]] || continue
    [[ "$(cd "$(dirname "$c")" && pwd -P)/$(basename "$c")" == /usr/bin/python3 ]] && continue
    "$c" -c 'import sys; sys.exit(sys.version_info < (3, 9))' 2>/dev/null || continue
    echo "$c"
    return
  done
  echo /usr/bin/python3
}
py="$(pick_python)"
request="GET $path HTTP/1.0\\r\\nHost: $host:$port\\r\\nConnection: close\\r\\n\\r\\n"

ancestors() {
  local pid=$$ line=""
  while [[ "$pid" -gt 1 ]]; do
    line+="$(ps -o comm= -p "$pid" 2>/dev/null | sed 's#.*/##') < "
    pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"
    [[ -n "$pid" ]] || break
  done
  echo "${line}launchd"
}

{
  echo "host: $(hostname -s) $(sw_vers -productVersion 2>/dev/null || uname -sr) uid=$(id -u)"
  echo "python: $py ($("$py" -c 'import sys; print(sys.version.split()[0])'))"
  echo "process tree: $(ancestors)"
  echo "target: $host:$port$path, $rounds rounds each"
} | tee "$out/demo.txt"

: >"$out/rounds.jsonl"
for via in direct relay; do
  for ((i = 1; i <= rounds; i++)); do
    "$py" "$here/lan_dial.py" --via "$via" probe "$host" "$port" --send "$request" --read 120 \
      | tee -a "$out/rounds.jsonl"
  done
done

if [[ "$(uname -s)" == Darwin ]]; then
  log show --last 3m --info --predicate 'process == "mDNSResponder" OR process == "nehelper"' 2>/dev/null \
    | grep -i "local network" | tail -n 20 >"$out/privacy-log.txt" || true
  "$py" "$here/lan_dial.py" status >"$out/relay-status.json" 2>&1 || true
  [[ "${LAN_DIAL_DEMO_KEEP:-}" == 1 ]] || "$py" "$here/lan_dial.py" down >/dev/null 2>&1 || true
fi

"$py" - "$out" "$rounds" "$py" <<'EOF'
import json, sys
from pathlib import Path
out, rounds, py = Path(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
rows = [json.loads(line) for line in (out / "rounds.jsonl").read_text().splitlines() if line.strip()]
def side(via):
    got = [r for r in rows if r["via"] == via]
    ok = [r for r in got if r.get("ok") and r.get("first", "").startswith("HTTP/")]
    ms = sorted(r["ms"] for r in ok)
    return {"rounds": len(got), "http_ok": len(ok), "median_ms": ms[len(ms) // 2] if ms else None,
            "errors": sorted({f'{r.get("errno")} {r.get("error", "")}'.strip() for r in got if r not in ok})}
receipt = {"schema": "lan-dial-demo/v1", "python": py, "before_direct": side("direct"), "after_relay": side("relay"),
           "denials_logged": (out / "privacy-log.txt").read_text().count("\n") if (out / "privacy-log.txt").exists() else None}
(out / "demo.json").write_text(json.dumps(receipt, indent=2) + "\n")
print(json.dumps(receipt, indent=2))
b, a = receipt["before_direct"], receipt["after_relay"]
print(f"before (direct): {b['http_ok']}/{b['rounds']} reached; after (lan-dial relay): {a['http_ok']}/{a['rounds']} reached")
sys.exit(0 if a["http_ok"] == rounds else 1)
EOF
