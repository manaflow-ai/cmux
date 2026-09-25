#!/usr/bin/env bash
set -euo pipefail

# The production deployment is pinned to the expected project and account. The
# scope probes catch a Worker whose production secrets were populated from dev.
readonly account_id="${CLOUDFLARE_ACCOUNT_ID:-}"
readonly expected_account="0c1675e0def6de1ab3a50a4e17dc5656"
readonly environment="${1:-production}"
case "$environment" in
  production)
    expected_project="9790718f-14cd-4f7e-824d-eaf527a82b82"
    worker_name="cmux-v2"
    foreign_environment="development"
    foreign_project="454ecd03-1db2-4050-845e-4ce5b0cd9895"
    ;;
  staging)
    expected_project="454ecd03-1db2-4050-845e-4ce5b0cd9895"
    worker_name="cmux-v2-staging"
    foreign_environment="production"
    foreign_project="9790718f-14cd-4f7e-824d-eaf527a82b82"
    ;;
  *) echo "refusing deployment: unsupported environment" >&2; exit 2 ;;
esac
readonly worker_url="https://${worker_name}.debussy.workers.dev"

if [[ "$account_id" != "$expected_account" ]]; then
  echo "refusing production deploy: invalid production account configuration" >&2
  exit 2
fi

for command in python3 curl; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "refusing production deploy: required command not found: $command" >&2
    exit 2
  fi
done

bun scripts/rollout-policy.ts target "$environment"
source_revision_vars="$(bash scripts/source-revision-vars.sh)"
if [[ "$source_revision_vars" == *:unknown ]]; then
  echo "refusing deployment: the Worker source must be clean and committed" >&2
  exit 1
fi
if [[ "$environment" == "production" ]] && ! git merge-base --is-ancestor "${source_revision_vars##*:}" origin/main; then
  echo "refusing production deploy: source revision is not on fetched origin/main" >&2
  exit 1
fi
bun run check
bun run test:runtime

probe_dir=$(mktemp -d "${TMPDIR:-/tmp}/iroh-v2-prod-probe.XXXXXX")
trap 'rm -rf "$probe_dir"' EXIT

capture_deployment() {
  local deployment_path="$1" version_path="$2" identity_path="$3"
  if ! wrangler deployments status --env "$environment" --name "$worker_name" --json >"$deployment_path"; then
    return 1
  fi
  python3 - "$deployment_path" "$version_path" "$identity_path" <<'PY_DEPLOYMENT'
import json, pathlib, sys
try:
    deployment = json.loads(pathlib.Path(sys.argv[1]).read_text())
    versions = deployment["versions"]
    active = [item["version_id"] for item in versions if item["percentage"] == 100]
    if len(active) != 1 or not active[0]:
        raise ValueError("deployment does not have one active version")
    identity = {
        "created_on": deployment["created_on"],
        "versions": sorted(versions, key=lambda item: item["version_id"]),
    }
except (KeyError, TypeError, ValueError, OSError, json.JSONDecodeError):
    sys.exit(1)
pathlib.Path(sys.argv[2]).write_text(active[0])
pathlib.Path(sys.argv[3]).write_text(json.dumps(identity, sort_keys=True, separators=(",", ":")))
PY_DEPLOYMENT
}

same_deployment() {
  python3 - "$1" "$2" <<'PY_SAME_DEPLOYMENT'
import pathlib, sys
try:
    before = pathlib.Path(sys.argv[1]).read_text()
    after = pathlib.Path(sys.argv[2]).read_text()
except OSError:
    sys.exit(1)
sys.exit(0 if before == after else 1)
PY_SAME_DEPLOYMENT
}

check_pending_migration() {
  python3 - "$1" wrangler.jsonc <<'PY_MIGRATION'
import json, pathlib, sys
try:
    version = json.loads(pathlib.Path(sys.argv[1]).read_text())
    config = json.loads(pathlib.Path(sys.argv[2]).read_text())
    production = config.get("env", {}).get("production", {})
    migrations = production.get("migrations", config.get("migrations", []))
    latest = migrations[-1].get("tag") if migrations else None
    current = version.get("migration_tag")
    if current is None:
        resources = version.get("resources", {})
        for resource_name in ("script", "script_runtime"):
            resource = resources.get(resource_name, {})
            if isinstance(resource, dict) and resource.get("migration_tag") is not None:
                current = resource["migration_tag"]
                break
    if latest is not None and current != latest:
        raise ValueError("pending Durable Object migration")
except (KeyError, TypeError, ValueError, OSError, json.JSONDecodeError, IndexError):
    sys.exit(1)
sys.exit(0)
PY_MIGRATION
}

