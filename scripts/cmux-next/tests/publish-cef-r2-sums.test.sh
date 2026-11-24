#!/usr/bin/env bash
# Review follow-up on #37825 (F1): publish-cef-r2.sh, fetching a release's
# assets itself, uploads only archives the release's SHA256SUMS vouches for.
# It refuses a release with no SHA256SUMS, and one with a .tar.xz that has no
# line in it or does not match its line, before anything is uploaded.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
publish="$here/../publish-cef-r2.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/publish-cef-r2-sums.XXXXXX")"
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# A fake gh serves the release from $work/release; a fake curl records each call
# and answers 500, so a run that gets past the checks stops at its first upload.
mkdir -p "$work/bin" "$work/release"
cat > "$work/bin/gh" <<'SH'
#!/usr/bin/env bash
pattern=""; dir=""
while (( $# )); do
  case "$1" in --pattern) pattern="$2"; shift 2 ;; --dir) dir="$2"; shift 2 ;; *) shift ;; esac
done
shopt -s nullglob
files=("$FAKE_RELEASE"/$pattern)
(( ${#files[@]} )) || { echo "no assets match $pattern" >&2; exit 1; }
cp "${files[@]}" "$dir/"
SH
cat > "$work/bin/curl" <<'SH'
#!/usr/bin/env bash
cat > /dev/null
echo call >> "$FAKE_CURL_LOG"
printf 500
SH
chmod +x "$work/bin/gh" "$work/bin/curl"

release() {
  rm -rf "$work/release"; mkdir -p "$work/release"
  printf 'arm64' > "$work/release/a-arm64.tar.xz"
  printf 'x86' > "$work/release/a-x86_64.tar.xz"
}
sums() { (cd "$work/release" && shasum -a 256 "$@" > SHA256SUMS); }

# run: the script's exit status and stderr, with the fakes and dummy credentials.
run() {
  : > "$work/curl.log"
  PATH="$work/bin:$PATH" FAKE_RELEASE="$work/release" FAKE_CURL_LOG="$work/curl.log" \
    CMUX_CEF_R2_ENV_FILE=/dev/null CMUX_CEF_R2_ACCOUNT_ID=acct \
    CMUX_CEF_R2_WRITE_ACCESS_KEY_ID=id CMUX_CEF_R2_WRITE_SECRET_ACCESS_KEY=secret \
    bash "$publish" cef-test-tag > /dev/null 2> "$work/err" && return 0 || return $?
}
uploads() { wc -l < "$work/curl.log" | tr -d ' '; }

# No SHA256SUMS: refused, nothing uploaded.
release
if run; then fail "a release with no SHA256SUMS was published"; fi
[[ "$(uploads)" == 0 ]] || fail "uploaded with no SHA256SUMS"
grep -q 'SHA256SUMS' "$work/err" || fail "no SHA256SUMS error: $(cat "$work/err")"

# An archive SHA256SUMS does not list: refused, nothing uploaded.
release; sums a-arm64.tar.xz
if run; then fail "an archive missing from SHA256SUMS was published"; fi
[[ "$(uploads)" == 0 ]] || fail "uploaded an archive SHA256SUMS does not list"
grep -q 'a-x86_64.tar.xz' "$work/err" || fail "the unlisted archive is not named: $(cat "$work/err")"

# An archive that does not match its line: refused, nothing uploaded.
release; sums a-arm64.tar.xz a-x86_64.tar.xz; printf 'changed' > "$work/release/a-x86_64.tar.xz"
if run; then fail "a mismatched archive was published"; fi
[[ "$(uploads)" == 0 ]] || fail "uploaded a mismatched archive"

# Every archive listed and matching: the checks pass and the upload starts.
release; sums a-arm64.tar.xz a-x86_64.tar.xz
if run; then fail "the fake upload did not fail"; fi
[[ "$(uploads)" -ge 1 ]] || fail "a fully checked release was not uploaded: $(cat "$work/err")"
grep -q 'upload of cef/' "$work/err" || fail "stopped before the upload: $(cat "$work/err")"

# A name with spaces, listed in binary mode (`<sha> *<name>`), passes; a line whose
# name only starts the same way does not vouch for it.
release; mv "$work/release/a-x86_64.tar.xz" "$work/release/a x86 64.tar.xz"
(cd "$work/release" && { shasum -a 256 a-arm64.tar.xz; shasum -a 256 -b "a x86 64.tar.xz"; } > SHA256SUMS)
if run; then fail "the fake upload did not fail"; fi
grep -q 'upload of cef/' "$work/err" || fail "a binary-mode line with spaces was refused: $(cat "$work/err")"
(cd "$work/release" && { shasum -a 256 a-arm64.tar.xz; shasum -a 256 "a x86 64.tar.xz" | sed 's/ 64.tar.xz$//'; } > SHA256SUMS)
if run; then fail "a truncated name was published"; fi
[[ "$(uploads)" == 0 ]] || fail "uploaded an archive whose name SHA256SUMS lists only a prefix of"

echo "publish-cef-r2 SHA256SUMS checks: ok"
