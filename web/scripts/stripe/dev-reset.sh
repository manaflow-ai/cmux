#!/usr/bin/env bash
set -euo pipefail

WEB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEV_STACK_PROJECT_ID="454ecd03-1db2-4050-845e-4ce5b0cd9895"
PROD_STACK_PROJECT_ID="9790718f-14cd-4f7e-824d-eaf527a82b82"
STACK_API_BASE_URL="${STACK_API_BASE_URL:-https://api.stack-auth.com}"

EMAIL=""
ALLOW_PROJECT=0
DB_PORT=""
SUMMARY=()

usage() {
  cat >&2 <<'EOF'
Usage: web/scripts/stripe/dev-reset.sh [--allow-project] [--db-port <n>] <email>

Un-Pros a Stack Auth dev account so /api/billing/checkout can be tested again.
EOF
}

die() {
  echo "dev-reset: $*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --allow-project)
      ALLOW_PROJECT=1
      shift
      ;;
    --db-port)
      if [[ $# -lt 2 ]]; then
        echo "--db-port requires a value" >&2
        usage
        exit 2
      fi
      DB_PORT="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --*)
      echo "Unknown argument: $1" >&2
      usage
      exit 2
      ;;
    *)
      if [[ -n "$EMAIL" ]]; then
        echo "Unexpected extra argument: $1" >&2
        usage
        exit 2
      fi
      EMAIL="$1"
      shift
      ;;
  esac
done

if [[ -z "$EMAIL" ]]; then
  usage
  exit 2
fi

if [[ -n "$DB_PORT" && ! "$DB_PORT" =~ ^[0-9]+$ ]]; then
  die "--db-port must be numeric"
fi

for required in curl node stripe; do
  if ! command -v "$required" >/dev/null 2>&1; then
    die "$required is required"
  fi
done

if [[ -n "$DB_PORT" ]] && ! command -v psql >/dev/null 2>&1; then
  die "psql is required when --db-port is passed"
fi

urlencode() {
  node -e 'process.stdout.write(encodeURIComponent(process.argv[1]))' "$1"
}

resolve_stack_env() {
  local existing_project_set existing_project existing_secret_set existing_secret
  existing_project_set="${NEXT_PUBLIC_STACK_PROJECT_ID+x}"
  existing_project="${NEXT_PUBLIC_STACK_PROJECT_ID-}"
  existing_secret_set="${STACK_SECRET_SERVER_KEY+x}"
  existing_secret="${STACK_SECRET_SERVER_KEY-}"

  if [[ -z "${NEXT_PUBLIC_STACK_PROJECT_ID:-}" || -z "${STACK_SECRET_SERVER_KEY:-}" ]]; then
    # Reuse the same env loader as web/scripts/dev-local.sh: optional
    # ~/.secrets/cmux.env first, then Stack/web secrets from
    # ~/.secrets/cmuxterm-dev.env or the documented legacy fallbacks.
    # shellcheck disable=SC1091
    source "$WEB_DIR/scripts/load-dev-env.sh"
  fi

  if [[ -n "$existing_project_set" ]]; then
    export NEXT_PUBLIC_STACK_PROJECT_ID="$existing_project"
  fi
  if [[ -n "$existing_secret_set" ]]; then
    export STACK_SECRET_SERVER_KEY="$existing_secret"
  fi

  if [[ -z "${NEXT_PUBLIC_STACK_PROJECT_ID:-}" ]]; then
    die "NEXT_PUBLIC_STACK_PROJECT_ID is required"
  fi
  if [[ -z "${STACK_SECRET_SERVER_KEY:-}" ]]; then
    die "STACK_SECRET_SERVER_KEY is required"
  fi
}

resolve_stripe_secret_key() {
  local stripe_config key
  stripe_config="$(stripe config --list 2>/dev/null || true)"
  key="$(
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

  if [[ "$key" == sk_live_* || "$key" == rk_live_* ]]; then
    die "refusing to use a live Stripe key from stripe config"
  fi
  if [[ -z "$key" ]]; then
    die "could not read stripe test_mode_api_key. Run 'stripe login' and retry."
  fi
  if [[ "$key" != sk_test_* ]]; then
    die "stripe test_mode_api_key must be an sk_test key"
  fi
  STRIPE_SECRET_KEY="$key"
}

HTTP_STATUS=""
HTTP_BODY=""

stack_request_capture() {
  local method path body url response curl_status
  method="$1"
  path="$2"
  body="${3:-}"
  url="${STACK_API_BASE_URL%/}/api/v1${path}"

  local args=(
    -g
    -sS
    --retry 2
    --retry-delay 1
    -X "$method"
    "$url"
    -H "x-stack-access-type: server"
    -H "x-stack-project-id: ${NEXT_PUBLIC_STACK_PROJECT_ID}"
    -H "x-stack-secret-server-key: ${STACK_SECRET_SERVER_KEY}"
    -H "x-stack-override-error-status: true"
  )
  if [[ -n "$body" ]]; then
    args+=(-H "content-type: application/json" --data "$body")
  fi

  set +e
  response="$(curl "${args[@]+"${args[@]}"}" -w $'\n%{http_code}')"
  curl_status=$?
  set -e
  if [[ "$curl_status" != "0" ]]; then
    HTTP_STATUS="curl-$curl_status"
    HTTP_BODY="$response"
    return 1
  fi

  HTTP_STATUS="${response##*$'\n'}"
  HTTP_BODY="${response%$'\n'*}"
  [[ "$HTTP_STATUS" =~ ^2[0-9][0-9]$ ]]
}

stack_request() {
  local method path body
  method="$1"
  path="$2"
  body="${3:-}"
  if ! stack_request_capture "$method" "$path" "$body"; then
    echo "Stack API $method $path failed with $HTTP_STATUS" >&2
    if [[ -n "$HTTP_BODY" ]]; then
      echo "$HTTP_BODY" >&2
    fi
    exit 1
  fi
  printf '%s' "$HTTP_BODY"
}

stripe_request_capture() {
  local method path query response curl_status url
  method="$1"
  path="$2"
  query="${3:-}"
  url="https://api.stripe.com${path}"
  if [[ -n "$query" ]]; then
    url="${url}?${query}"
  fi

  set +e
  response="$(
    curl -g -sS --retry 2 --retry-delay 1 \
      -X "$method" \
      "$url" \
      -H "authorization: Bearer ${STRIPE_SECRET_KEY}" \
      -w $'\n%{http_code}'
  )"
  curl_status=$?
  set -e
  if [[ "$curl_status" != "0" ]]; then
    HTTP_STATUS="curl-$curl_status"
    HTTP_BODY="$response"
    return 1
  fi

  HTTP_STATUS="${response##*$'\n'}"
  HTTP_BODY="${response%$'\n'*}"
  [[ "$HTTP_STATUS" =~ ^2[0-9][0-9]$ ]]
}

