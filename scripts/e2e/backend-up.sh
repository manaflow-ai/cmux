#!/usr/bin/env bash
# Per-run backend for the iOS e2e lane, on the Linux runner that hosts it.
#
# One fresh, isolated copy of everything the Mac<->iPhone path calls, so a run
# never shares state with another run, an agent's dev stack, or staging:
#   - workers/iroh-v2   (TeamControl/UserUsage Durable Objects: API tickets,
#                        device registration, directory/advertise, relay
#                        credentials)  -> https://$FQDN:8443
#   - workers/presence  (TeamPresence/AccountControlPlane/WorkspacePresence
#                        Durable Objects)                     -> https://$FQDN:10000
#   - web/              (Next.js: device registry, push, legacy broker,
#                        general API)                         -> https://$FQDN
#   - Postgres 16       (web's database plus the iroh-v2 ownership tables)
# Stack Auth and the managed relays stay shared: sign-in is the CI account in
# the dev Stack project, and the relays only trust the dev v2 signing key.
#
# Both Workers run in local workerd (`wrangler dev`), so Durable Object state
# starts empty every run and nothing is deployed to Cloudflare. Tailscale Serve
# publishes the three HTTPS origins on the runner's tailnet name with a public
# certificate, which the apps require (https-only origins, iOS ATS).
#
# iroh-v2 connects to Postgres with rejectUnauthorized TLS. Postgres therefore
# serves the same `tailscale cert` certificate and listens on the runner's own
# tailnet address, so the Worker's connection verifies against a public CA
# without any test-only TLS switch in product code. The tailnet ACL does not
# expose 5432 to other nodes.
#
# Usage: backend-up.sh up     start and health-check everything, then return
#        backend-up.sh hold   block until CMUX_E2E_BACKEND_DONE_FILE appears
#                             or CMUX_E2E_WAIT_TIMEOUT_SECONDS expires
#
# Env contract (docs/ci/ios-e2e.md#per-run-backend):
#   CMUX_E2E_BACKEND_FQDN            tailnet name this runner joined with
#   CMUX_E2E_BACKEND_STATE_DIR       scratch dir (default $RUNNER_TEMP/e2e-backend)
#   CMUX_E2E_STACK_PROJECT_ID        dev Stack project (same as the CI account)
#   CMUX_E2E_STACK_PUBLISHABLE_KEY
#   CMUX_E2E_STACK_SERVER_KEY
#   CMUX_E2E_RELAY_SIGNING_KEY       dev v2 relay EdDSA key (PEM) the relays trust
#   CMUX_E2E_RELAY_KEY_ID
#   CMUX_E2E_SKIP_WEB_BUILD=1        .next was restored for this exact web/ tree
# Failures print [infra-preflight] because nothing here is the product path
# under test (docs/ci/ios-e2e.md#infra-preflight-failure-labeling).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FQDN="${CMUX_E2E_BACKEND_FQDN:?CMUX_E2E_BACKEND_FQDN is required}"
STATE="${CMUX_E2E_BACKEND_STATE_DIR:-${RUNNER_TEMP:-/tmp}/e2e-backend}"
LOGS="$STATE/logs"

WEB_PORT=3000
IROH_V2_PORT=8787
PRESENCE_PORT=8788
PG_CONTAINER=cmux-e2e-postgres

