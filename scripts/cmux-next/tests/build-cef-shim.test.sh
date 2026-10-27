#!/usr/bin/env bash
# build-cef-shim.sh's flags, cache key and sanitizer variant (p10-stability-162), and
# check-cef-shim-sanitizer.sh, with a stub toolchain: no Xcode, no CEF, runs on Linux.
# - The shim's sources get the hardening and warning flags; the wrapper gets `common` only.
# - warnings.json counts the compile's warnings once each (a header's warning seen by two sources is one).
# - CMUX_CEF_SHIM_SANITIZE builds under another key and directory; only the shim's own sources and its
#   link are instrumented, never the helper or the wrapper.
# - The instrumented shim's DWARF is kept in a dSYM (dsymutil before obj/ goes); a plain build has none.
# - Inside an Xcode build the shim takes the app's sanitizer and refuses another one.
# - A bundle whose shim loads a sanitizer runtime its main executable does not is refused.
#
# Not in CI (lead, 2026-10-23: no new CI tests); run it when you change either script.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../../.." && pwd)"
build="$here/../build-cef-shim.sh"
check="$here/../check-cef-shim-sanitizer.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/build-cef-shim-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# The stub toolchain: clang++ records each call (one line of arguments) and writes its output file.
bin="$work/bin"
mkdir -p "$bin"
cat > "$bin/xcrun" <<STUB
#!/usr/bin/env bash
case "\$*" in
  *--find\ clang++*) echo "$bin/clang++" ;;
  *--show-sdk-path*) echo "$work/sdk" ;;
  *) exit 1 ;;
esac
STUB
cat > "$bin/clang++" <<'STUB'
#!/usr/bin/env bash
[[ "${1:-}" == --version ]] && { echo "stub clang version 1"; exit 0; }
printf '%s\n' "$*" >> "$STUB_LOG"
out="" src=""
while (( $# )); do
  case "$1" in
    -o) out="$2"; shift ;;
    -c) src="$2"; shift ;;
  esac
  shift
done
[[ -n "${STUB_FAIL:-}" && "$src" == *"$STUB_FAIL" ]] && { echo "$src:1:1: error: stub failure" >&2; exit 1; }
header="$STUB_ROOT/Packages/macOS/CmuxNext/CEFShim/src/shim_internal.h"
case "$src" in
  */shim_client.mm)
    echo "$header:10:3: warning: unsafe buffer access [-Wunsafe-buffer-usage]" >&2
    echo "$src:5:1: warning: unused parameter 'x' [-Wunused-parameter]" >&2 ;;
  */shim_browser.mm)
    echo "In file included from $src:3:" >&2
    echo "$header:10:3: warning: unsafe buffer access [-Wunsafe-buffer-usage]" >&2 ;;
