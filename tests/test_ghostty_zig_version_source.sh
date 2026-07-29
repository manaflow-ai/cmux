#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RESOLVER="$ROOT_DIR/scripts/ghostty-required-zig-version.sh"

if [[ ! -x "$RESOLVER" ]]; then
  echo "FAIL: missing executable Ghostty Zig version resolver" >&2
  exit 1
fi

expected="$(
  awk -F '"' '/minimum_zig_version/ { print $2; exit }' \
    "$ROOT_DIR/ghostty/build.zig.zon"
)"
actual="$("$RESOLVER")"
if [[ -z "$expected" || "$actual" != "$expected" ]]; then
  echo "FAIL: resolver returned '$actual', expected '$expected'" >&2
  exit 1
fi

fixture_dir="$(mktemp -d "${TMPDIR:-/tmp}/cmux-ghostty-zig-version.XXXXXX")"
trap 'rm -rf "$fixture_dir"' EXIT
fixture="$fixture_dir/build.zig.zon"
printf '.{ .minimum_zig_version = "99.1.2", }\n' > "$fixture"
fixture_actual="$(GHOSTTY_ZIG_MANIFEST="$fixture" "$RESOLVER")"
if [[ "$fixture_actual" != "99.1.2" ]]; then
  echo "FAIL: resolver ignored the supplied manifest" >&2
  exit 1
fi

for consumer in \
  "$ROOT_DIR/scripts/install-zig-ci.sh" \
  "$ROOT_DIR/scripts/build-ghostty-cli-helper.sh"
do
  if ! grep -Fq 'ghostty-required-zig-version.sh' "$consumer"; then
    echo "FAIL: $(basename "$consumer") does not use the shared resolver" >&2
    exit 1
  fi
done

echo "PASS: Ghostty Zig consumers share the submodule version"
