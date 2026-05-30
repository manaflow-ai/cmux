#!/usr/bin/env bash

# Source this file from direnv or dev scripts. It intentionally keeps local dev
# database URLs derived from CMUX_PORT so parallel worktrees cannot hit the same
# Postgres instance by accident.

cmux_web_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cmux_existing_cmux_port_set="${CMUX_PORT+x}"
cmux_existing_cmux_port="${CMUX_PORT-}"
cmux_existing_port_set="${PORT+x}"
cmux_existing_port="${PORT-}"
cmux_existing_db_port_offset_set="${CMUX_DB_PORT_OFFSET+x}"
cmux_existing_db_port_offset="${CMUX_DB_PORT_OFFSET-}"
cmux_existing_db_port_set="${CMUX_DB_PORT+x}"
cmux_existing_db_port="${CMUX_DB_PORT-}"
cmux_existing_db_user_set="${CMUX_DB_USER+x}"
cmux_existing_db_user="${CMUX_DB_USER-}"
cmux_existing_db_password_set="${CMUX_DB_PASSWORD+x}"
cmux_existing_db_password="${CMUX_DB_PASSWORD-}"
cmux_existing_db_name_set="${CMUX_DB_NAME+x}"
cmux_existing_db_name="${CMUX_DB_NAME-}"

cmux_extra_secret_file="${CMUXTERM_EXTRA_ENV_FILE:-${CMUX_WEB_EXTRA_ENV_FILE:-}}"
if [[ -z "$cmux_extra_secret_file" && -f "$HOME/.secrets/cmux.env" ]]; then
  cmux_extra_secret_file="$HOME/.secrets/cmux.env"
fi

cmux_secret_file="${CMUXTERM_ENV_FILE:-${CMUX_WEB_ENV_FILE:-}}"
if [[ -z "$cmux_secret_file" ]]; then
  if [[ -f "$HOME/.secrets/cmuxterm-dev.env" ]]; then
    cmux_secret_file="$HOME/.secrets/cmuxterm-dev.env"
  elif [[ -f "$HOME/.secret/cmuxterm.env" ]]; then
    cmux_secret_file="$HOME/.secret/cmuxterm.env"
  elif [[ -f "$HOME/.secrets/cmuxterm.env" ]]; then
    cmux_secret_file="$HOME/.secrets/cmuxterm.env"
  else
    echo "Missing cmux web secrets. Expected ~/.secrets/cmuxterm-dev.env." >&2
    return 1 2>/dev/null || exit 1
  fi
fi

cmux_nounset_was_enabled=0
case "$-" in
  *u*) cmux_nounset_was_enabled=1 ;;
esac
set +u
set -a
if [[ -n "$cmux_extra_secret_file" ]]; then
  # shellcheck disable=SC1090
  source "$cmux_extra_secret_file"
fi
# shellcheck disable=SC1090
source "$cmux_secret_file"
set +a
if ! grep -q '^STACK_SUPER_SECRET_ADMIN_KEY=' "$cmux_secret_file"; then
  unset STACK_SUPER_SECRET_ADMIN_KEY
fi
if [[ "$cmux_nounset_was_enabled" == "1" ]]; then
  set -u
fi

if [[ -n "$cmux_existing_cmux_port_set" ]]; then export CMUX_PORT="$cmux_existing_cmux_port"; fi
if [[ -n "$cmux_existing_port_set" ]]; then export PORT="$cmux_existing_port"; fi
if [[ -n "$cmux_existing_db_port_offset_set" ]]; then export CMUX_DB_PORT_OFFSET="$cmux_existing_db_port_offset"; fi
if [[ -n "$cmux_existing_db_port_set" ]]; then export CMUX_DB_PORT="$cmux_existing_db_port"; fi
if [[ -n "$cmux_existing_db_user_set" ]]; then export CMUX_DB_USER="$cmux_existing_db_user"; fi
if [[ -n "$cmux_existing_db_password_set" ]]; then export CMUX_DB_PASSWORD="$cmux_existing_db_password"; fi
if [[ -n "$cmux_existing_db_name_set" ]]; then export CMUX_DB_NAME="$cmux_existing_db_name"; fi

cmux_port="${CMUX_PORT:-${PORT:-3777}}"
if [[ ! "$cmux_port" =~ ^[0-9]+$ ]]; then
  echo "CMUX_PORT must be numeric, got: $cmux_port" >&2
  return 2 2>/dev/null || exit 2
fi
export CMUX_PORT="$cmux_port"

cmux_db_offset="${CMUX_DB_PORT_OFFSET:-10000}"
if [[ ! "$cmux_db_offset" =~ ^[0-9]+$ ]]; then
  echo "CMUX_DB_PORT_OFFSET must be numeric, got: $cmux_db_offset" >&2
  return 2 2>/dev/null || exit 2
fi
export CMUX_DB_PORT_OFFSET="$cmux_db_offset"

export CMUX_DB_USER="${CMUX_DB_USER:-cmux}"
export CMUX_DB_PASSWORD="${CMUX_DB_PASSWORD:-cmux}"
export CMUX_DB_NAME="${CMUX_DB_NAME:-cmux}"
export CMUX_DB_PORT="${CMUX_DB_PORT:-$((cmux_port + cmux_db_offset))}"

if [[ "${CMUX_DEV_USE_EXTERNAL_DATABASE_URL:-0}" != "1" ]]; then
  export DATABASE_URL="postgres://${CMUX_DB_USER}:${CMUX_DB_PASSWORD}@localhost:${CMUX_DB_PORT}/${CMUX_DB_NAME}"
  export DIRECT_DATABASE_URL="$DATABASE_URL"
elif [[ -z "${DIRECT_DATABASE_URL:-}" && -n "${DATABASE_URL:-}" ]]; then
  export DIRECT_DATABASE_URL="$DATABASE_URL"
fi

if [[ "${CMUX_DEV_USE_EXTERNAL_VM_API_BASE_URL:-0}" != "1" ]]; then
  export CMUX_VM_API_BASE_URL="http://localhost:${CMUX_PORT}"
fi

# Local dev should not require a checked-in or per-worktree .env.local just to pass
# startup validation for routes the developer is not exercising.
export RESEND_API_KEY="${RESEND_API_KEY:-cmux-local-dev}"
export CMUX_FEEDBACK_FROM_EMAIL="${CMUX_FEEDBACK_FROM_EMAIL:-dev@example.invalid}"
export CMUX_FEEDBACK_RATE_LIMIT_ID="${CMUX_FEEDBACK_RATE_LIMIT_ID:-cmux-feedback-local}"

export CMUX_WEB_SECRET_ENV_FILE="$cmux_secret_file"
export CMUX_WEB_EXTRA_SECRET_ENV_FILE="$cmux_extra_secret_file"
export PATH="$cmux_web_dir/node_modules/.bin:$PATH"
