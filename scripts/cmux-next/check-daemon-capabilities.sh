#!/usr/bin/env bash
# Fails when a cmux-tui binary does not serve a daemon capability the
# cmux-next app relies on, so no build ships a feature gated on a capability
# its bundled daemon lacks.
#
# The app's list is plans/cmux-next/daemon-capabilities.json, exported from
# enum DaemonCapability (Packages/macOS/CmuxNext/Sources/CmuxNextDaemon/
# Connection/DaemonEndpoint.swift) by DaemonCapabilityExportTests, which fails
# when the file is stale:
#   required, optional         the binary must serve every one (error)
#   unservedByBundledDaemon    app code that waits for a daemon half no
#                              branch has yet; reported, and an error once the
#                              binary serves one (move it to `optional`)
# Capabilities the binary serves that the app does not use are fine.
#
# Before it starts a daemon it runs check-app-capability-references.py, which
# finds every capability the app's Swift code references (not only the lists)
# and fails when one is neither defined by the daemon source nor declared as
# unserved, or is a daemon capability missing from the lists.
#
# It starts the binary as an isolated daemon (temporary HOME, TMPDIR and
# CMUX_TUI_STATE_DIR, `server ensure` with the app's reap grace, bound to this
# script's pid), sends a raw `identify` over its
# socket, and stops it (`server stop --end-terminals`). Distribution workflows
# use `--static-only` so runtime checks stay in the daemon integration lane.
#
# The Xcode "Bundle cmux-tui" phase runs it on every non-release bundle, and
# the cmux-next workflow runs it on the same-tree binary.
#
# Usage: check-daemon-capabilities.sh [--binary <cmux-tui>] [--capabilities <json>] [--static-only]
#   default binary: scripts/cmux-next/pin-cmux-tui.sh path (this tree's binary)
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
binary=""
capabilities="$repo_root/plans/cmux-next/daemon-capabilities.json"
static_only=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --binary) binary="${2:?--binary needs a path}"; shift 2 ;;
    --capabilities) capabilities="${2:?--capabilities needs a path}"; shift 2 ;;
    --static-only) static_only=true; shift ;;
    -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
    *) echo "usage: check-daemon-capabilities.sh [--binary <cmux-tui>] [--capabilities <json>] [--static-only]" >&2; exit 2 ;;
  esac
done
[[ -n "$binary" ]] || binary="$("$script_dir/pin-cmux-tui.sh" path)"
[[ -x "$binary" ]] || { echo "check-daemon-capabilities: $binary is not an executable cmux-tui (scripts/cmux-next/pin-cmux-tui.sh fetch)" >&2; exit 2; }
[[ -f "$capabilities" ]] || { echo "check-daemon-capabilities: $capabilities is missing" >&2; exit 2; }

# The list above is written by hand. check-app-capability-references.py reads
# the app's Swift sources and the daemon's Rust sources (no build, about 3 s)
# and fails when the app gates on a capability the daemon source never defines,
# or references a daemon capability the list leaves out (so this identify
# check would not cover it). Release builds check a pinned binary below; the
# source check still reads this tree.
if [[ -d "$repo_root/Packages/macOS/CmuxNext/Sources" && -d "$repo_root/cmux-tui/crates/cmux-tui-core" ]]; then
  python3 -I "$script_dir/check-app-capability-references.py" --repo "$repo_root"
else
  echo "check-daemon-capabilities: note: no app or cmux-tui-core source under $repo_root; skipped check-app-capability-references.py"
fi

if [[ "$static_only" = true ]]; then
  # install-cmux-tui-client.sh and bundle-cmux-tui.sh generate this manifest
  # directly from the exact binary (`__daemon-capabilities --json`). Validate
  # that signed artifact's advertised static set without starting a daemon.
  # `required` is the unconditional publication contract. Most `optional`
  # entries are also static, but this explicit set is installed only when the
  # daemon has a runtime service/configuration; those remain covered by the
  # daemon integration lane.
  manifest="$(dirname "$binary")/daemon-capabilities.json"
  [[ -f "$manifest" ]] || {
    echo "check-daemon-capabilities: $manifest is missing; regenerate it from the installed binary" >&2
    exit 1
  }
  python3 - "$manifest" "$capabilities" <<'PY'
