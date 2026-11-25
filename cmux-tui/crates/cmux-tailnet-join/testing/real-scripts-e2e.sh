#!/usr/bin/env bash
# Runs headscale-e2e.sh with this crate's own join and leave scripts (the ones `cmux vm tailnet
# join|leave` sends a VM), rendered by `cargo run --example join_script`. Throwaway tailnet only:
# headscale and every node are docker containers; the host's tailscaled is never touched.
# Usage: cmux-tui/crates/cmux-tailnet-join/testing/real-scripts-e2e.sh
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
req='{"credential":{"kind":"auth_key","key":"rendered-only-never-sent"},"controlUrl":"http://headscale:8080","allowHttp":true,"hostname":"cmux-vm-test","ssh":true,"serve":[{"localPort":8000,"httpsPort":80}]}'
(cd "$here/../../.." && printf '%s' "$req" | cargo run -q -p cmux-tailnet-join --example join_script) >"$work/join.sh"
(cd "$here/../../.." && printf '%s' "$req" | cargo run -q -p cmux-tailnet-join --example join_script leave) >"$work/leave.sh"
# The harness mounts the key read-only; the real script reads (and deletes) a writable copy.
{
  cat <<'EOF'
#!/bin/sh
set -eu
mkdir -p /srv/www /run/cmux-join
echo "cmux-tailnet-e2e served page" >/srv/www/index.html
(cd /srv/www && nohup python3 -m http.server 8000 --bind 127.0.0.1 >/var/log/http.log 2>&1 &)
cp /run/cmux-tailnet/authkey /run/cmux-join/authkey && chmod 600 /run/cmux-join/authkey
cat >/root/real.sh <<'REAL'
EOF
  sed 's|/run/cmux-tailnet/authkey|/run/cmux-join/authkey|g' "$work/join.sh"
  cat <<'EOF'
REAL
sh /root/real.sh >/root/join.out
test ! -e /run/cmux-join/authkey || { echo "the join left its key file" >&2; exit 1; }
grep -q '^cmux-tailnet-joined ' /root/join.out
EOF
} >"$work/wrap.sh"
chmod +x "$work/wrap.sh" "$work/leave.sh"
JOIN_SCRIPT="$work/wrap.sh" LEAVE_SCRIPT="$work/leave.sh" "$here/headscale-e2e.sh"
