#!/usr/bin/env bash
# Fails when a cmux-tui binary does not serve a daemon capability the
# cmux-next app relies on, so no build ships a feature gated on a capability
# its bundled daemon lacks.
#
# The app's list is plans/cmux-next/daemon-capabilities.json, exported from
# DaemonCapabilities (Packages/macOS/CmuxNext/Sources/CmuxNextDaemon/
# Connection/DaemonEndpoint.swift) by DaemonCapabilityExportTests, which fails
# when the file is stale:
#   required, optional         the binary must serve every one (error)
#   unservedByBundledDaemon    app code that waits for a daemon half no
#                              branch has yet; reported, and an error once the
#                              binary serves one (move it to `optional`)
# Capabilities the binary serves that the app does not use are fine.
#
# It starts the binary as an isolated daemon (temporary HOME, TMPDIR and
# CMUX_TUI_STATE_DIR, `server ensure`), sends a raw `identify` over its
# socket, and stops it (`server stop --end-terminals`).
#
# The Xcode "Bundle cmux-tui" phase runs it on every non-release bundle, and
# the cmux-next workflow runs it on the same-tree binary.
#
# Usage: check-daemon-capabilities.sh [--binary <cmux-tui>] [--capabilities <json>]
#   default binary: scripts/cmux-next/pin-cmux-tui.sh path (this tree's binary)
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
binary=""
capabilities="$repo_root/plans/cmux-next/daemon-capabilities.json"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --binary) binary="${2:?--binary needs a path}"; shift 2 ;;
    --capabilities) capabilities="${2:?--capabilities needs a path}"; shift 2 ;;
    -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
    *) echo "usage: check-daemon-capabilities.sh [--binary <cmux-tui>] [--capabilities <json>]" >&2; exit 2 ;;
  esac
done
[[ -n "$binary" ]] || binary="$("$script_dir/pin-cmux-tui.sh" path)"
[[ -x "$binary" ]] || { echo "check-daemon-capabilities: $binary is not an executable cmux-tui (scripts/cmux-next/pin-cmux-tui.sh fetch)" >&2; exit 2; }
[[ -f "$capabilities" ]] || { echo "check-daemon-capabilities: $capabilities is missing" >&2; exit 2; }

# A short private root: the daemon's socket path must fit sun_path (104 bytes).
root="$(mktemp -d /tmp/cdc.XXXXXX)"
session="cdc-$$"
mkdir -p "$root/home" "$root/state"
chmod 700 "$root/state"
run_binary() {
  env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$root/home" TMPDIR="$root" \
    CMUX_TUI_STATE_DIR="$root/state" CMUX_TUI_CONFIG="$root/home/no-config.toml" \
    "$binary" --session "$session" --json "$@"
}
cleanup() {
  if ! run_binary server stop --end-terminals >/dev/null 2>&1 && ! run_binary server stop --force >/dev/null 2>&1; then
    # Never leave the probe daemon running: stop it by the pid ensure printed.
    pid="$(cat "$root/pid" 2>/dev/null || true)"
    [[ "$pid" =~ ^[0-9]+$ ]] && kill "$pid" 2>/dev/null || true
  fi
  rm -rf "$root"
}
trap cleanup EXIT

if ! ensured="$(run_binary server ensure 2>"$root/ensure.err")"; then
  echo "check-daemon-capabilities: $binary server ensure failed:" >&2
  cat "$root/ensure.err" >&2
  exit 1
fi
printf '%s\n' "$ensured" | python3 -c 'import json,sys
lines=[l for l in sys.stdin if l.strip().startswith("{")]
print(json.loads(lines[-1]).get("pid") or "" if lines else "")' > "$root/pid" 2>/dev/null || true

python3 -u - "$capabilities" "$binary" "$ensured" <<'PY'
import json, socket, sys

capabilities_path, binary, ensured = sys.argv[1:4]
lines = [line for line in ensured.splitlines() if line.strip().startswith("{")]
if not lines:
    sys.exit(f"check-daemon-capabilities: server ensure printed no endpoint: {ensured!r}")
endpoint = json.loads(lines[-1])
path = endpoint.get("socket")
if not path:
    sys.exit(f"check-daemon-capabilities: server ensure printed no socket: {lines[-1]}")

sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.settimeout(15)
sock.connect(path)
sock.sendall(b'{"id":1,"cmd":"identify"}\n')
buffer = b""
reply = None
while reply is None:
    while b"\n" not in buffer:
        chunk = sock.recv(1 << 20)
        if not chunk:
            sys.exit("check-daemon-capabilities: socket closed before the identify reply")
        buffer += chunk
    line, buffer = buffer.split(b"\n", 1)
    message = json.loads(line)
    if message.get("id") == 1:
        reply = message
sock.close()
if not reply.get("ok"):
    sys.exit(f"check-daemon-capabilities: identify failed: {reply.get('error')}")
identity = reply.get("data") or {}
served = set(identity.get("capabilities") or [])

app = json.load(open(capabilities_path))
needed = list(app.get("required", [])) + list(app.get("optional", []))
unserved_list = list(app.get("unservedByBundledDaemon", []))
missing = [c for c in needed if c not in served]
now_served = [c for c in unserved_list if c in served]
still_unserved = [c for c in unserved_list if c not in served]

build = identity.get("build_commit") or identity.get("version") or "?"
print(f"check-daemon-capabilities: {binary} (build {build}) serves {len(served)} capabilities; "
      f"the app needs {len(needed)}")
if still_unserved:
    print("check-daemon-capabilities: note: app features waiting for a daemon half (disabled with a reason): "
          + ", ".join(still_unserved))
failed = False
if missing:
    failed = True
    print("check-daemon-capabilities: error: the bundled cmux-tui does not serve "
          + ", ".join(missing), file=sys.stderr)
    print("  Every capability in DaemonCapabilities.required/optional must be served by the same-tree daemon.",
          file=sys.stderr)
    print("  Land the daemon change on this branch, or remove the app's use of the capability.", file=sys.stderr)
if now_served:
    failed = True
    print("check-daemon-capabilities: error: the bundled cmux-tui now serves "
          + ", ".join(now_served)
          + "; move them from DaemonCapabilities.unservedByBundledDaemon to optional", file=sys.stderr)
sys.exit(1 if failed else 0)
PY
