#!/usr/bin/env bash
# cmux NEXT Cloud plans in Stripe: one Product and one monthly Price per plan
# (manaflow-ai/cmux#46966). The numbers match NEXT_PLAN_OFFERS in
# web/services/billing/nextPlans.ts and cmux-platform's PAID_PLAN_LIMITS, which
# enforce them.
#
#   provision-next-plans.sh <test|live>            dry run: read Stripe, print the plan
#   provision-next-plans.sh test --apply           create or update in test mode
#   CMUX_STRIPE_LIVE_CONFIRM=next-plans \
#     provision-next-plans.sh live --apply         create or update in live mode
#
# A dry run never writes. A live write also needs CMUX_STRIPE_LIVE_CONFIRM, so
# no live Product or Price changes without an explicit OK. Price amounts are
# immutable in Stripe: a Price whose lookup key exists with another amount is
# reported and left alone, never edited. At the end it prints the
# STRIPE_PRICE_NEXT_*_MONTHLY values checkout reads.
set -euo pipefail

MODE="${1:-}"
APPLY=0
[[ "${2:-}" == "--apply" ]] && APPLY=1
case "$MODE" in
  live) SECRET_FILE="${HOME}/.secrets/cmux-stripe-live.env"; KEY_NAME="STRIPE_LIVE_PROVISION_KEY"; KEY_PREFIX="live" ;;
  test) SECRET_FILE="${HOME}/.secrets/cmux-stripe-test.env"; KEY_NAME="STRIPE_TEST_PROVISION_KEY"; KEY_PREFIX="test" ;;
  *) echo "Usage: $(basename "$0") <test|live> [--apply]" >&2; exit 2 ;;
esac
if [[ "$MODE" == "live" && "$APPLY" == 1 && "${CMUX_STRIPE_LIVE_CONFIRM:-}" != "next-plans" ]]; then
  echo "Live writes need CMUX_STRIPE_LIVE_CONFIRM=next-plans (an explicit OK)." >&2
  exit 1
fi

# plan id | product name | monthly cents | lookup key | description (checkout shows it)
PLANS=(
  "next_plus|cmux NEXT Plus|2000|cmux-next-plus-monthly-20|Up to 8 Cloud machines running at once, each up to 4 vCPU and 16 GB RAM with a 64 GB disk. 30,000 machine minutes included each month."
  "next_pro|cmux NEXT Pro|5000|cmux-next-pro-monthly-50|Up to 32 Cloud machines running at once, each up to 8 vCPU and 32 GB RAM with a 128 GB disk. 75,000 machine minutes included each month."
  "next_max|cmux NEXT Max|20000|cmux-next-max-monthly-200|Up to 64 Cloud machines running at once, each up to 32 vCPU and 64 GB RAM with a 256 GB disk. 300,000 machine minutes included each month."
)

if [[ "${CMUX_NEXT_PLANS_PRINT:-}" == "1" ]]; then
  printf '%s\n' "${PLANS[@]}"
  exit 0
fi

if [[ ! -f "$SECRET_FILE" ]]; then
  echo "Missing $SECRET_FILE (${KEY_NAME}=sk_${KEY_PREFIX}_..., chmod 600)." >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$SECRET_FILE"
KEY="${!KEY_NAME:-}"
if [[ "$KEY" != "sk_${KEY_PREFIX}_"* && "$KEY" != "rk_${KEY_PREFIX}_"* ]]; then
  echo "$KEY_NAME must be a ${MODE}-mode Stripe secret or restricted key" >&2
  exit 1
fi
command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }

API="https://api.stripe.com/v1"
get() { local p="$1"; shift; printf 'Authorization: Bearer %s\n' "$KEY" | curl -fsS --max-time 30 --header @- --get "$@" "${API}${p}"; }
post() { local p="$1"; shift; printf 'Authorization: Bearer %s\n' "$KEY" | curl -fsS --max-time 30 --header @- -X POST "$@" "${API}${p}"; }
# Creates carry a stable Idempotency-Key per plan and catalog version, so two overlapping --apply runs make one
# Product and one Price, not two (Stripe answers the second request with the first one's object for 24 hours).
CATALOG_VERSION="v1"
create() { local p="$1" key="$2"; shift 2; post "$p" --header "Idempotency-Key: cmux-next-${MODE}-${CATALOG_VERSION}-${key}" "$@"; }
say() { echo "[$MODE$([[ $APPLY == 1 ]] || echo ' dry run')] $*" >&2; }

