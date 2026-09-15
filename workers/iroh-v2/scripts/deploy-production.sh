#!/usr/bin/env bash
set -euo pipefail

# Production Stack Auth is deliberately pinned to the production project. This
# probe catches a Worker whose secrets were accidentally populated from dev.
readonly account_id="${CLOUDFLARE_ACCOUNT_ID:-}"
readonly expected_account="0c1675e0def6de1ab3a50a4e17dc5656"
readonly expected_project="9790718f-14cd-4f7e-824d-eaf527a82b82"
readonly worker_name="cmux-iroh-v2"
readonly worker_url="https://cmux-iroh-v2.debussy.workers.dev"

if [[ "$account_id" != "$expected_account" ]]; then
  echo "refusing production deploy: set CLOUDFLARE_ACCOUNT_ID to the Manaflow account" >&2
  exit 2
fi

for command in python3 curl; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "refusing production deploy: required command not found: $command" >&2
    exit 2
  fi
done

bun run check
bun run test:runtime

probe_dir=$(mktemp -d "${TMPDIR:-/tmp}/iroh-v2-prod-probe.XXXXXX")
trap 'rm -rf "$probe_dir"' EXIT

# Keep the version that was live before this deploy. It is only eligible for
# rollback after its scope probe passes. Wrangler's rollback only changes
# Worker code and traffic, it does not undo Durable Object migrations or other
# bound-resource changes, so this is a recovery path for a bad Worker version.
if ! wrangler deployments status --env production --name "$worker_name" --json >"$probe_dir/previous-deployment.json"; then
  echo "refusing production deploy: could not read the current deployment" >&2
  exit 1
fi
if ! python3 - "$probe_dir/previous-deployment.json" "$probe_dir/previous-version" <<'PY_PREVIOUS'
import json, pathlib, sys
try:
    deployment = json.loads(pathlib.Path(sys.argv[1]).read_text())
    versions = deployment["versions"]
    active = [item["version_id"] for item in versions if item["percentage"] == 100]
    if len(active) != 1 or not active[0]:
        raise ValueError("deployment does not have one 100% version")
except (KeyError, TypeError, ValueError, OSError, json.JSONDecodeError):
    sys.exit(1)
pathlib.Path(sys.argv[2]).write_text(active[0])
PY_PREVIOUS
then
  echo "refusing production deploy: current deployment has no single active version" >&2
  exit 1
fi

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
  local name="$1" expected="$2" expected_error="$3"
  local code
  # Expected auth failures (401/403) are successful scope probes, so do not
  # use curl's --fail mode here. It turns those expected responses into exit 22.
  code=$(curl -sS --connect-timeout 10 --max-time 30 --max-filesize 65536 -o "$probe_dir/$name.response" -w '%{http_code}' \
    -X POST "$worker_url/v2/control/session" \
    -H 'content-type: application/json' \
    -H 'authorization: Bearer invalid-production-config-probe' \
    --data-binary "@$probe_dir/$name.json") || {
      echo "production config probe request failed ($name)" >&2
      return 1
    }
  if [[ "$code" != "$expected" ]]; then
    echo "production scope verification failed: $name returned HTTP $code, expected $expected" >&2
    return 1
  fi
  # Require our structured error, rather than an unrelated proxy's 401/403.
  # Never print a provider response body into deployment logs.
  if ! python3 - "$probe_dir/$name.response" "$expected_error" <<'PY_CHECK'
import json, pathlib, sys
try:
    value = json.loads(pathlib.Path(sys.argv[1]).read_text())
    valid = isinstance(value, dict) and value.get("schemaId") == "error.v1" and value.get("code") == sys.argv[2]
except (ValueError, OSError):
    valid = False
sys.exit(0 if valid else 1)
PY_CHECK
  then
    echo "production scope verification failed: $name returned an unexpected error response" >&2
    return 1
  fi
}

# Validate the version we would restore before changing traffic. If this fails,
# leave the currently running deployment untouched.
check_scope production 401 unauthorized
check_scope development 403 environment_mismatch

deployment_marker="cmux-prod-guard-$$"
wrangler deploy --env production --strict --message "$deployment_marker" --tag "$deployment_marker"

probe_failure=0
check_scope production 401 unauthorized || probe_failure=1
check_scope development 403 environment_mismatch || probe_failure=1
if (( probe_failure )); then
  rollback_safe=0
  # Roll back only while the current deployment still carries our unique
  # message/tag. A concurrent deploy changes this status and is left alone.
  if wrangler deployments status --env production --name "$worker_name" --json >"$probe_dir/current-deployment.json" \
    && python3 - "$probe_dir/current-deployment.json" "$deployment_marker" <<'PY_CURRENT'
import json, pathlib, sys
try:
    deployment = json.loads(pathlib.Path(sys.argv[1]).read_text())
    annotations = deployment.get("annotations") or {}
    marker = sys.argv[2]
    if marker not in (annotations.get("workers/message"), annotations.get("workers/tag")):
        raise ValueError("current deployment was replaced")
except (AttributeError, TypeError, ValueError, OSError, json.JSONDecodeError):
    sys.exit(1)
sys.exit(0)
PY_CURRENT
  then
    rollback_safe=1
  fi

  if (( rollback_safe )); then
    if wrangler rollback "$(<"$probe_dir/previous-version")" --env production --name "$worker_name" \
      --message "restore pre-deploy verified version after scope probe failure" --yes; then
      echo "production scope probe failed; restored the previously verified Worker version" >&2
    else
      echo "production scope probe failed and automatic rollback failed; inspect the Worker immediately" >&2
    fi
  else
    echo "production scope probe failed; current deployment changed after ours, so rollback was skipped" >&2
  fi
  exit 1
fi

echo "production Stack Auth scope probe passed"
