#!/usr/bin/env bash
# embed-cef.sh picks the CEF artifacts and shims for the build's ARCHS:
#   arm64            -> the arm64 artifact and an arm64 shim
#   x86_64           -> the x86_64 artifact (ensure-cef --arch x86_64) and an x86_64 shim
#   arm64 x86_64     -> both artifacts, merge-cef-universal.sh, both shims lipo-merged
#   universal without an x86_64 artifact -> the arm64 engine alone
# ensure-cef, the merge, the shim build, lipo, signing and the notices are stubs
# that log their calls: no network, no compiler. macOS only (ditto).
set -euo pipefail
[[ "$(uname)" == Darwin ]] || { echo 'embed-cef arch test: skipped (not macOS)'; exit 0; }
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
FW="Chromium Embedded Framework.framework"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

S="$TMP/scripts"; mkdir -p "$S" "$TMP/bin" "$TMP/cache"
cp "$ROOT/scripts/cef/embed-cef.sh" "$ROOT/scripts/cef/cef-locale-allowlist.sh" "$S/"
printf '{"chromium": "1.0"}\n' > "$S/cef-manifest.json"
for arch in arm64 x86_64 universal; do
  mkdir -p "$TMP/dist-$arch/$FW/Libraries" "$TMP/dist-$arch/$FW/Resources"
  printf '%s\n' "$arch" > "$TMP/dist-$arch/$FW/Chromium Embedded Framework"
