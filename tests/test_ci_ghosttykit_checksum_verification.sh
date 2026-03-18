#!/usr/bin/env bash
# Regression test for the pinned GhosttyKit artifact verification helper.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/download-prebuilt-ghosttykit.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

HELPER_CALL_SITES=(
  "$ROOT_DIR/.github/actions/run-unit-test-shard/action.yml"
  "$ROOT_DIR/.github/actions/run-display-resolution-regression/action.yml"
  "$ROOT_DIR/.github/actions/run-lag-regression/action.yml"
  "$ROOT_DIR/.github/actions/run-macos-compat-check/action.yml"
  "$ROOT_DIR/.github/workflows/nightly.yml"
  "$ROOT_DIR/.github/workflows/release.yml"
)

FIXTURE_SHA="7dd589824d4c9bda8265355718800cccaf7189a0"
FIXTURE_DIR="$TMP_DIR/fixture"
SUCCESS_DIR="$TMP_DIR/success"
MISMATCH_DIR="$TMP_DIR/mismatch"
MISSING_ENTRY_DIR="$TMP_DIR/missing-entry"
BIN_DIR="$TMP_DIR/bin"
CHECKSUMS_FILE="$TMP_DIR/ghosttykit-checksums.txt"
SUCCESS_LOG="$TMP_DIR/curl-success.log"
MISMATCH_LOG="$TMP_DIR/curl-mismatch.log"
MISMATCH_OUTPUT="$TMP_DIR/mismatch.out"
MISSING_ENTRY_OUTPUT="$TMP_DIR/missing-entry.out"

mkdir -p "$FIXTURE_DIR/GhosttyKit.xcframework" "$SUCCESS_DIR" "$MISMATCH_DIR" "$MISSING_ENTRY_DIR" "$BIN_DIR"
printf 'fixture\n' > "$FIXTURE_DIR/GhosttyKit.xcframework/marker.txt"
(cd "$FIXTURE_DIR" && tar czf "$TMP_DIR/GhosttyKit.xcframework.tar.gz" GhosttyKit.xcframework)
ACTUAL_SHA256="$(shasum -a 256 "$TMP_DIR/GhosttyKit.xcframework.tar.gz" | awk '{print $1}')"
printf '%s %s\n' "$FIXTURE_SHA" "$ACTUAL_SHA256" > "$CHECKSUMS_FILE"

for helper_call_site in "${HELPER_CALL_SITES[@]}"; do
  if ! grep -Fq './scripts/download-prebuilt-ghosttykit.sh' "$helper_call_site"; then
    echo "FAIL: $helper_call_site must call download-prebuilt-ghosttykit.sh"
    exit 1
  fi
done

cat > "$BIN_DIR/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="${TEST_CURL_LOG:?}"
FIXTURE_ARCHIVE="${TEST_FIXTURE_ARCHIVE:?}"
OUTPUT=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    -o)
      OUTPUT="$2"
      shift 2
      ;;
    *)
      printf '%s\n' "$1" >> "$LOG_FILE"
      shift
      ;;
  esac
done

if [ -z "$OUTPUT" ]; then
  echo "curl stub missing -o output path" >&2
  exit 1
fi

cp "$FIXTURE_ARCHIVE" "$OUTPUT"
EOF
chmod +x "$BIN_DIR/curl"

(
  cd "$SUCCESS_DIR"
  PATH="$BIN_DIR:$PATH" \
  TEST_CURL_LOG="$SUCCESS_LOG" \
  TEST_FIXTURE_ARCHIVE="$TMP_DIR/GhosttyKit.xcframework.tar.gz" \
  GHOSTTY_SHA="$FIXTURE_SHA" \
  GHOSTTYKIT_CHECKSUMS_FILE="$CHECKSUMS_FILE" \
  "$SCRIPT"
)

if [ ! -f "$SUCCESS_DIR/GhosttyKit.xcframework/marker.txt" ]; then
  echo "FAIL: verification helper did not extract GhosttyKit.xcframework"
  exit 1
fi

if [ -f "$SUCCESS_DIR/GhosttyKit.xcframework.tar.gz" ]; then
  echo "FAIL: verification helper did not clean up the downloaded archive"
  exit 1
fi

for expected_arg in --retry --retry-delay --retry-all-errors; do
  if ! grep -Fxq -- "$expected_arg" "$SUCCESS_LOG"; then
    echo "FAIL: curl invocation missing $expected_arg"
    exit 1
  fi
done

printf '%s %s\n' "$FIXTURE_SHA" "0000000000000000000000000000000000000000000000000000000000000000" > "$CHECKSUMS_FILE"

if (
  cd "$MISMATCH_DIR"
  PATH="$BIN_DIR:$PATH" \
  TEST_CURL_LOG="$MISMATCH_LOG" \
  TEST_FIXTURE_ARCHIVE="$TMP_DIR/GhosttyKit.xcframework.tar.gz" \
  GHOSTTY_SHA="$FIXTURE_SHA" \
  GHOSTTYKIT_CHECKSUMS_FILE="$CHECKSUMS_FILE" \
  "$SCRIPT"
) >"$MISMATCH_OUTPUT" 2>&1; then
  echo "FAIL: verification helper succeeded with an invalid pinned checksum"
  exit 1
fi

if ! grep -Fq "GhosttyKit.xcframework.tar.gz checksum mismatch" "$MISMATCH_OUTPUT"; then
  echo "FAIL: verification helper did not report checksum mismatch"
  exit 1
fi

printf '%s %s\n' "0000000000000000000000000000000000000000" "$ACTUAL_SHA256" > "$CHECKSUMS_FILE"

if (
  cd "$MISSING_ENTRY_DIR"
  PATH="$BIN_DIR:$PATH" \
  TEST_CURL_LOG="$MISMATCH_LOG" \
  TEST_FIXTURE_ARCHIVE="$TMP_DIR/GhosttyKit.xcframework.tar.gz" \
  GHOSTTY_SHA="$FIXTURE_SHA" \
  GHOSTTYKIT_CHECKSUMS_FILE="$CHECKSUMS_FILE" \
  "$SCRIPT"
) >"$MISSING_ENTRY_OUTPUT" 2>&1; then
  echo "FAIL: verification helper succeeded without a pinned checksum entry"
  exit 1
fi

if ! grep -Fq "Missing pinned GhosttyKit checksum for ghostty $FIXTURE_SHA" "$MISSING_ENTRY_OUTPUT"; then
  echo "FAIL: verification helper did not report a missing pinned checksum entry"
  exit 1
fi

echo "PASS: GhosttyKit verification helper enforces pinned checksums"
