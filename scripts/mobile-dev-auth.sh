#!/usr/bin/env bash
# Registers an Android access token with the cmux Mac debug app so that
# Android RPCs are accepted without the Mac needing to be signed in.
# This uses the DEBUG-only mobile.dev_stack_auth.configure socket command.
#
# Usage:
#   CMUX_TAG=first-run ./scripts/mobile-dev-auth.sh <access_token>
#   CMUX_TAG=first-run ./scripts/mobile-dev-auth.sh --disable

set -euo pipefail

if [[ -z "${CMUX_TAG:-}" ]]; then
  cat >&2 <<'EOF'
CMUX_TAG is required.

Usage:
  CMUX_TAG=<tag> scripts/mobile-dev-auth.sh <access_token>
  CMUX_TAG=<tag> scripts/mobile-dev-auth.sh --disable
EOF
  exit 1
fi

if [[ $# -lt 1 ]]; then
  echo "Usage: CMUX_TAG=$CMUX_TAG $0 <access_token>" >&2
  echo "       CMUX_TAG=$CMUX_TAG $0 --disable" >&2
  exit 1
fi

token_arg="$1"

# Match cmux-debug-cli.sh slug sanitization
tag_slug="$(printf '%s' "$CMUX_TAG" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
socket_path="/tmp/cmux-debug-${tag_slug}.sock"

if [[ ! -S "$socket_path" ]]; then
  cat >&2 <<EOF
cmux debug socket not found: $socket_path

Launch the tagged debug app first:
  ./scripts/reload.sh --tag $CMUX_TAG --launch
EOF
  exit 1
fi

python3 - "$token_arg" "$socket_path" <<'PYEOF'
import socket, json, uuid, sys

token_arg = sys.argv[1]
sock_path = sys.argv[2]

if token_arg == "--disable":
    params: dict = {"enabled": False}
else:
    params = {"enabled": True, "token": token_arg}

cmd = json.dumps({
    "id": str(uuid.uuid4()),
    "method": "mobile.dev_stack_auth.configure",
    "params": params,
})

s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(sock_path)
s.settimeout(5.0)
s.sendall((cmd + "\n").encode())

resp = b""
while True:
    chunk = s.recv(4096)
    if not chunk:
        break
    resp += chunk
    if b"\n" in resp:
        break
s.close()

result = json.loads(resp.decode().strip())
if result.get("ok"):
    r = result.get("result", {})
    if r.get("enabled"):
        prefix = r.get("token_prefix", "?")
        print(f"Mac debug app will now accept tokens starting with: {prefix}...")
    else:
        print("Dev Stack Auth bypass disabled.")
else:
    err = result.get("error", {})
    print(f"Error: {err.get('message', result)}", file=sys.stderr)
    sys.exit(1)
PYEOF
