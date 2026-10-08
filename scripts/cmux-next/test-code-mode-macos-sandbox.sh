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
tmp_parent=${TMPDIR:-/tmp}
tmp_parent=${tmp_parent%/}
tmp="$(mktemp -d "$tmp_parent/cmux-code-mode-macos-smoke.XXXXXX")"
tmp=$(realpath "$tmp")
trap 'rm -rf "$tmp"' EXIT
mkdir -m 700 "$tmp/run" "$tmp/sdk" "$tmp/host-home"
printf '%s\n' secret >"$tmp/host-home/secret"
proxy_socket="$tmp/proxy.sock"
denied_socket="$tmp/denied.sock"
server="$tmp/socket-server.mjs"
script="$tmp/smoke.mjs"
profile="$tmp/profile.sb"

cat >"$server" <<'EOF_SERVER'
import net from "node:net";
const path = process.argv[2];
const echo = () => net.createServer((client) => client.on("data", (data) => client.write(data)));
const server = echo();
const denied = echo();
const tcp = echo();
await Promise.all([
  new Promise((resolve) => server.listen(path, resolve)),
  new Promise((resolve) => denied.listen(process.argv[3], resolve)),
  new Promise((resolve) => tcp.listen(0, "127.0.0.1", resolve)),
]);
process.stdout.write(`${tcp.address().port}\nready\n`);
EOF_SERVER

cat >"$script" <<'EOF_SCRIPT'
import net from "node:net";
import { promises as fs } from "node:fs";

const socketPath = process.env.SMOKE_SOCKET;
const writable = `${process.env.TMPDIR}/allowed.txt`;
const denied = process.env.SMOKE_DENIED;
const outside = process.env.SMOKE_OUTSIDE === "1";
if (!outside) {
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
}
for (const address of [process.env.SMOKE_DENIED_SOCKET, { host: "127.0.0.1", port: Number(process.env.SMOKE_DENIED_PORT) }]) {
  await new Promise((resolve, reject) => {
    const client = net.createConnection(address);
    const timer = setTimeout(() => { client.destroy(); reject(new Error("denial probe timed out")); }, 2000);
    client.once("connect", () => {
      clearTimeout(timer);
      client.destroy();
      if (outside) resolve();
      else reject(new Error("sandbox allowed an unapproved network endpoint"));
    });
    client.once("error", (error) => {
      clearTimeout(timer);
      client.destroy();
      if (outside) { reject(error); return; }
      // Seatbelt hides the unapproved Unix socket from path lookup; the host
      // verifies it exists before this probe, so ENOENT also proves denial.
      if (error.code === "EACCES" || error.code === "EPERM" || (typeof address === "string" && error.code === "ENOENT") || (typeof address !== "string" && error.code === "ECONNREFUSED")) resolve();
      else reject(error);
    });
  });
}
EOF_SCRIPT

"$bun" "$server" "$proxy_socket" "$denied_socket" >"$tmp/server.log" 2>&1 &
server_pid=$!
cleanup_server() { kill "$server_pid" 2>/dev/null || true; wait "$server_pid" 2>/dev/null || true; }
trap 'cleanup_server; rm -rf "$tmp"' EXIT
# Bun can take a few seconds to cold-start on a newly allocated runner.
for _ in $(seq 1 500); do
  grep -q '^ready$' "$tmp/server.log" && break
  kill -0 "$server_pid" 2>/dev/null || { cat "$tmp/server.log" >&2; exit 1; }
  sleep 0.01
done
grep -q '^ready$' "$tmp/server.log" || { echo "socket server did not start" >&2; exit 1; }
[[ -S "$denied_socket" ]]
denied_port=$(head -n 1 "$tmp/server.log")
# The same probes must connect outside Seatbelt before their denial can count.
SMOKE_OUTSIDE=1 SMOKE_DENIED_SOCKET="$denied_socket" SMOKE_DENIED_PORT="$denied_port" "$bun" "$script"

"$profile_helper" "$profile" "$bun" "$tmp/sdk" "$script" "$proxy_socket" "$tmp/run"
# Keep this assertion close to the invocation so a future profile cannot silently
# become permissive while the smoke still passes.
grep -q '^(deny default)$' "$profile"
if grep -Fq 'network-outbound (**)' "$profile"; then
  echo "sandbox profile grants broad network access" >&2
  exit 1
fi

# Use an existing host-home file outside the allowlist, so a missing file cannot
# make the denial assertion pass accidentally.
(
  cd "$tmp/run"
  exec env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  HOME="$tmp/run" TMPDIR="$tmp/run" \
  SMOKE_SOCKET="$proxy_socket" SMOKE_DENIED="$tmp/host-home/secret" \
  SMOKE_DENIED_SOCKET="$denied_socket" SMOKE_DENIED_PORT="$denied_port" \
  "$sandbox_exec" -f "$profile" "$bun" "$script"
)

[[ -f "$tmp/run/allowed.txt" ]]
echo "macOS Seatbelt smoke passed on $(sw_vers -productVersion)"
