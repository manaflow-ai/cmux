#!/usr/bin/env bash
# embed-cef.sh with CMUX_NEXT_REQUIRE_CEF=1 must reach ensure-cef.sh with no
# extra arguments under Xcode's /bin/bash 3.2, where an empty array is
# "unbound" under `set -u`. ensure-cef.sh is a stub here: no network, no build.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/scripts" "$TMP/build/app.app/Contents/Frameworks"
cp "$ROOT/scripts/cmux-next/embed-cef.sh" "$ROOT/scripts/cmux-next/cef-locale-allowlist.sh" "$ROOT/scripts/cmux-next/bundle-ublock.sh" \
  "$ROOT/scripts/cmux-next/lipo-dsym.sh" "$TMP/scripts/"
cat > "$TMP/scripts/ensure-cef.sh" <<'STUB'
#!/usr/bin/env bash
echo "stub ensure-cef args=[$*]" >&2
exit 7
STUB
chmod +x "$TMP/scripts/ensure-cef.sh"
run() { # <require> -> output of embed-cef.sh under /bin/bash
  env -i PATH=/usr/bin:/bin HOME="$TMP" ARCHS=arm64 TARGET_BUILD_DIR="$TMP/build" WRAPPER_NAME=app.app \
    CMUX_NEXT_SKIP_UBLOCK=1 CMUX_NEXT_REQUIRE_CEF="$1" /bin/bash "$TMP/scripts/embed-cef.sh" 2>&1 || true
}
out=$(run 1)
grep -q 'stub ensure-cef args=\[\]$' <<<"$out" || { printf 'REQUIRE_CEF=1 did not reach ensure-cef.sh:\n%s\n' "$out" >&2; exit 1; }
if grep -q 'unbound variable' <<<"$out"; then printf 'unbound variable:\n%s\n' "$out" >&2; exit 1; fi
out=$(run 0)
grep -q 'stub ensure-cef args=\[--optional\]$' <<<"$out" || { printf 'optional mode lost --optional:\n%s\n' "$out" >&2; exit 1; }
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
    PRODUCT_NAME=app PRODUCT_BUNDLE_IDENTIFIER=test.app DERIVED_FILE_DIR="$TMP/derived" CMUX_NEXT_SKIP_UBLOCK=1 \
    /bin/bash "$TMP/scripts/embed-cef.sh" 2>&1) || { printf 'embed-cef.sh failed:\n%s\n' "$out" >&2; exit 1; }
  lib="$TMP/build/app.app/Contents/Frameworks/Chromium Embedded Framework.framework/Versions/A/Libraries/libvk_swiftshader.dylib"
  syms=$(nm -a "$lib")
  grep -qE ' T _?vk_icdGetInstanceProcAddr$' <<<"$syms" || { printf 'the exported symbol is gone:\n%s\n' "$syms" >&2; exit 1; }
  # Apple's strip leaves one marker stab (radr://5614542) that says the file was stripped.
  if grep -v 'radr://5614542' <<<"$syms" | grep -qE ' - |hidden_helper'; then
    printf 'embedded CEF library keeps local symbols or debug stabs:\n%s\n' "$syms" >&2; exit 1
  fi

  # The framework binary itself: the fork's framework is not an official build,
  # so it carries Chromium's whole symbol table (210 MiB of the 468 MiB arm64
  # slice of stage c8953bc613cd). A Release build that keeps the framework's
  # dSYM for Sentry (CEF-dSYMs/<arch>) ships it with strip -S -x: exported
  # symbols stay, locals and debug-map stabs go. Debug and bench builds name
  # Chromium frames of local dumps with atos on the framework, and a build
  # without the dSYM has nothing else to name them with: those keep them.
  printf 'static int chromium_local(int x) { return x * 5; }\nint cef_api_hash(int x) { return chromium_local(x); }\n' > "$TMP/fw.c"
  if [[ "$(uname)" == Darwin ]]; then
    cc -g -dynamiclib -o "$fw/Chromium Embedded Framework" "$TMP/fw.c"
  else
    cc -g -O0 -shared -fPIC -o "$fw/Chromium Embedded Framework" "$TMP/fw.c"
  fi
  mkdir -p "$TMP/dsym-src/Chromium Embedded Framework.dSYM/Contents/Resources/DWARF"
  : > "$TMP/dsym-src/Chromium Embedded Framework.dSYM/Contents/Resources/DWARF/Chromium Embedded Framework"
  tar -cf "$dist/fw.dSYM.tar" -C "$TMP/dsym-src" .
  with_dsym='{"chromium": "1.0", "debug_symbols": "fw.dSYM.tar"}'
  embed() { # <case> <configuration> <manifest JSON> [OTHER_SWIFT_FLAGS]
    printf '%s\n' "$3" > "$TMP/scripts/cef-manifest.json"
    env -i PATH="$TMP/bin:/usr/bin:/bin" HOME="$TMP" ARCHS=arm64 TARGET_BUILD_DIR="$TMP/$1/Products/$2" \
      WRAPPER_NAME=app.app PRODUCT_NAME=app PRODUCT_BUNDLE_IDENTIFIER=test.app DERIVED_FILE_DIR="$TMP/$1/derived" \
      CONFIGURATION="$2" OTHER_SWIFT_FLAGS="${4:-}" CMUX_NEXT_SKIP_UBLOCK=1 \
      /bin/bash "$TMP/scripts/embed-cef.sh" > "$TMP/$1.log" 2>&1 ||
      { printf 'embed-cef.sh failed (%s):\n' "$1" >&2; cat "$TMP/$1.log" >&2; exit 1; }
  }
  framework_symbols() { # <case> <configuration>
    nm -a "$TMP/$1/Products/$2/app.app/Contents/Frameworks/Chromium Embedded Framework.framework/Versions/A/Chromium Embedded Framework"
  }
  expect_framework() { # <case> <configuration> stripped|kept
    local syms; syms=$(framework_symbols "$1" "$2")
    grep -qE ' T _?cef_api_hash$' <<<"$syms" || { printf '%s: the exported symbol is gone:\n%s\n' "$1" "$syms" >&2; exit 1; }
    if [[ "$3" == stripped ]] && grep -q chromium_local <<<"$syms"; then
      printf '%s: the Release framework keeps its local symbols although its dSYM is kept:\n%s\n' "$1" "$syms" >&2; exit 1
    fi
    if [[ "$3" == kept ]] && ! grep -q chromium_local <<<"$syms"; then
      printf '%s: the framework lost its local symbols in a build that needs them:\n%s\n' "$1" "$syms" >&2; exit 1
    fi
  }
  embed release Release "$with_dsym"
  [[ -d "$TMP/release/Products/CEF-dSYMs/arm64" ]] || { echo 'release: the Chromium dSYM was not kept' >&2; cat "$TMP/release.log" >&2; exit 1; }
  expect_framework release Release stripped
  embed bench Release "$with_dsym" '-O -DCMUX_BENCH_HOOKS'
  expect_framework bench Release kept
  embed nodsym Release '{"chromium": "1.0"}'
  expect_framework nodsym Release kept
  # An unstripped embed from an earlier build is redone, not reused from the stamp.
  embed reuse Debug "$with_dsym"
  expect_framework reuse Debug kept
  mkdir -p "$TMP/reuse/Products/Release"
  cp -R "$TMP/reuse/Products/Debug/app.app" "$TMP/reuse/Products/Release/app.app"
  embed reuse Release "$with_dsym"
  expect_framework reuse Release stripped
fi
printf 'embed-cef tests: ok\n'