python3 - "$probe_dir" "$expected_project" "$environment" "$foreign_environment" "$foreign_project" <<'PY_PAYLOADS'
import json, pathlib, sys, uuid
out = pathlib.Path(sys.argv[1])
project = sys.argv[2]
base = {
  "schemaId": "session.open.v1",
  "requestId": str(uuid.uuid4()),
  "device": {
    "identity": {
      "environment": sys.argv[3], "projectId": project,
      "teamId": "production-config-probe", "userId": "production-config-probe",
      "deviceId": "production-config-probe", "appNamespace": "com.cmux.config.probe", "buildTag": "probe"
    },
    "endpointId": "a" * 64, "identityGeneration": 0,
    "metadata": {"platform": "ios", "displayName": "probe", "appVersion": "1", "pairingEnabled": True, "capabilities": [], "relayURLs": []}
  }
}
out.joinpath("production.json").write_text(json.dumps(base))
base["device"]["identity"]["environment"] = sys.argv[4]
base["device"]["identity"]["projectId"] = sys.argv[5]
out.joinpath("development.json").write_text(json.dumps(base))
PY_PAYLOADS

check_scope() {
  local name="$1" expected="$2" expected_error="$3"
  local code
  code=$(curl -sS --connect-timeout 10 --max-time 30 --max-filesize 65536 -o "$probe_dir/$name.response" -w '%{http_code}' \
    -X POST "$worker_url/v2/control/session" \
    -H 'content-type: application/json' \
    -H 'authorization: Bearer invalid-production-config-probe' \
    --data-binary "@$probe_dir/$name.json") || {
      echo "production scope probe request failed ($name)" >&2
      return 1
    }
  if [[ "$code" != "$expected" ]]; then
    echo "production scope verification failed: $name returned HTTP $code, expected $expected" >&2
    return 1
  fi
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

run_scope_pair() {
  local phase="$1"
  local before="$probe_dir/$phase-before.json"
  local after="$probe_dir/$phase-after.json"
  local before_version="$probe_dir/$phase-before.version"
  local after_version="$probe_dir/$phase-after.version"
  local before_identity="$probe_dir/$phase-before.identity"
  local after_identity="$probe_dir/$phase-after.identity"
  capture_deployment "$before" "$before_version" "$before_identity" || return 3
  local probe_failure=0
  check_scope production 401 unauthorized || probe_failure=1
  check_scope development 403 environment_mismatch || probe_failure=1
  capture_deployment "$after" "$after_version" "$after_identity" || return 3
  if ! same_deployment "$before_identity" "$after_identity"; then
    echo "production scope verification failed: active deployment changed during $phase probes" >&2
    return 2
  fi
  return "$probe_failure"
}

pre_result=0
run_scope_pair pre || pre_result=$?
if (( pre_result )); then
  if (( pre_result == 2 )); then
    echo "refusing production deploy: active deployment changed during pre-deploy probes" >&2
  else
    echo "refusing production deploy: current deployment failed scope verification" >&2
  fi
  exit 1
fi

previous_version=$(<"$probe_dir/pre-before.version")
if ! wrangler versions view "$previous_version" --env "$environment" --name "$worker_name" --json >"$probe_dir/previous-version.json"; then
  echo "refusing production deploy: could not read the active Worker version" >&2
  exit 1
fi
if ! check_pending_migration "$probe_dir/previous-version.json"; then
  echo "refusing production deploy: pending Durable Object migration requires a dedicated migration rollout" >&2
  exit 1
fi

read_health() {
  curl -sS --connect-timeout 10 --max-time 30 --max-filesize 65536 \
    -o "$1" -w '%{http_code}' "$worker_url/v2/health"
}
health_status="$(read_health "$probe_dir/pre-health.json")"
bun scripts/rollout-policy.ts pre "$environment" "$probe_dir/previous-version.json" "$probe_dir/pre-health.json" "$health_status"

# Production promotes the same clean revision already verified in staging.
if [[ "$environment" == "production" ]]; then
  wrangler deployments status --env staging --name cmux-v2-staging --json >"$probe_dir/staging-deployment.json"
  staging_version="$(python3 - "$probe_dir/staging-deployment.json" <<'PY_STAGING'
import json,sys
value=json.load(open(sys.argv[1]))
versions=value["versions"]
if len(versions)!=1 or versions[0]["percentage"]!=100: raise SystemExit("staging must have one active version")
print(versions[0]["version_id"])
PY_STAGING
)"
  wrangler versions view "$staging_version" --env staging --name cmux-v2-staging --json >"$probe_dir/staging-version.json"
  staging_status="$(curl -sS --connect-timeout 10 --max-time 30 --max-filesize 65536 \
    -o "$probe_dir/staging-health.json" -w '%{http_code}' https://cmux-v2-staging.debussy.workers.dev/v2/health)"
  bun scripts/rollout-policy.ts post staging "$probe_dir/staging-version.json" "$probe_dir/staging-health.json" "$staging_status" "$probe_dir/staging-version.json" "${source_revision_vars##*:}"
  wrangler deployments status --env staging --name cmux-v2-staging --json >"$probe_dir/staging-after.json"
  python3 - "$probe_dir/staging-deployment.json" "$probe_dir/staging-after.json" <<'PY_STABLE'
