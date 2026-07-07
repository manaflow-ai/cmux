#!/usr/bin/env bash
# One-time, idempotent team dogfood onboarding.
#
# Each developer runs this ONCE to store their own Stack account in
# ~/.secrets/cmuxterm-dev.env. Thereafter every DEBUG build they make with
# scripts/dev-setup.sh --tag <x> auto-signs-in as THEM and auto-attaches to
# THEIR Mac, with zero manual steps. DEBUG-only and per-user: the file lives
# outside the repo and is never committed.
#
# This script:
#   1. If ~/.secrets/cmuxterm-dev.env already has a complete dogfood pair, prints
#      who it is configured as and exits 0 (re-running is safe).
#   2. Otherwise prompts for the developer's Stack email + password (the password
#      is read with `read -s` and never echoed), writes the file with chmod 600.
#   3. Verifies the credentials with a real Stack sign-in (the same project,
#      endpoint, and keys the DEBUG app uses) and reports success or failure.
#   4. Prints the exact next command to build a signed-in, auto-attached build.
#
# Reuses scripts/lib/dev-secrets.sh for all parsing; it does not duplicate it.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/dev-secrets.sh
source "$SCRIPT_DIR/lib/dev-secrets.sh"

HOME_DIR="${HOME:-}"
if [[ -z "$HOME_DIR" ]]; then
  echo "error: \$HOME is not set; cannot locate ~/.secrets." >&2
  exit 1
fi
SECRETS_DIR="$HOME_DIR/.secrets"
DEV_ENV_FILE="$SECRETS_DIR/cmuxterm-dev.env"

# The DEBUG (development) Stack project the macOS/iOS dev builds sign in against.
# Mirrors AuthConfig.swift development defaults so this verify path matches what
# the app actually does. (DEBUG => CMUXAuthEnvironment.development.)
STACK_BASE_URL="https://api.stack-auth.com"
STACK_PROJECT_ID="454ecd03-1db2-4050-845e-4ce5b0cd9895"
STACK_PUBLISHABLE_CLIENT_KEY="pck_xb63160bwe9699vtxfzfj6emmxpafg5mkjrtp6ehzxv5g"

next_steps() {
  local email="$1"
  cat <<EOF

==> Configured. Next, build a signed-in + auto-attached dev build:

      scripts/dev-setup.sh --tag <your-initials>

    That builds the tagged macOS DEBUG app, auto-signs-in as
    ${email}, enables the iOS pairing host, mints an attach
    ticket, and launches the iOS dev build auto-attached to your Mac.
    Mac-only: scripts/dev-setup.sh --tag <x> --surface mac
EOF
}

# --- idempotent: already configured? ----------------------------------------
# cmux_dev_secrets_load resolves a COMPLETE pair from the same precedence chain
# the app uses. If the dogfood pair already resolves from the dev file (or env),
# we are done. Run it in a subshell so the exported password never enters this
# process environment.
existing_email="$(
  cmux_dev_secrets_load >/dev/null 2>&1 && printf '%s' "${CMUX_UITEST_STACK_EMAIL:-}" || true
)"
if [[ -n "$existing_email" ]]; then
  echo "==> already configured as ${existing_email}"
  echo "    (creds resolve via scripts/lib/dev-secrets.sh; delete $DEV_ENV_FILE to reset)"
  next_steps "$existing_email"
  exit 0
fi

# --- prompt for the developer's own Stack account ----------------------------
echo "==> cmux team dogfood setup (one-time, per developer)"
echo "    Stores YOUR Stack account in $DEV_ENV_FILE so DEBUG builds sign in as you."
echo

email=""
while [[ -z "$email" ]]; do
  read -r -p "Stack email: " email
  email="${email#"${email%%[![:space:]]*}"}"
  email="${email%"${email##*[![:space:]]}"}"
  if [[ -z "$email" ]]; then
    echo "  email cannot be empty." >&2
  fi
done

password=""
while [[ -z "$password" ]]; do
  # -s: never echo the password to the terminal.
  read -r -s -p "Stack password: " password
  echo
  if [[ -z "$password" ]]; then
    echo "  password cannot be empty." >&2
  fi
done

# Emit a JSON string literal for a value, escaping backslash and double quote so
# the request body stays valid even for unusual passwords. No external deps.
json_string() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '"%s"' "$s"
}

# --- verify against Stack BEFORE writing -------------------------------------
# Hits the exact endpoint/project/keys the DEBUG app's StackClientApp uses.
# A successful sign-in returns an access_token; a wrong pair returns a known
# error code (e.g. EMAIL_PASSWORD_MISMATCH). x-stack-override-error-status keeps
# the HTTP status at 200 so we read the JSON body for the verdict.
verify_credentials() {
  local resp
  if ! command -v curl >/dev/null 2>&1; then
    echo "warning: curl not found; skipping credential verification." >&2
    return 2
  fi
  resp="$(
    curl -fsS -X POST "$STACK_BASE_URL/api/v1/auth/password/sign-in" \
      -H "content-type: application/json" \
      -H "x-stack-project-id: $STACK_PROJECT_ID" \
      -H "x-stack-publishable-client-key: $STACK_PUBLISHABLE_CLIENT_KEY" \
      -H "x-stack-access-type: client" \
      -H "x-stack-override-error-status: true" \
      --data-binary @- <<JSON 2>/dev/null || true
{"email": $(json_string "$email"), "password": $(json_string "$password")}
JSON
  )"
  if [[ -z "$resp" ]]; then
    echo "warning: no response from Stack (network issue?); could not verify." >&2
    return 2
  fi
  if printf '%s' "$resp" | grep -q '"access_token"'; then
    return 0
  fi
  # Surface the error code (e.g. EMAIL_PASSWORD_MISMATCH) without dumping tokens.
  local code
  code="$(printf '%s' "$resp" | sed -n 's/.*"code"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
  if [[ -n "$code" ]]; then
    echo "  Stack rejected the credentials: $code" >&2
  fi
  return 1
}

echo
echo "==> verifying with Stack..."
verify_rc=0
verify_credentials || verify_rc=$?

case "$verify_rc" in
  0)
    echo "==> credentials verified."
    ;;
  1)
    echo "error: sign-in failed; not writing $DEV_ENV_FILE." >&2
    echo "       Re-run scripts/setup-team-dev.sh with the correct Stack account." >&2
    exit 1
    ;;
  *)
    echo "==> could not verify non-interactively; writing the file as a best effort."
    echo "    Confirm by running scripts/dev-setup.sh --tag <x> and checking the build signs in."
    ;;
esac

# --- write the per-user creds file (chmod 600) -------------------------------
mkdir -p "$SECRETS_DIR"
chmod 700 "$SECRETS_DIR" 2>/dev/null || true

umask_old="$(umask)"
umask 077
{
  echo "# cmux per-developer dogfood credentials. Written by scripts/setup-team-dev.sh."
  echo "# DEBUG-only, per-user; never commit. See scripts/cmuxterm-dev.env.example."
  printf 'CMUX_DOGFOOD_STACK_EMAIL=%s\n' "$email"
  printf 'CMUX_DOGFOOD_STACK_PASSWORD=%s\n' "$password"
} > "$DEV_ENV_FILE"
umask "$umask_old"
chmod 600 "$DEV_ENV_FILE"

echo "==> wrote $DEV_ENV_FILE (chmod 600) for ${email}"
next_steps "$email"
