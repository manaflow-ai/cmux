#!/usr/bin/env bash
# Provision one isolated dev backend through the VM's loopback control API.
# The only network path from CI is Tailscale SSH as ubuntu; no deploy key or
# public control port is used. Print only the resulting Serve URL.
set -euo pipefail

TAG="${CMUX_E2E_BACKEND_TAG:?CMUX_E2E_BACKEND_TAG is required}"
HOST="${CMUX_E2E_BACKEND_HOST:?CMUX_E2E_BACKEND_HOST is required}"
RUN_ID="${GITHUB_RUN_ID:?GITHUB_RUN_ID is required}"
COMMIT="${GITHUB_SHA:?GITHUB_SHA is required}"
REMOTE_BASE="${CMUX_E2E_REMOTE_BASE:-/srv/cmux-dev}"
REMOTE_USER="${CMUX_E2E_BACKEND_USER:-ubuntu}"
REMOTE_INCOMING="$REMOTE_BASE/incoming"
REMOTE_API="http://127.0.0.1:8477"
SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=2)

[[ "$TAG" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || { echo "invalid backend tag" >&2; exit 2; }
[[ "$HOST" == *.tail137216.ts.net ]] || { echo "invalid backend host" >&2; exit 2; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEMP_ROOT="$(mktemp -d "${RUNNER_TEMP:-/tmp}/cmux-e2e-backend.XXXXXX")"
trap 'rm -rf "$TEMP_ROOT"' EXIT
ARCHIVE="$TEMP_ROOT/source.tar.gz"
python3 "$ROOT/scripts/e2e/backend-archive.py" "$ROOT" "$ARCHIVE"
SHA256="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
ARCHIVE_NAME="cmux-e2e-${RUN_ID}-${SHA256:0:16}.tar.gz"

ssh "${SSH_OPTS[@]}" "$REMOTE_USER@$HOST" "install -d -m 700 '$REMOTE_INCOMING'"
base64 < "$ARCHIVE" | ssh "${SSH_OPTS[@]}" "$REMOTE_USER@$HOST" \
  "base64 --decode > '$REMOTE_INCOMING/$ARCHIVE_NAME' && chmod 600 '$REMOTE_INCOMING/$ARCHIVE_NAME'"

INSTANCE_ID="ci-e2e-${RUN_ID}"
BODY="$(python3 - "$TAG" "$INSTANCE_ID" "$COMMIT" "$ARCHIVE_NAME" "$SHA256" <<'PY'
import json, sys
tag, instance_id, commit, archive, digest = sys.argv[1:]
print(json.dumps({
    "tag": tag,
    "instance_id": instance_id,
    "branch": "github-actions",
    "commit": commit,
    "archive": archive,
    "source_sha256": digest,
    "wait": 30,
    "transport": "direct",
}))
PY
)"

response="$(printf '%s' "$BODY" | ssh "${SSH_OPTS[@]}" "$REMOTE_USER@$HOST" \
  "curl --fail-with-body --silent --show-error --connect-timeout 10 --max-time 900 -X POST -H Content-Type:application/json --data-binary @- '$REMOTE_API/provision'")" || {
  ssh "${SSH_OPTS[@]}" "$REMOTE_USER@$HOST" "rm -f '$REMOTE_INCOMING/$ARCHIVE_NAME'" >/dev/null 2>&1 || true
  echo "backend provisioning failed" >&2
  exit 1
}

URL="$(jq -er '.url' <<<"$response")"
[[ "$URL" =~ ^https://cmux-dev-backend-1\.tail137216\.ts\.net:(3[89][0-9][0-9]|4[0-7][0-9][0-9])/$ ]] || {
  echo "backend returned an invalid Serve URL" >&2
  exit 1
}
printf '%s\n' "$URL"
