#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-}"
case "$MODE" in
  live)
    SECRET_FILE="${HOME}/.secrets/cmux-stripe-live.env"
    KEY_NAME="STRIPE_LIVE_PROVISION_KEY"
    KEY_PREFIX="live"
    ;;
  test)
    SECRET_FILE="${HOME}/.secrets/cmux-stripe-test.env"
    KEY_NAME="STRIPE_TEST_PROVISION_KEY"
    KEY_PREFIX="test"
    ;;
  *)
    echo "Usage: $(basename "$0") <test|live>" >&2
    exit 2
    ;;
esac

STRIPE_API_BASE="https://api.stripe.com/v1"
WEBHOOK_URL="https://cmux.com/api/stripe/webhook"
WEBHOOK_DESCRIPTION="cmux billing (webhook-driven entitlements)"
EVENTS=(
  "checkout.session.completed"
  "checkout.session.async_payment_succeeded"
  "customer.subscription.created"
  "customer.subscription.updated"
  "customer.subscription.deleted"
  "invoice.paid"
  "invoice.payment_failed"
  "charge.refunded"
)

if [[ ! -f "$SECRET_FILE" ]]; then
  cat >&2 <<EOF
Missing $SECRET_FILE.
Create it with:
  ${KEY_NAME}=sk_${KEY_PREFIX}_...
and chmod 600.
EOF
  exit 1
fi

# shellcheck disable=SC1090
source "$SECRET_FILE"

STRIPE_PROVISION_KEY="${!KEY_NAME:-}"
if [[ -z "$STRIPE_PROVISION_KEY" ]]; then
  echo "$KEY_NAME is required in $SECRET_FILE" >&2
  exit 1
fi

if [[
  "$STRIPE_PROVISION_KEY" != "sk_${KEY_PREFIX}_"* &&
  "$STRIPE_PROVISION_KEY" != "rk_${KEY_PREFIX}_"*
]]; then
  echo "$KEY_NAME must be a ${MODE}-mode Stripe secret or restricted key" >&2
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
  printf 'Authorization: Bearer %s\n' "$STRIPE_PROVISION_KEY" |
    curl -fsS --connect-timeout 5 --max-time 30 --retry 2 --retry-all-errors \
      --header @- --get "$@" "${STRIPE_API_BASE}${path}"
}

stripe_post() {
  local path="$1"
  shift
  # POST mutations are not automatically retried without a stable Stripe
  # idempotency key. A failed operator run safely re-discovers completed
  # catalog objects before attempting a new mutation.
  printf 'Authorization: Bearer %s\n' "$STRIPE_PROVISION_KEY" |
    curl -fsS --connect-timeout 5 --max-time 30 \
      --header @- -X POST "$@" "${STRIPE_API_BASE}${path}"
}

product_matches_catalog_identity() {
  local product_json="$1"
  local name="$2"
  local plan="$3"
  jq -e \
    --arg name "$name" \
    --arg plan "$plan" \
    '
      .name == $name
      and .active == true
      and .metadata.app == "cmux"
      and .metadata.plan == $plan
    ' <<<"$product_json" >/dev/null
}

