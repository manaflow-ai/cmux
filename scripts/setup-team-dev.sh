#!/usr/bin/env bash
# Configure named development profiles and optional production verification.
# All credentials stay outside the repository, are verified before saving, and
# are read with the same parser used by the development launchers.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/dev-secrets.sh
source "$SCRIPT_DIR/lib/dev-secrets.sh"

REFRESH_PERSONAL=0
REFRESH_AGENT=0
REFRESH_PRODUCTION=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --refresh) REFRESH_PERSONAL=1; shift ;;
    --refresh-agent) REFRESH_AGENT=1; shift ;;
    --refresh-production) REFRESH_PRODUCTION=1; shift ;;
    -h|--help)
      cat <<'HELP'
Usage: scripts/setup-team-dev.sh [--refresh] [--refresh-agent] [--refresh-production]

Prompts separately for missing development dogfood and simulator/test accounts.
Offers optional production credentials for developers who may want to verify
against the production environment. Decline or press Enter to skip production.
All profiles require an account password. If you normally use email codes, first
set your own password in the Hexclave account portal for the matching environment.
Complete profiles are kept unless their refresh option is selected:
  --refresh             Replace the development personal dogfood account.
  --refresh-agent       Replace the development simulator/test account.
  --refresh-production  Configure or replace the optional production account.

Development: ~/.secrets/cmuxterm-dev.env (CMUX_DOGFOOD_STACK_* / CMUX_UITEST_STACK_*)
Production:  ~/.secrets/cmuxterm-prod.env (CMUX_DOGFOOD_STACK_*)
An existing complete cmux-beta-production.env is copied to the production path
only if that path is absent; the legacy file stays available to explicit callers.
Production requires an explicit --credentials-file selection on a launcher
configured for production; normal development launches never select this file.
Passwords are hidden, verified with the matching sign-in environment, and saved
with mode 600. Requires python3 to verify or adopt credentials and curl for sign-in.
HELP
      exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; exit 2 ;;
  esac
done

SECRETS_DIR="${HOME:?HOME must be set}/.secrets"
DEV_ENV_FILE="$SECRETS_DIR/cmuxterm-dev.env"
PRODUCTION_ENV_FILE="$SECRETS_DIR/cmuxterm-prod.env"

validate_existing_file() {
  local file="$1"
  if [[ -e "$file" || -L "$file" ]]; then
    cmux_dev_secrets_validate_file "$file"
  fi
}

profile_configured() {
  # A subshell keeps the loader's exported variables out of subsequent profiles.
  (cmux_dev_secrets_load --profile "$2" --credentials-file "$1" >/dev/null 2>&1)
}

adopt_legacy_production() (
  local legacy_file="$SECRETS_DIR/cmux-beta-production.env" temporary_file=""
  # Never replace even an incomplete canonical profile or combine its values
  # with legacy credentials. Existing explicit callers retain their old file.
  [[ ! -e "$PRODUCTION_ENV_FILE" && ! -L "$PRODUCTION_ENV_FILE" ]] || return 0
  [[ -e "$legacy_file" || -L "$legacy_file" ]] || return 0
  cmux_dev_secrets_validate_file "$legacy_file"
  profile_configured "$legacy_file" personal || return 0

  umask 077
  temporary_file="$(mktemp "$SECRETS_DIR/.cmux-credentials.XXXXXX")"
  trap 'rm -f "$temporary_file"' EXIT
  cat "$legacy_file" > "$temporary_file"
  chmod 600 "$temporary_file"
  # Publish a complete copy atomically. An exclusive link also protects a
  # canonical path created by another setup process while this copy was made.
  python3 -c '
import os, sys
try:
    os.link(sys.argv[1], sys.argv[2])
except FileExistsError:
    pass
' "$temporary_file" "$PRODUCTION_ENV_FILE"
)

prompt_credentials() {
  local label="$1" optional="$2"
  email=""
  password=""
  while [[ -z "$email" ]]; do
    if ! IFS= read -r -p "$label email: " email; then
      return 2
    fi
    email="${email#"${email%%[![:space:]]*}"}"
    email="${email%"${email##*[![:space:]]}"}"
    [[ -n "$email" ]] && break
    [[ "$optional" -eq 1 ]] && return 2
    echo "  email cannot be empty." >&2
  done
  while [[ -z "$password" ]]; do
    if ! IFS= read -r -s -p "$label password: " password; then
      echo
      return 2
    fi
    echo
    if [[ -z "$password" ]]; then
      echo "  password cannot be empty." >&2
    fi
  done
}

verify_credentials() {
  local environment="$1" project_id client_key response
  # Mirrors the development and production defaults in AuthConfig.swift.
  case "$environment" in
    development)
      project_id="454ecd03-1db2-4050-845e-4ce5b0cd9895"
      client_key="pck_xb63160bwe9699vtxfzfj6emmxpafg5mkjrtp6ehzxv5g" ;;
    production)
      project_id="9790718f-14cd-4f7e-824d-eaf527a82b82"
      client_key="pck_kzj80gx4mh2jrzn1cx6y5e8jk0kwa01vkevh2p9zd4twr" ;;
    *) return 1 ;;
  esac
  if ! command -v curl >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
    echo "error: curl and python3 are required to verify credentials." >&2
    return 1
  fi
  # Credentials travel on stdin, never in subprocess arguments or logs. JSON
  # encoding preserves quotes, backslashes, whitespace, and control characters.
  if ! response="$(
    printf '%s\n%s\n' "$email" "$password" | python3 -c '
