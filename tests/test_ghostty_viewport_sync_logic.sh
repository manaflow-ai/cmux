#!/usr/bin/env bash
set -euo pipefail

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

swiftc \
  Sources/GhosttyViewportSync.swift \
  tests/test_ghostty_viewport_sync_logic.swift \
  -o "$TMPDIR/test-ghostty-viewport-sync-logic"

"$TMPDIR/test-ghostty-viewport-sync-logic"
