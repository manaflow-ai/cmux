#!/usr/bin/env bash
# Regression contract for the cmux-tui client downloader used by Nightly.
# A transient R2 failure must be retried, while a persistent failure must leave
# any previously cached manifest untouched and fail closed.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

FAKE_BIN="$TMP_DIR/bin"
STATE_DIR="$TMP_DIR/state"
APP_DIR="$TMP_DIR/cmux.app"
CACHE_DIR="$TMP_DIR/cache"
PAYLOAD="$TMP_DIR/cmux-tui-fixture"
MANIFEST_URL="https://fixtures.invalid/cmux-tui/latest/manifest.json"
COMMIT="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

mkdir -p "$FAKE_BIN" "$STATE_DIR" "$APP_DIR/Contents" "$CACHE_DIR"
printf '#!/bin/sh\nprintf '\''{"app":"cmux-tui"}\\n'\''\n' >"$PAYLOAD"
chmod 755 "$PAYLOAD"
DIGEST="$(shasum -a 256 "$PAYLOAD" | awk '{print $1}')"

cat >"$FAKE_BIN/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

output=""
url=""
while (($#)); do
  case "$1" in
    -o) output="$2"; shift 2 ;;
    http://*|https://*) url="$1"; shift ;;
    *) shift ;;
  esac
done
[[ -n "$output" && -n "$url" ]] || exit 2

case "$url" in
  */manifest.json) kind=manifest ;;
  */cmux-tui-aarch64-apple-darwin) kind=arm ;;
  */cmux-tui-x86_64-apple-darwin) kind=x64 ;;
  *) echo "unexpected fixture URL: $url" >&2; exit 2 ;;
esac

count_file="$TEST_CURL_STATE/$kind.attempts"
count=0
if [[ -f "$count_file" ]]; then
  read -r count <"$count_file"
fi
count=$((count + 1))
printf '%s\n' "$count" >"$count_file"

if [[ "${TEST_CURL_ALWAYS_FAIL:-0}" == 1 ]]; then
  printf 'fixture upstream 500\n' >&2
  printf '{"partial":true}\n' >"$output"
  exit 56
fi

if [[ "$count" == 1 ]]; then
  printf 'fixture upstream 500\n' >&2
  printf '{"partial":true}\n' >"$output"
  exit 56
fi

if [[ "$kind" == manifest ]]; then
  printf '%s\n' "$TEST_CURL_MANIFEST" >"$output"
else
  cp "$TEST_CURL_PAYLOAD" "$output"
fi
EOF
chmod 755 "$FAKE_BIN/curl"

cat >"$FAKE_BIN/lipo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == -create ]]; then
  [[ "${4:-}" == -output ]] || exit 2
  cp "$2" "$5"
  chmod 755 "$5"
  exit 0
fi
if [[ "${1:-}" == -verify_arch || "${2:-}" == -verify_arch ]]; then
  exit 0
fi
echo "unexpected fixture lipo invocation" >&2
exit 2
EOF
chmod 755 "$FAKE_BIN/lipo"

MANIFEST=$(printf '{"commit":"%s","binaries":{"cmux-tui-aarch64-apple-darwin":"%s","cmux-tui-x86_64-apple-darwin":"%s"}}' "$COMMIT" "$DIGEST" "$DIGEST")

if ! PATH="$FAKE_BIN:$PATH" \
  TEST_CURL_STATE="$STATE_DIR" \
  TEST_CURL_PAYLOAD="$PAYLOAD" \
  TEST_CURL_MANIFEST="$MANIFEST" \
  CMUX_TUI_CLIENT_MANIFEST_URL="$MANIFEST_URL" \
  CMUX_TUI_CLIENT_CACHE="$CACHE_DIR" \
  CMUX_TUI_CLIENT_RETRY_DELAY_SECONDS=0 \
  bash "$ROOT_DIR/scripts/install-cmux-tui-client.sh" "$APP_DIR"; then
  echo "FAIL: cmux-tui downloader did not recover from a transient upstream failure"
  exit 1
fi

[[ "$(cat "$STATE_DIR/manifest.attempts")" == 2 ]]
[[ "$(cat "$STATE_DIR/arm.attempts")" == 2 ]]
[[ "$(cat "$STATE_DIR/x64.attempts")" == 2 ]]
[[ -x "$APP_DIR/Contents/Resources/bin/cmux-tui" ]]
[[ "$("$APP_DIR/Contents/Resources/bin/cmux-tui" remote-probe --json)" == *'"app":"cmux-tui"'* ]]

MANIFEST_HASH="$(printf '%s' "$MANIFEST_URL" | shasum -a 256 | cut -c1-12)"
CACHED_MANIFEST="$CACHE_DIR/manifest.$MANIFEST_HASH.json"
printf '%s\n' "$MANIFEST" >"$CACHED_MANIFEST"
cp "$CACHED_MANIFEST" "$TMP_DIR/manifest.before"

mkdir -p "$TMP_DIR/persistent-state"
set +e
PATH="$FAKE_BIN:$PATH" \
  TEST_CURL_STATE="$TMP_DIR/persistent-state" \
  TEST_CURL_PAYLOAD="$PAYLOAD" \
  TEST_CURL_MANIFEST="$MANIFEST" \
  TEST_CURL_ALWAYS_FAIL=1 \
  CMUX_TUI_CLIENT_MANIFEST_URL="$MANIFEST_URL" \
  CMUX_TUI_CLIENT_CACHE="$CACHE_DIR" \
  CMUX_TUI_CLIENT_RETRY_DELAY_SECONDS=0 \
  bash "$ROOT_DIR/scripts/install-cmux-tui-client.sh" "$APP_DIR"
persistent_status=$?
set -e
if [[ "$persistent_status" == 0 ]]; then
  echo "FAIL: persistent cmux-tui upstream failure was reported as success"
  exit 1
fi

cmp -s "$TMP_DIR/manifest.before" "$CACHED_MANIFEST"

echo "PASS: cmux-tui downloader retries transient failures and fails closed without stale manifests"
