#!/usr/bin/env bash
set -euo pipefail

SECRET_FILE="${HOME}/.secrets/cmux-stripe-live.env"
WEBHOOK_SECRET_FILE="/tmp/.cmux-live-whsec"
STRIPE_API_BASE="https://api.stripe.com/v1"
PRODUCT_NAME="cmux Pro"
WEBHOOK_URL="https://cmux.com/api/stripe/webhook"
WEBHOOK_DESCRIPTION="cmux Pro billing (webhook-driven entitlements)"
EVENTS=(
  "checkout.session.completed"
  "customer.subscription.created"
  "customer.subscription.updated"
  "customer.subscription.deleted"
  "invoice.paid"
  "invoice.payment_failed"
)

if [[ ! -f "$SECRET_FILE" ]]; then
  cat >&2 <<EOF
Missing $SECRET_FILE.
Create it with:
  STRIPE_LIVE_PROVISION_KEY=sk_live_...
and chmod 600.
EOF
  exit 1
fi

# shellcheck disable=SC1090
source "$SECRET_FILE"

if [[ -z "${STRIPE_LIVE_PROVISION_KEY:-}" ]]; then
  echo "STRIPE_LIVE_PROVISION_KEY is required in $SECRET_FILE" >&2
  exit 1
fi

if [[ "$STRIPE_LIVE_PROVISION_KEY" != sk_live_* && "$STRIPE_LIVE_PROVISION_KEY" != rk_live_* ]]; then
  echo "STRIPE_LIVE_PROVISION_KEY must be a live-mode Stripe secret or restricted key" >&2
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "curl is required" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required" >&2
  exit 1
fi

stripe_get() {
  local path="$1"
  shift
  curl -fsS -u "${STRIPE_LIVE_PROVISION_KEY}:" --get "$@" "${STRIPE_API_BASE}${path}"
}

stripe_post() {
  local path="$1"
  shift
  curl -fsS -u "${STRIPE_LIVE_PROVISION_KEY}:" -X POST "$@" "${STRIPE_API_BASE}${path}"
}

product_response="$(
  stripe_get "/products/search" \
    --data-urlencode "query=name:'${PRODUCT_NAME}' AND active:'true'" \
    --data-urlencode "limit=1"
)"
product_id="$(jq -r '.data[0].id // empty' <<<"$product_response")"

if [[ -n "$product_id" ]]; then
  echo "Found product: $product_id"
else
  create_product_response="$(
    stripe_post "/products" \
      -d "name=${PRODUCT_NAME}" \
      -d "metadata[app]=cmux" \
      -d "metadata[plan]=pro"
  )"
  product_id="$(jq -er '.id' <<<"$create_product_response")"
  echo "Created product: $product_id"
fi

ensure_price() {
  local lookup_key="$1"
  local unit_amount="$2"
  local interval="$3"
  local nickname="$4"
  local response price_id

  response="$(
    stripe_get "/prices" \
      --data-urlencode "lookup_keys[]=${lookup_key}" \
      --data-urlencode "limit=1"
  )"
  price_id="$(jq -r '.data[0].id // empty' <<<"$response")"

  if [[ -n "$price_id" ]]; then
    echo "Found price ${lookup_key}: ${price_id}"
    return 0
  fi

  response="$(
    stripe_post "/prices" \
      -d "product=${product_id}" \
      -d "currency=usd" \
      -d "unit_amount=${unit_amount}" \
      -d "recurring[interval]=${interval}" \
      -d "lookup_key=${lookup_key}" \
      -d "nickname=${nickname}"
  )"
  price_id="$(jq -er '.id' <<<"$response")"
  echo "Created price ${lookup_key}: ${price_id}"
}

ensure_price "cmux-pro-monthly" "3000" "month" "cmux Pro Monthly"
ensure_price "cmux-pro-yearly" "24000" "year" "cmux Pro Yearly"

webhooks_response="$(stripe_get "/webhook_endpoints" --data-urlencode "limit=100")"
webhook_id="$(
  jq -r --arg url "$WEBHOOK_URL" '
    .data[]
    | select(.url == $url and .status == "enabled")
    | .id
  ' <<<"$webhooks_response" | head -n 1
)"

if [[ -n "$webhook_id" ]]; then
  echo "Found webhook endpoint: $webhook_id"
  echo "Webhook signing secrets are only returned at creation time; use the existing production STRIPE_WEBHOOK_SECRET."
else
  event_args=()
  for event in "${EVENTS[@]}"; do
    event_args+=(-d "enabled_events[]=${event}")
  done
  webhook_response="$(
    stripe_post "/webhook_endpoints" \
      -d "url=${WEBHOOK_URL}" \
      -d "description=${WEBHOOK_DESCRIPTION}" \
      "${event_args[@]}"
  )"
  webhook_id="$(jq -er '.id' <<<"$webhook_response")"
  webhook_secret="$(jq -er '.secret' <<<"$webhook_response")"
  umask 077
  printf '%s\n' "$webhook_secret" >"$WEBHOOK_SECRET_FILE"
  chmod 600 "$WEBHOOK_SECRET_FILE"
  echo "Created webhook endpoint: $webhook_id"
  echo "Captured new webhook signing secret in $WEBHOOK_SECRET_FILE (chmod 600)."
fi

cat <<'EOF'

Vercel production env commands
Run these from a checkout linked to the cmux Vercel project:

  vercel env add STRIPE_SECRET_KEY production --scope manaflow
  vercel env add STRIPE_WEBHOOK_SECRET production --scope manaflow

Do not paste the provisioning key as STRIPE_SECRET_KEY. Use a least-privilege server key with:
  Checkout Sessions write, Customers write, Subscriptions read, Prices read, Products read.
EOF
