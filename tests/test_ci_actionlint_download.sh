#!/usr/bin/env bash
# Behavioral tests for the checksum-pinned actionlint downloader.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/ci/install-actionlint.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

FIXTURE_DIR="$TMP_DIR/fixture"
FIXTURE_ARCHIVE="$TMP_DIR/actionlint-fixture.tar.gz"
WRONG_ARCHIVE="$TMP_DIR/actionlint-wrong.tar.gz"
BIN_DIR="$TMP_DIR/bin"
RUNNER_TEMP="$TMP_DIR/runner-temp"
CURL_LOG="$TMP_DIR/curl.log"
OUTPUT="$TMP_DIR/output"
EXPECTED_VERSION="1.7.7"
EXPECTED_ASSET_ID="221573254"
EXPECTED_SHA256=""

mkdir -p "$FIXTURE_DIR" "$BIN_DIR" "$RUNNER_TEMP"
cat > "$FIXTURE_DIR/actionlint" <<'EOF'
#!/usr/bin/env bash
exit "${FAKE_ACTIONLINT_STATUS:-0}"
EOF
chmod +x "$FIXTURE_DIR/actionlint"
(cd "$FIXTURE_DIR" && tar -czf "$FIXTURE_ARCHIVE" actionlint)
printf 'wrong actionlint bytes\n' > "$WRONG_ARCHIVE"

sha256sum_help="$(sha256sum --help 2>&1 || true)"
if [[ "$sha256sum_help" == *"--check"* ]]; then
  EXPECTED_SHA256="$(sha256sum "$FIXTURE_ARCHIVE" | awk '{print $1}')"
else
  EXPECTED_SHA256="$(shasum -a 256 "$FIXTURE_ARCHIVE" | awk '{print $1}')"
fi

cat > "$BIN_DIR/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

url=""
output=""
accept_header=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output|-o)
      output="$2"
      shift 2
      ;;
    --header|-H)
      accept_header="$2"
      shift 2
      ;;
    https://*)
      url="$1"
      shift
      ;;
    *)
      shift
      ;;
  esac
done

printf '%s\t%s\n' "$url" "$accept_header" >> "${CURL_LOG:?}"
case "${FAKE_CURL_MODE:?}" in
  success)
    case "$url" in
      https://github.com/rhysd/actionlint/releases/download/v1.7.7/actionlint_1.7.7_linux_amd64.tar.gz) ;;
      *) exit 90 ;;
    esac
    cp "${FAKE_ARCHIVE:?}" "$output"
    ;;
  fallback)
    case "$url" in
      https://github.com/rhysd/actionlint/releases/download/v1.7.7/actionlint_1.7.7_linux_amd64.tar.gz)
        exit 22
        ;;
      https://api.github.com/repos/rhysd/actionlint/releases/assets/221573254)
        [ "$accept_header" = "Accept: application/octet-stream" ]
        cp "${FAKE_ARCHIVE:?}" "$output"
        ;;
      *) exit 91 ;;
    esac
    ;;
  mismatch)
    case "$url" in
      https://github.com/rhysd/actionlint/releases/download/v1.7.7/actionlint_1.7.7_linux_amd64.tar.gz) ;;
      *) exit 92 ;;
    esac
    cp "${FAKE_WRONG_ARCHIVE:?}" "$output"
    ;;
  all-fail)
    exit 23
    ;;
  *)
    echo "unknown fake curl mode" >&2
    exit 2
    ;;
esac
EOF
chmod +x "$BIN_DIR/curl"

run_install() {
  local mode="$1"
  local output_file="$2"
  PATH="$BIN_DIR:$PATH" \
    ACTIONLINT_VERSION="$EXPECTED_VERSION" \
    ACTIONLINT_SHA256="$EXPECTED_SHA256" \
    ACTIONLINT_ASSET_ID="$EXPECTED_ASSET_ID" \
    RUNNER_TEMP="$RUNNER_TEMP" \
    FAKE_CURL_MODE="$mode" \
    FAKE_ARCHIVE="$FIXTURE_ARCHIVE" \
    FAKE_WRONG_ARCHIVE="$WRONG_ARCHIVE" \
    CURL_LOG="$CURL_LOG" \
    "$SCRIPT" > "$output_file" 2>&1
}

: > "$CURL_LOG"
run_install success "$OUTPUT"
grep -Fqx "$RUNNER_TEMP/actionlint" "$OUTPUT"
grep -Fq $'https://github.com/rhysd/actionlint/releases/download/v1.7.7/actionlint_1.7.7_linux_amd64.tar.gz\t' "$CURL_LOG"

: > "$CURL_LOG"
run_install fallback "$OUTPUT"
grep -Fq $'https://api.github.com/repos/rhysd/actionlint/releases/assets/221573254\tAccept: application/octet-stream' "$CURL_LOG"
[ "$(wc -l < "$CURL_LOG" | tr -d ' ')" -eq 2 ]

if FAKE_ACTIONLINT_STATUS=17 "$RUNNER_TEMP/actionlint"; then
  echo "FAIL: actionlint execution failure was swallowed" >&2
  exit 1
fi

: > "$CURL_LOG"
if run_install mismatch "$OUTPUT"; then
  echo "FAIL: checksum mismatch was accepted" >&2
  exit 1
fi
if grep -Fq 'releases/assets/221573254' "$CURL_LOG"; then
  echo "FAIL: checksum mismatch unexpectedly used the fallback" >&2
  exit 1
fi

if run_install all-fail "$OUTPUT"; then
  echo "FAIL: download failure was accepted" >&2
  exit 1
fi
grep -Fq 'both pinned GitHub endpoints' "$OUTPUT"

echo "PASS: actionlint download fallback, checksum, and execution failures are fail-closed"