import json,sys
before,after=(json.load(open(path)) for path in sys.argv[1:])
if any(before.get(key)!=after.get(key) for key in ("id","created_on","versions")): raise SystemExit("staging changed during verification")
PY_STABLE
fi
# A deployment while the additional checks ran invalidates the rollback proof.
capture_deployment "$probe_dir/final-pre.json" "$probe_dir/final-pre.version" "$probe_dir/final-pre.identity"
same_deployment "$probe_dir/pre-after.identity" "$probe_dir/final-pre.identity" || {
  echo "refusing deployment: active version changed during rollout checks" >&2; exit 1;
}

deployment_marker="cmux-prod-guard-$(python3 -c 'import uuid; print(uuid.uuid4())')"
# The published revision is what GET /v2/health reports and what
# scripts/check-production-drift.ts compares against main.
# shellcheck disable=SC2086
wrangler deploy --env "$environment" --keep-vars --strict --message "$deployment_marker" --tag "$deployment_marker" $source_revision_vars

post_result=0
run_scope_pair post || post_result=$?
if (( post_result == 0 )); then
  current_version="$(<"$probe_dir/post-after.version")"
  if ! wrangler versions view "$current_version" --env "$environment" --name "$worker_name" --json >"$probe_dir/current-version.json"; then
    post_result=3
  elif ! health_status="$(read_health "$probe_dir/post-health.json")"; then
    post_result=1
  elif ! bun scripts/rollout-policy.ts post "$environment" "$probe_dir/previous-version.json" "$probe_dir/post-health.json" "$health_status" "$probe_dir/current-version.json" "${source_revision_vars##*:}"; then
    post_result=1
  fi
fi
if (( post_result == 0 )); then
  if ! capture_deployment "$probe_dir/final-post.json" "$probe_dir/final-post.version" "$probe_dir/final-post.identity"; then
    post_result=3
  elif ! same_deployment "$probe_dir/post-after.identity" "$probe_dir/final-post.identity"; then
    post_result=2
  fi
fi
if (( post_result )); then
  rollback_safe=0
  if (( post_result == 1 )); then
    rollback_current="$probe_dir/rollback-current.json"
    rollback_version="$probe_dir/rollback-current.version"
    rollback_identity="$probe_dir/rollback-current.identity"
    if capture_deployment "$rollback_current" "$rollback_version" "$rollback_identity" \
      && same_deployment "$probe_dir/post-after.identity" "$rollback_identity" \
      && python3 - "$rollback_current" "$deployment_marker" <<'PY_MARKER'
import json, pathlib, sys
try:
    deployment = json.loads(pathlib.Path(sys.argv[1]).read_text())
    annotations = deployment.get("annotations") or {}
    marker = sys.argv[2]
    valid = marker in (annotations.get("workers/message"), annotations.get("workers/tag"))
except (AttributeError, TypeError, OSError, json.JSONDecodeError):
    valid = False
sys.exit(0 if valid else 1)
PY_MARKER
    then
      rollback_safe=1
    fi
  fi

  if (( rollback_safe )); then
    if wrangler rollback "$previous_version" --env "$environment" --name "$worker_name" \
      --message "restore pre-deploy verified version after scope probe failure" --yes; then
      echo "production scope verification failed; restored the previously verified Worker version" >&2
    else
      echo "production scope verification failed and automatic rollback failed; inspect the Worker immediately" >&2
    fi
  else
    echo "production scope verification failed; active deployment changed, so rollback was skipped" >&2
  fi
  exit 1
fi

echo "production deployment scope verification passed"
echo "published $source_revision_vars; confirm with: curl -sS $worker_url/v2/health"