stripe_request() {
  local method path query
  method="$1"
  path="$2"
  query="${3:-}"
  if ! stripe_request_capture "$method" "$path" "$query"; then
    echo "Stripe API $method $path failed with $HTTP_STATUS" >&2
    if [[ -n "$HTTP_BODY" ]]; then
      echo "$HTTP_BODY" >&2
    fi
    exit 1
  fi
  printf '%s' "$HTTP_BODY"
}

resolve_stripe_secret_key
resolve_stack_env

if [[ "$NEXT_PUBLIC_STACK_PROJECT_ID" == "$PROD_STACK_PROJECT_ID" ]]; then
  die "refusing to run against the production Stack project"
fi
if [[ "$ALLOW_PROJECT" != "1" && "$NEXT_PUBLIC_STACK_PROJECT_ID" != "$DEV_STACK_PROJECT_ID" ]]; then
  die "refusing Stack project ${NEXT_PUBLIC_STACK_PROJECT_ID}; pass --allow-project for non-prod test projects"
fi

echo "cmux billing dev reset"
echo "  Stack project: $NEXT_PUBLIC_STACK_PROJECT_ID"
echo "  Email: $EMAIL"
if [[ -n "$DB_PORT" ]]; then
  echo "  Local DB port: $DB_PORT"
