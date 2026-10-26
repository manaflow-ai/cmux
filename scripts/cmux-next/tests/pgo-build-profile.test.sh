#!/usr/bin/env bash
# scripts/cmux-next/pgo/build-profile.sh (p08-startup-049): it builds `reload.sh --config profile`, refuses a
# bundle that is not an instrumented profile build, and passes only when the launched app's own .profraw has
# counts. reload.sh, the launch and llvm-profdata are stubs (the script's test seams); the real run is a fleet
# step. Also checks that reload.sh's profile arm carries the PGO flags and that no other arm does.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
script="$root/scripts/cmux-next/pgo/build-profile.sh"
reload="$root/scripts/reload.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failures=0

fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }

# --- reload.sh: the profile arm and its flags --------------------------------------------------------------
grep -qE '^\s*profile\) BUILD_CONFIGURATION="Release" BENCH_HOOKS=1 BLOCKING_CHECKS=0 PGO_PROFILE=1 ;;' "$reload" \
  || fail "reload.sh has no profile arm (Release, bench hooks, PGO_PROFILE=1)"
for arm in debug release bench bench-checks; do
  grep -qE "^\s*${arm}\) BUILD_CONFIGURATION=.* PGO_PROFILE=0 ;;" "$reload" || fail "reload.sh arm $arm does not clear PGO_PROFILE"
done
grep -qE '^\s*BUILD_CONFIGURATION="Release" BENCH_HOOKS=0 BLOCKING_CHECKS=0 PGO_PROFILE=0 BUILD_CONFIG_NAME="release"' "$reload" \
  || fail "reload.sh --release does not clear PGO_PROFILE"
grep -qF 'SWIFT_OTHER_FLAGS+=" -DCMUX_PGO_PROFILE -profile-generate"' "$reload" || fail "reload.sh profile adds no Swift PGO flags"
grep -qF "XCODEBUILD_ARGS+=('OTHER_LDFLAGS=\$(inherited) -fprofile-instr-generate')" "$reload" \
  || fail "reload.sh profile does not link the profile runtime"
# The profile arm is the one place reload.sh sets OTHER_LDFLAGS, so no other config links the profile runtime.
[[ "$(grep -c 'OTHER_LDFLAGS=' "$reload")" -eq 1 ]] || fail "reload.sh sets OTHER_LDFLAGS outside the profile arm"

# --- build-profile.sh with stubs ---------------------------------------------------------------------------
mkdir -p "$work/bin"
cat >"$work/bin/reload" <<'SH'
#!/usr/bin/env bash
# Records its arguments and stages the bundle STUB_CONFIG / STUB_SECTION describe.
printf '%s\n' "$@" >"$STUB_LOG"
derived="" tag=""
while [[ $# -gt 0 ]]; do
  case "$1" in --derived-data) derived="$2"; shift 2 ;; --tag) tag="$2"; shift 2 ;; *) shift ;; esac
done
app="$derived/Build/Products/Release/cmux DEV $tag.app"
mkdir -p "$app/Contents/MacOS"
python3 -I -c 'import plistlib, sys; plistlib.dump({"CFBundleExecutable": "cmux DEV", "CMUXBuildConfiguration": sys.argv[2]}, open(sys.argv[1], "wb"))' \
  "$app/Contents/Info.plist" "$STUB_CONFIG"
printf 'MACHO %s DATA' "$STUB_SECTION" >"$app/Contents/MacOS/cmux DEV"
SH
cat >"$work/bin/launcher" <<'SH'
#!/usr/bin/env bash
# Writes the app's profile where LLVM_PROFILE_FILE says (pid 4242) unless STUB_PROFRAW is empty.
[[ -n "$STUB_PROFRAW" ]] && printf '%s' "$STUB_PROFRAW" >"${LLVM_PROFILE_FILE//%p/4242}"
echo "pid=4242"
exit "${STUB_LAUNCH_STATUS:-0}"
SH
cat >"$work/bin/profdata" <<'SH'
#!/usr/bin/env bash
[[ "$1" == show && -s "$2" ]] || exit 1
printf 'Instrumentation level: Front-end\nTotal functions: %s\nMaximum function count: %s\n' "$STUB_FUNCTIONS" "$STUB_MAX"
SH
chmod +x "$work/bin/"*

run() {
  # run EXPECTED_STATUS NAME [ARGS...]: runs build-profile.sh with the stubs and the current STUB_* values.
  local expected="$1" name="$2"; shift 2
  local status=0
  rm -rf "$work/derived" "$work/out"
  CMUX_DERIVED_DATA="$work/derived" CMUX_PGO_RELOAD="$work/bin/reload" CMUX_PGO_LAUNCHER="$work/bin/launcher" \
    CMUX_PGO_LLVM_PROFDATA="$work/bin/profdata" STUB_LOG="$work/reload.args" \
    bash "$script" "$@" >"$work/stdout" 2>"$work/stderr" || status=$?
  if [[ "$status" -ne "$expected" ]]; then
    fail "$name: exit $status, expected $expected"
    sed 's/^/    /' "$work/stdout" "$work/stderr" >&2
  fi
}

export STUB_CONFIG=profile STUB_SECTION=__llvm_prf_cnts STUB_PROFRAW=raw STUB_FUNCTIONS=1200 STUB_MAX=37 STUB_LAUNCH_STATUS=0

run 0 "ok" --tag pgo-t --out "$work/out" -- --swift-frontend-workaround
grep -qF 'build-profile: ok:' "$work/stdout" || fail "ok: no ok line"
[[ -s "$work/out/cmux-next-4242.profraw" ]] || fail "ok: the profile is not under --out"
expected_args="--tag
pgo-t
--config
profile
--build-only
--derived-data
$work/derived
--swift-frontend-workaround"
[[ "$(cat "$work/reload.args")" == "$expected_args" ]] || fail "ok: reload.sh got: $(tr '\n' ' ' <"$work/reload.args")"

run 0 "no launch" --tag pgo-t --no-launch
[[ ! -e "$work/out" ]] || fail "no launch: wrote an out dir"

STUB_PROFRAW="" run 1 "no profraw" --tag pgo-t --out "$work/out"
grep -qF 'wrote no profile' "$work/stderr" || fail "no profraw: wrong reason"

STUB_MAX=0 run 1 "zero counts" --tag pgo-t --out "$work/out"
grep -qF 'has no counts' "$work/stderr" || fail "zero counts: wrong reason"

STUB_LAUNCH_STATUS=3 run 1 "launch failed" --tag pgo-t --out "$work/out"
grep -qF 'the launch of pid 4242 failed' "$work/stderr" || fail "launch failed: wrong reason"

STUB_CONFIG=bench run 1 "bench bundle" --tag pgo-t --out "$work/out"
grep -qF "built with --config 'bench'" "$work/stderr" || fail "bench bundle: wrong reason"

STUB_SECTION=__text run 1 "uninstrumented" --tag pgo-t --out "$work/out"
grep -qF 'no __llvm_prf_cnts section' "$work/stderr" || fail "uninstrumented: wrong reason"

run 2 "bad tag" --tag "Pgo T"
run 2 "config after --" --tag pgo-t -- --config bench
run 2 "bad timeout" --tag pgo-t --timeout 0

if (( failures )); then
  echo "pgo-build-profile.test.sh: $failures failure(s)" >&2
  exit 1
fi
echo "pgo-build-profile.test.sh: ok"
