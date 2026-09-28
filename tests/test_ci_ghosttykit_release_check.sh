#!/usr/bin/env bash
# Regression test for the CI GhosttyKit release-existence guard.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/download-prebuilt-ghosttykit.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

FIXTURE_SHA="0123456789012345678901234567890123456789"
FIXTURE_DIR="$TMP_DIR/fixture"
ARCHIVE="$TMP_DIR/GhosttyKit.xcframework.tar.gz"
CHECKSUMS_FILE="$TMP_DIR/ghosttykit-checksums.txt"
BIN_DIR="$TMP_DIR/bin"
URL_LOG="$TMP_DIR/urls.log"
MISSING_OUTPUT="$TMP_DIR/missing.out"
OUTPUT_DIR="$TMP_DIR/output"

mkdir -p "$FIXTURE_DIR/GhosttyKit.xcframework" "$BIN_DIR"
printf 'fixture\n' > "$FIXTURE_DIR/GhosttyKit.xcframework/marker.txt"
(cd "$FIXTURE_DIR" && COPYFILE_DISABLE=1 tar czf "$ARCHIVE" GhosttyKit.xcframework)
ARCHIVE_SHA256="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
printf '%s %s\n' "$FIXTURE_SHA" "$ARCHIVE_SHA256" > "$CHECKSUMS_FILE"

cat > "$BIN_DIR/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

OUTPUT=""
URL=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o)
      OUTPUT="$2"
      shift 2
      ;;
    http://*|https://*)
      URL="$1"
      shift
      ;;
    *)
      shift
      ;;
  esac
done

printf '%s\n' "$URL" >> "${TEST_URL_LOG:?}"
if [ "${TEST_RELEASE_PRESENT:-0}" != "1" ]; then
  echo "curl: simulated release not found" >&2
  exit 22
fi

test -n "$OUTPUT"
cp "${TEST_FIXTURE_ARCHIVE:?}" "$OUTPUT"
EOF
chmod +x "$BIN_DIR/curl"

EXPECTED_TAG="xcframework-${FIXTURE_SHA}-crashsubdir-cmux-crash-sentry-off-noi18n-v2"
EXPECTED_URL="https://github.com/manaflow-ai/ghostty/releases/download/${EXPECTED_TAG}/GhosttyKit.xcframework.tar.gz"

PATH="$BIN_DIR:$PATH" \
  TEST_URL_LOG="$URL_LOG" \
  TEST_FIXTURE_ARCHIVE="$ARCHIVE" \
  TEST_RELEASE_PRESENT=1 \
  GHOSTTY_SHA="$FIXTURE_SHA" \
  GHOSTTYKIT_CHECKSUMS_FILE="$CHECKSUMS_FILE" \
  GHOSTTYKIT_OUTPUT_DIR="$OUTPUT_DIR" \
  GHOSTTYKIT_DOWNLOAD_RETRIES=0 \
  GHOSTTYKIT_DOWNLOAD_RETRY_DELAY=0 \
  "$SCRIPT" --verify-only

if ! grep -Fxq "$EXPECTED_URL" "$URL_LOG"; then
  echo "FAIL: verification guard did not use the shared GhosttyKit release URL" >&2
  cat "$URL_LOG" >&2
  exit 1
fi

if [ -e "$OUTPUT_DIR" ]; then
  echo "FAIL: verification-only mode extracted an xcframework" >&2
  exit 1
fi

if (
  PATH="$BIN_DIR:$PATH" \
    TEST_URL_LOG="$URL_LOG" \
    TEST_FIXTURE_ARCHIVE="$ARCHIVE" \
    TEST_RELEASE_PRESENT=0 \
    GHOSTTY_SHA="$FIXTURE_SHA" \
    GHOSTTYKIT_CHECKSUMS_FILE="$CHECKSUMS_FILE" \
    GHOSTTYKIT_OUTPUT_DIR="$OUTPUT_DIR" \
    GHOSTTYKIT_DOWNLOAD_RETRIES=0 \
    GHOSTTYKIT_DOWNLOAD_RETRY_DELAY=0 \
    "$SCRIPT" --verify-only
) >"$MISSING_OUTPUT" 2>&1; then
  echo "FAIL: verification guard succeeded when the release was missing" >&2
  exit 1
fi

if ! grep -Fq "simulated release not found" "$MISSING_OUTPUT"; then
  echo "FAIL: missing-release failure did not reach the download helper" >&2
  cat "$MISSING_OUTPUT" >&2
  exit 1
fi

echo "PASS: GhosttyKit release guard verifies the derived release and rejects a missing one"
