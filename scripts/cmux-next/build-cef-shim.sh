#!/usr/bin/env bash
# Builds the CEF glue for cmux-next from the pinned artifact:
#   libcef_dll_wrapper.a      CEF's C++ wrapper (from the artifact's libcef_dll/)
#   libcmux_cef_shim.dylib    Packages/macOS/CmuxNext/CEFShim (C ABI for Swift)
#   cmux-cef-helper           the subprocess binary for the helper apps
#
# Usage: build-cef-shim.sh <cef_dir> <cache_dir>
# Prints the output directory on stdout (progress goes to stderr); exits
# non-zero on compile errors. The output is content-addressed,
# <cache_dir>/<artifact>[-<sanitizer>]-<key>, where the key hashes the
# artifact, the shim header (the ABI identity) and sources, this script, the
# warning counter, the shim's flags (with the sanitizer), clang and the target.
#
# The shim's own sources build with Chromium's hardening
# (build/config/compiler/BUILD.gn, build/config/c++/BUILD.gn): libc++
# hardening (fast), pattern-initialized locals, -fstack-protector-strong and
# -fno-delete-null-pointer-checks; and with -Wall -Wextra
# -Wunsafe-buffer-usage as warnings. The warnings are a queue (p10-stability
# Q22), counted per build in <output>/warnings.json (cef_shim_warnings.py),
# with the full text in <output>/warnings.log. CEF's headers count as system
# headers, as Chromium's third_party does (build/config/unsafe_buffers_paths.txt).
# The wrapper keeps `common` only: it is CEF's code, and the Chromium host
# links it with the same flags (tests/chromium-host-flags.test.sh).
#
# CMUX_CEF_SHIM_SANITIZE=address|thread|undefined (or address,undefined)
# builds an instrumented libcmux_cef_shim.dylib for lab apps, under its own
# key and directory, with its DWARF in <output>/libcmux_cef_shim.dylib.dSYM
# (embed-cef.sh puts it in the build's dSYM folder). Inside an Xcode build
# the shim takes the app's own sanitizer (ENABLE_ADDRESS_SANITIZER, ENABLE_THREAD_SANITIZER,
# ENABLE_UNDEFINED_BEHAVIOR_SANITIZER, which scripts/reload.sh --config
# asan|tsan|ubsan sets) and refuses any other value: an instrumented shim
# needs the app to load its runtime. check-cef-shim-sanitizer.sh (run by
# check-no-bench-hooks.sh in the release and nightly pipelines) refuses a
# bundle whose shim loads a runtime its main executable does not. The helper
# and the wrapper are never instrumented: the helper runs in Chromium's
# processes, where PartitionAlloc owns malloc.
# A finished directory is never changed or deleted, so worktrees and
# concurrent builds that share the cache cannot disturb each other: a build
# writes to a private temporary directory and renames it into place; when
# another build got there first, that result is used.
set -euo pipefail

CEF_DIR="${1:?usage: build-cef-shim.sh <cef_dir> <cache_dir>}"
CACHE_DIR="${2:?usage: build-cef-shim.sh <cef_dir> <cache_dir>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SHIM_DIR="$REPO_ROOT/Packages/macOS/CmuxNext/CEFShim"
# The public header lives in the Swift target (it is also a SwiftPM resource
# there). Its SHA-256 is the ABI identity on both sides; see the header.
SHIM_HEADER_DIR="$REPO_ROOT/Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/CEF/Shim"
SHIM_HEADER="$SHIM_HEADER_DIR/cmux_cef_shim.h"
ABI_ID="$(shasum -a 256 "$SHIM_HEADER" | awk '{print $1}')"
ARCH="${CMUX_CEF_ARCH:-arm64}"
MIN_OS="${CMUX_CEF_MIN_OS:-14.0}"

WARNINGS_TOOL="$SCRIPT_DIR/cef_shim_warnings.py"