ENV_LINES=()
for row in "${PLANS[@]}"; do
  IFS='|' read -r plan name cents lookup description <<<"$row"

  # The Price is read first: when its lookup key exists, its own Product is the plan's Product (checked below), so a
  # run never creates a second Product because Stripe search has not caught up with one made in the dashboard.
  prices="$(get /prices --data-urlencode "lookup_keys[]=${lookup}" --data-urlencode "expand[]=data.product" --data-urlencode "limit=1")"
  price="$(jq -r '.data[0].id // empty' <<<"$prices")"
  if [[ -n "$price" ]]; then
    # Checkout (resolveNextPlanPrice / assertPriceMatchesPlan) takes only an active USD Price billed every month at
    # this amount whose Product is this plan's (app=cmux, plan=<id>, not deleted): anything else is reported, never
    # printed as the id to deploy, and no Product is created for it.
    shape="$(jq -r '.data[0] | [.unit_amount, .active, .currency, .recurring.interval // "none", .recurring.interval_count // 0, (.product.deleted // false), (.product.metadata.app // "-"), (.product.metadata.plan // "-")] | map(tostring) | join(" ")' <<<"$prices")"
    want="${cents} true usd month 1 false cmux ${plan}"
    if [[ "$shape" != "$want" ]]; then
      echo "Price ${price} (${lookup}) is [amount active currency interval count deleted app plan] ${shape}, expected ${want}; left alone." >&2
      exit 1
    fi
    product="$(jq -r '.data[0].product.id' <<<"$prices")"
    old_name="$(jq -r '.data[0].product.name // ""' <<<"$prices")"; old_desc="$(jq -r '.data[0].product.description // ""' <<<"$prices")"
    say "price ${price} (${lookup}, ${cents} cents a month) is current on product ${product}"
  else
    products="$(get /products/search --data-urlencode "query=active:'true' AND metadata['app']:'cmux' AND metadata['plan']:'${plan}'")"
    count="$(jq '.data | length' <<<"$products")"
    if (( count > 1 )); then echo "More than one active product for ${plan}; fix by hand." >&2; exit 1; fi
    product="$(jq -r '.data[0].id // empty' <<<"$products")"
    old_name="$(jq -r '.data[0].name // ""' <<<"$products")"; old_desc="$(jq -r '.data[0].description // ""' <<<"$products")"
    if [[ -z "$product" ]]; then
      say "create product ${name} (metadata plan=${plan}) with description: ${description}"
      if [[ $APPLY == 1 ]]; then
        product="$(create /products "product-${plan}" --data-urlencode "name=${name}" --data-urlencode "description=${description}" \
          --data-urlencode "metadata[app]=cmux" --data-urlencode "metadata[plan]=${plan}" | jq -er .id)"
      fi
      old_name="$name"; old_desc="$description"
    fi
    say "create price ${lookup}: ${cents} cents USD a month on ${product:-the new product}"
    if [[ $APPLY == 1 ]]; then
      price="$(create /prices "price-${lookup}" --data-urlencode "product=${product}" --data-urlencode "currency=usd" \
        --data-urlencode "unit_amount=${cents}" --data-urlencode "recurring[interval]=month" \
        --data-urlencode "lookup_key=${lookup}" --data-urlencode "nickname=${name} Monthly" \
        --data-urlencode "metadata[app]=cmux" --data-urlencode "metadata[plan]=${plan}" | jq -er .id)"
    fi
  fi

  if [[ -n "$product" && ( "$old_name" != "$name" || "$old_desc" != "$description" ) ]]; then
    say "update product ${product}: name '${old_name}' -> '${name}'; description '${old_desc}' -> '${description}'"
    [[ $APPLY == 1 ]] && post "/products/${product}" --data-urlencode "name=${name}" --data-urlencode "description=${description}" >/dev/null
  fi
  var="STRIPE_PRICE_$(tr '[:lower:]' '[:upper:]' <<<"$plan")_MONTHLY"
  ENV_LINES+=("${var}=${price:-<created on --apply>}")
done

printf '%s\n' "${ENV_LINES[@]}"
