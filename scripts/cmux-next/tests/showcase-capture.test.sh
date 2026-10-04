#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
SCRIPT=$ROOT/scripts/cmux-next/showcase-capture.sh
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
OUT=$TMP/out
# Dry-run validates intent and must not create archive or call any helper.
output=$($SCRIPT --dry-run --host mini --tag showcase-test --checkout /tmp/checkout --out-root "$OUT")
grep -q 'dry run (no effects)' <<<"$output"
test ! -e "$OUT"
# Artifact bytes must be pulled on the capture host; Big Red never relays an app zip.
grep -q -- "cmux-ci artifact" "$SCRIPT"
! grep -q -- "scp \"\$RECEIPTS/cmux-\$TAG.zip" "$SCRIPT"
# A live run must fail closed before mkdir, SSH, CUA, or cmux-ci without admission.
touch "$TMP/lease.json"; set +e
CMUX_CUA_SSH=$TMP/no-cua CMUX_SHOWCASE_WAIT_SECONDS=0 "$SCRIPT" --host mini --tag showcase-test --checkout /tmp/checkout --skip-build --app /tmp/cmux.app --out-root "$OUT" --lease-receipt "$TMP/lease.json" >"$TMP/fail.out" 2>&1
rc=$?; set -e
test "$rc" -ne 0; grep -q -- '--admission-command' "$TMP/fail.out"; test ! -e "$OUT"
# Portable fake-run: no native build tools, network, or GUI is used.
mkdir -p "$TMP/bin" "$TMP/app/Contents" "$TMP/checkout"
mkdir -p "$TMP/backdrops"
printf 'test wallpaper\n' > "$TMP/backdrops/test.jpg"
hash=$(sha256sum "$TMP/backdrops/test.jpg" | cut -d' ' -f1)
printf 'source wallpaper\n' > "$TMP/source.jpg"
source_hash=$(sha256sum "$TMP/source.jpg" | cut -d' ' -f1)
cat > "$TMP/backdrops/manifest.json" <<JSON
{"schema_version":1,"entries":[{"id":"test-wallpaper","file":"test.jpg","title":"Test wallpaper","artist":"Test artist","year":"1900","source_url":"https://example.test/test","license":"CC0-1.0","license_url":"https://creativecommons.org/publicdomain/zero/1.0/","sha256":"$hash","bundle_eligible":true,"capture_only":false},{"id":"source-wallpaper","file":"not-published.jpg","title":"Source fallback","artist":"Test artist","year":"1901","source_url":"$TMP/source.jpg","license":"capture-only","license_url":null,"sha256":"$source_hash","bundle_eligible":false,"capture_only":true}]}
JSON
cat > "$TMP/bin/ssh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
# The fake host admits the tagged app and accepts socket operations.
cmd="${*: -1}"
if [[ "$cmd" == *"find "* ]]; then echo /tmp/cmux.app; fi
if [[ "$cmd" == *"printf '%s'"* ]]; then echo /tmp/cmux-showcase-wallpaper/test.jpg; fi
SH
cat > "$TMP/bin/scp" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$TMP/bin/cua" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
sub=$1; shift
if [[ "$sub" == state ]]; then
  out=""; while [[ $# -gt 0 ]]; do [[ $1 == --out ]] && out=$2 && shift 2 || shift; done
  mkdir -p "$out"; printf 'png' > "$out/screenshot.png"; printf '{"role":"window","showcase":true}\n' > "$out/state.json"
elif [[ "$sub" == record-start ]]; then :
elif [[ "$sub" == record-end ]]; then out=""; while [[ $# -gt 0 ]]; do [[ $1 == --out ]] && out=$2 && shift 2 || shift; done; mkdir -p "$out"; printf 'mov' > "$out/recording.mov"; printf '{}' > "$out/meta.json"; printf '{}\n' > "$out/events.jsonl"
fi
SH
chmod +x "$TMP/bin/ssh" "$TMP/bin/scp" "$TMP/bin/cua"
printf 'admitted' > "$TMP/admitted"
printf '{"admitted":true,"owner":"test"}\n' > "$TMP/admission.json"
PATH="$TMP/bin:$PATH" CMUX_CUA_SSH="$TMP/bin/cua" CMUX_SHOWCASE_WAIT_SECONDS=0 \
  "$SCRIPT" --host mini --tag showcase-test --checkout "$TMP/checkout" --skip-build --app /tmp/cmux.app \
  --out-root "$OUT" --date 2099-01-01 --backdrop-manifest "$TMP/backdrops/manifest.json" \
  --backdrop-root "$TMP/backdrops" --backdrop-id test-wallpaper --lease-receipt "$TMP/lease.json" \
  --admission-command "cat $TMP/admission.json" >/dev/null
manifest=$OUT/captures/manifest.json
test -s "$manifest"; grep -q 'cmux-next-showcase' "$manifest"
grep -q 'test-wallpaper' "$manifest"; grep -q "$hash" "$manifest"
test -s "$OUT/captures/cmux-next-showcase/2099-01-01/reel/recording.mov"
test -s "$OUT/captures/cmux-next-showcase/2099-01-01/receipts/wallpaper.json"
PATH="$TMP/bin:$PATH" CMUX_CUA_SSH="$TMP/bin/cua" CMUX_SHOWCASE_WAIT_SECONDS=0 \
  "$SCRIPT" --host mini --tag showcase-test --checkout "$TMP/checkout" --skip-build --app /tmp/cmux.app \
  --out-root "$OUT" --date 2099-01-02 --backdrop-manifest "$TMP/backdrops/manifest.json" \
  --backdrop-root "$TMP/backdrops" --backdrop-id source-wallpaper --lease-receipt "$TMP/lease.json" \
  --admission-command "cat $TMP/admission.json" >/dev/null
grep -q 'source-wallpaper' "$OUT/captures/manifest.json"; grep -q "$source_hash" "$OUT/captures/manifest.json"
printf 'showcase-capture tests: ok\n'
