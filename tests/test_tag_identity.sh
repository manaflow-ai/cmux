#!/usr/bin/env bash
# Regression test: macOS and iOS reload paths share one option-safe tag identity.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib/mobile-attach.sh
source "$ROOT_DIR/scripts/lib/mobile-attach.sh"

assert_identity() {
  local raw="$1" expected_slug="$2" expected_bundle="$3"
  local actual_slug actual_bundle
  actual_slug="$(cmux_attach__slug_raw "$raw")"
  actual_bundle="$(cmux_attach__bundle_seg "$raw")"
  if [[ "$actual_slug" != "$expected_slug" || "$actual_bundle" != "$expected_bundle" ]]; then
    printf 'FAIL: tag %q => slug=%q bundle=%q, expected slug=%q bundle=%q\n' \
      "$raw" "$actual_slug" "$actual_bundle" "$expected_slug" "$expected_bundle" >&2
    exit 1
  fi
}

assert_identity "default" "default" "default"
assert_identity "-n" "n" "n"
assert_identity "-ne" "ne" "ne"
assert_identity "Feature Tag" "feature-tag" "feature.tag"

if cmux_attach_tag_is_usable "default"; then
  echo "FAIL: reserved tag 'default' was accepted" >&2
  exit 1
fi
if ! cmux_attach_tag_is_usable "feature"; then
  echo "FAIL: normal tag 'feature' was rejected" >&2
  exit 1
fi

assert_entrypoint_rejects_default() {
  local script="$1" output
  if output="$("$script" --tag default 2>&1)"; then
    echo "FAIL: $script accepted reserved tag 'default'" >&2
    exit 1
  fi
  if ! grep -Fq "reserved tag 'default'" <<<"$output"; then
    printf 'FAIL: %s rejected for the wrong reason:\n%s\n' "$script" "$output" >&2
    exit 1
  fi
}

assert_entrypoint_rejects_default "$ROOT_DIR/scripts/reload.sh"
assert_entrypoint_rejects_default "$ROOT_DIR/ios/scripts/reload.sh"

echo "PASS: shared dev tag identity is option-safe and consistent"