normalize_sanitizers() { # <comma-separated kinds> -> sorted, comma-separated; fails on a bad list
  local kind kinds out=() list
  [[ -z "${1// /}" ]] && return 0
  IFS=, read -r -a kinds <<< "${1// /}"
  for kind in "${kinds[@]}"; do
    case "$kind" in
      address | thread | undefined) out+=("$kind") ;;
      *) echo "error: CMUX_CEF_SHIM_SANITIZE takes address, thread or undefined (got '$1')" >&2; return 1 ;;
    esac
  done
  list="$(printf '%s\n' "${out[@]}" | sort -u | paste -sd, -)"
  if [[ ",$list," == *,address,* && ",$list," == *,thread,* ]]; then
    echo "error: CMUX_CEF_SHIM_SANITIZE cannot combine address and thread" >&2
    return 1
  fi
  printf '%s' "$list"
}
SANITIZE="$(normalize_sanitizers "${CMUX_CEF_SHIM_SANITIZE:-}")"
if [[ -n "${CONFIGURATION:-}" ]]; then
  app_sanitize=""
  [[ "${ENABLE_ADDRESS_SANITIZER:-NO}" == YES ]] && app_sanitize+="address,"
  [[ "${ENABLE_THREAD_SANITIZER:-NO}" == YES ]] && app_sanitize+="thread,"
  [[ "${ENABLE_UNDEFINED_BEHAVIOR_SANITIZER:-NO}" == YES ]] && app_sanitize+="undefined,"
  app_sanitize="$(normalize_sanitizers "${app_sanitize%,}")"
  if [[ -n "${CMUX_CEF_SHIM_SANITIZE:-}" && "$SANITIZE" != "$app_sanitize" ]]; then
    echo "error: CMUX_CEF_SHIM_SANITIZE=$CMUX_CEF_SHIM_SANITIZE in a $CONFIGURATION build with sanitizers '${app_sanitize:-none}': the shim takes the app's own sanitizer" >&2
    exit 1
  fi
  SANITIZE="$app_sanitize"
fi
sanitize_tag=""
[[ -n "$SANITIZE" ]] && sanitize_tag="$(printf '%s' "$SANITIZE" | sed 's/address/asan/; s/thread/tsan/; s/undefined/ubsan/' | tr , -)"

# The shim's own flags, after `common` (the later -fstack-protector-strong wins).
hardening=(
  -D_LIBCPP_HARDENING_MODE=_LIBCPP_HARDENING_MODE_FAST
  -ftrivial-auto-var-init=pattern -fstack-protector-strong -fno-delete-null-pointer-checks
)
warnings=(-Wall -Wextra -Wunsafe-buffer-usage --system-header-prefix=include/)
sanitize_flags=()
if [[ -n "$SANITIZE" ]]; then
  sanitize_flags=(-fsanitize="$SANITIZE" -fno-omit-frame-pointer -g)
  # vptr needs RTTI; the shim builds without it, like CEF.
  if [[ ",$SANITIZE," == *,undefined,* ]]; then sanitize_flags+=(-fno-sanitize=vptr); fi
fi

CXX="$(xcrun --sdk macosx --find clang++)"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
key="$(
  {
    cat "$CEF_DIR/CMUX-ARTIFACT.json" 2>/dev/null || cat "$CEF_DIR/archive.json"
    find "$SHIM_DIR" -type f \( -name '*.h' -o -name '*.mm' \) -print0 | sort -z | xargs -0 shasum -a 256
    echo "abi $ABI_ID"
    shasum -a 256 "${BASH_SOURCE[0]}"
    shasum -a 256 "$WARNINGS_TOOL"
    echo "flags ${hardening[*]} ${warnings[*]}"
    echo "sanitize ${SANITIZE:-none} ${sanitize_flags[*]:-}"
    "$CXX" --version | head -n 1
    echo "$ARCH $MIN_OS"
  } | shasum -a 256 | awk '{print $1}'
)"
FINAL_DIR="$CACHE_DIR/$(basename "$CEF_DIR")-${sanitize_tag:+$sanitize_tag-}${key:0:16}"
complete() {
  [[ -f "$1/.build-key" && "$(cat "$1/.build-key")" == "$key" && -f "$1/libcmux_cef_shim.dylib" && -x "$1/cmux-cef-helper" && -f "$1/warnings.json" ]] &&
    { [[ -z "$SANITIZE" ]] || [[ -d "$1/libcmux_cef_shim.dylib.dSYM" ]]; }
}
if complete "$FINAL_DIR"; then
  echo "$FINAL_DIR"
  exit 0
