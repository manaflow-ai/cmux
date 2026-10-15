#!/usr/bin/env bash
# embed-cef.sh with CMUX_REQUIRE_CEF=1 must reach ensure-cef.sh with no
# extra arguments under Xcode's /bin/bash 3.2, where an empty array is
# "unbound" under `set -u`. ensure-cef.sh is a stub here: no network, no build.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/scripts" "$TMP/build/app.app/Contents/Frameworks"
cp "$ROOT/scripts/cef/embed-cef.sh" "$ROOT/scripts/cef/cef-locale-allowlist.sh" "$TMP/scripts/"
cat > "$TMP/scripts/ensure-cef.sh" <<'STUB'
#!/usr/bin/env bash
echo "stub ensure-cef args=[$*]" >&2
exit 7
STUB
chmod +x "$TMP/scripts/ensure-cef.sh"
run() { # <require> [VAR=value...] -> output of embed-cef.sh under /bin/bash
  local require="$1"; shift
  env -i PATH=/usr/bin:/bin HOME="$TMP" ARCHS=arm64 TARGET_BUILD_DIR="$TMP/build" WRAPPER_NAME=app.app \
    CONFIGURATION=Debug CMUX_REQUIRE_CEF="$require" "$@" /bin/bash "$TMP/scripts/embed-cef.sh" 2>&1 || true
}
out=$(run 1)
grep -q 'stub ensure-cef args=\[\]$' <<<"$out" || { printf 'REQUIRE_CEF=1 did not reach ensure-cef.sh:\n%s\n' "$out" >&2; exit 1; }
if grep -q 'unbound variable' <<<"$out"; then printf 'unbound variable:\n%s\n' "$out" >&2; exit 1; fi
out=$(run 0)
grep -q 'stub ensure-cef args=\[--optional\]$' <<<"$out" || { printf 'optional mode lost --optional:\n%s\n' "$out" >&2; exit 1; }
# Embed policy: Debug outside CI embeds; Release, CI and CMUX_SKIP_CEF do not
# (and remove an earlier embed); CMUX_EMBED_CEF=1 embeds in any configuration.
leftover="$TMP/build/app.app/Contents/Frameworks/app Helper (GPU).app"
mkdir -p "$leftover"
out=$(run 0 CONFIGURATION=Release)
grep -q 'not embedding CEF (CONFIGURATION=Release)' <<<"$out" || { printf 'Release embedded CEF:\n%s\n' "$out" >&2; exit 1; }
[[ ! -e "$leftover" ]] || { echo 'a Release build kept an earlier CEF helper' >&2; exit 1; }
out=$(run 0 CI=true)
grep -q 'not embedding CEF (CI=true)' <<<"$out" || { printf 'CI embedded CEF:\n%s\n' "$out" >&2; exit 1; }
out=$(run 0 CMUX_SKIP_CEF=1)
grep -q 'not embedding CEF (CMUX_SKIP_CEF=1)' <<<"$out" || { printf 'CMUX_SKIP_CEF=1 embedded CEF:\n%s\n' "$out" >&2; exit 1; }
out=$(run 0 CONFIGURATION=Release CMUX_EMBED_CEF=1)
grep -q 'stub ensure-cef args=\[--optional\]$' <<<"$out" || { printf 'CMUX_EMBED_CEF=1 did not embed in Release:\n%s\n' "$out" >&2; exit 1; }
out=$(run 0 CMUX_EMBED_CEF=0)
grep -q 'not embedding CEF (CMUX_EMBED_CEF=0)' <<<"$out" || { printf 'CMUX_EMBED_CEF=0 embedded CEF:\n%s\n' "$out" >&2; exit 1; }
# The embedded CEF Libraries ship without local symbols or debug stabs
# (strip -S -x before signing): the stock libvk_swiftshader.dylib carries
# 7 MiB of them. Exported symbols stay, since the Vulkan loader dlsyms them.
# Builds a real library with the host compiler (a Mach-O dylib on macOS, an
# ELF object on Linux CI, where `ditto` is stood in by cp) and reads it back.
if ! { command -v cc && command -v nm && command -v strip; } >/dev/null; then
  [[ -n "${CI:-}" ]] && { echo 'embed-cef strip test needs cc, nm and strip on CI' >&2; exit 1; }
  echo 'embed-cef strip test: skipped (no cc, nm or strip)'
