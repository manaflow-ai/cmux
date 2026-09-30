#!/usr/bin/env bash
# App-side half of the per-run backend (scripts/e2e/backend-up.sh): prints the
# environment that points a tagged Mac or iOS simulator app at this run's
# origins instead of shared staging/development, then optionally waits until
# the backend runner is serving them.
#
# Usage: backend-env.sh env [--simctl]   KEY=VALUE lines for $GITHUB_ENV;
#                                         --simctl also emits SIMCTL_CHILD_*
#                                         copies for apps launched by simctl
#        backend-env.sh wait [seconds]   bounded poll until all three origins
#                                         answer (default 1200: covers a cold
#                                         web build on the backend runner)
#
# The Mac reads these from its process environment only when launched
# directly (scripts/e2e/mac-host.sh execs the binary): LaunchServices applies
# a baked LSEnvironment on `open`, and reload.sh bakes staging origins there.
# iOS reads CMUX_IROH_V2_* and CMUX_PRESENCE_BASE_URL from SIMCTL_CHILD_* at
# launch; its general API origin is Info.plist-only (CMUXApiBaseURL), so the
# sim product step must stamp it (docs/ci/ios-e2e.md#per-run-backend).
set -euo pipefail

FQDN="${CMUX_E2E_BACKEND_FQDN:?CMUX_E2E_BACKEND_FQDN is required}"
WEB="https://$FQDN"
IROH_V2="https://$FQDN:8443"
PRESENCE="https://$FQDN:10000"

emit_env() {
  local simctl="${1:-}" line
  local lines=(
    "CMUX_IROH_V2_BASE_URL=$IROH_V2"
    "CMUX_IROH_V2_ENVIRONMENT=development"
    # The lane gates the managed relay path; direct routes between the two
    # runners are also closed by the tailnet ACL.
    "CMUX_IROH_V2_FORCE_RELAY=1"
    "CMUX_PRESENCE_BASE_URL=$PRESENCE"
    "CMUX_API_BASE_URL=$WEB"
    "CMUX_VM_API_BASE_URL=$WEB"
    "CMUX_WWW_ORIGIN=$WEB"
    "CMUX_AUTH_WWW_ORIGIN=$WEB"
    "CMUX_DEVICE_REGISTRY_API_BASE_URL=$WEB"
    "CMUX_PUSH_API_BASE_URL=$WEB"
    "CMUX_IROH_BROKER_BASE_URL=$WEB"
    "CMUX_DEV_BACKEND_URL=$WEB"
  )
  for line in "${lines[@]}"; do
    echo "$line"
    [[ "$simctl" == "--simctl" ]] && echo "SIMCTL_CHILD_$line"
  done
  return 0
}

wait_ready() {
  local budget="${1:-1200}" deadline url
  deadline=$(( $(date +%s) + budget ))
  for url in "$IROH_V2/v2/health" "$PRESENCE/healthz" "$WEB/"; do
    until curl -fsS -o /dev/null --max-time 5 "$url"; do
      if (( $(date +%s) >= deadline )); then
        echo "::error::[infra-preflight] per-run backend never served $url (backend job log has the cause)" >&2
        exit 1
      fi
      sleep 3
    done
    echo "[backend-env] ready: $url"
  done
}

case "${1:-}" in
  env) emit_env "${2:-}" ;;
  wait) wait_ready "${2:-1200}" ;;
  *) echo "usage: $0 env [--simctl] | wait [seconds]" >&2; exit 2 ;;
esac
