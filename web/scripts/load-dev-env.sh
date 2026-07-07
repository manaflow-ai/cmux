#!/usr/bin/env bash

# Source this file from direnv or dev scripts. It intentionally keeps local dev
# database URLs derived from CMUX_PORT so parallel worktrees cannot hit the same
# Postgres instance by accident.

cmux_web_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck disable=SC1091
source "$cmux_web_dir/scripts/stack-placeholders.sh"

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
cmux_existing_freestyle_snapshot_set="${FREESTYLE_SANDBOX_SNAPSHOT+x}"
cmux_existing_freestyle_snapshot="${FREESTYLE_SANDBOX_SNAPSHOT-}"
cmux_existing_e2b_template_set="${E2B_CMUXD_WS_TEMPLATE+x}"
cmux_existing_e2b_template="${E2B_CMUXD_WS_TEMPLATE-}"
cmux_existing_daytona_snapshot_set="${DAYTONA_SANDBOX_SNAPSHOT+x}"
cmux_existing_daytona_snapshot="${DAYTONA_SANDBOX_SNAPSHOT-}"
cmux_existing_stack_project_set="${NEXT_PUBLIC_STACK_PROJECT_ID+x}"
cmux_existing_stack_project="${NEXT_PUBLIC_STACK_PROJECT_ID-}"
cmux_existing_stack_client_set="${NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY+x}"
cmux_existing_stack_client="${NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY-}"
cmux_existing_stack_secret_set="${STACK_SECRET_SERVER_KEY+x}"
cmux_existing_stack_secret="${STACK_SECRET_SERVER_KEY-}"

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
if [[ -n "$cmux_secret_file" ]]; then
  # shellcheck disable=SC1090
  source "$cmux_secret_file"
fi
set +a
if [[ -z "$cmux_secret_file" ]] || ! grep -q '^STACK_SUPER_SECRET_ADMIN_KEY=' "$cmux_secret_file"; then
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
if [[ -n "$cmux_existing_freestyle_snapshot_set" ]]; then export FREESTYLE_SANDBOX_SNAPSHOT="$cmux_existing_freestyle_snapshot"; fi
if [[ -n "$cmux_existing_e2b_template_set" ]]; then export E2B_CMUXD_WS_TEMPLATE="$cmux_existing_e2b_template"; fi
if [[ -n "$cmux_existing_daytona_snapshot_set" ]]; then export DAYTONA_SANDBOX_SNAPSHOT="$cmux_existing_daytona_snapshot"; fi
if [[ -n "$cmux_existing_stack_project_set" ]]; then export NEXT_PUBLIC_STACK_PROJECT_ID="$cmux_existing_stack_project"; fi
if [[ -n "$cmux_existing_stack_client_set" ]]; then export NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY="$cmux_existing_stack_client"; fi
if [[ -n "$cmux_existing_stack_secret_set" ]]; then export STACK_SECRET_SERVER_KEY="$cmux_existing_stack_secret"; fi

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
export CMUX_CLIENT_CONFIG_RATE_LIMIT_ID="${CMUX_CLIENT_CONFIG_RATE_LIMIT_ID:-cmux-client-config-local}"
export CMUX_PUSH_RATE_LIMIT_ID="${CMUX_PUSH_RATE_LIMIT_ID:-cmux-push-local}"

# Local browser auth should boot on a fresh dev machine. The public DEBUG Stack
# project/client key mirror the macOS DEBUG defaults. A real Stack server key is
# still required for server-side Stack calls.
export NEXT_PUBLIC_STACK_PROJECT_ID="${NEXT_PUBLIC_STACK_PROJECT_ID:-454ecd03-1db2-4050-845e-4ce5b0cd9895}"
export NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY="${NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY:-pck_xb63160bwe9699vtxfzfj6emmxpafg5mkjrtp6ehzxv5g}"
if [[ "${STACK_SECRET_SERVER_KEY:-}" == "$CMUX_STACK_LOCAL_DEV_PLACEHOLDER" ]]; then
  export CMUX_STACK_SECRET_SERVER_KEY_PLACEHOLDER=1
else
  export CMUX_STACK_SECRET_SERVER_KEY_PLACEHOLDER=0
fi

export CMUX_WEB_SECRET_ENV_FILE="$cmux_secret_file"
export CMUX_WEB_EXTRA_SECRET_ENV_FILE="$cmux_extra_secret_file"
export PATH="$cmux_web_dir/node_modules/.bin:$PATH"