esac
[[ -n "$out" ]] && : > "$out" && chmod +x "$out"
exit 0
STUB
cat > "$bin/libtool" <<'STUB'
#!/usr/bin/env bash
while (( $# )); do [[ "$1" == -o ]] && { : > "$2"; exit 0; }; shift; done
STUB
cat > "$bin/dsymutil" <<'STUB'
#!/usr/bin/env bash
printf 'dsymutil %s\n' "$*" >> "$STUB_LOG"
while (( $# )); do [[ "$1" == -o ]] && { mkdir -p "$2/Contents/Resources/DWARF"; exit 0; }; shift; done
exit 1
STUB
printf '#!/usr/bin/env bash\necho 4\n' > "$bin/sysctl"
chmod +x "$bin"/*

cef="$work/cef_binary_test"
mkdir -p "$cef/libcef_dll/wrapper"
echo '{"artifact": "test"}' > "$cef/CMUX-ARTIFACT.json"
: > "$cef/libcef_dll/wrapper/a.cc"
cache="$work/cache"

runs=0
out=""
run() { # [env...] -> $out, the output directory; the calls in $work/calls.$runs, stderr in $work/stderr.$runs
  runs=$((runs + 1))
  local log="$work/calls.$runs"
  : > "$log"
  out="$(env -u CONFIGURATION -u CMUX_CEF_SHIM_SANITIZE -u ENABLE_ADDRESS_SANITIZER -u ENABLE_THREAD_SANITIZER \
    -u ENABLE_UNDEFINED_BEHAVIOR_SANITIZER PATH="$bin:$PATH" STUB_LOG="$log" STUB_ROOT="$root" "$@" \
    bash "$build" "$cef" "$cache" 2> "$work/stderr.$runs")"
}
ok() { # [env...] -> run, which must succeed
  run "$@" || fail "build-cef-shim.sh $* failed: $(cat "$work/stderr.$runs")"
}
calls() { cat "$work/calls.$runs"; }
call_for() { grep -F -- "$1" "$work/calls.$runs" || fail "no call for $1"; }
json() { python3 -I -c 'import json, sys; d = json.load(open(sys.argv[1])); print(eval(sys.argv[2], {"d": d}))' "$@"; }

# 1. The plain shim: hardening on the shim's sources, not on the wrapper; the warning file.
ok; plain="$out"
[[ "$(basename "$plain")" =~ ^cef_binary_test-[0-9a-f]{16}$ ]] || fail "plain output directory: $plain"
client="$(call_for /src/shim_client.mm)"
for flag in -D_LIBCPP_HARDENING_MODE=_LIBCPP_HARDENING_MODE_FAST -ftrivial-auto-var-init=pattern \
  -fstack-protector-strong -fno-delete-null-pointer-checks -Wall -Wextra -Wunsafe-buffer-usage \
  --system-header-prefix=include/; do
  [[ " $client " == *" $flag "* ]] || fail "the shim's sources lack $flag: $client"
done
wrapper="$(call_for /libcef_dll/./wrapper/a.cc)"
[[ "$wrapper" != *-fstack-protector-strong* && "$wrapper" != *-Wunsafe-buffer-usage* ]] ||
  fail "the wrapper got the shim's own flags (the Chromium host links it with \`common\`): $wrapper"
! calls | grep -q -- -fsanitize || fail "a plain build passed -fsanitize"
! calls | grep -q '^dsymutil ' || fail "a plain build ran dsymutil"
[[ ! -e "$plain/libcmux_cef_shim.dylib.dSYM" ]] || fail "a plain build published a dSYM"
[[ -f "$plain/warnings.json" && -f "$plain/warnings.log" ]] || fail "no warnings.json or warnings.log in $plain"
[[ "$(json "$plain/warnings.json" 'd["total"], d["unsafe_buffer_usage"], d["sanitize"]')" == "(2, 1, 'none')" ]] ||
  fail "warnings.json: $(cat "$plain/warnings.json")"
[[ "$(json "$plain/warnings.json" 'sorted(d["by_file"])')" == \
  "['Packages/macOS/CmuxNext/CEFShim/src/shim_client.mm', 'Packages/macOS/CmuxNext/CEFShim/src/shim_internal.h']" ]] ||
  fail "warnings.json by_file is not repository-relative: $(cat "$plain/warnings.json")"
grep -q 'CEF shim warnings: 2 (1 -Wunsafe-buffer-usage)' "$work/stderr.$runs" || fail "no warning summary on stderr"

# 2. The same inputs hit the cache.
ok; [[ "$out" == "$plain" ]] || fail "the same inputs gave another directory"
[[ ! -s "$work/calls.$runs" ]] || fail "a cache hit compiled again"

# 3. The instrumented shim: its own key and directory; only the shim's sources and link instrumented.
ok CMUX_CEF_SHIM_SANITIZE=address; asan="$out"
[[ "$(basename "$asan")" =~ ^cef_binary_test-asan-[0-9a-f]{16}$ ]] || fail "asan output directory: $asan"
[[ "${asan##*-}" != "${plain##*-}" ]] || fail "the asan shim has the plain shim's key"
[[ " $(call_for /src/shim_client.mm) " == *" -fsanitize=address -fno-omit-frame-pointer -g "* ]] ||
  fail "the asan shim's sources are not instrumented"
[[ "$(call_for /src/helper_main.mm)" != *-fsanitize* ]] || fail "the helper was instrumented"
[[ "$(call_for /libcef_dll/./wrapper/a.cc)" != *-fsanitize* ]] || fail "the wrapper was instrumented"
[[ " $(call_for libcmux_cef_shim.dylib) " == *" -fsanitize=address -Xlinker -rpath -Xlinker @loader_path "* ]] ||
  fail "the asan shim's link does not load the runtime"
[[ "$(call_for /cmux-cef-helper)" != *-fsanitize* ]] || fail "the helper's link loads a sanitizer runtime"
# -g's DWARF is in obj/, which the build deletes: a dSYM keeps it, published with the shim.
[[ "$(grep '^dsymutil ' "$work/calls.$runs")" == \
  "dsymutil $cache/.building."*"/libcmux_cef_shim.dylib -o $cache/.building."*"/libcmux_cef_shim.dylib.dSYM" ]] ||
  fail "the asan shim's DWARF is not collected into a dSYM: $(calls)"
[[ -d "$asan/libcmux_cef_shim.dylib.dSYM/Contents/Resources/DWARF" ]] || fail "the asan shim was published without its dSYM"
[[ "$(json "$asan/warnings.json" 'd["sanitize"]')" == address ]] || fail "warnings.json does not name the sanitizer"

# 4. Two sanitizers, in any order, are one variant; vptr stays off (no RTTI).
ok CMUX_CEF_SHIM_SANITIZE=undefined,address; both="$out"
[[ "$(basename "$both")" =~ ^cef_binary_test-asan-ubsan-[0-9a-f]{16}$ ]] || fail "asan+ubsan directory: $both"
[[ " $(call_for /src/shim_client.mm) " == *" -fsanitize=address,undefined "*" -fno-sanitize=vptr "* ]] ||
  fail "asan+ubsan flags: $(call_for /src/shim_client.mm)"

# 5. Refused values.
for bad in memory address,thread; do
  if run CMUX_CEF_SHIM_SANITIZE="$bad"; then fail "CMUX_CEF_SHIM_SANITIZE=$bad was accepted"; fi
done

# 6. Inside Xcode: the app's sanitizer, and no other.
ok CONFIGURATION=Release ENABLE_ADDRESS_SANITIZER=YES; [[ "$out" == "$asan" ]] ||
  fail "an Xcode ASan build did not get the asan shim"
ok CONFIGURATION=Release ENABLE_ADDRESS_SANITIZER=YES CMUX_CEF_SHIM_SANITIZE=address; [[ "$out" == "$asan" ]] ||
  fail "an Xcode ASan build refused its own sanitizer"
if run CONFIGURATION=Release CMUX_CEF_SHIM_SANITIZE=address; then
  fail "a Release build without a sanitizer took an instrumented shim"
fi
grep -q "the shim takes the app's own sanitizer" "$work/stderr.$runs" || fail "no reason for the refusal"
if run CONFIGURATION=Debug ENABLE_THREAD_SANITIZER=YES CMUX_CEF_SHIM_SANITIZE=address; then
  fail "a TSan build took an ASan shim"
fi
ok CONFIGURATION=Release; [[ "$out" == "$plain" ]] || fail "a plain Xcode build did not get the plain shim"

# 7. A failed compile prints its diagnostics and publishes nothing.
rm -rf "$cache"
if run STUB_FAIL=/src/shim_site.mm; then fail "a failed compile succeeded"; fi
grep -q 'stub failure' "$work/stderr.$runs" || fail "a failed compile did not print its diagnostics"
[[ -z "$(find "$cache" -mindepth 1 -maxdepth 1 -name 'cef_binary_test-*')" ]] || fail "a failed build published a directory"

# 8. check-cef-shim-sanitizer.sh.
app="$work/cmux.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks"
printf 'plain executable' > "$app/Contents/MacOS/cmux"
expect_check() { # <0|1> <what>
  local status=0
  bash "$check" "$app" "$app/Contents/MacOS/cmux" 2> "$work/check.err" || status=$?
  [[ "$status" == "$1" ]] || fail "check-cef-shim-sanitizer.sh: $2 (exit $status: $(cat "$work/check.err"))"
}
expect_check 0 "an app without a shim"
printf 'plain shim' > "$app/Contents/Frameworks/libcmux_cef_shim.dylib"
expect_check 0 "a plain shim in a plain app"
printf 'shim\0@rpath/libclang_rt.asan_osx_dynamic.dylib\0' > "$app/Contents/Frameworks/libcmux_cef_shim.dylib"
expect_check 1 "an asan shim in a plain (shipped) app"
grep -q 'asan sanitizer' "$work/check.err" || fail "the refusal does not name the sanitizer"
printf 'exe\0@rpath/libclang_rt.tsan_osx_dynamic.dylib\0' > "$app/Contents/MacOS/cmux"
expect_check 1 "an asan shim in a tsan app"
printf 'exe\0@rpath/libclang_rt.asan_osx_dynamic.dylib\0' > "$app/Contents/MacOS/cmux"
expect_check 0 "an asan shim in an asan app"
echo "build-cef-shim tests: ok"
