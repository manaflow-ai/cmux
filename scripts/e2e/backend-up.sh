#!/usr/bin/env bash
# Per-run backend for the iOS e2e lane, on the Linux runner that hosts it.
#
# One fresh, isolated copy of every service on the Mac<->iPhone critical path,
# so a run shares no state with another run, an agent's dev stack, or the
# production relay fleet:
#   - workers/iroh-v2   (TeamControl/UserUsage Durable Objects: API tickets,
#                        device registration, directory/advertise, relay
#                        credentials)                         -> https://$NAME:8443
#   - workers/presence  (TeamPresence/AccountControlPlane/WorkspacePresence
#                        Durable Objects)                     -> https://$NAME:8444
#   - iroh-relay        (upstream n0 relay server, the version cmux-relay
#                        wraps)                               -> https://$NAME:10000
#   - Postgres 16       (iroh-v2's endpoint ownership tables)
# web/ (Next.js) is deliberately absent: sign-in goes to Stack directly and
# pairing, advertise and relay credentials go through iroh-v2. The apps' web
# side paths keep their Debug default, shared staging. Stack Auth (the CI
# account in the dev project) is the only shared service on the path.
#
# The relay is per run, so iroh-v2 signs its relay credentials with a key
# minted here and no production relay key ever reaches CI. The upstream
# server does not check cmux's credential JWT (manaflow-ai/cmux-relay tests
# that); the apps still fetch, validate and install credentials exactly as in
# production, and the relay-only policy forces the stream through it.
#
# Both Workers run in local workerd (`wrangler dev`), so Durable Object state
# starts empty every run, nothing is built, and nothing is deployed to
# Cloudflare.
#
# TLS: every origin uses one fixed name, $NAME (cmux-e2e-backend on the
# tailnet domain), whose publicly trusted certificate was issued once and is
# stored in the ios-e2e environment. The apps require https, and the iOS Iroh
# client checks relay TLS against built-in public roots, so a private CA would
# not do; a certificate per run would exhaust Let's Encrypt's weekly limit for
# the tailnet domain. No node carries that name: each runner maps it in
# /etc/hosts (the macOS runner to this runner's tailnet address, this runner
# to loopback for Postgres). scripts/e2e/tls-forward.mjs terminates TLS on the
# tailnet address and forwards bytes to the loopback services; Postgres serves
# the same certificate itself, so iroh-v2's rejectUnauthorized connection
# verifies with no test-only switch in product code. The ACL opens only 8443,
# 8444 and 10000 of tag:e2e-backend, so nothing here is reachable from the
# internet or from any other tailnet node.
#
# Usage: backend-up.sh up     start and health-check everything, then return
#        backend-up.sh hold   block until CMUX_E2E_BACKEND_DONE_FILE appears
#                             or CMUX_E2E_WAIT_TIMEOUT_SECONDS expires
#        backend-up.sh down   stop and remove everything `up` created; safe to
#                             run after any partial `up`, and more than once
#
# Env contract (docs/ci/ios-e2e.md#per-run-backend):
#   CMUX_E2E_BACKEND_NAME            fixed certificate name (the origins' host)
#   CMUX_E2E_TLS_CERT / _KEY         its certificate chain and key (PEM)
#   CMUX_E2E_BACKEND_STATE_DIR       scratch dir (default $RUNNER_TEMP/e2e-backend)
#   CMUX_E2E_STACK_PROJECT_ID        dev Stack project (same as the CI account)
#   CMUX_E2E_STACK_PUBLISHABLE_KEY
#   CMUX_E2E_STACK_SERVER_KEY
#   CMUX_E2E_IROH_RELAY_BIN          iroh-relay binary (the workflow caches it)
#   CMUX_E2E_PRESENCE_WEB_BASE_URL   presence's legacy control-plane upstream
#                                    (default: staging, as its dev config)
# Failures print [infra-preflight] because nothing here is the product path
# under test (docs/ci/ios-e2e.md#infra-preflight-failure-labeling). Per-phase
# timings go to the log and, on CI, the step summary.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
NAME="${CMUX_E2E_BACKEND_NAME:-}"
STATE="${CMUX_E2E_BACKEND_STATE_DIR:-${RUNNER_TEMP:-/tmp}/e2e-backend}"
LOGS="$STATE/logs"

