#!/usr/bin/env bash
# embed-cef.sh with CMUX_NEXT_REQUIRE_CEF=1 must reach ensure-cef.sh with no
# extra arguments under Xcode's /bin/bash 3.2, where an empty array is
# "unbound" under `set -u`. ensure-cef.sh is a stub here: no network, no build.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/scripts" "$TMP/build/app.app/Contents/Frameworks"
cp "$ROOT/scripts/cmux-next/embed-cef.sh" "$ROOT/scripts/cmux-next/cef-locale-allowlist.sh" "$TMP/scripts/"
cat > "$TMP/scripts/ensure-cef.sh" <<'STUB'
#!/usr/bin/env bash
echo "stub ensure-cef args=[$*]" >&2
exit 7
STUB
chmod +x "$TMP/scripts/ensure-cef.sh"
run() { # <require> -> output of embed-cef.sh under /bin/bash
  env -i PATH=/usr/bin:/bin HOME="$TMP" ARCHS=arm64 TARGET_BUILD_DIR="$TMP/build" WRAPPER_NAME=app.app \
    CMUX_NEXT_REQUIRE_CEF="$1" /bin/bash "$TMP/scripts/embed-cef.sh" 2>&1 || true
}
out=$(run 1)
grep -q 'stub ensure-cef args=\[\]$' <<<"$out" || { printf 'REQUIRE_CEF=1 did not reach ensure-cef.sh:\n%s\n' "$out" >&2; exit 1; }
! grep -q 'unbound variable' <<<"$out"
out=$(run 0)
grep -q 'stub ensure-cef args=\[--optional\]$' <<<"$out" || { printf 'optional mode lost --optional:\n%s\n' "$out" >&2; exit 1; }
printf 'embed-cef tests: ok\n'