ensure_product() {
  local name="$1"
  local plan="$2"
  local response product_id next_page page_product_ids
  local -a matching_product_ids=()
  local -a page_args=(--data-urlencode "limit=100")

  next_page=""
  while :; do
    page_args=(
      --data-urlencode "limit=100"
      --data-urlencode "query=active:'true' AND metadata['app']:'cmux' AND metadata['plan']:'${plan}'"
    )
    if [[ -n "$next_page" ]]; then
      page_args+=(--data-urlencode "page=${next_page}")
    fi
    response="$(
      stripe_get "/products/search" "${page_args[@]}"
    )"
    echo "Scanned Stripe products for ${plan}." >&2
    page_product_ids="$(
      jq -r --arg name "$name" --arg plan "$plan" '
        .data[]
        | select(
            .name == $name
            and .active == true
            and .metadata.app == "cmux"
            and .metadata.plan == $plan
          )
        | .id
      ' <<<"$response"
    )"
    while IFS= read -r product_id; do
      [[ -n "$product_id" ]] && matching_product_ids+=("$product_id")
    done <<<"$page_product_ids"

    if [[ "$(jq -r '.has_more // false' <<<"$response")" != "true" ]]; then
      break
    fi
    next_page="$(jq -er '.next_page' <<<"$response")"
  done

  if (( ${#matching_product_ids[@]} > 1 )); then
    echo "Multiple canonical products found for ${name}" >&2
    exit 1
  fi
  product_id="${matching_product_ids[0]:-}"

  if [[ -n "$product_id" ]]; then
    echo "Found product ${name}: ${product_id}" >&2
  else
    response="$(
      stripe_post "/products" \
        --data-urlencode "name=${name}" \
        --data-urlencode "metadata[app]=cmux" \
        --data-urlencode "metadata[plan]=${plan}"
    )"
    product_id="$(jq -er '.id' <<<"$response")"
    echo "Created product ${name}: ${product_id}" >&2
  fi
  printf '%s' "$product_id"
}

canonical_product() {
  local monthly_lookup_key="$1"
  local name="$2"
  local plan="$3"
  local response product_json product_id

  response="$(
    stripe_get "/prices" \
      --data-urlencode "lookup_keys[]=${monthly_lookup_key}" \
      --data-urlencode "expand[]=data.product" \
      --data-urlencode "limit=1"
  )"
  echo "Checked Stripe price ${monthly_lookup_key}." >&2
  product_id="$(jq -r '.data[0].product.id // empty' <<<"$response")"
  if [[ -z "$product_id" ]]; then
    ensure_product "$name" "$plan"
    return
  fi

  product_json="$(jq -c '.data[0].product' <<<"$response")"
  if ! product_matches_catalog_identity "$product_json" "$name" "$plan"; then
    echo "Price ${monthly_lookup_key} belongs to an unexpected product: ${product_id}" >&2
    exit 1
  fi

  echo "Using canonical product ${name}: ${product_id}" >&2
  printf '%s' "$product_id"
}

ensure_price() {
  local product_id="$1"
  local lookup_key="$2"
  local unit_amount="$3"
  local interval="$4"
  local nickname="$5"
  local response price_id existing_amount existing_currency existing_interval
  local existing_interval_count
  local existing_product existing_active

  response="$(
    stripe_get "/prices" \
      --data-urlencode "lookup_keys[]=${lookup_key}" \
      --data-urlencode "limit=1"
  )"
  price_id="$(jq -r '.data[0].id // empty' <<<"$response")"

  if [[ -n "$price_id" ]]; then
    existing_amount="$(jq -r '.data[0].unit_amount // empty' <<<"$response")"
    existing_currency="$(jq -r '.data[0].currency // empty' <<<"$response")"
    existing_interval="$(jq -r '.data[0].recurring.interval // empty' <<<"$response")"
    existing_interval_count="$(jq -r '.data[0].recurring.interval_count // empty' <<<"$response")"
    existing_product="$(jq -r '.data[0].product // empty' <<<"$response")"
    existing_active="$(jq -r '.data[0].active // false' <<<"$response")"
    if [[
      "$existing_amount" != "$unit_amount" ||
      "$existing_currency" != "usd" ||
      "$existing_interval" != "$interval" ||
      "$existing_interval_count" != "1" ||
      "$existing_product" != "$product_id" ||
      "$existing_active" != "true"
    ]]; then
      echo "Price ${lookup_key} exists with unexpected configuration: ${price_id}" >&2
      exit 1
    fi
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

echo "Resolving ${MODE} Stripe catalog…" >&2
pro_product_id="$(canonical_product "cmux-pro-monthly" "cmux Pro" "pro")"
echo "Resolved Pro product." >&2
team_product_id="$(canonical_product "cmux-team-monthly" "cmux Team" "team")"
echo "Resolved Team product." >&2