IROH_V2_PORT=8787
PRESENCE_PORT=8788
RELAY_PORT=3341
HOSTS_MARKER="# cmux-e2e-backend (scripts/e2e/backend-up.sh)"
PG_CONTAINER=cmux-e2e-postgres
PG_IMAGE=postgres:16-alpine

STARTED_MS="$(date +%s%3N)"
phase() { echo "[backend:$1] $2"; }
# timing <label>: elapsed since start, logged and summarized.
timing() {
  local ms=$(( $(date +%s%3N) - STARTED_MS ))
  printf '[backend:timing] %-22s %6d ms\n' "$1" "$ms"
  [[ -n "${GITHUB_STEP_SUMMARY:-}" ]] && printf '| %s | %d ms |\n' "$1" "$ms" >>"$GITHUB_STEP_SUMMARY"
  return 0
}
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
  until curl -fsS -o /dev/null --max-time 5 "$@" "$url" 2>/dev/null; do
    (( $(date +%s) < deadline )) || die health "$label never answered at $url"
    sleep 0.2
  done
  timing "$label ready"
}

require_secrets() {
  local key missing=()
  for key in CMUX_E2E_STACK_PROJECT_ID CMUX_E2E_STACK_PUBLISHABLE_KEY \
      CMUX_E2E_STACK_SERVER_KEY CMUX_E2E_IROH_RELAY_BIN CMUX_E2E_TLS_CERT CMUX_E2E_TLS_KEY; do
    [[ -n "${!key:-}" ]] || missing+=("$key")
  done
  (( ${#missing[@]} == 0 )) || die config "missing ${missing[*]} (docs/ci/ios-e2e.md#secrets-and-tailnet-identity)"
  [[ -x "$CMUX_E2E_IROH_RELAY_BIN" ]] || die config "iroh-relay not executable at $CMUX_E2E_IROH_RELAY_BIN"
}

# Writes the fixed-name certificate to disk and checks it still has time left.
# Renewal is a manual step (docs/ci/ios-e2e.md#renewing-the-backend-certificate);
# the warning gives three weeks' notice, the error stops runs it cannot serve.
install_certificate() {
  mkdir -p "$STATE/tls"
  (umask 077; printf '%s\n' "$CMUX_E2E_TLS_CERT" >"$STATE/tls/tls.crt"; printf '%s\n' "$CMUX_E2E_TLS_KEY" >"$STATE/tls/tls.key")
  openssl x509 -in "$STATE/tls/tls.crt" -noout -checkhost "$NAME" 2>/dev/null | grep -q 'does match' \
    || die tls "certificate does not cover $NAME"
  openssl x509 -in "$STATE/tls/tls.crt" -noout -checkend $(( 7 * 86400 )) >/dev/null \
    || die tls "certificate for $NAME expires within 7 days; renew it (docs/ci/ios-e2e.md#renewing-the-backend-certificate)"
  openssl x509 -in "$STATE/tls/tls.crt" -noout -checkend $(( 21 * 86400 )) >/dev/null \
    || echo "::warning::backend certificate for $NAME expires within 21 days; renew it (docs/ci/ios-e2e.md#renewing-the-backend-certificate)"
  # Postgres resolves the name to loopback, where it listens.
  printf '127.0.0.1 %s %s\n' "$NAME" "$HOSTS_MARKER" | sudo tee -a /etc/hosts >/dev/null
}

start_postgres() {
  local pg_password="$1"
  # postgres:16-alpine runs as uid 70 and refuses a group/world-readable key.
  mkdir -p "$STATE/pg-tls"
  cp "$STATE/tls/tls.crt" "$STATE/tls/tls.key" "$STATE/pg-tls/"
  sudo chown 70:70 "$STATE/pg-tls/tls.crt" "$STATE/pg-tls/tls.key"
  sudo chmod 600 "$STATE/pg-tls/tls.key"

  # Loopback only; iroh-v2 reaches it by the certificate's name, which
  # /etc/hosts maps to 127.0.0.1. fsync off: the database lives for one run.
  docker run -d --name "$PG_CONTAINER" \
    -p "127.0.0.1:5432:5432" \
    -e POSTGRES_USER=cmux -e POSTGRES_PASSWORD="$pg_password" -e POSTGRES_DB=cmux_v2 \
    -v "$STATE/pg-tls:/tls:ro" \
    "$PG_IMAGE" \
    -c ssl=on -c ssl_cert_file=/tls/tls.crt -c ssl_key_file=/tls/tls.key \
    -c fsync=off -c synchronous_commit=off -c full_page_writes=off \
    >"$LOGS/postgres-run.log" 2>&1 || die postgres "docker run failed"

  local deadline=$(( $(date +%s) + 60 ))
  # pg_isready over TCP: the image's init phase answers on the socket first,
  # then restarts, so a socket probe can report ready too early.
  until docker exec "$PG_CONTAINER" pg_isready -h 127.0.0.1 -U cmux -d cmux_v2 >/dev/null 2>&1; do
    (( $(date +%s) < deadline )) || { docker logs "$PG_CONTAINER" >"$LOGS/postgres.log" 2>&1 || true; die postgres "never became ready"; }
    sleep 0.2
  done
  # iroh-v2 owns no migration runner; these files are its schema.
  local sql
  for sql in "$REPO_ROOT"/workers/iroh-v2/ownership-drizzle/*.sql; do
    docker exec -i "$PG_CONTAINER" psql -h 127.0.0.1 -v ON_ERROR_STOP=1 -U cmux -d cmux_v2 -q <"$sql" \
      >>"$LOGS/postgres-run.log" 2>&1 || die postgres "apply $(basename "$sql") failed"
  done
  # Prove what iroh-v2 will require: a verified chain and hostname for the
  # fixed name over Postgres's STARTTLS negotiation.
  openssl s_client -starttls postgres -connect 127.0.0.1:5432 -servername "$NAME" \
    -verify_hostname "$NAME" -verify_return_error </dev/null >"$LOGS/postgres-tls.log" 2>&1 \
    || die postgres "TLS for $NAME does not verify"
  timing "postgres ready"
}

# Writes a wrangler .dev.vars file from E2E_VAR_* environment values without
# putting any value on argv. dotenv keeps single-quoted values literal (JSON
# stays intact) and expands \n only inside double quotes (the PEM key).
write_dev_vars() {
  local file="$1"
  shift
  python3 - "$file" "$@" <<'PY'
import os, sys
path, names = sys.argv[1], sys.argv[2:]
with open(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as out:
    for name in names:
        value = os.environ[name].strip("\n")
        if "\n" in value:
            if '"' in value or "\\" in value:
                sys.exit(f"{name}: multi-line value cannot hold a quote or backslash")
            quoted = '"' + value.replace("\n", "\\n") + '"'
        else:
            if "'" in value:
                sys.exit(f"{name}: value cannot hold a single quote")
            quoted = "'" + value + "'"
        out.write(f"{name.removeprefix('E2E_VAR_')}={quoted}\n")
PY
}

start_relay() {
  cat >"$STATE/relay.toml" <<EOF
enable_relay = true
http_bind_addr = "127.0.0.1:$RELAY_PORT"
enable_quic_addr_discovery = false
enable_metrics = false
EOF
  "$CMUX_E2E_IROH_RELAY_BIN" --config-path "$STATE/relay.toml" >"$LOGS/relay.log" 2>&1 &
  echo $! >"$STATE/relay.pid"
}

start_workers() {
  local pg_password="$1"
  # Everything iroh-v2 signs is keyed per run: API tickets are self-contained
  # HMACs, and relay credentials target this run's relay.
  E2E_VAR_API_TICKET_KEYS="$(python3 -c 'import base64,json,os; print(json.dumps({"ci": base64.urlsafe_b64encode(os.urandom(32)).rstrip(b"=").decode()}))')"
  E2E_VAR_API_TICKET_CURRENT_KEY_ID=ci
  E2E_VAR_RELAY_SIGNING_KEY="$(openssl genpkey -algorithm ed25519 2>/dev/null || true)"
  E2E_VAR_RELAY_KEY_ID=ci
  E2E_VAR_RELAY_URLS="$(printf '["https://%s:10000/"]' "$NAME")"
  E2E_VAR_DATABASE_URL="postgres://cmux:${pg_password}@${NAME}:5432/cmux_v2"
  E2E_VAR_STACK_API_URL="https://api.stack-auth.com"
  E2E_VAR_STACK_PROJECT_ID="$CMUX_E2E_STACK_PROJECT_ID"
  E2E_VAR_STACK_PUBLISHABLE_KEY="$CMUX_E2E_STACK_PUBLISHABLE_KEY"
  E2E_VAR_STACK_SERVER_KEY="$CMUX_E2E_STACK_SERVER_KEY"
  E2E_VAR_STACK_PUBLISHABLE_CLIENT_KEY="$CMUX_E2E_STACK_PUBLISHABLE_KEY"
  [[ "$E2E_VAR_RELAY_SIGNING_KEY" == "-----BEGIN PRIVATE KEY-----"* ]] || die config "openssl could not mint an Ed25519 key"
  export E2E_VAR_API_TICKET_KEYS E2E_VAR_API_TICKET_CURRENT_KEY_ID E2E_VAR_RELAY_URLS \
    E2E_VAR_DATABASE_URL E2E_VAR_STACK_API_URL E2E_VAR_STACK_PROJECT_ID \
    E2E_VAR_STACK_PUBLISHABLE_KEY E2E_VAR_STACK_SERVER_KEY E2E_VAR_RELAY_SIGNING_KEY \
    E2E_VAR_RELAY_KEY_ID E2E_VAR_STACK_PUBLISHABLE_CLIENT_KEY
  write_dev_vars "$REPO_ROOT/workers/iroh-v2/.dev.vars" \
    E2E_VAR_API_TICKET_KEYS E2E_VAR_API_TICKET_CURRENT_KEY_ID E2E_VAR_RELAY_URLS \
    E2E_VAR_DATABASE_URL E2E_VAR_STACK_API_URL E2E_VAR_STACK_PROJECT_ID \
    E2E_VAR_STACK_PUBLISHABLE_KEY E2E_VAR_STACK_SERVER_KEY E2E_VAR_RELAY_SIGNING_KEY \
    E2E_VAR_RELAY_KEY_ID
  write_dev_vars "$REPO_ROOT/workers/presence/.dev.vars" \
    E2E_VAR_STACK_PROJECT_ID E2E_VAR_STACK_PUBLISHABLE_CLIENT_KEY E2E_VAR_STACK_API_URL

  # `--env development` gives iroh-v2 ENVIRONMENT=development, which must equal
  # the apps' CMUX_IROH_V2_ENVIRONMENT. Durable Object state persists only
  # under this run's scratch dir.
  export WRANGLER_SEND_METRICS=false CI=1
  # STACK_PUBLISHABLE_KEY is optional, so it is not in wrangler.jsonc's
  # required secrets and `wrangler dev` drops it from .dev.vars; a public
  # key may ride argv.
  (cd "$REPO_ROOT/workers/iroh-v2" && exec node_modules/.bin/wrangler dev --env development \
      ${E2E_VAR_STACK_PUBLISHABLE_KEY:+--var "STACK_PUBLISHABLE_KEY:$E2E_VAR_STACK_PUBLISHABLE_KEY"} \
      --ip 127.0.0.1 --port "$IROH_V2_PORT" --persist-to "$STATE/wrangler-iroh-v2" \
      --inspector-port 9230 --show-interactive-dev-session=false \
      >"$LOGS/iroh-v2.log" 2>&1) &
  echo $! >"$STATE/iroh-v2.pid"
  (cd "$REPO_ROOT/workers/presence" && exec node_modules/.bin/wrangler dev --config wrangler.toml \
      --ip 127.0.0.1 --port "$PRESENCE_PORT" --persist-to "$STATE/wrangler-presence" \
      --inspector-port 9231 --show-interactive-dev-session=false \
      --var "CMUX_WEB_BASE_URL:${CMUX_E2E_PRESENCE_WEB_BASE_URL:-https://cmux-staging.vercel.app}" \
      >"$LOGS/presence.log" 2>&1) &
  echo $! >"$STATE/presence.pid"
}

start_tls_forward() {
  local ts_ip="$1"
  node "$SCRIPT_DIR/tls-forward.mjs" "$ts_ip" "$STATE/tls/tls.crt" "$STATE/tls/tls.key" \
    "8443:$IROH_V2_PORT" "8444:$PRESENCE_PORT" "10000:$RELAY_PORT" >"$LOGS/tls-forward.log" 2>&1 &
  echo $! >"$STATE/tls-forward.pid"
}

up() {
  : "${CMUX_E2E_BACKEND_NAME:?CMUX_E2E_BACKEND_NAME is required}"
  require_secrets
  mkdir -p "$LOGS"
  [[ -n "${GITHUB_STEP_SUMMARY:-}" ]] && printf '### Backend bring-up\n| phase | since start |\n| --- | --- |\n' >>"$GITHUB_STEP_SUMMARY"
  local ts_ip pg_password
  ts_ip="$(tailscale ip -4 || true)"
  [[ -n "$ts_ip" ]] || die tailnet "runner has no tailnet IPv4 address"
  pg_password="$(python3 -c 'import secrets; print(secrets.token_urlsafe(24))')"

  install_certificate
  # Nothing below depends on Postgres until iroh-v2's first device
  # registration, so the relay, the Workers and the TLS front start while it
  # initializes.
  start_relay
  start_workers "$pg_password"
  start_tls_forward "$ts_ip"
  start_postgres "$pg_password"

  wait_http relay "http://127.0.0.1:$RELAY_PORT/healthz" 30
  wait_http iroh-v2 "http://127.0.0.1:$IROH_V2_PORT/v2/health" 120
  wait_http presence "http://127.0.0.1:$PRESENCE_PORT/healthz" 120
  # Prove the published origins over verified TLS, not just the loopback
  # ports. --resolve pins the name to this runner's tailnet address, exactly
  # as the macOS runner's /etc/hosts entry does.
  wait_http iroh-v2-tls "https://$NAME:8443/v2/health" 30 --resolve "$NAME:8443:$ts_ip"
  wait_http presence-tls "https://$NAME:8444/healthz" 30 --resolve "$NAME:8444:$ts_ip"
  wait_http relay-tls "https://$NAME:10000/healthz" 30 --resolve "$NAME:10000:$ts_ip"
  phase ready "https://$NAME:8443 (iroh-v2), :8444 (presence), :10000 (relay) on $ts_ip"
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
      [[ -f "$pid_file" ]] || continue
      kill -0 "$(cat "$pid_file")" 2>/dev/null \
        || die crash "$(basename "$pid_file" .pid) exited while clients were using it"
    done
    sleep 5
  done
  phase "done" "completion signal received"
}

# Everything `up` leaves behind: four process trees, the Postgres container,
# the /etc/hosts line, and secret-bearing files (.dev.vars with the Stack
# server key and the per-run relay key, two copies of the TLS key). Each step tolerates a missing
# piece, so `down` also cleans a failed or partial `up`.
down() {
  local pid_file pid
  for pid_file in "$STATE"/*.pid; do
    [[ -f "$pid_file" ]] || continue
    pid="$(cat "$pid_file")"
    # The subshells exec wrangler, which spawns workerd; stop the children
    # first so no workerd outlives its parent.
    pkill -TERM -P "$pid" 2>/dev/null || true
    kill -TERM "$pid" 2>/dev/null || true
  done
  local deadline=$(( $(date +%s) + 10 ))
  for pid_file in "$STATE"/*.pid; do
    [[ -f "$pid_file" ]] || continue
    pid="$(cat "$pid_file")"
    while kill -0 "$pid" 2>/dev/null && (( $(date +%s) < deadline )); do sleep 0.2; done
    pkill -KILL -P "$pid" 2>/dev/null || true
    kill -KILL "$pid" 2>/dev/null || true
    rm -f "$pid_file"
  done
  docker rm -f -v "$PG_CONTAINER" >/dev/null 2>&1 || true
  sudo sed -i "\\|${HOSTS_MARKER}|d" /etc/hosts 2>/dev/null || true
  rm -f "$REPO_ROOT/workers/iroh-v2/.dev.vars" "$REPO_ROOT/workers/presence/.dev.vars"
  # Root owns the TLS files (chowned for Postgres), so remove them with sudo;
  # logs survive for the upload step, which runs before `down`.
  sudo rm -rf "${STATE:?}/tls" "${STATE:?}/pg-tls" "${STATE:?}/wrangler-iroh-v2" \
    "${STATE:?}/wrangler-presence" "${STATE:?}/relay.toml"
  phase down "stopped processes, removed Postgres, the hosts entry, secrets and state"
}

case "${1:-}" in
  up) up ;;
  hold) hold ;;
  down) down ;;
  *) echo "usage: $0 up|hold|down" >&2; exit 2 ;;
esac
