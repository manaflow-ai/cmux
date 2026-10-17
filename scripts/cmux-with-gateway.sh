#!/usr/bin/env bash
#
# cmux-with-gateway.sh — workaround wrapper that pre-exports LLM gateway env
# vars before exec'ing cmux, so gateway-fronted agents (Claude Code, Codex,
# Gemini CLI) reach a local proxy like LiteLLM / Helicone / OpenRouter.
#
# Tracking issue: https://github.com/manaflow-ai/cmux/issues/3317
# Documentation:  docs/llm-gateway.md
#
# Usage:
#   cmux-with-gateway.sh                  # forwards no args (launches cmux UI)
#   cmux-with-gateway.sh sessions list    # any cmux subcommand
#   cmux-with-gateway.sh --debug ...      # print what was loaded, then run
#
# Config file (default ~/.cmux/gateway.env). Each line is KEY=VALUE.
# Lines starting with # are comments. Values are taken verbatim — do not quote.
#
# Override config path with CMUX_GATEWAY_ENV_FILE.
# Override cmux binary with CMUX_BIN.

set -euo pipefail

CMUX_GATEWAY_ENV_FILE="${CMUX_GATEWAY_ENV_FILE:-$HOME/.cmux/gateway.env}"
DEBUG=0

if [[ "${1:-}" == "--debug" ]]; then
  DEBUG=1
  shift
fi

# Resolve cmux binary:
#   1. $CMUX_BIN if set
#   2. cmux on $PATH (excluding ourselves to avoid recursion)
#   3. /Applications/cmux.app/Contents/Resources/bin/cmux
#   4. ~/Applications/cmux.app/Contents/Resources/bin/cmux
SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

resolve_cmux() {
  if [[ -n "${CMUX_BIN:-}" ]]; then
    if [[ -x "$CMUX_BIN" ]]; then
      printf '%s\n' "$CMUX_BIN"
      return 0
    fi
    echo "cmux-with-gateway: CMUX_BIN=$CMUX_BIN is not executable" >&2
    return 1
  fi

  local cand
  while IFS= read -r cand; do
    [[ -z "$cand" || "$cand" == "$SCRIPT_PATH" ]] && continue
    [[ -x "$cand" ]] && { printf '%s\n' "$cand"; return 0; }
  done < <(type -aP cmux 2>/dev/null || true)

  for cand in \
    "/Applications/cmux.app/Contents/Resources/bin/cmux" \
    "$HOME/Applications/cmux.app/Contents/Resources/bin/cmux"; do
    [[ -x "$cand" ]] && { printf '%s\n' "$cand"; return 0; }
  done

  echo "cmux-with-gateway: cmux binary not found. Set CMUX_BIN or add cmux to PATH." >&2
  return 1
}

CMUX_BIN_RESOLVED="$(resolve_cmux)"

# Load gateway env file. Each non-empty, non-comment line of the form KEY=VALUE
# is exported. We deliberately do NOT `source` the file (avoids running shell
# code from a credential file).
LOADED_KEYS=()
if [[ -f "$CMUX_GATEWAY_ENV_FILE" ]]; then
  # Refuse to load a world-readable credential file.
  if [[ "$(uname -s)" == "Darwin" ]]; then
    PERMS="$(stat -f '%A' "$CMUX_GATEWAY_ENV_FILE")"
  else
    PERMS="$(stat -c '%a' "$CMUX_GATEWAY_ENV_FILE")"
  fi
  if [[ "$PERMS" != "600" && "$PERMS" != "400" ]]; then
    echo "cmux-with-gateway: refusing to load $CMUX_GATEWAY_ENV_FILE (mode $PERMS); chmod 600 it" >&2
    exit 2
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    # strip leading/trailing whitespace
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" || "${line:0:1}" == "#" ]] && continue
    if [[ "$line" != *=* ]]; then
      echo "cmux-with-gateway: ignoring malformed line: $line" >&2
      continue
    fi
    key="${line%%=*}"
    value="${line#*=}"
    # accept only sane env-var names
    if [[ ! "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]]; then
      echo "cmux-with-gateway: ignoring suspicious key: $key" >&2
      continue
    fi
    export "$key"="$value"
    LOADED_KEYS+=("$key")
  done < "$CMUX_GATEWAY_ENV_FILE"
elif (( DEBUG )); then
  echo "cmux-with-gateway: $CMUX_GATEWAY_ENV_FILE not found, running cmux without gateway env" >&2
fi

if (( DEBUG )); then
  echo "cmux-with-gateway: cmux binary  -> $CMUX_BIN_RESOLVED" >&2
  echo "cmux-with-gateway: env file     -> $CMUX_GATEWAY_ENV_FILE" >&2
  echo "cmux-with-gateway: loaded keys  -> ${LOADED_KEYS[*]:-<none>}" >&2
fi

exec "$CMUX_BIN_RESOLVED" "$@"
