#!/usr/bin/env bash
# sign-cef.sh with CMUX_CEF_REUSE_FRAMEWORK: an earlier build's signed Chromium
# framework takes the place of the fresh signature only when it is the same code
# signed by the same signer with a time stamp, so the framework's bytes stay the
# same from build to build and Sparkle deltas leave it out. Other code, another
# signer, no time stamp or a missing copy keep the fresh signature.
# codesign, lipo and ditto are stubs (a signature is a sidecar holding the
# signer, the code's hash and a time stamp that differs per signing), so this
# runs on Linux too; the real codesign output fields are what the stub prints.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
sign_cef="$here/../sign-cef.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/sign-cef-reuse-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

mkdir -p "$work/bin"
cat > "$work/bin/codesign" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
mode=sign identity="" ts=1 path=""
while (($#)); do
  case "$1" in
    -d) mode=display ;;
    --verify) mode=verify ;;
    --sign) identity="$2"; shift ;;
    --timestamp=none) ts=0 ;;
    --arch|--entitlements|--options) shift ;;
    -*) ;;
    *) path="$1" ;;
  esac
  shift
done
sig() { if [[ -d "$1" ]]; then echo "$1/_CodeSignature/sig"; else echo "$1.sig"; fi; }
content() {
  if [[ -d "$1" ]]; then
    (cd "$1" && find . -type f ! -path './_CodeSignature/*' ! -name '*.sig' | LC_ALL=C sort | while read -r f; do
      printf '%s %s\n' "$f" "$(sha256sum < "$f")"; done) | sha256sum | cut -c1-40
  else
    sha256sum < "$1" | cut -c1-40
  fi
}
s="$(sig "$path")"
case "$mode" in
  sign)
    mkdir -p "$(dirname "$s")"
    { echo "content=$(content "$path")"; echo "Authority=$identity"
      if ((ts)); then echo "Timestamp=$RANDOM$RANDOM$RANDOM"; fi; } > "$s" ;;
  display)
    [[ -f "$s" ]] || { echo "$path: code object is not signed at all" >&2; exit 1; }
    echo "Executable=$path" >&2
    echo "Identifier=${path##*/}" >&2
    echo "CDHash=$(printf '%s %s' "$(grep '^content=' "$s")" "$(grep '^Authority=' "$s")" | sha256sum | cut -c1-40)" >&2
    grep -E '^(Authority|Timestamp)=' "$s" >&2 || true
    echo "Signature size=$RANDOM" >&2 ;;
  verify)
    [[ -f "$s" && "$(grep '^content=' "$s")" == "content=$(content "$path")" ]] ||
      { echo "$path: invalid signature" >&2; exit 1; } ;;
esac
STUB
printf '#!/usr/bin/env bash\n[[ "$1" == -archs ]] && echo arm64\n' > "$work/bin/lipo"
printf '#!/usr/bin/env bash\nmkdir -p "$(dirname "$2")" && cp -pR "$1" "$2"\n' > "$work/bin/ditto"
chmod +x "$work/bin/"*
export PATH="$work/bin:$PATH" CMUX_CODESIGN_TOOL="$work/bin/codesign"

fw_name="Chromium Embedded Framework.framework"
make_app() { # <dir> [library content]
  local fw="$1/cmux TEST.app/Contents/Frameworks/$fw_name"
  mkdir -p "$fw/Versions/A/Libraries" "$fw/Versions/A/Resources"
  printf 'chromium' > "$fw/Versions/A/Chromium Embedded Framework"
  printf '%s' "${2:-egl}" > "$fw/Versions/A/Libraries/libEGL.dylib"
  printf 'pak' > "$fw/Versions/A/Resources/resources.pak"
  ln -s A "$fw/Versions/Current"
  printf 'shim' > "$1/cmux TEST.app/Contents/Frameworks/libcmux_cef_shim.dylib"
  echo "$1/cmux TEST.app"
}
fw_of() { echo "$1/Contents/Frameworks/$fw_name"; }
id="Developer ID Application: Test (TEAM)"
mkdir -p "$work/reuse" "$work/saved"
reuse="$work/reuse/$fw_name"

# The published build: signed fresh, nothing to reuse.
published="$(make_app "$work/published")"
out="$(CMUX_CEF_REUSE_FRAMEWORK="$work/none/$fw_name" bash "$sign_cef" "$published" "$id")"
[[ "$out" != *sign-cef:* ]] || fail "a missing reuse copy printed: $out"
cp -pR "$(fw_of "$published")" "$reuse"

# Two fresh signatures of the same code differ (the time stamp), the problem this solves.
fresh="$(make_app "$work/fresh")"
bash "$sign_cef" "$fresh" "$id" >/dev/null
diff -r "$(fw_of "$published")" "$(fw_of "$fresh")" >/dev/null && fail "two fresh signatures came out byte-identical; the stub lost its time stamp"

# The next build, same engine: it ships the published framework's bytes.
next="$(make_app "$work/next")"
out="$(CMUX_CEF_REUSE_FRAMEWORK="$reuse" bash "$sign_cef" "$next" "$id")"
[[ "$out" == *"sign-cef: reused the signed Chromium framework"* ]] || fail "same code and signer was not reused: $out"
diff -r "$reuse" "$(fw_of "$next")" || fail "the reused framework is not the published one byte for byte"
[[ ! -e "$next/Contents/Frameworks/.cef-reuse" ]] || fail "the staging folder was left in the app"
[[ -f "$next/Contents/Frameworks/libcmux_cef_shim.dylib.sig" ]] || fail "the shim was not signed after the reuse"

expect_fresh() { # <name> <why> <app> <identity> [env...]
  local name="$1" why="$2" app="$3" ident="$4" out
  shift 4
  out="$(env "$@" CMUX_CEF_REUSE_FRAMEWORK="$reuse" bash "$sign_cef" "$app" "$ident")"
  [[ "$out" == *"sign-cef: kept the fresh Chromium framework signature"*"$why"* ]] || fail "$name: $out"
  diff -r "$reuse" "$(fw_of "$app")" >/dev/null && fail "$name: the published framework was put in the app"
  codesign --verify --strict "$(fw_of "$app")" || fail "$name: the fresh framework does not verify"
}
# A new engine (a library changed): signed fresh.
expect_fresh "new engine" "other code" "$(make_app "$work/engine" egl2)" "$id"
# An extra file in the published copy: signed fresh.
cp -pR "$reuse" "$work/saved/$fw_name"
printf 'x' > "$reuse/Versions/A/Resources/extra.txt"
expect_fresh "extra file" "other code" "$(make_app "$work/extra-app")" "$id"
rm -rf "$reuse" && mv "$work/saved/$fw_name" "$reuse"
# Another signer: signed fresh.
expect_fresh "other signer" "other code" "$(make_app "$work/signer")" "Developer ID Application: Other (OTHER)"
# A published copy with no time stamp, for a build that wants one: signed fresh.
nots="$(make_app "$work/nots")"
CMUX_TIMESTAMP=none bash "$sign_cef" "$nots" "$id" >/dev/null
rm -rf "$reuse" && cp -pR "$(fw_of "$nots")" "$reuse"
expect_fresh "no time stamp" "no secure time stamp" "$(make_app "$work/wants-ts")" "$id"

echo "PASS: sign-cef.sh reuses only the same code signed by the same signer with a time stamp"
