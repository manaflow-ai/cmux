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
# A live run must fail closed before mkdir, SSH, CUA, or cmux-ci without admission.
touch "$TMP/lease.json"; set +e
CMUX_CUA_SSH=$TMP/no-cua CMUX_SHOWCASE_WAIT_SECONDS=0 "$SCRIPT" --host mini --tag showcase-test --checkout /tmp/checkout --skip-build --app /tmp/cmux.app --out-root "$OUT" --lease-receipt "$TMP/lease.json" >"$TMP/fail.out" 2>&1
rc=$?; set -e
test "$rc" -ne 0; grep -q -- '--admission-command' "$TMP/fail.out"; test ! -e "$OUT"
# Portable fake-run: no native build tools, network, or GUI is used.
mkdir -p "$TMP/bin" "$TMP/app/Contents" "$TMP/checkout"
cat > "$TMP/bin/ssh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
# The fake host admits the tagged app and accepts socket operations.
cmd="${*: -1}"
if [[ "$cmd" == *"find "* ]]; then echo /tmp/cmux.app; fi
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
elif [[ "$sub" == record-end ]]; then out=""; while [[ $# -gt 0 ]]; do [[ $1 == --out ]] && out=$2 && shift 2 || shift; done; mkdir -p "$out"; printf 'mov' > "$out/recording.mov"
fi
SH
chmod +x "$TMP/bin/ssh" "$TMP/bin/scp" "$TMP/bin/cua"
printf 'admitted' > "$TMP/admitted"
printf '{"admitted":true,"owner":"test"}\n' > "$TMP/admission.json"
PATH="$TMP/bin:$PATH" CMUX_CUA_SSH="$TMP/bin/cua" CMUX_SHOWCASE_WAIT_SECONDS=0 \
  "$SCRIPT" --host mini --tag showcase-test --checkout "$TMP/checkout" --skip-build --app /tmp/cmux.app \
  --out-root "$OUT" --lease-receipt "$TMP/lease.json" --admission-command "cat $TMP/admission.json" >/dev/null
manifest=$OUT/captures/manifest.json
test -s "$manifest"; grep -q 'cmux-next-showcase' "$manifest"
test -s "$OUT/captures/cmux-next-showcase/$(date +%F)/reel/recording.mov"
printf 'showcase-capture tests: ok\n'
