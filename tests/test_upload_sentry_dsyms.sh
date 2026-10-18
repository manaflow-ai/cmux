#!/usr/bin/env bash
# Regression test for scripts/upload-sentry-dsyms.sh: a flaky Sentry upload
# (nightly runs 37531729976 and 37535932538 died on curl 28) is retried with
# backoff, and a Sentry outage warns instead of failing the nightly.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/upload-sentry-dsyms.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A fake sentry-cli that fails its first $FAILS calls, counting each call.
cat > "$WORK/sentry-cli" <<'FAKE'
#!/usr/bin/env bash
n=$(( $(cat "$COUNT_FILE" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$COUNT_FILE"
echo "args: $*" >> "$COUNT_FILE.args"
[ "$n" -gt "$FAILS" ]
FAKE
chmod +x "$WORK/sentry-cli"

run() {
  rm -f "$WORK/count" "$WORK/count.args"
  COUNT_FILE="$WORK/count" FAILS="$1" SENTRY_CLI="$WORK/sentry-cli" \
    SENTRY_UPLOAD_RETRY_DELAYS="0 0" SENTRY_AUTH_TOKEN=token \
    "$SCRIPT" "$WORK/dsyms" > "$WORK/out" 2>&1
}

run 2 || { echo "FAIL: an upload that succeeds on the third try must pass"; cat "$WORK/out"; exit 1; }
[ "$(cat "$WORK/count")" = 3 ] || { echo "FAIL: expected 3 upload attempts, saw $(cat "$WORK/count")"; exit 1; }
grep -q -- "debug-files upload --include-sources $WORK/dsyms" "$WORK/count.args" \
  || { echo "FAIL: the upload must pass --include-sources and the path"; cat "$WORK/count.args"; exit 1; }

run 99 || { echo "FAIL: a Sentry outage must not fail the nightly"; cat "$WORK/out"; exit 1; }
[ "$(cat "$WORK/count")" = 3 ] || { echo "FAIL: expected 3 attempts before giving up, saw $(cat "$WORK/count")"; exit 1; }
grep -q '^::warning' "$WORK/out" || { echo "FAIL: giving up must leave a ::warning annotation"; cat "$WORK/out"; exit 1; }

rm -f "$WORK/count"
COUNT_FILE="$WORK/count" FAILS=0 SENTRY_CLI="$WORK/sentry-cli" SENTRY_AUTH_TOKEN= "$SCRIPT" "$WORK/dsyms" > "$WORK/out" 2>&1 \
  || { echo "FAIL: no token must skip quietly"; exit 1; }
[ ! -e "$WORK/count" ] || { echo "FAIL: no token must not call sentry-cli"; exit 1; }

if ! awk '
  /^      - name: Upload dSYMs to Sentry/ { in_step=1; next }
  in_step && /^      - name:/ { in_step=0 }
  in_step && /scripts\/upload-sentry-dsyms\.sh/ { saw=1 }
  END { exit !saw }
' "$ROOT_DIR/.github/workflows/nightly.yml"; then
  echo "FAIL: the nightly dSYM upload must go through scripts/upload-sentry-dsyms.sh"
  exit 1
fi

echo "PASS: dSYM upload retries with backoff and never fails the nightly"