else
  echo "  Local DB cleanup: skipped"
fi

encoded_email="$(urlencode "$EMAIL")"
# Stack SDK listServerUsers maps to:
#   GET https://api.stack-auth.com/api/v1/users?query=<email>&limit=10&include_anonymous=true&include_restricted=true
# It uses x-stack-access-type: server, x-stack-project-id, and x-stack-secret-server-key.
users_body="$(stack_request GET "/users?query=${encoded_email}&limit=10&include_anonymous=true&include_restricted=true")"
user_match_status=0
user_json="$(
  printf '%s' "$users_body" | node -e '
const email = process.argv[1].toLowerCase();
let input = "";
process.stdin.on("data", (chunk) => input += chunk);
process.stdin.on("end", () => {
  const data = JSON.parse(input);
  const items = Array.isArray(data) ? data : (Array.isArray(data.items) ? data.items : []);
  const matches = items.filter((user) => {
    const primary = user.primary_email ?? user.primaryEmail ?? null;
    return typeof primary === "string" && primary.toLowerCase() === email;
  });
  if (matches.length !== 1) {
    process.exit(matches.length === 0 ? 10 : 11);
  }
  process.stdout.write(JSON.stringify(matches[0]));
});
  ' "$EMAIL"
)" || user_match_status=$?
if [[ "$user_match_status" == "10" ]]; then
  die "no Stack user found with primary email $EMAIL"
elif [[ "$user_match_status" == "11" ]]; then
  die "multiple Stack users matched primary email $EMAIL"
elif [[ "$user_match_status" != "0" ]]; then
  die "failed to parse Stack users response"
fi

stack_user_id="$(
  printf '%s' "$user_json" | node -e 'let s="";process.stdin.on("data",c=>s+=c);process.stdin.on("end",()=>process.stdout.write(JSON.parse(s).id));'
)"
SUMMARY+=("Resolved Stack user: ${stack_user_id}")

cancel_stripe_subscriptions_for_status() {
  local status page pages query encoded_query search_body ids id has_more next_page found
  status="$1"
  page=""
  pages=0
  found=0
  while :; do
    pages=$((pages + 1))
    if [[ "$pages" -gt 5 ]]; then
      SUMMARY+=("Stopped Stripe search for ${status} after 5 pages")
      return
    fi
    query="metadata['stackUserId']:'${stack_user_id}' AND status:'${status}'"
    encoded_query="query=$(urlencode "$query")&limit=100"
    if [[ -n "$page" ]]; then
      encoded_query="${encoded_query}&page=$(urlencode "$page")"
    fi
    # Stripe API endpoint used:
    #   GET /v1/subscriptions/search?query=metadata['stackUserId']:'<id>' AND status:'<status>'
    search_body="$(stripe_request GET "/v1/subscriptions/search" "$encoded_query")"
    ids="$(
      printf '%s' "$search_body" | node -e 'let s="";process.stdin.on("data",c=>s+=c);process.stdin.on("end",()=>{const d=JSON.parse(s);for(const sub of d.data||[]) if(sub.id) console.log(sub.id);});'
    )"
    while IFS= read -r id; do
      [[ -z "$id" ]] && continue
      found=$((found + 1))
      stripe_request DELETE "/v1/subscriptions/${id}" >/dev/null
      SUMMARY+=("Canceled Stripe ${status} subscription: ${id}")
    done <<EOF
$ids
EOF
    has_more="$(
      printf '%s' "$search_body" | node -e 'let s="";process.stdin.on("data",c=>s+=c);process.stdin.on("end",()=>process.stdout.write(JSON.parse(s).has_more ? "1" : "0"));'
    )"
    if [[ "$has_more" != "1" ]]; then
      if [[ "$found" == "0" ]]; then
        SUMMARY+=("No Stripe ${status} subscriptions found")
      fi
      return
    fi
    next_page="$(
      printf '%s' "$search_body" | node -e 'let s="";process.stdin.on("data",c=>s+=c);process.stdin.on("end",()=>process.stdout.write(JSON.parse(s).next_page || ""));'
    )"
    if [[ -z "$next_page" ]]; then
      SUMMARY+=("Stripe search for ${status} had has_more=true without next_page")
      return
    fi
    page="$next_page"
  done
}