fi

mkdir -p "$CACHE_DIR"
OUT_DIR="$(mktemp -d "$CACHE_DIR/.building.XXXXXX")"
trap 'rm -rf "$OUT_DIR"' EXIT
echo "==> building CEF shim into $FINAL_DIR" >&2
mkdir -p "$OUT_DIR/obj/wrapper" "$OUT_DIR/obj/shim"

common=(
  -arch "$ARCH" -isysroot "$SDK" -mmacosx-version-min="$MIN_OS" -O2
  -std=c++20 -fno-exceptions -fno-rtti -fno-strict-aliasing -fstack-protector -funwind-tables
  -fvisibility=hidden -fvisibility-inlines-hidden -fobjc-call-cxx-cdtors
  -D__STDC_CONSTANT_MACROS -D__STDC_FORMAT_MACROS
  -I"$CEF_DIR"
  -Wno-deprecated-declarations -Wno-undefined-var-template -Werror=unguarded-availability-new
)
export CXX CEF_DIR OUT_DIR
export COMMON_FLAGS="${common[*]}"

# Wrapper: every translation unit under libcef_dll, as its CMake target does.
jobs="$(sysctl -n hw.ncpu)"
(cd "$CEF_DIR/libcef_dll" && find . -type f \( -name '*.cc' -o -name '*.mm' \) -print0) |
  xargs -0 -P "$jobs" -I{} sh -c '
    src="$1"
    obj="$OUT_DIR/obj/wrapper/$(printf "%s" "$src" | sed "s#^\./##; s#/#_#g").o"
    # shellcheck disable=SC2086
    "$CXX" $COMMON_FLAGS -DWRAPPING_CEF_SHARED -c "$CEF_DIR/libcef_dll/$src" -o "$obj"
  ' _ {} || { echo "error: CEF wrapper compile failed" >&2; exit 1; }