else
  dist="$TMP/dist"; fw="$dist/Chromium Embedded Framework.framework"
  mkdir -p "$fw/Libraries" "$fw/Resources" "$TMP/cache" "$TMP/bin"
  : > "$fw/Chromium Embedded Framework"
  printf 'static int hidden_helper(int x) { return x * 3; }\nint vk_icdGetInstanceProcAddr(int x) { return hidden_helper(x); }\n' > "$TMP/lib.c"
  if [[ "$(uname)" == Darwin ]]; then
    cc -g -dynamiclib -o "$fw/Libraries/libvk_swiftshader.dylib" "$TMP/lib.c"
  else
    cc -g -O0 -shared -fPIC -o "$fw/Libraries/libvk_swiftshader.dylib" "$TMP/lib.c"
    printf '#!/usr/bin/env bash\nmkdir -p "$(dirname "$2")"; cp -R "$1" "$2"\n' > "$TMP/bin/ditto"
    chmod +x "$TMP/bin/ditto"
  fi
  nm -a "$fw/Libraries/libvk_swiftshader.dylib" | grep -q hidden_helper || { echo 'fixture has no local symbol' >&2; exit 1; }
  printf '{"chromium": "1.0"}\n' > "$TMP/scripts/cef-manifest.json"
  for stub in install-cef-credits.sh install-cef-license.sh sign-cef.sh; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/scripts/$stub"
  done
  printf '#!/usr/bin/env bash\necho "%s"\n' "$dist" > "$TMP/scripts/ensure-cef.sh"
  printf '#!/usr/bin/env bash\necho "%s"\n' "$TMP/cache" > "$TMP/scripts/cef-cache-root.sh"
  cat > "$TMP/scripts/build-cef-shim.sh" <<STUB
#!/usr/bin/env bash
mkdir -p "$TMP/shim"; : > "$TMP/shim/libcmux_cef_shim.dylib"; : > "$TMP/shim/cmux-cef-helper"; printf k > "$TMP/shim/.build-key"
echo "$TMP/shim"
STUB
  chmod +x "$TMP/scripts/"*.sh
  out=$(env -i PATH="$TMP/bin:/usr/bin:/bin" HOME="$TMP" ARCHS=arm64 TARGET_BUILD_DIR="$TMP/build" WRAPPER_NAME=app.app \
    PRODUCT_NAME=app PRODUCT_BUNDLE_IDENTIFIER=test.app DERIVED_FILE_DIR="$TMP/derived" CONFIGURATION=Debug \
    /bin/bash "$TMP/scripts/embed-cef.sh" 2>&1) || { printf 'embed-cef.sh failed:\n%s\n' "$out" >&2; exit 1; }
  lib="$TMP/build/app.app/Contents/Frameworks/Chromium Embedded Framework.framework/Versions/A/Libraries/libvk_swiftshader.dylib"
  syms=$(nm -a "$lib")
  grep -qE ' T _?vk_icdGetInstanceProcAddr$' <<<"$syms" || { printf 'the exported symbol is gone:\n%s\n' "$syms" >&2; exit 1; }
  # Apple's strip leaves one marker stab (radr://5614542) that says the file was stripped.
  if grep -v 'radr://5614542' <<<"$syms" | grep -qE ' - |hidden_helper'; then
    printf 'embedded CEF library keeps local symbols or debug stabs:\n%s\n' "$syms" >&2; exit 1
  fi
fi
printf 'embed-cef tests: ok\n'
