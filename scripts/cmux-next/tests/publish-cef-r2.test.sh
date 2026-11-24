#!/usr/bin/env bash
# publish-cef-r2.sh without --dir must refuse when the release has no
# SHA256SUMS (or it cannot be downloaded), before any R2 upload.
# No network: gh and curl are stubbed.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
SCRIPT="$ROOT/scripts/cmux-next/publish-cef-r2.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail() { printf '%s\n' "$@" >&2; exit 1; }

mkdir -p "$TMP/bin"
# gh: serves one .tar.xz asset; SHA256SUMS download fails (release lacks it).
cat > "$TMP/bin/gh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/gh.log"
dir=""; pattern=""
while (( \$# )); do
  case "\$1" in
    --dir) dir="\$2"; shift 2 ;;
    --pattern) pattern="\$2"; shift 2 ;;
    *) shift ;;
  esac
done
if [[ "\$pattern" == SHA256SUMS ]]; then exit 1; fi
printf 'fake' > "\$dir/cef_linux.tar.xz"
exit 0
STUB
# curl: must never run; record it if it does.
cat > "$TMP/bin/curl" <<STUB
#!/usr/bin/env bash
echo curl >> "$TMP/curl.log"
exit 0
STUB
chmod +x "$TMP/bin/gh" "$TMP/bin/curl"

status=0
PATH="$TMP/bin:$PATH" CMUX_CEF_R2_ACCOUNT_ID=x CMUX_CEF_R2_WRITE_ACCESS_KEY_ID=x \
  CMUX_CEF_R2_WRITE_SECRET_ACCESS_KEY=x CMUX_CEF_R2_ENV_FILE=/dev/null \
  bash "$SCRIPT" v1.0 >"$TMP/out" 2>&1 || status=$?

(( status != 0 )) || fail "expected refusal without SHA256SUMS, got success"
[[ ! -e "$TMP/curl.log" ]] || fail "uploaded to R2 without SHA256SUMS verification"
grep -q 'SHA256SUMS' "$TMP/out" || fail "error does not mention SHA256SUMS: $(cat "$TMP/out")"
printf 'publish-cef-r2 tests: ok\n'
