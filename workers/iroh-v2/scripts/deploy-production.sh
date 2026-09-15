#!/usr/bin/env bash
set -euo pipefail

# Production Stack Auth is deliberately pinned to the production project. This
# probe catches a Worker whose secrets were accidentally populated from dev.
readonly account_id="${CLOUDFLARE_ACCOUNT_ID:-}"
readonly expected_account="0c1675e0def6de1ab3a50a4e17dc5656"
readonly expected_project="9790718f-14cd-4f7e-824d-eaf527a82b82"
readonly worker_url="https://cmux-iroh-v2.debussy.workers.dev"

if [[ "$account_id" != "$expected_account" ]]; then
  echo "refusing production deploy: set CLOUDFLARE_ACCOUNT_ID to the Manaflow account" >&2
  exit 2
fi

bun run check
bun run test:runtime
wrangler deploy --env production

probe_dir=$(mktemp -d "${TMPDIR:-/tmp}/iroh-v2-prod-probe.XXXXXX")
trap 'rm -rf "$probe_dir"' EXIT
python3 - "$probe_dir" "$expected_project" <<'PY'
import json, pathlib, sys, uuid
out = pathlib.Path(sys.argv[1])
project = sys.argv[2]
base = {
  "schemaId": "session.open.v1",
  "requestId": str(uuid.uuid4()),
  "device": {
    "identity": {
      "environment": "production", "projectId": project,
      "teamId": "production-config-probe", "userId": "production-config-probe",
      "deviceId": "production-config-probe", "appNamespace": "com.cmux.config.probe", "buildTag": "probe"
    },
    "endpointId": "a" * 64, "identityGeneration": 0,
    "metadata": {"platform": "ios", "displayName": "probe", "appVersion": "1", "pairingEnabled": True, "capabilities": [], "relayURLs": []}
  }
}
out.joinpath("production.json").write_text(json.dumps(base))
base["device"]["identity"]["environment"] = "development"
base["device"]["identity"]["projectId"] = "454ecd03-1db2-4050-845e-4ce5b0cd9895"
out.joinpath("development.json").write_text(json.dumps(base))
PY

check_scope() {
  local name="$1" expected="$2"
  local code
  code=$(curl --fail-with-body -sS -o "$probe_dir/$name.response" -w '%{http_code}' \
    -X POST "$worker_url/v2/control/session" \
    -H 'content-type: application/json' \
    -H 'authorization: Bearer invalid-production-config-probe' \
    --data-binary "@$probe_dir/$name.json") || {
      echo "production config probe request failed ($name)" >&2
      return 1
    }
  if [[ "$code" != "$expected" ]]; then
    echo "refusing production deploy: $name scope returned HTTP $code, expected $expected" >&2
    cat "$probe_dir/$name.response" >&2
    return 1
  fi
}

check_scope production 401
check_scope development 403
echo "production Stack Auth scope probe passed"
