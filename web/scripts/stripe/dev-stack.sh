#!/usr/bin/env bash
set -euo pipefail

WEB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REPO_DIR="$(cd "$WEB_DIR/.." && pwd)"

PORT=""
DB_PORT=""
TAG=""

usage() {
  cat >&2 <<'EOF'
Usage: web/scripts/stripe/dev-stack.sh --port <CMUX_PORT> [--db-port <n>] [--tag <tag>]

Starts bun dev plus Stripe webhook forwarding for local Pro checkout testing.
Use the CMUX_PORT printed by the tagged app reload; that port is baked into Info.plist.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)
      PORT="${2:-}"
      shift 2
      ;;
    --db-port)
      DB_PORT="${2:-}"
      shift 2
      ;;
    --tag)
      TAG="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

if [[ -z "$PORT" || ! "$PORT" =~ ^[0-9]+$ ]]; then
  echo "--port is required and must be numeric" >&2
  usage
  exit 2
fi

if [[ -z "$DB_PORT" ]]; then
  DB_PORT="$((PORT + 10000))"
elif [[ ! "$DB_PORT" =~ ^[0-9]+$ ]]; then
  echo "--db-port must be numeric" >&2
  exit 2
fi

if ! command -v stripe >/dev/null 2>&1; then
  echo "stripe CLI is required. Install it and run 'stripe login' first." >&2
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "curl is required" >&2
  exit 1
fi

stripe_config="$(stripe config --list 2>/dev/null || true)"
STRIPE_SECRET_KEY="$(
  printf '%s\n' "$stripe_config" \
    | awk '
      $1 == "test_mode_api_key" {
        value = $0
        sub(/^[^:=]+[[:space:]]*[:=]?[[:space:]]*/, "", value)
        gsub(/["'\'']/, "", value)
        print value
        exit
      }
    '
)"

if [[ -z "$STRIPE_SECRET_KEY" || "$STRIPE_SECRET_KEY" != sk_test_* ]]; then
  echo "Could not read stripe test_mode_api_key. Run 'stripe login' and retry." >&2
  exit 1
fi

web_log="$(mktemp "${TMPDIR:-/tmp}/cmux-stripe-web.XXXXXX.log")"
stripe_log="$(mktemp "${TMPDIR:-/tmp}/cmux-stripe-listen.XXXXXX.log")"
secret_log="$(mktemp "${TMPDIR:-/tmp}/cmux-stripe-secret.XXXXXX.log")"
web_pid=""
stripe_pid=""
secret_pid=""

cleanup() {
  local status=$?
  trap - EXIT INT TERM
  for pid in "$stripe_pid" "$web_pid" "$secret_pid"; do
    if [[ -n "$pid" ]] && kill -0 "$pid" >/dev/null 2>&1; then
      kill "$pid" >/dev/null 2>&1 || true
      wait "$pid" >/dev/null 2>&1 || true
    fi
  done
  exit "$status"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

stripe listen --print-secret >"$secret_log" 2>&1 &
secret_pid=$!

STRIPE_WEBHOOK_SECRET=""
for _ in $(seq 1 30); do
  STRIPE_WEBHOOK_SECRET="$(grep -Eo 'whsec_[A-Za-z0-9_]+' "$secret_log" | head -n 1 || true)"
  if [[ -n "$STRIPE_WEBHOOK_SECRET" ]]; then
    break
  fi
  if ! kill -0 "$secret_pid" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

if [[ -n "$secret_pid" ]] && kill -0 "$secret_pid" >/dev/null 2>&1; then
  kill "$secret_pid" >/dev/null 2>&1 || true
  wait "$secret_pid" >/dev/null 2>&1 || true
fi
secret_pid=""

if [[ -z "$STRIPE_WEBHOOK_SECRET" ]]; then
  echo "Could not resolve STRIPE_WEBHOOK_SECRET from 'stripe listen --print-secret'." >&2
  echo "Stripe CLI output: $secret_log" >&2
  exit 1
fi

CMUX_PORT_END="$((PORT + 9))"
SCHEME="cmux"
auth_scheme_env=()
if [[ -n "$TAG" ]]; then
  SCHEME="cmux-dev-$TAG"
  auth_scheme_env=(CMUX_AUTH_CALLBACK_SCHEME="$SCHEME")
fi

branch="$(git -C "$REPO_DIR" branch --show-current 2>/dev/null || true)"
if [[ -z "$branch" ]]; then
  branch="$(basename "$REPO_DIR")"
fi
slug="$(
  printf '%s' "$branch" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-+/-/g' \
    | cut -c1-48
)"
if [[ -z "$slug" ]]; then
  slug="worktree"
fi
db_container="${CMUX_DB_CONTAINER_NAME:-cmux-postgres-${slug}-dev-${PORT}}"

events="checkout.session.completed,customer.subscription.created,customer.subscription.updated,customer.subscription.deleted,invoice.paid,invoice.payment_failed"

echo "cmux Stripe dev stack"
echo "  Web log: $web_log"
echo "  Stripe listen log: $stripe_log"
echo "  CMUX_PORT=$PORT"
echo "  CMUX_DB_PORT=$DB_PORT"
echo "  CMUX_DB_CONTAINER_NAME=$db_container"
echo "  Callback scheme: $SCHEME"

(
  cd "$WEB_DIR"
  env \
    CMUX_PORT="$PORT" \
    CMUX_PORT_RANGE=10 \
    CMUX_PORT_END="$CMUX_PORT_END" \
    CMUX_DB_KIND=dev \
    CMUX_DB_PORT="$DB_PORT" \
    STRIPE_SECRET_KEY="$STRIPE_SECRET_KEY" \
    STRIPE_WEBHOOK_SECRET="$STRIPE_WEBHOOK_SECRET" \
    ${auth_scheme_env[@]+"${auth_scheme_env[@]}"} \
    bun dev
) >"$web_log" 2>&1 &
web_pid=$!

stripe listen \
  --forward-to "http://localhost:${PORT}/api/stripe/webhook" \
  --events "$events" >"$stripe_log" 2>&1 &
stripe_pid=$!

pricing_url="http://localhost:${PORT}/app-pricing?cmux_app=1"
for _ in $(seq 1 90); do
  if ! kill -0 "$web_pid" >/dev/null 2>&1; then
    echo "bun dev exited before the pricing page became ready. See $web_log" >&2
    exit 1
  fi
  if curl -fsS -o /dev/null "$pricing_url"; then
    break
  fi
  sleep 1
done

if ! curl -fsS -o /dev/null "$pricing_url"; then
  echo "Timed out waiting for $pricing_url to return 200. See $web_log" >&2
  exit 1
fi

checkout_url="http://localhost:${PORT}/api/billing/checkout?plan=pro&cmux_scheme=${SCHEME}"
plan_url="http://localhost:${PORT}/api/billing/plan"

cat <<EOF

Verification
  Checkout redirect:
    curl -I -sS -o /dev/null -w '%{http_code} %{redirect_url}\n' '$checkout_url'
    Expected: 307 https://checkout.stripe.com/...

  Stripe test card:
    4242 4242 4242 4242

  DB inspection:
    docker exec $db_container psql -U cmux -d cmux -c 'select id, status, plan from stripe_subscriptions;'

  Plan probe:
    curl -sS '$plan_url'

Press Ctrl-C to stop bun dev and Stripe forwarding.
EOF

wait "$web_pid"