import json, sys
email, password = sys.stdin.read().split("\n", 2)[:2]
json.dump({"email": email, "password": password}, sys.stdout)
' | curl -fsS --connect-timeout 10 --max-time 30 \
      -X POST "https://api.stack-auth.com/api/v1/auth/password/sign-in" \
      -H "content-type: application/json" \
      -H "x-stack-project-id: $project_id" \
      -H "x-stack-publishable-client-key: $client_key" \
      -H "x-stack-access-type: client" \
      -H "x-stack-override-error-status: true" \
      --data-binary @- 2>/dev/null
  )"; then
    echo "error: sign-in service unavailable; credentials were not saved." >&2
    return 1
  fi
  if ! printf '%s' "$response" | python3 -c '
import json, sys
try:
    value = json.load(sys.stdin)
    token = value.get("access_token") if isinstance(value, dict) else None
except (ValueError, TypeError):
    token = None
sys.exit(0 if isinstance(token, str) and token else 1)
'; then
    echo "error: sign-in failed; credentials were not saved. Check the account and environment." >&2
    return 1
  fi
}

save_profile() (
  local file="$1" prefix="$2" temporary_file=""
  # File updates are atomic; an interrupted replacement leaves the old pair.
  umask 077
  mkdir -p "$SECRETS_DIR"
  chmod 700 "$SECRETS_DIR"
  validate_existing_file "$file"
  temporary_file="$(mktemp "$SECRETS_DIR/.cmux-credentials.XXXXXX")"
  trap 'rm -f "$temporary_file"' EXIT
  {
    if [[ -f "$file" ]]; then
      awk -F= -v prefix="$prefix" '
        { key = $1; gsub(/^[[:space:]]+|[[:space:]]+$/, "", key) }
        key != prefix "_EMAIL" && key != prefix "_PASSWORD" { print }
      ' "$file"
    else
      echo "# Local cmux sign-in credentials. Never commit or source this file."
    fi
    # The shared parser strips exactly one layer of quotes without evaluating
    # the value. This preserves leading/trailing whitespace and literal quotes.
    printf '%s_EMAIL="%s"\n' "$prefix" "$email"
    printf '%s_PASSWORD="%s"\n' "$prefix" "$password"
  } > "$temporary_file"
  chmod 600 "$temporary_file"
  mv -f "$temporary_file" "$file"
)

configure_profile() {
  local label="$1" environment="$2" profile="$3" prefix="$4" file="$5" refresh="$6" optional="$7"
  local email="" password=""
  validate_existing_file "$file"
  echo "==> $label"
  if [[ "$refresh" -eq 0 ]] && profile_configured "$file" "$profile"; then
    echo "    Already configured; keeping this profile."
    return 0
  fi
  if ! prompt_credentials "$label" "$optional"; then
    if [[ "$optional" -eq 1 ]]; then
      echo "    Production setup skipped; existing credentials were kept."
      return 0
    fi
    echo "error: input ended before the $label account was complete; rerun setup to continue." >&2
    return 1
  fi
  echo "    Verifying with the $environment sign-in service..."
  verify_credentials "$environment"
  save_profile "$file" "$prefix"
  echo "    Verified and saved in $file (mode 600)."
}

configure_production() {
  local choice=""
  echo
  echo "==> Optional production verification"
  echo "    Add this only if you may want to verify against the production environment."
  echo "    This requires your production account password, even if you normally use email codes."
  echo "    First set your own password in the Hexclave account portal for cmux production."
  echo "    These credentials are separate from development and require explicit selection."
  adopt_legacy_production
  validate_existing_file "$PRODUCTION_ENV_FILE"
  if [[ "$REFRESH_PRODUCTION" -eq 0 ]]; then
    if profile_configured "$PRODUCTION_ENV_FILE" personal; then
      echo "    Already configured; use --refresh-production to replace this profile."
      return 0
    fi
    while true; do
      if ! IFS= read -r -p "Configure production credentials now? [y/N]: " choice; then
        choice=""
      fi
      case "$choice" in
        y|Y|yes|YES|Yes) break ;;
        ""|n|N|no|NO|No) echo "    Production setup skipped."; return 0 ;;
        *) echo "    Enter yes to configure production or no to skip." ;;
      esac
    done
  fi
  echo "    Leave the email empty to skip."
  configure_profile "Production verification" production personal CMUX_DOGFOOD_STACK \
    "$PRODUCTION_ENV_FILE" "$REFRESH_PRODUCTION" 1
}

echo "==> cmux developer account setup"
echo "    Use development accounts for both dogfood and simulator/test profiles."
echo "    Both accounts may belong to you; existing complete profiles are preserved."
echo
configure_profile "Development personal dogfood" development personal CMUX_DOGFOOD_STACK \
  "$DEV_ENV_FILE" "$REFRESH_PERSONAL" 0
configure_profile "Development simulator/test" development agent CMUX_UITEST_STACK \
  "$DEV_ENV_FILE" "$REFRESH_AGENT" 0
configure_production

cat <<EOF

==> Development profiles are configured in $DEV_ENV_FILE.
    Personal dogfood: scripts/dev-setup.sh --tag <your-initials>
    Simulator testing: scripts/dev-setup.sh --tag <test-tag> --agent
    Refresh one profile: --refresh (personal), --refresh-agent, or --refresh-production.

    Production verification requires a launcher configured for production and
    an explicit --credentials-file "$PRODUCTION_ENV_FILE".
    Normal development launches do not read the production file.
EOF