for stripe_status in active trialing past_due; do
  cancel_stripe_subscriptions_for_status "$stripe_status"
done

list_and_clean_stack_products() {
  local cursor pages encoded_user products_body lines line product_id quantity sub_id current_end is_cancelable cancel_path encoded_sub found
  cursor=""
  pages=0
  found=0
  encoded_user="$(urlencode "$stack_user_id")"
  while :; do
    pages=$((pages + 1))
    if [[ "$pages" -gt 10 ]]; then
      SUMMARY+=("Stopped Stack product scan after 10 pages")
      return
    fi

    # Scan the Stack payments products endpoint for stale dev grants.
    if [[ -n "$cursor" ]]; then
      products_body="$(stack_request GET "/payments/products/user/${encoded_user}?limit=50&cursor=$(urlencode "$cursor")")"
    else
      products_body="$(stack_request GET "/payments/products/user/${encoded_user}?limit=50")"
    fi

    lines="$(
      printf '%s' "$products_body" | node -e '
let input = "";
process.stdin.on("data", (chunk) => input += chunk);
process.stdin.on("end", () => {
  const data = JSON.parse(input);
  for (const product of data.items || []) {
    if (product.id !== "pro") continue;
    const sub = product.subscription || null;
    console.log([
      product.id || "",
      product.quantity ?? 0,
      sub?.subscription_id || "",
      sub?.current_period_end || "",
      sub?.is_cancelable ? "1" : "0",
    ].join("\t"));
  }
});
      '
    )"
    while IFS="$(printf '\t')" read -r product_id quantity sub_id current_end is_cancelable; do
      [[ -z "$product_id" ]] && continue
      found=$((found + 1))
      if [[ -n "$sub_id" ]]; then
        encoded_sub="$(urlencode "$sub_id")"
        # Stack SDK cancelSubscription maps to:
        #   DELETE /api/v1/payments/products/user/<stackUserId>/pro?subscription_id=<subscriptionId>
        cancel_path="/payments/products/user/${encoded_user}/pro?subscription_id=${encoded_sub}"
        if stack_request_capture DELETE "$cancel_path"; then
          SUMMARY+=("Canceled Stack Pro subscription: ${sub_id}")
        else
          SUMMARY+=("TODO Stack Pro subscription cleanup failed (${HTTP_STATUS}): product=pro subscription=${sub_id} current_period_end=${current_end}")
        fi
      elif [[ "$quantity" =~ ^-?[0-9]+$ && "$quantity" -gt 0 ]]; then
        SUMMARY+=("TODO revoke Stack manual Pro grant: product=pro quantity=${quantity} user=${stack_user_id}")
      else
        SUMMARY+=("Observed Stack Pro product with no active quantity/subscription")
      fi
    done <<EOF
$lines
EOF

    cursor="$(
      printf '%s' "$products_body" | node -e 'let s="";process.stdin.on("data",c=>s+=c);process.stdin.on("end",()=>{const d=JSON.parse(s);process.stdout.write(d.pagination?.next_cursor || d.nextCursor || "");});'
    )"
    if [[ -z "$cursor" ]]; then
      if [[ "$found" == "0" ]]; then
        SUMMARY+=("No Stack Pro products found")
      fi
      return
    fi
  done
}

list_and_clean_stack_products

metadata_state="$(
  printf '%s' "$user_json" | node -e '
