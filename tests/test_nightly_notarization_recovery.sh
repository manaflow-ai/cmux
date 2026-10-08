#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKFLOW_FILE="$ROOT_DIR/.github/workflows/nightly-notarization-recovery.yml"
SCRIPT="$ROOT_DIR/scripts/ci/recover-nightly-notarization.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

if ! grep -Fq 'workflow_dispatch:' "$WORKFLOW_FILE" \
  || grep -Fq 'workflow_run:' "$WORKFLOW_FILE"; then
  echo "FAIL: recovery workflow must be manual-only so automatic continuation cannot duplicate waits" >&2
  exit 1
fi
for required in \
  'SOURCE_WORKFLOW_PATHS: .github/workflows/nightly.yml' \
  'run-id: ${{ env.SOURCE_RUN_ID }}' \
  'pattern: cmux-*-notarization-recovery-*' \
  'merge-multiple: false' \
  'actions: read' \
  'contents: read' \
  'recover-nightly-notarization.sh recovery-inputs' \
  'run: ./scripts/select-ci-xcode.sh' \
  'compression-level: 0'; do
  if ! grep -Fq "$required" "$WORKFLOW_FILE"; then
    echo "FAIL: recovery workflow is missing contract: $required" >&2
    exit 1
  fi
done
if grep -Eq 'action-gh-release|upload-r2-object|contents: write' "$WORKFLOW_FILE"; then
  echo "FAIL: recovery must not publish incomplete release metadata or grant contents write" >&2
  exit 1
fi
if ! grep -Fq 'name: cmux-nightly-notarization-recovered-${{ env.SOURCE_RUN_ID }}' "$WORKFLOW_FILE"; then
  echo "FAIL: recovery must upload a separately named verified recovery artifact" >&2
  exit 1
fi

if ! grep -Fq 'notarytool wait' "$SCRIPT" \
  || ! grep -Fq 'notarytool log' "$SCRIPT" \
  || ! grep -Fq 'dmg_sha256' "$SCRIPT" \
  || ! grep -Fq 'stapler staple' "$SCRIPT"; then
  echo "FAIL: recovery helper must verify SHA, wait/log, and staple" >&2
  exit 1
fi

ARTIFACT="$TMP_DIR/artifact"
FAKE_BIN="$TMP_DIR/bin"
CALLS="$TMP_DIR/calls.log"
mkdir -p "$ARTIFACT/build-universal/Build/Products/Release/cmux.app/Contents" "$FAKE_BIN"
printf 'exact signed dmg fixture\n' > "$ARTIFACT/cmux-nightly-macos-arm64.dmg"
printf 'app fixture\n' > "$ARTIFACT/build-universal/Build/Products/Release/cmux.app/Contents/Info.plist"
DIGEST="$(python3 - "$ARTIFACT/cmux-nightly-macos-arm64.dmg" <<'PY'
import hashlib
import sys
print(hashlib.sha256(open(sys.argv[1], 'rb').read()).hexdigest())
PY
)"
cat > "$ARTIFACT/cmux-nightly-macos-arm64.dmg.notarization.state" <<EOF
submission_id=fixture-id
status=In Progress
dmg_path=cmux-nightly-macos-arm64.dmg
dmg_sha256=$DIGEST
output_file=cmux-nightly-macos-arm64.dmg.notarization.log
EOF
printf 'pending\n' > "$ARTIFACT/cmux-nightly-macos-arm64.dmg.notarization.log"

cat > "$FAKE_BIN/xcrun" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$CMUX_TEST_CALLS"
if [ "$1" = notarytool ] && [ "$2" = wait ]; then
  if [ "${CMUX_TEST_NOTARY_STATUS:-Accepted}" = Accepted ]; then
    printf '{"id":"fixture-id","status":"Accepted"}\n'
  else
    printf '{"id":"fixture-id","status":"Invalid"}\n'
  fi
  exit 0
fi
if [ "$1" = notarytool ] && [ "$2" = log ]; then
  printf '{"id":"fixture-id","status":"Accepted","log":"fixture"}\n'
  exit 0
fi
if [ "$1" = stapler ]; then
  printf 'stapler %s\n' "$3" >> "$CMUX_TEST_STAPLES"
  exit 0
fi
echo "unexpected xcrun invocation: $*" >&2
exit 2
EOF
chmod +x "$FAKE_BIN/xcrun"

export ASC_API_KEY_ID=fixture
export ASC_API_ISSUER_ID=issuer
export ASC_API_KEY_P8_BASE64="$(printf fixture-p8 | base64)"
export CMUX_XCRUN_TOOL="$FAKE_BIN/xcrun"
export CMUX_TEST_CALLS="$CALLS"
export CMUX_TEST_STAPLES="$TMP_DIR/staples.log"
export CMUX_NOTARY_RECOVERY_WAIT_TIMEOUT=1m

"$SCRIPT" "$ARTIFACT" > "$TMP_DIR/success.out"
grep -Fq 'Recovered and stapled 1 notarization artifact(s)' "$TMP_DIR/success.out"
grep -Fq 'notarytool wait fixture-id' "$CALLS"
grep -Fq 'notarytool log fixture-id' "$CALLS"
[ "$(wc -l < "$TMP_DIR/staples.log" | tr -d ' ')" = 4 ]

if ! awk '/notarytool wait/{waitline=NR} /notarytool log/{logline=NR} /stapler/{stapleline=NR} END { exit !(waitline < logline && logline < stapleline) }' "$CALLS"; then
  echo "FAIL: stapling must happen after notarytool wait and log" >&2
  exit 1
fi

BAD="$TMP_DIR/bad"
cp -R "$ARTIFACT" "$BAD"
python3 - "$BAD/cmux-nightly-macos-arm64.dmg.notarization.state" <<'PY'
from pathlib import Path
path = Path(__import__('sys').argv[1])
lines = path.read_text().splitlines()
path.write_text('\n'.join('dmg_sha256=' + '0' * 64 if line.startswith('dmg_sha256=') else line for line in lines) + '\n')
PY
if "$SCRIPT" "$BAD" >/dev/null 2>"$TMP_DIR/bad.err"; then
  echo "FAIL: SHA mismatch unexpectedly succeeded" >&2
  exit 1
fi
grep -Fq 'SHA-256 mismatch' "$TMP_DIR/bad.err"

INVALID="$TMP_DIR/invalid"
cp -R "$ARTIFACT" "$INVALID"
export CMUX_TEST_NOTARY_STATUS=Invalid
staples_before="$(wc -l < "$TMP_DIR/staples.log" | tr -d ' ')"
if "$SCRIPT" "$INVALID" >/dev/null 2>"$TMP_DIR/invalid.err"; then
  echo "FAIL: non-accepted notarization unexpectedly stapled" >&2
  exit 1
fi
grep -Fq 'status Invalid' "$TMP_DIR/invalid.err"
[ "$(wc -l < "$TMP_DIR/staples.log" | tr -d ' ')" = "$staples_before" ]
unset CMUX_TEST_NOTARY_STATUS

echo "PASS: nightly notarization recovery verifies SHA, waits/logs, and gates stapling"
