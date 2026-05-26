#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cmux-textbox-policy.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

swiftc \
  -module-cache-path "$TMP_DIR/module-cache" \
  "$REPO_ROOT/Sources/TextBoxInputChromeBackgroundPolicy.swift" \
  "$REPO_ROOT/tests/textbox_chrome_background_policy_regression.swift" \
  -o "$TMP_DIR/textbox_chrome_background_policy_regression"

"$TMP_DIR/textbox_chrome_background_policy_regression"
