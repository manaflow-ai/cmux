#!/usr/bin/env bash
set -euo pipefail

WEB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEV_STACK_PROJECT_ID="454ecd03-1db2-4050-845e-4ce5b0cd9895"
PROD_STACK_PROJECT_ID="9790718f-14cd-4f7e-824d-eaf527a82b82"
STACK_API_BASE_URL="${STACK_API_BASE_URL:-https://api.stack-auth.com}"

EMAIL=""
PLAN="pro"
ALLOW_PROJECT=0

usage() {
  cat >&2 <<'EOF'
Usage: web/scripts/stripe/dev-grant.sh [--allow-project] [--plan <id>] <email>

Fake-pays a Stack Auth dev account: writes clientReadOnlyMetadata.cmuxVmPlan
(default "pro"), the manual override that survives purchase reconciliation, so billing-gated features unlock without checkout. This is the
inverse of dev-reset.sh; run dev-reset.sh <email> to undo it. For the full
checkout path at $0 instead, use promotion code CMUXDEV100 in test-mode
checkout (allow_promotion_codes is already enabled).
EOF
}

die() {
  echo "dev-grant: $*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --allow-project)
      ALLOW_PROJECT=1
      shift
      ;;
    --plan)
      if [[ $# -lt 2 ]]; then
        echo "--plan requires a value" >&2
        usage
        exit 2
      fi
      PLAN="${2:-}"
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
if [[ ! "$PLAN" =~ ^[a-z0-9_-]+$ ]]; then
  die "--plan must be a lowercase plan id such as pro"
fi

for required in curl node; do
  if ! command -v "$required" >/dev/null 2>&1; then
    die "$required is required"
  fi
done

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

resolve_stack_env

if [[ "$NEXT_PUBLIC_STACK_PROJECT_ID" == "$PROD_STACK_PROJECT_ID" ]]; then
  die "refusing to run against the production Stack project"
fi
if [[ "$ALLOW_PROJECT" != "1" && "$NEXT_PUBLIC_STACK_PROJECT_ID" != "$DEV_STACK_PROJECT_ID" ]]; then
  die "refusing Stack project ${NEXT_PUBLIC_STACK_PROJECT_ID}; pass --allow-project for non-prod test projects"
fi

echo "cmux billing dev grant"
echo "  Stack project: $NEXT_PUBLIC_STACK_PROJECT_ID"
echo "  Email: $EMAIL"
echo "  Plan: $PLAN"

encoded_email="$(urlencode "$EMAIL")"
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
  die "no Stack user found with primary email $EMAIL (sign into the dev app first)"
elif [[ "$user_match_status" == "11" ]]; then
  die "multiple Stack users matched primary email $EMAIL"
elif [[ "$user_match_status" != "0" ]]; then
  die "failed to parse Stack users response"
fi

grant_state="$(
  printf '%s' "$user_json" | node -e '
const plan = process.argv[1];
let input = "";
process.stdin.on("data", (chunk) => input += chunk);
process.stdin.on("end", () => {
  const user = JSON.parse(input);
  const raw = user.client_read_only_metadata ?? user.clientReadOnlyMetadata ?? {};
  const metadata = raw && typeof raw === "object" && !Array.isArray(raw) ? { ...raw } : {};
  const previous = typeof metadata.cmuxVmPlan === "string" ? metadata.cmuxVmPlan : "";
  metadata.cmuxVmPlan = plan;
  console.log(JSON.stringify({
    userId: user.id,
    previous,
    patchBody: { client_read_only_metadata: metadata },
  }));
});
  ' "$PLAN"
)"
stack_user_id="$(
  printf '%s' "$grant_state" | node -e 'let s="";process.stdin.on("data",c=>s+=c);process.stdin.on("end",()=>process.stdout.write(JSON.parse(s).userId));'
)"
previous_plan="$(
  printf '%s' "$grant_state" | node -e 'let s="";process.stdin.on("data",c=>s+=c);process.stdin.on("end",()=>process.stdout.write(JSON.parse(s).previous));'
)"
patch_body="$(
  printf '%s' "$grant_state" | node -e 'let s="";process.stdin.on("data",c=>s+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(JSON.parse(s).patchBody)));'
)"

encoded_user_id="$(urlencode "$stack_user_id")"
stack_request PATCH "/users/${encoded_user_id}" "$patch_body" >/dev/null

echo "Granted clientReadOnlyMetadata.cmuxVmPlan=${PLAN} to ${stack_user_id}${previous_plan:+ (was: ${previous_plan})}"
echo "Undo with: web/scripts/stripe/dev-reset.sh ${EMAIL}"