done
log="$TMP/calls.log"
cat > "$S/ensure-cef.sh" <<STUB
#!/usr/bin/env bash
arch=arm64
while ((\$#)); do case "\$1" in --arch) arch="\$2"; shift 2 ;; *) shift ;; esac; done
echo "ensure \$arch" >> "$log"
[[ "\$arch" == x86_64 && "\${NO_X86:-0}" == 1 ]] && exit 0
echo "$TMP/dist-\$arch"
STUB
cat > "$S/merge-cef-universal.sh" <<STUB
#!/usr/bin/env bash
echo "merge \$(basename "\$1") \$(basename "\$2")" >> "$log"
echo "$TMP/dist-universal"
STUB
cat > "$S/build-cef-shim.sh" <<STUB
#!/usr/bin/env bash
arch="\${CMUX_CEF_ARCH:-arm64}"
echo "shim \$arch \$(basename "\$1")" >> "$log"
out="$TMP/shim-\$arch"; mkdir -p "\$out"
printf '%s' "\$arch" > "\$out/libcmux_cef_shim.dylib"; printf '%s' "\$arch" > "\$out/cmux-cef-helper"
printf 'key-%s' "\$arch" > "\$out/.build-key"
echo "\$out"
STUB
printf '#!/usr/bin/env bash\necho "%s"\n' "$TMP/cache" > "$S/cef-cache-root.sh"
for stub in install-cef-credits.sh install-cef-license.sh sign-cef.sh; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$S/$stub"
done
# lipo -create a b -output c: concatenates, so the result names both arches.
cat > "$TMP/bin/lipo" <<'STUB'
#!/usr/bin/env bash
out=""; inputs=()
while (($#)); do case "$1" in -create) shift ;; -output) out="$2"; shift 2 ;; *) inputs+=("$1"); shift ;; esac; done
cat "${inputs[@]}" > "$out"
STUB
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/bin/codesign"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/bin/strip"
chmod +x "$S/"*.sh "$TMP/bin/"*

run() { # <ARCHS> [VAR=value...]
  local archs="$1"; shift
  rm -rf "$TMP/build" "$TMP/derived" "$TMP/cache/shim"; : > "$log"
  env -i PATH="$TMP/bin:/usr/bin:/bin" HOME="$TMP" ARCHS="$archs" TARGET_BUILD_DIR="$TMP/build" WRAPPER_NAME=app.app \
    PRODUCT_NAME=app PRODUCT_BUNDLE_IDENTIFIER=test.app DERIVED_FILE_DIR="$TMP/derived" CMUX_EMBED_CEF=1 "$@" \
    /bin/bash "$S/embed-cef.sh" > "$TMP/out.log" 2>&1 || { cat "$TMP/out.log" >&2; fail "embed-cef.sh failed for ARCHS=$archs"; }
}
embedded() { cat "$TMP/build/app.app/Contents/Frameworks/$FW/Versions/A/Chromium Embedded Framework"; }
shim() { cat "$TMP/build/app.app/Contents/Frameworks/libcmux_cef_shim.dylib"; }
helper() { cat "$TMP/build/app.app/Contents/Frameworks/app Helper (Renderer).app/Contents/MacOS/app Helper (Renderer)"; }

run arm64
grep -qx 'ensure arm64' "$log" && ! grep -q 'ensure x86_64\|merge' "$log" || fail "arm64: $(cat "$log")"
[[ "$(embedded)" == arm64 && "$(shim)" == arm64 ]] || fail "arm64 embedded $(embedded) / shim $(shim)"

run x86_64
grep -qx 'ensure x86_64' "$log" && ! grep -q 'ensure arm64\|merge' "$log" || fail "x86_64: $(cat "$log")"
grep -qx 'shim x86_64 dist-x86_64' "$log" || fail "x86_64 shim not built from the x86_64 dist: $(cat "$log")"
[[ "$(embedded)" == x86_64 && "$(shim)" == x86_64 && "$(helper)" == x86_64 ]] || fail "x86_64 embedded $(embedded) / shim $(shim)"

run "arm64 x86_64"
grep -qx 'merge dist-arm64 dist-x86_64' "$log" || fail "universal did not merge: $(cat "$log")"
grep -qx 'shim arm64 dist-arm64' "$log" && grep -qx 'shim x86_64 dist-x86_64' "$log" || fail "universal shims: $(cat "$log")"
[[ "$(embedded)" == universal ]] || fail "universal embedded $(embedded)"
[[ "$(shim)" == arm64x86_64 && "$(helper)" == arm64x86_64 ]] || fail "universal shim/helper not lipo-merged: $(shim) / $(helper)"

run "arm64 x86_64" NO_X86=1
! grep -q merge "$log" || fail "merged without an x86_64 artifact: $(cat "$log")"
[[ "$(embedded)" == arm64 && "$(shim)" == arm64 ]] || fail "universal without x86_64 embedded $(embedded) / shim $(shim)"

# Thinning a universal app to x86_64 drops an arm64-only engine (and its shim
# and helpers) instead of failing; thinning to arm64 keeps it.
if command -v cc >/dev/null && [[ -x /usr/bin/lipo ]]; then
  for target in x86_64 arm64; do
    app="$TMP/thin-$target/T.app"; fwd="$app/Contents/Frameworks"
    mkdir -p "$fwd/$FW/Versions/A" "$fwd/T Helper (GPU).app/Contents/MacOS"
    printf 'int cef_probe(void) { return 1; }\n' > "$TMP/probe.c"
    cc -arch arm64 -dynamiclib -o "$fwd/$FW/Versions/A/Chromium Embedded Framework" "$TMP/probe.c"
    cp "$fwd/$FW/Versions/A/Chromium Embedded Framework" "$fwd/libcmux_cef_shim.dylib"
    PATH=/usr/bin:/bin bash "$ROOT/scripts/thin-app-bundle.sh" "$app" "$target" > "$TMP/thin.log" 2>&1 ||
      { cat "$TMP/thin.log" >&2; fail "thin-app-bundle.sh $target failed"; }
    if [[ "$target" == x86_64 ]]; then
      [[ ! -e "$fwd/$FW" && ! -e "$fwd/libcmux_cef_shim.dylib" && ! -e "$fwd/T Helper (GPU).app" ]] ||
        fail "an arm64-only engine survived thinning to x86_64"
    else
      [[ -e "$fwd/$FW" && -e "$fwd/libcmux_cef_shim.dylib" ]] || fail "thinning to arm64 dropped the arm64 engine"
    fi
  done
else
  echo 'embed-cef arch test: thinning part skipped (no cc or lipo)'
fi

printf 'embed-cef arch tests: ok\n'
