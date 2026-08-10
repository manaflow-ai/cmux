#!/usr/bin/env bash
set -euo pipefail

CRASH_REPORT_SUBDIR="${1:-cmux/crash}"
ENCODED_CRASH_REPORT_SUBDIR="$(
  printf '%s' "$CRASH_REPORT_SUBDIR" | tr '/=' '--'
)"

printf 'crashsubdir-%s-sentry-off-scene-v2\n' "$ENCODED_CRASH_REPORT_SUBDIR"
