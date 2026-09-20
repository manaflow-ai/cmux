#!/usr/bin/env bash
# The CI Release check is universal unless a maintainer opts into arm64, and
# nightly never takes that option.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RESOLVER="$ROOT_DIR/scripts/ci/release-build-archs.sh"
CI_FILE="$ROOT_DIR/.github/workflows/ci.yml"
NIGHTLY_FILE="$ROOT_DIR/.github/workflows/nightly.yml"

expect() {
  local input="$1" want="$2" got
  got="$("$RESOLVER" "$input")"
  if [[ "$got" != "$want" ]]; then
    echo "FAIL: '$input' resolved to '$got', expected '$want'"
    exit 1
  fi
}

expect "" "arm64 x86_64"
expect "default" "arm64 x86_64"
expect "universal" "arm64 x86_64"
expect "arm64" "arm64"
if [[ "$("$RESOLVER")" != "arm64 x86_64" ]]; then
  echo "FAIL: no argument must resolve to the universal build"
  exit 1
fi

for bad in "x86_64" "arm64 x86_64" "ARM64" "arm64;rm -rf /"; do
  if "$RESOLVER" "$bad" >/dev/null 2>&1; then
    echo "FAIL: '$bad' must be rejected, not silently narrowed or widened"
    exit 1
  fi
done

if ! awk '
  /^  release-build:/ { in_job=1; next }
  in_job && /^  [a-zA-Z0-9_-]+:/ { in_job=0 }
  in_job && /scripts\/ci\/release-build-archs\.sh/ { saw_resolver=1 }
  in_job && /ARCHS="\$RELEASE_ARCHS"/ { saw_build=1 }
  in_job && /ARCHS="arm64/ { saw_literal=1 }
  END { exit !(saw_resolver && saw_build && !saw_literal) }
' "$CI_FILE"; then
  echo "FAIL: release-build must take its architectures from scripts/ci/release-build-archs.sh"
  exit 1
fi

# Slice verification is exact: an arm64 check must reject a universal binary,
# or a change that brings the Intel compile back would pass unnoticed.
VERIFIER="$ROOT_DIR/scripts/ci/verify-binary-archs.sh"
FAKE_BIN="$(mktemp -d)"
trap 'rm -rf "$FAKE_BIN"' EXIT
cat > "$FAKE_BIN/lipo" <<'LIPO'
#!/usr/bin/env bash
# Stand-in for lipo -archs <binary>: the fixture file holds its slice list.
[[ "$1" == "-archs" ]] || exit 2
cat "$2"
LIPO
chmod +x "$FAKE_BIN/lipo"
echo "arm64" > "$FAKE_BIN/thin"
echo "x86_64 arm64" > "$FAKE_BIN/universal"
echo "x86_64" > "$FAKE_BIN/intel"

verify() { PATH="$FAKE_BIN:$PATH" "$VERIFIER" "$@" >/dev/null 2>&1; }

verify "arm64" "$FAKE_BIN/thin" || { echo "FAIL: an arm64 binary must pass the arm64 check"; exit 1; }
verify "arm64 x86_64" "$FAKE_BIN/universal" || { echo "FAIL: a universal binary must pass the universal check"; exit 1; }
if verify "arm64" "$FAKE_BIN/universal"; then
  echo "FAIL: a universal binary must not pass the arm64 check"
  exit 1
fi
if verify "arm64 x86_64" "$FAKE_BIN/thin"; then
  echo "FAIL: an arm64 binary must not pass the universal check"
  exit 1
fi
if verify "arm64" "$FAKE_BIN/thin" "$FAKE_BIN/intel"; then
  echo "FAIL: every listed binary must match, not just the first"
  exit 1
fi
if verify "arm64"; then
  echo "FAIL: the verifier must refuse to run without a binary"
  exit 1
fi

if ! awk '
  /^  release-build:/ { in_job=1; next }
  in_job && /^  [a-zA-Z0-9_-]+:/ { in_job=0 }
  in_job && /verify-binary-archs\.sh "\$RELEASE_ARCHS" "\$APP_BINARY" "\$CLI_BINARY" "\$CMUX_CUA_BINARY"/ { saw=1 }
  END { exit !saw }
' "$CI_FILE"; then
  echo "FAIL: release-build must check the built binaries against the exact resolved architectures"
  exit 1
fi

if grep -n -E 'CI_RELEASE_BUILD_ARCHS|release-build-archs\.sh|release_archs' "$NIGHTLY_FILE"; then
  echo "FAIL: nightly builds what ships and must stay universal unconditionally"
  exit 1
fi

echo "PASS: the CI Release check defaults to universal, arm64 is opt-in, and nightly cannot be narrowed"