import json
import sys

manifest_path, required_path = sys.argv[1:]
manifest = json.load(open(manifest_path, encoding="utf-8"))
served = set(manifest.get("cmuxTui") or [])
if not served:
    raise SystemExit(f"check-daemon-capabilities: {manifest_path} has no cmuxTui capability list")
required = json.load(open(required_path, encoding="utf-8"))
runtime_only = {
    "agent-inventory-watch-admission-v1", "agent-inventory-watch-v1",
    "agent-session-attach-v1", "agent-session-children-v1", "agent-session-folders-v1", "agent-session-observe-v1",
    "agent-session-presence-v1", "agent-session-settings-v1", "agent-session-start-keyed-reason-v1", "agent-session-start-v1",
    "agent-session-start-vm-kind-v1", "agent-session-start-model-v1", "agent-session-trust-v1", "agent-session-trust-vm-kind-v1",
    "cloud-attachments-v1", "cloud-chief-live-v1",
    "cloud-conversation-runs-v1", "cloud-conversation-typing-v1", "cloud-conversations-v1",
    "cloud-host-replica-v1", "cloud-selfhost-v1", "history-v1", "terminal-reaper-active-v1",
    "ws-listen-v1", "ws-listen-origins-v1",
}
needed = (set(required.get("required", [])) | set(required.get("optional", []))) - runtime_only
missing = sorted(needed - served)
if missing:
    raise SystemExit("check-daemon-capabilities: the bundled static capability manifest is missing " + ", ".join(missing))
print(f"check-daemon-capabilities: static bundled manifest serves all {len(needed)} needed capabilities ({len(served)} served)")
PY
  echo "check-daemon-capabilities: runtime daemon probe is reserved for integration tests"
  exit 0
fi

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

# With a reap grace, as DaemonLauncher starts the app's owner, so the
# conditional terminal-reaper-active-v1 is served. Bound to this script
# (`--exit-with-pid $$`): when the script is killed before its EXIT trap runs
# (a cancelled job or build phase), the probe owner ends its terminals and
# exits instead of running for hours (HQ REPAIR.md "Orphaned cmux-tui holds
# runner dirs"). Only a binary older than the option (its parser's
# unknown-option error) is probed unbound; the trap still stops it. Any other
# failure fails the check with the bound attempt's error.
ensure=(server ensure --terminal-reap-grace-seconds 30)
unknown_option='--exit-with-pid needs a value, or is not an option of this action|unknown flag --exit-with-pid'
if ! ensured="$(run_binary "${ensure[@]}" --exit-with-pid "$$" 2>"$root/ensure.err")" \
  && ! { grep -qE -- "$unknown_option" "$root/ensure.err" \
    && ensured="$(run_binary "${ensure[@]}" 2>"$root/ensure-unbound.err")"; }; then
  echo "check-daemon-capabilities: $binary server ensure failed:" >&2
  cat "$root/ensure.err" >&2
  [[ -s "$root/ensure-unbound.err" ]] && cat "$root/ensure-unbound.err" >&2
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
both = sorted(set(needed) & set(unserved_list))
if both:
    failed = True
    print("check-daemon-capabilities: error: " + ", ".join(both)
          + " is in required/optional AND in unservedByBundledDaemon; keep it in one list "
          "(unservedByBundledDaemon until the bundled daemon serves it)", file=sys.stderr)
    missing = [c for c in missing if c not in both]
if missing:
    failed = True
    print("check-daemon-capabilities: error: the bundled cmux-tui does not serve "
          + ", ".join(missing), file=sys.stderr)
    print("  Every capability in DaemonCapability.required/optional must be served by the same-tree daemon.",
          file=sys.stderr)
    print("  Land the daemon change on this branch, or remove the app's use of the capability.", file=sys.stderr)
if now_served:
    failed = True
    print("check-daemon-capabilities: error: the bundled cmux-tui now serves "
          + ", ".join(now_served)
          + "; move them from the unservedByBundledDaemon arm of DaemonCapability.tier to optional", file=sys.stderr)
if not failed:
    print(f"check-daemon-capabilities: PASS: {binary} serves all {len(needed)} needed capabilities "
          f"({len(served)} served)")
sys.exit(1 if failed else 0)
PY
