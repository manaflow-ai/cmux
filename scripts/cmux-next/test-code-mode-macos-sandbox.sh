#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != Darwin ]]; then
  echo "macOS Seatbelt smoke: skipped outside macOS"
  exit 0
fi

sandbox_exec=/usr/bin/sandbox-exec
[[ -x "$sandbox_exec" ]] || { echo "sandbox-exec is unavailable" >&2; exit 1; }
bun="$(command -v bun || true)"
[[ -n "$bun" ]] || { echo "bun is required" >&2; exit 1; }

root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
profile_helper="$root/scripts/cmux-next/cmux-code-mode-macos-profile"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/cmux-code-mode-macos-smoke.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
mkdir -m 700 "$tmp/run" "$tmp/sdk" "$tmp/host-home"
printf '%s\n' secret >"$tmp/host-home/secret"
proxy_socket="$tmp/proxy.sock"
server="$tmp/socket-server.mjs"
script="$tmp/smoke.mjs"
profile="$tmp/profile.sb"

cat >"$server" <<'EOF_SERVER'
import net from "node:net";
const path = process.argv[2];
const server = net.createServer((client) => client.on("data", (data) => client.write(data)));
server.listen(path, () => process.stdout.write("ready\n"));
EOF_SERVER

cat >"$script" <<'EOF_SCRIPT'
import net from "node:net";
import { promises as fs } from "node:fs";

const socketPath = process.env.SMOKE_SOCKET;
const writable = `${process.env.TMPDIR}/allowed.txt`;
const denied = process.env.SMOKE_DENIED;
await new Promise((resolve, reject) => {
  const client = net.createConnection(socketPath, () => client.write("seatbelt-smoke"));
  client.once("data", (data) => {
    if (data.toString() !== "seatbelt-smoke") reject(new Error("socket reply mismatch"));
    else { client.end(); resolve(); }
  });
  client.once("error", reject);
});
await fs.writeFile(writable, "allowed");
if ((await fs.readFile(writable, "utf8")) !== "allowed") throw new Error("temporary write failed");
let deniedRead = false;
try { await fs.readFile(denied); } catch { deniedRead = true; }
if (!deniedRead) throw new Error("sandbox allowed an arbitrary host file read");
EOF_SCRIPT

"$bun" "$server" "$proxy_socket" >"$tmp/server.log" 2>&1 &
server_pid=$!
cleanup_server() { kill "$server_pid" 2>/dev/null || true; wait "$server_pid" 2>/dev/null || true; }
trap 'cleanup_server; rm -rf "$tmp"' EXIT
for _ in $(seq 1 100); do
  grep -q '^ready$' "$tmp/server.log" && break
  kill -0 "$server_pid" 2>/dev/null || { cat "$tmp/server.log" >&2; exit 1; }
  sleep 0.01
done
grep -q '^ready$' "$tmp/server.log" || { echo "socket server did not start" >&2; exit 1; }

"$profile_helper" "$profile" "$bun" "$tmp/sdk" "$script" "$proxy_socket" "$tmp/run"
# Keep this assertion close to the invocation so a future profile cannot silently
# become permissive while the smoke still passes.
grep -q '^(deny default)$' "$profile"
if grep -q 'network-outbound (**)' "$profile"; then
  echo "sandbox profile grants broad network access" >&2
  exit 1
fi

# Use an existing host-home file outside the allowlist, so a missing file cannot
# make the denial assertion pass accidentally.
env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  HOME="$tmp/host-home" TMPDIR="$tmp/run" \
  SMOKE_SOCKET="$proxy_socket" SMOKE_DENIED="$tmp/host-home/secret" \
  "$sandbox_exec" -f "$profile" "$bun" "$script"

[[ -f "$tmp/run/allowed.txt" ]]
echo "macOS Seatbelt smoke passed on $(sw_vers -productVersion)"