ensure_price "$pro_product_id" "cmux-pro-monthly" "3000" "month" "cmux Pro Monthly"
# Keep the original $240 annual Price active for existing subscribers. Stripe
# Price amounts are immutable, so new annual checkouts use a new lookup key.
ensure_price "$pro_product_id" "cmux-pro-yearly" "24000" "year" "cmux Pro Yearly (Legacy)"
ensure_price "$pro_product_id" "cmux-pro-yearly-288" "28800" "year" "cmux Pro Yearly"
ensure_price "$team_product_id" "cmux-team-monthly" "3500" "month" "cmux Team Monthly"
ensure_price "$team_product_id" "cmux-team-yearly-336" "33600" "year" "cmux Team Yearly"

if [[ "$MODE" == "live" ]]; then
  webhook_ids=""
  starting_after=""
  webhook_page_args=(--data-urlencode "limit=100")
  while :; do
    webhook_page_args=(--data-urlencode "limit=100")
    if [[ -n "$starting_after" ]]; then
      webhook_page_args+=(--data-urlencode "starting_after=${starting_after}")
    fi
    webhooks_response="$(
      stripe_get "/webhook_endpoints" "${webhook_page_args[@]}"
    )"
    page_webhook_ids="$(
      jq -r --arg url "$WEBHOOK_URL" '
        .data[]
        | select(.url == $url and .status == "enabled")
        | .id
      ' <<<"$webhooks_response"
    )"
    if [[ -n "$page_webhook_ids" ]]; then
      webhook_ids+="${webhook_ids:+$'\n'}${page_webhook_ids}"
    fi
    if [[ "$(jq -r '.has_more // false' <<<"$webhooks_response")" != "true" ]]; then
      break
    fi
    starting_after="$(
      jq -er '.data[-1].id | select(type == "string" and length > 0)' \
        <<<"$webhooks_response"
    )"
  done
  webhook_count="$(awk 'NF { count += 1 } END { print count + 0 }' <<<"$webhook_ids")"
  if (( webhook_count > 1 )); then
    echo "Multiple enabled webhook endpoints found for ${WEBHOOK_URL}" >&2
    exit 1
  fi
  webhook_id="$(sed -n '1p' <<<"$webhook_ids")"

  event_args=()
  for event in "${EVENTS[@]}"; do
    event_args+=(-d "enabled_events[]=${event}")
  done

  if [[ -n "$webhook_id" ]]; then
    echo "Found webhook endpoint: $webhook_id"
    stripe_post "/webhook_endpoints/${webhook_id}" "${event_args[@]}" >/dev/null
    echo "Updated webhook event subscriptions."
    echo "Webhook signing secrets are only returned at creation time; use the existing production STRIPE_WEBHOOK_SECRET."
  else
    webhook_response="$(
      stripe_post "/webhook_endpoints" \
        -d "url=${WEBHOOK_URL}" \
        -d "description=${WEBHOOK_DESCRIPTION}" \
        "${event_args[@]}"
    )"
    webhook_id="$(jq -er '.id' <<<"$webhook_response")"
    webhook_secret="$(jq -er '.secret' <<<"$webhook_response")"
    umask 077
    webhook_secret_file="$(mktemp "${TMPDIR:-/tmp}/cmux-live-whsec.XXXXXX")"
    printf '%s\n' "$webhook_secret" >"$webhook_secret_file"
    chmod 600 "$webhook_secret_file"
    echo "Created webhook endpoint: $webhook_id"
    echo "Captured new webhook signing secret in $webhook_secret_file (chmod 600)."
  fi

  cat <<'EOF'

Vercel production env commands
Run these from a checkout linked to the cmux Vercel project:

  vercel env add STRIPE_SECRET_KEY production --scope manaflow
  vercel env add STRIPE_WEBHOOK_SECRET production --scope manaflow

Do not paste the provisioning key as STRIPE_SECRET_KEY. Use a least-privilege server key with:
  Checkout Sessions write, Customers write, Subscriptions read, Prices read, Products read.
EOF
fi
