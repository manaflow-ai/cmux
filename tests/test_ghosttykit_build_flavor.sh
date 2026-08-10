#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/ghosttykit-build-flavor.sh"

DEFAULT_FLAVOR="$($SCRIPT)"
CUSTOM_FLAVOR="$($SCRIPT 'team/crash=reports')"

if [ "$DEFAULT_FLAVOR" != "crashsubdir-cmux-crash-sentry-off-scene-v2" ]; then
  echo "FAIL: default GhosttyKit build flavor does not name the scene archive format"
  exit 1
fi

if [ "$CUSTOM_FLAVOR" != "crashsubdir-team-crash-reports-sentry-off-scene-v2" ]; then
  echo "FAIL: GhosttyKit build flavor does not encode the crash-report subdirectory"
  exit 1
fi

if [ "$DEFAULT_FLAVOR" = "crashsubdir-cmux-crash-sentry-off-v1" ]; then
  echo "FAIL: scene archive reused the legacy one-framework release identity"
  exit 1
fi

echo "PASS: GhosttyKit build flavor identifies the two-framework scene archive"