libtool -static -no_warning_for_no_symbols -o "$OUT_DIR/libcef_dll_wrapper.a" "$OUT_DIR"/obj/wrapper/*.o

# Each source's diagnostics go to its own log: printed when the compile fails,
# counted in warnings.json and kept in warnings.log.
for src in "$SHIM_DIR"/src/*.mm; do
  name="$(basename "$src")"
  flags=("${common[@]}" "${hardening[@]}" "${warnings[@]}")
  # The helper runs in Chromium's processes (PartitionAlloc's malloc): never instrumented.
  if [[ "$name" != helper_main.mm ]]; then flags+=(${sanitize_flags[@]+"${sanitize_flags[@]}"}); fi
  if ! "$CXX" "${flags[@]}" -I"$SHIM_DIR" -I"$SHIM_HEADER_DIR" -DCMUX_CEF_SHIM_ABI_ID="\"$ABI_ID\"" \
    -c "$src" -o "$OUT_DIR/obj/shim/$name.o" 2> "$OUT_DIR/obj/shim/$name.log"; then
    cat "$OUT_DIR/obj/shim/$name.log" >&2
    echo "error: CEF shim compile failed: $name" >&2
    exit 1
  fi
done
cat "$OUT_DIR"/obj/shim/*.log > "$OUT_DIR/warnings.log"
/usr/bin/python3 -I "$WARNINGS_TOOL" --root "$REPO_ROOT" --sanitize "${SANITIZE:-none}" \
  --out "$OUT_DIR/warnings.json" "$OUT_DIR/warnings.log" >&2

# An instrumented shim loads its runtime by @rpath: the app's copy, already
# loaded, or the one beside the shim in Contents/Frameworks.
shim_link=()
if [[ -n "$SANITIZE" ]]; then shim_link=(-fsanitize="$SANITIZE" -Xlinker -rpath -Xlinker @loader_path); fi
"$CXX" -arch "$ARCH" -isysroot "$SDK" -mmacosx-version-min="$MIN_OS" -dynamiclib \
  ${shim_link[@]+"${shim_link[@]}"} \
  -install_name "@rpath/libcmux_cef_shim.dylib" \
  -o "$OUT_DIR/libcmux_cef_shim.dylib" \
  "$OUT_DIR/obj/shim/shim_process.mm.o" "$OUT_DIR/obj/shim/shim_client.mm.o" "$OUT_DIR/obj/shim/shim_browser.mm.o" \
  "$OUT_DIR/obj/shim/shim_site.mm.o" "$OUT_DIR/obj/shim/shim_devtools.mm.o" \
  "$OUT_DIR/obj/shim/shim_windows.mm.o" "$OUT_DIR/obj/shim/shim_proxy.mm.o" \
  "$OUT_DIR/obj/shim/shim_extensions_ui.mm.o" "$OUT_DIR/obj/shim/shim_webstore.mm.o" \
  "$OUT_DIR/obj/shim/shim_cookie_import.mm.o" "$OUT_DIR/obj/shim/shim_browsing_data.mm.o" \
  "$OUT_DIR/obj/shim/shim_password_import.mm.o" "$OUT_DIR/obj/shim/shim_passkeys.mm.o" \
  "$OUT_DIR/obj/shim/shim_password_core.mm.o" \
  "$OUT_DIR/obj/shim/shim_devtools_protocol.mm.o" "$OUT_DIR/obj/shim/shim_prefs.mm.o" \
  "$OUT_DIR/obj/shim/shim_page_scheme.mm.o" "$OUT_DIR/obj/shim/shim_downloads.mm.o" \
  "$OUT_DIR/obj/shim/shim_background.mm.o" "$OUT_DIR/obj/shim/shim_bookmarks.mm.o" \
  "$OUT_DIR/obj/shim/shim_permissions.mm.o" "$OUT_DIR/obj/shim/shim_helper_host.mm.o" \
  "$OUT_DIR/obj/shim/shim_file_dialog.mm.o" "$OUT_DIR/obj/shim/shim_tracing.mm.o" \
  "$OUT_DIR/libcef_dll_wrapper.a" -framework AppKit -framework Cocoa -framework IOSurface -lobjc
# The instrumented shim's -g DWARF stays in obj/ (the dylib keeps only a debug
# map to it, and obj/ goes below): collect it into a dSYM, kept in the output
# directory, so its sanitizer reports symbolize to file:line.
if [[ -n "$SANITIZE" ]]; then
  dsymutil "$OUT_DIR/libcmux_cef_shim.dylib" -o "$OUT_DIR/libcmux_cef_shim.dylib.dSYM"
fi

"$CXX" -arch "$ARCH" -isysroot "$SDK" -mmacosx-version-min="$MIN_OS" \
  -o "$OUT_DIR/cmux-cef-helper" \
  "$OUT_DIR/obj/shim/helper_main.mm.o" \
  "$OUT_DIR/libcef_dll_wrapper.a" -framework AppKit -framework Cocoa -framework IOSurface

rm -rf "$OUT_DIR/obj"
printf '%s' "$key" > "$OUT_DIR/.build-key"
# Atomic publish: rename(2) fails when the target already exists (another
# build published the same key meanwhile, from the same inputs); keep that.
if ! /usr/bin/python3 -c 'import os, sys; os.rename(sys.argv[1], sys.argv[2])' "$OUT_DIR" "$FINAL_DIR" 2>/dev/null; then
  complete "$FINAL_DIR" || { echo "error: $FINAL_DIR exists but is incomplete" >&2; exit 1; }
fi
# Entries of older inputs: drop those unused for a week (and stale
# temporary directories of crashed builds).
find "$CACHE_DIR" -mindepth 1 -maxdepth 1 -type d -mtime +7 ! -path "$FINAL_DIR" -exec rm -rf {} + 2>/dev/null || true
echo "==> CEF shim ready (abi ${ABI_ID:0:12}${SANITIZE:+, $SANITIZE sanitizer})" >&2
echo "$FINAL_DIR"
