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
printf '.{\n    .minimum_zig_version = "99.1.2",\n}\n' > "$fixture"
fixture_actual="$(GHOSTTY_ZIG_MANIFEST="$fixture" "$RESOLVER")"
if [[ "$fixture_actual" != "99.1.2" ]]; then
  echo "FAIL: resolver ignored the supplied manifest" >&2
  exit 1
fi

for consumer in \
  "$ROOT_DIR/scripts/install-zig-ci.sh" \
  "$ROOT_DIR/scripts/build-ghostty-cli-helper.sh"
do
  if ! grep -Fq 'ZIG_REQUIRED="${ZIG_REQUIRED:-$("$SCRIPT_DIR/ghostty-required-zig-version.sh")}"' "$consumer"; then
    echo "FAIL: $(basename "$consumer") does not assign the shared resolver result" >&2
    exit 1
  fi
done

reload_script="$ROOT_DIR/scripts/reload.sh"
installer_script="$ROOT_DIR/scripts/install-zig-ci.sh"
for required_assignment in \
  'ZIG_LOCAL_INSTALL_ONLY=1' \
  'ZIG_PATH_OUTPUT="$ZIG_PATH_FILE"' \
  'XCODEBUILD_ARGS+=(CMUX_ZIG="$CMUX_ZIG")'
do
  if ! grep -Fq "$required_assignment" "$reload_script"; then
    echo "FAIL: reload.sh does not provision and forward the resolved Zig executable" >&2
    exit 1
  fi
done

if ! grep -Fq 'if [[ "${CMUX_SKIP_ZIG_BUILD:-}" != "1" ]]; then' "$reload_script"; then
  echo "FAIL: reload.sh does not preserve the explicit no-Zig build path" >&2
  exit 1
fi

if grep -Fq 'rm -rf "$target_root"' "$installer_script"; then
  echo "FAIL: Zig cache publication can delete a toolchain used by another reload" >&2
  exit 1
fi

if ! grep -Fq 'install_lock="${target_root}.install-lock"' "$installer_script"; then
  echo "FAIL: Zig cache publication is not serialized per toolchain" >&2
  exit 1
fi

for documentation in \
  "$ROOT_DIR/cmux-tui/README.md" \
  "$ROOT_DIR/cmux-tui/docs/getting-started.md"
do
  if ! grep -Fq './scripts/ghostty-required-zig-version.sh' "$documentation"; then
    echo "FAIL: $documentation does not reference the shared Zig version source" >&2
    exit 1
  fi
done

echo "PASS: Ghostty Zig consumers and setup docs share the submodule version"