phase() { echo "[backend:$1] $2"; }
die() {
  echo "::error::[infra-preflight] backend $1: $2" >&2
  for log in "$LOGS"/*.log; do
    [[ -f "$log" ]] || continue
    echo "--- tail $log" >&2
    tail -n 40 "$log" >&2 || true
  done
  exit 1
}

# wait_http <label> <url> <seconds> [curl args...]: bounded poll on a real
# response, never a fixed sleep standing in for readiness.
wait_http() {
  local label="$1" url="$2" budget="$3" deadline
  shift 3
  deadline=$(( $(date +%s) + budget ))
  until curl -fsS -o /dev/null --max-time 5 "$@" "$url"; do
    (( $(date +%s) < deadline )) || die health "$label never answered at $url"
    sleep 1
  done
  phase health "$label ok ($url)"
}

require_secrets() {
  local key missing=()
  for key in CMUX_E2E_STACK_PROJECT_ID CMUX_E2E_STACK_PUBLISHABLE_KEY \
      CMUX_E2E_STACK_SERVER_KEY CMUX_E2E_RELAY_SIGNING_KEY CMUX_E2E_RELAY_KEY_ID; do
    [[ -n "${!key:-}" ]] || missing+=("$key")
  done
  (( ${#missing[@]} == 0 )) || die secrets "missing ${missing[*]} (docs/ci/ios-e2e.md#secrets)"
}

start_postgres() {
  local ts_ip="$1" pg_password="$2"
  mkdir -p "$STATE/tls"
  sudo tailscale cert --cert-file "$STATE/tls/tls.crt" --key-file "$STATE/tls/tls.key" "$FQDN" \
    >"$LOGS/tls.log" 2>&1 || die tls "tailscale cert failed for $FQDN (HTTPS certificates enabled on the tailnet?)"
  # postgres:16-alpine runs as uid 70 and refuses a group/world-readable key.
  sudo chown 70:70 "$STATE/tls/tls.crt" "$STATE/tls/tls.key"
  sudo chmod 600 "$STATE/tls/tls.key"

  # Loopback for web and migrations, the tailnet address for iroh-v2's
  # verified-TLS connection by name. Never 0.0.0.0.
  docker run -d --name "$PG_CONTAINER" \
    -p "127.0.0.1:5432:5432" -p "$ts_ip:5432:5432" \
    -e POSTGRES_USER=cmux -e POSTGRES_PASSWORD="$pg_password" -e POSTGRES_DB=cmux \
    -v "$STATE/tls:/tls:ro" \
    postgres:16-alpine \
    -c ssl=on -c ssl_cert_file=/tls/tls.crt -c ssl_key_file=/tls/tls.key \
    >"$LOGS/postgres-run.log" 2>&1 || die postgres "docker run failed"

  local deadline=$(( $(date +%s) + 60 ))
  until docker exec "$PG_CONTAINER" pg_isready -U cmux -d cmux >/dev/null 2>&1; do
    (( $(date +%s) < deadline )) || { docker logs "$PG_CONTAINER" >"$LOGS/postgres.log" 2>&1 || true; die postgres "never became ready"; }
    sleep 1
  done
  docker exec "$PG_CONTAINER" psql -v ON_ERROR_STOP=1 -U cmux -d cmux -qc 'CREATE DATABASE cmux_v2' \
    >>"$LOGS/postgres-run.log" 2>&1 || die postgres "create cmux_v2 failed"
  # iroh-v2's ownership tables are not part of web's migrations.
  local sql
  for sql in "$REPO_ROOT"/workers/iroh-v2/ownership-drizzle/*.sql; do
    docker exec -i "$PG_CONTAINER" psql -v ON_ERROR_STOP=1 -U cmux -d cmux_v2 -q <"$sql" \
      >>"$LOGS/postgres-run.log" 2>&1 || die postgres "apply $(basename "$sql") failed"
  done
  phase postgres "ready (cmux, cmux_v2)"
}

# Writes a wrangler .dev.vars file (dotenv, values JSON-quoted) from name/value
# pairs without putting any value on argv.
write_dev_vars() {
  local file="$1"
  shift
  python3 - "$file" "$@" <<'PY'
import json, os, sys
path, names = sys.argv[1], sys.argv[2:]
with open(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as out:
    for name in names:
        out.write(f"{name.removeprefix('E2E_VAR_')}={json.dumps(os.environ[name])}\n")
PY
}

start_workers() {
  local pg_password="$1"
  # API tickets are self-contained HMACs, so each run mints its own key.
  E2E_VAR_API_TICKET_KEYS="$(python3 -c 'import base64,json,os; print(json.dumps({"ci": base64.urlsafe_b64encode(os.urandom(32)).rstrip(b"=").decode()}))')"
  E2E_VAR_API_TICKET_CURRENT_KEY_ID=ci
  E2E_VAR_RELAY_URLS="$(python3 -c 'import json,sys; print(json.dumps([r["url"] for r in json.load(open(sys.argv[1]))["relays"]]))' "$REPO_ROOT/config/iroh/managed-relay-catalog.json")"
  E2E_VAR_DATABASE_URL="postgres://cmux:${pg_password}@${FQDN}:5432/cmux_v2"
  E2E_VAR_STACK_API_URL="https://api.stack-auth.com"
  E2E_VAR_STACK_PROJECT_ID="$CMUX_E2E_STACK_PROJECT_ID"
  E2E_VAR_STACK_PUBLISHABLE_KEY="$CMUX_E2E_STACK_PUBLISHABLE_KEY"
  E2E_VAR_STACK_SERVER_KEY="$CMUX_E2E_STACK_SERVER_KEY"
  E2E_VAR_RELAY_SIGNING_KEY="$CMUX_E2E_RELAY_SIGNING_KEY"
  E2E_VAR_RELAY_KEY_ID="$CMUX_E2E_RELAY_KEY_ID"
  export E2E_VAR_API_TICKET_KEYS E2E_VAR_API_TICKET_CURRENT_KEY_ID E2E_VAR_RELAY_URLS \
    E2E_VAR_DATABASE_URL E2E_VAR_STACK_API_URL E2E_VAR_STACK_PROJECT_ID \
    E2E_VAR_STACK_PUBLISHABLE_KEY E2E_VAR_STACK_SERVER_KEY E2E_VAR_RELAY_SIGNING_KEY \
    E2E_VAR_RELAY_KEY_ID
  write_dev_vars "$REPO_ROOT/workers/iroh-v2/.dev.vars" \
    E2E_VAR_API_TICKET_KEYS E2E_VAR_API_TICKET_CURRENT_KEY_ID E2E_VAR_RELAY_URLS \
    E2E_VAR_DATABASE_URL E2E_VAR_STACK_API_URL E2E_VAR_STACK_PROJECT_ID \
    E2E_VAR_STACK_PUBLISHABLE_KEY E2E_VAR_STACK_SERVER_KEY E2E_VAR_RELAY_SIGNING_KEY \
    E2E_VAR_RELAY_KEY_ID

  E2E_VAR_STACK_PUBLISHABLE_CLIENT_KEY="$CMUX_E2E_STACK_PUBLISHABLE_KEY"
  export E2E_VAR_STACK_PUBLISHABLE_CLIENT_KEY
  write_dev_vars "$REPO_ROOT/workers/presence/.dev.vars" \
    E2E_VAR_STACK_PROJECT_ID E2E_VAR_STACK_PUBLISHABLE_CLIENT_KEY E2E_VAR_STACK_API_URL

  # `--env development` gives iroh-v2 ENVIRONMENT=development, which must equal
  # the apps' CMUX_IROH_V2_ENVIRONMENT. Durable Object state persists only
  # under this run's scratch dir.
  (cd "$REPO_ROOT/workers/iroh-v2" && exec bunx wrangler dev --env development \
      --ip 127.0.0.1 --port "$IROH_V2_PORT" --persist-to "$STATE/wrangler-iroh-v2" \
      >"$LOGS/iroh-v2.log" 2>&1) &
  echo $! >"$STATE/iroh-v2.pid"
  (cd "$REPO_ROOT/workers/presence" && exec bunx wrangler dev --config wrangler.toml \
      --ip 127.0.0.1 --port "$PRESENCE_PORT" --persist-to "$STATE/wrangler-presence" \
      --var "CMUX_WEB_BASE_URL:https://$FQDN" \
      >"$LOGS/presence.log" 2>&1) &
  echo $! >"$STATE/presence.pid"
}

start_web() {
  local pg_password="$1"
  local database_url="postgres://cmux:${pg_password}@127.0.0.1:5432/cmux"
  # Build-time and runtime env. NEXT_PUBLIC_* values are baked by next build,
  # which is why the restored-build cache key includes the Stack project.
  export NEXT_PUBLIC_STACK_PROJECT_ID="$CMUX_E2E_STACK_PROJECT_ID"
  export NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY="$CMUX_E2E_STACK_PUBLISHABLE_KEY"
  export STACK_SECRET_SERVER_KEY="$CMUX_E2E_STACK_SERVER_KEY"
  export RESEND_API_KEY=re_ci_e2e
  export CMUX_FEEDBACK_FROM_EMAIL=ci@example.test
  export DATABASE_URL="$database_url" DIRECT_DATABASE_URL="$database_url"
  export CMUX_PRESENCE_BASE_URL="https://$FQDN:10000"
  export CMUX_WWW_ORIGIN="https://$FQDN"
  export CMUX_ANALYTICS_TEST_MODE=1
  export NEXT_TELEMETRY_DISABLED=1

  (cd "$REPO_ROOT/web" && node_modules/.bin/drizzle-kit migrate --config drizzle.config.ts) \
    >"$LOGS/web-migrate.log" 2>&1 || die web "drizzle-kit migrate failed"
  if [[ "${CMUX_E2E_SKIP_WEB_BUILD:-0}" == "1" && -f "$REPO_ROOT/web/.next/BUILD_ID" ]]; then
    phase web "reusing restored build $(cat "$REPO_ROOT/web/.next/BUILD_ID")"
  else
    local started
    started="$(date +%s)"
    (cd "$REPO_ROOT/web" && bun run vercel-build) >"$LOGS/web-build.log" 2>&1 \
      || die web "build failed"
    phase web "built in $(( $(date +%s) - started ))s"
  fi
  (cd "$REPO_ROOT/web" && exec node_modules/.bin/next start --hostname 127.0.0.1 --port "$WEB_PORT" \
      >"$LOGS/web.log" 2>&1) &
  echo $! >"$STATE/web.pid"
}

serve_tailnet() {
  sudo tailscale serve --bg --https=443 "http://127.0.0.1:$WEB_PORT" >/dev/null
  sudo tailscale serve --bg --https=8443 "http://127.0.0.1:$IROH_V2_PORT" >/dev/null
  sudo tailscale serve --bg --https=10000 "http://127.0.0.1:$PRESENCE_PORT" >/dev/null
}

up() {
  require_secrets
  mkdir -p "$LOGS"
  local ts_ip pg_password
  ts_ip="$(tailscale ip -4)"
  [[ -n "$ts_ip" ]] || die tailnet "runner has no tailnet IPv4 address"
  pg_password="$(python3 -c 'import secrets; print(secrets.token_urlsafe(24))')"

  start_postgres "$ts_ip" "$pg_password"
  start_workers "$pg_password"
  start_web "$pg_password"

  wait_http iroh-v2 "http://127.0.0.1:$IROH_V2_PORT/v2/health" 120
  wait_http presence "http://127.0.0.1:$PRESENCE_PORT/healthz" 120
  wait_http web "http://127.0.0.1:$WEB_PORT/" 120

  serve_tailnet
  # Prove the published origins, not just the loopback ports. --resolve pins
  # the name to this runner's tailnet address, where Serve listens.
  wait_http iroh-v2-tls "https://$FQDN:8443/v2/health" 60 --resolve "$FQDN:8443:$ts_ip"
  wait_http presence-tls "https://$FQDN:10000/healthz" 60 --resolve "$FQDN:10000:$ts_ip"
  wait_http web-tls "https://$FQDN/" 60 --resolve "$FQDN:443:$ts_ip"
  phase ready "https://$FQDN (web), :8443 (iroh-v2), :10000 (presence)"
}

hold() {
  local done_file="${CMUX_E2E_BACKEND_DONE_FILE:?CMUX_E2E_BACKEND_DONE_FILE is required}"
  local budget="${CMUX_E2E_WAIT_TIMEOUT_SECONDS:-1800}" deadline
  deadline=$(( $(date +%s) + budget ))
  phase hold "serving until $done_file appears (budget ${budget}s)"
  until [[ -f "$done_file" ]]; do
    if (( $(date +%s) >= deadline )); then
      phase wait-timeout "no completion signal within ${budget}s; releasing the runner"
      return 0
    fi
    local pid_file
    for pid_file in "$STATE"/*.pid; do
      kill -0 "$(cat "$pid_file")" 2>/dev/null \
        || die crash "$(basename "$pid_file" .pid) exited while clients were using it"
    done
    sleep 5
  done
  phase done "completion signal received"
}

case "${1:-}" in
  up) up ;;
  hold) hold ;;
  *) echo "usage: $0 up|hold" >&2; exit 2 ;;
esac
