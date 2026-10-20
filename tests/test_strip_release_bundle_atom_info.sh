#!/usr/bin/env bash
# strip-release-bundle.sh removes LC_ATOM_INFO (mergeable-library link data,
# read only by a static link) from bundled frameworks and keeps their symbols.
# Sentry.framework ships 6.6 MB of it in a 9.7 MB binary (nightly-next,
# 2026-10-20). Builds a real mergeable dylib with clang, so it needs macOS.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

APP="$TMP_DIR/cmux.app"
FW="$APP/Contents/Frameworks/Mergeable.framework"
mkdir -p "$APP/Contents/Resources" "$FW/Versions/A"
ln -s A "$FW/Versions/Current"
ln -s Versions/Current/Mergeable "$FW/Mergeable"

cat > "$TMP_DIR/m.c" <<'EOF'
int mergeable_add(int x) { return x + 1; }
static int helper(int x) { return x * 3; }
int mergeable_mul(int x) { return helper(x); }
EOF
clang -dynamiclib -install_name @rpath/Mergeable.framework/Versions/A/Mergeable \
  -o "$FW/Versions/A/Mergeable" "$TMP_DIR/m.c" -Wl,-make_mergeable
codesign -f -s - "$FW/Versions/A/Mergeable" >/dev/null 2>&1

atom_info() { otool -l "$1" | grep -c LC_ATOM_INFO || true; }
[ "$(atom_info "$FW/Versions/A/Mergeable")" = 1 ] || { echo "fixture has no LC_ATOM_INFO" >&2; exit 1; }
before="$(stat -f%z "$FW/Versions/A/Mergeable")"

/bin/bash "$ROOT/scripts/strip-release-bundle.sh" "$APP" > "$TMP_DIR/out.log"

after="$(stat -f%z "$FW/Versions/A/Mergeable")"
if [ "$(atom_info "$FW/Versions/A/Mergeable")" != 0 ]; then
  echo "expected LC_ATOM_INFO to be removed from the bundled framework" >&2
  cat "$TMP_DIR/out.log" >&2
  exit 1
fi
[ "$after" -lt "$before" ] || { echo "expected the framework to shrink ($before -> $after)" >&2; exit 1; }
# The exported symbols stay: the framework still links and resolves.
nm -gU "$FW/Versions/A/Mergeable" | grep -q '_mergeable_add' || { echo "exported symbol was stripped" >&2; exit 1; }
# The top-level symlink is not stripped twice.
[ -L "$FW/Mergeable" ] || { echo "framework symlink was replaced" >&2; exit 1; }
# A second run leaves the stripped framework as it is.
/bin/bash "$ROOT/scripts/strip-release-bundle.sh" "$APP" > /dev/null
[ "$(stat -f%z "$FW/Versions/A/Mergeable")" = "$after" ] || { echo "second strip changed the framework" >&2; exit 1; }
echo "ok: LC_ATOM_INFO removed ($before -> $after bytes), symbols kept"