let input = "";
process.stdin.on("data", (chunk) => input += chunk);
process.stdin.on("end", () => {
  const user = JSON.parse(input);
  const raw = user.client_read_only_metadata ?? user.clientReadOnlyMetadata ?? {};
  const metadata = raw && typeof raw === "object" && !Array.isArray(raw) ? { ...raw } : {};
  const hadCmuxPlan = Object.prototype.hasOwnProperty.call(metadata, "cmuxPlan");
  const vmPlan = typeof metadata.cmuxVmPlan === "string" && metadata.cmuxVmPlan.trim() ? metadata.cmuxVmPlan.trim() : "";
  delete metadata.cmuxPlan;
  console.log(JSON.stringify({
    hadCmuxPlan,
    vmPlan,
    patchBody: { client_read_only_metadata: metadata },
  }));
});
  '
)"
had_cmux_plan="$(
  printf '%s' "$metadata_state" | node -e 'let s="";process.stdin.on("data",c=>s+=c);process.stdin.on("end",()=>process.stdout.write(JSON.parse(s).hadCmuxPlan ? "1" : "0"));'
)"
cmux_vm_plan="$(
  printf '%s' "$metadata_state" | node -e 'let s="";process.stdin.on("data",c=>s+=c);process.stdin.on("end",()=>process.stdout.write(JSON.parse(s).vmPlan || ""));'
)"
if [[ -n "$cmux_vm_plan" ]]; then
  SUMMARY+=("WARNING cmuxVmPlan is set to '${cmux_vm_plan}' and still overrides cmuxPlan")
fi
if [[ "$had_cmux_plan" == "1" ]]; then
  patch_body="$(
    printf '%s' "$metadata_state" | node -e 'let s="";process.stdin.on("data",c=>s+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(JSON.parse(s).patchBody)));'
  )"
  encoded_user_id="$(urlencode "$stack_user_id")"
  stack_request PATCH "/users/${encoded_user_id}" "$patch_body" >/dev/null
  SUMMARY+=("Removed clientReadOnlyMetadata.cmuxPlan")
else
  SUMMARY+=("clientReadOnlyMetadata.cmuxPlan was already absent")
fi

if [[ -n "$DB_PORT" ]]; then
  db_output="$(
    PGPASSWORD="${CMUX_DB_PASSWORD:-cmux}" psql \
      -h localhost \
      -p "$DB_PORT" \
      -U "${CMUX_DB_USER:-cmux}" \
      -d "${CMUX_DB_NAME:-cmux}" \
      -v ON_ERROR_STOP=1 \
      -v stack_user_id="$stack_user_id" \
      -c "delete from stripe_subscriptions where stack_user_id = :'stack_user_id';" \
      -c "delete from stripe_customers where stack_user_id = :'stack_user_id';" \
      -t
  )"
  SUMMARY+=("Local DB cleanup on port ${DB_PORT}: $(printf '%s' "$db_output" | tr '\n' ';' | sed -E 's/[[:space:]]+/ /g; s/;+$//')")
fi

# Re-check after all cleanup: a Stack-era paid product can survive cancellation
# until its period ends (the API has no early-revoke), and a comped grant can
# have quantity > 0 with no subscription. These no longer grant cmux Pro, but
# they are still useful to report during dev cleanup.
residual_body="$(stack_request GET "/payments/products/user/$(urlencode "$stack_user_id")?limit=50" || true)"
residual="$(printf '%s' "$residual_body" | node -e '
let raw = "";
process.stdin.on("data", (chunk) => { raw += chunk; });
process.stdin.on("end", () => {
  let count = 0;
  try {
    const items = JSON.parse(raw).items ?? [];
    count = items.filter((p) => p.id === "pro" && ((p.quantity ?? 0) > 0 || p.subscription != null)).length;
  } catch {}
  process.stdout.write(String(count));
});
' || echo 0)"
if [ "${residual:-0}" != "0" ]; then
  SUMMARY+=("WARNING: Stack product 'pro' still present (paid period not over or comped grant; no API early-revoke). This account stays Pro until it lapses; use a private window to dogfood checkout.")
fi

checkout_port="${CMUX_PORT:-${PORT:-3777}}"
checkout_url="http://localhost:${checkout_port}/api/billing/checkout?plan=pro"

echo
echo "Summary"
for item in "${SUMMARY[@]+"${SUMMARY[@]}"}"; do
  echo "  - $item"
done

cat <<EOF

Re-test
  Checkout URL: $checkout_url
  Use a private window for a fresh anonymous buyer. For this signed-in dev account, retry checkout after refreshing the session.
EOF
