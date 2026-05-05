#!/usr/bin/env bash
set -euo pipefail

output_path="${1:-/tmp/continue-params.json}"
trusted_org="${CIRCLECI_TRUSTED_GITHUB_ORG:-manaflow-ai}"
branch="${CIRCLECI_PIPELINE_BRANCH:-}"
sender_login="${CIRCLECI_PIPELINE_SENDER_LOGIN:-}"

require_approval=true
reason="untrusted"

is_safe_github_component() {
  local value="$1"
  case "$value" in
    ""|*[!A-Za-z0-9_.-]*)
      return 1
      ;;
    *)
      return 0
      ;;
  esac
}

write_parameters() {
  mkdir -p "$(dirname "$output_path")"
  printf '{\n  "require_approval": %s\n}\n' "$require_approval" > "$output_path"
}

check_github_membership() {
  local endpoint="$1"
  local token="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
  local response_file http_status
  local auth_headers=()

  response_file="$(mktemp)"
  trap 'rm -f "$response_file"' RETURN

  if [ -n "$token" ]; then
    auth_headers=(-H "Authorization: Bearer $token")
  fi

  http_status="$(
    curl -sS \
      -o "$response_file" \
      -w "%{http_code}" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "${auth_headers[@]}" \
      "https://api.github.com/orgs/${trusted_org}/${endpoint}/${sender_login}" || true
  )"

  case "$http_status" in
    204)
      require_approval=false
      reason="github-org-member"
      ;;
    302|404)
      require_approval=true
      reason="not-github-org-member"
      ;;
    *)
      require_approval=true
      reason="github-membership-check-${http_status:-failed}"
      ;;
  esac
}

if [ "$branch" = "main" ]; then
  require_approval=false
  reason="main-branch"
elif ! is_safe_github_component "$trusted_org" || ! is_safe_github_component "$sender_login"; then
  require_approval=true
  reason="missing-or-invalid-github-sender"
elif [ -n "${GITHUB_TOKEN:-${GH_TOKEN:-}}" ]; then
  check_github_membership "members"
else
  check_github_membership "public_members"
fi

write_parameters
echo "CircleCI approval required: ${require_approval} (${reason})"
