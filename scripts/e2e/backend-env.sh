#!/usr/bin/env bash
# App-side half of the per-run backend (scripts/e2e/backend-up.sh).
#
# Usage: backend-env.sh env [--simctl]   KEY=VALUE lines for $GITHUB_ENV;
#                                         --simctl also emits SIMCTL_CHILD_*
#                                         copies for apps launched by simctl
#        backend-env.sh hosts [seconds]  map the backend's fixed certificate
#                                         name to this run's backend runner in
#                                         /etc/hosts (waits for it to join)
#        backend-env.sh wait [seconds]   bounded poll until both Workers
#                                         answer over verified TLS
#        backend-env.sh unhosts          remove the /etc/hosts line again
#
# Every origin uses one fixed name with a publicly trusted certificate, and no
# tailnet node carries it: `hosts` points it at the backend runner's tailnet
# address, so the apps connect over the tailnet with ordinary TLS checks. The
# simulator shares the Mac's resolver, so one entry serves both apps.
#
# The Mac app reads these from the LSEnvironment the reload scripts bake, and
# iOS from SIMCTL_CHILD_* at launch. Web origins keep the apps' Debug default
# (staging): nothing on the path under test calls web/.
set -euo pipefail

NAME="${CMUX_E2E_BACKEND_NAME:?CMUX_E2E_BACKEND_NAME is required}"
IROH_V2="https://$NAME:8443"
PRESENCE="https://$NAME:8444"
HOSTS_MARKER="# cmux-e2e-backend (scripts/e2e/backend-env.sh)"

emit_env() {
  local simctl="${1:-}" line
  local lines=(
    "CMUX_IROH_V2_BASE_URL=$IROH_V2"
    "CMUX_IROH_V2_ENVIRONMENT=development"
    # The lane gates the managed relay path; the relay-only policy forces the
    # terminal stream through this run's relay.
    "CMUX_IROH_V2_FORCE_RELAY=1"
    "CMUX_PRESENCE_BASE_URL=$PRESENCE"
  )
  for line in "${lines[@]}"; do
    echo "$line"
    [[ "$simctl" == "--simctl" ]] && echo "SIMCTL_CHILD_$line"
  done
  return 0
}

map_hosts() {
  local budget="${1:-300}" deadline ip=""
  local peer="${CMUX_E2E_BACKEND_TAILNET_HOSTNAME:?CMUX_E2E_BACKEND_TAILNET_HOSTNAME is required}"
  deadline=$(( $(date +%s) + budget ))
  until ip="$(tailscale ip -4 "$peer" 2>/dev/null)" && [[ -n "$ip" ]]; do
    if (( $(date +%s) >= deadline )); then
      echo "::error::[infra-preflight] backend runner $peer never joined the tailnet (backend job log has the cause)" >&2
      exit 1
    fi
    sleep 2
  done
  unmap_hosts
  printf '%s %s %s\n' "$ip" "$NAME" "$HOSTS_MARKER" | sudo tee -a /etc/hosts >/dev/null
  # macOS caches negative lookups; drop them so the new entry wins at once.
  if command -v dscacheutil >/dev/null 2>&1; then
    sudo dscacheutil -flushcache 2>/dev/null || true
    sudo killall -HUP mDNSResponder 2>/dev/null || true
  fi
  echo "[backend-env] $NAME -> $ip ($peer)"
}

unmap_hosts() {
  if [[ "$(uname)" == Darwin ]]; then
    sudo sed -i '' "\\|${HOSTS_MARKER}|d" /etc/hosts 2>/dev/null || true
  else
    sudo sed -i "\\|${HOSTS_MARKER}|d" /etc/hosts 2>/dev/null || true
  fi
}

wait_ready() {
  local budget="${1:-300}" deadline url
  deadline=$(( $(date +%s) + budget ))
  for url in "$IROH_V2/v2/health" "$PRESENCE/healthz"; do
    until curl -fsS -o /dev/null --max-time 5 "$url" 2>/dev/null; do
      if (( $(date +%s) >= deadline )); then
        echo "::error::[infra-preflight] per-run backend never served $url (backend job log has the cause)" >&2
        exit 1
      fi
      sleep 1
    done
    echo "[backend-env] ready: $url"
  done
}

case "${1:-}" in
  env) emit_env "${2:-}" ;;
  hosts) map_hosts "${2:-300}" ;;
  wait) wait_ready "${2:-300}" ;;
  unhosts) unmap_hosts ;;
  *) echo "usage: $0 env [--simctl] | hosts [seconds] | wait [seconds] | unhosts" >&2; exit 2 ;;
esac
