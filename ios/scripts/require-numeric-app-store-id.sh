#!/usr/bin/env bash
set -euo pipefail

APP_ID="${1:-}"
LABEL="${2:-require-numeric-app-store-id}"

if [[ -z "$APP_ID" ]]; then
  printf '%s: App Store app id is required\n' "$LABEL" >&2
  exit 1
fi
if ! [[ "$APP_ID" =~ ^[0-9]+$ ]]; then
  printf "%s: App Store app id must be numeric (got '%s')\n" "$LABEL" "$APP_ID" >&2
  exit 1
fi
