#!/usr/bin/env bash
# scripts/cmux-next/pgo/build-profile.sh: it builds `reload.sh --config profile`, refuses a
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
# Records its arguments and builds the way scripts/reload.sh does for a Release tag: xcodebuild's product is
# the unstamped cmux.app; a copy is stamped (CMUXBuildConfiguration = STUB_CONFIG, STUB_SECTION in the
# executable) at `.cmux DEV <tag>.reload-$$.app`. With --build-only (or STUB_PUBLISH=0) that copy is deleted
# on exit; otherwise it replaces `cmux DEV <tag>.app` (rm -rf, then mv).
printf '%s\n' "$@" >"$STUB_LOG"
derived="" tag="" build_only=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --derived-data) derived="$2"; shift 2 ;;
    --tag) tag="$2"; shift 2 ;;
    --build-only) build_only=1; shift ;;
    *) shift ;;
  esac
done
products="$derived/Build/Products/Release"
mkdir -p "$products/cmux.app/Contents/MacOS"
python3 -I -c 'import plistlib, sys; plistlib.dump({"CFBundleExecutable": "cmux"}, open(sys.argv[1], "wb"))' \
  "$products/cmux.app/Contents/Info.plist"
printf 'MACHO %s DATA' "$STUB_SECTION" >"$products/cmux.app/Contents/MacOS/cmux"
staging="$products/.cmux DEV $tag.reload-$$.app"
cp -R "$products/cmux.app" "$staging"
python3 -I -c 'import plistlib, sys; plistlib.dump({"CFBundleExecutable": "cmux", "CMUXBuildConfiguration": sys.argv[2]}, open(sys.argv[1], "wb"))' \
  "$staging/Contents/Info.plist" "$STUB_CONFIG"
if [[ "$build_only" -eq 1 || "${STUB_PUBLISH:-1}" == 0 ]]; then
  rm -rf "$staging"
else
  rm -rf "$products/cmux DEV $tag.app"
  mv "$staging" "$products/cmux DEV $tag.app"
fi
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
  if [[ "${SEED_STALE:-0}" == 1 ]]; then
    # An earlier profile build of the same tag, with counters, left at the final path.
    local stale="$work/derived/Build/Products/Release/cmux DEV pgo-t.app"
    mkdir -p "$stale/Contents/MacOS"
    python3 -I -c 'import plistlib, sys; plistlib.dump({"CFBundleExecutable": "cmux", "CMUXBuildConfiguration": "profile"}, open(sys.argv[1], "wb"))' \
      "$stale/Contents/Info.plist"
    printf 'MACHO __llvm_prf_cnts STALE' >"$stale/Contents/MacOS/cmux"
  fi
  CMUX_CI_STEP_KEY=pgo-build-profile-test \
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
--no-global-cli-links
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

# reload.sh deletes a --build-only artifact, so only a published tagged bundle can be checked.
STUB_PUBLISH=0 run 1 "nothing published" --tag pgo-t --out "$work/out"
grep -qF 'no profile build at' "$work/stderr" || fail "nothing published: wrong reason"

# A bundle an earlier build left must not stand in for this build's.
SEED_STALE=1 STUB_PUBLISH=0 run 1 "stale bundle" --tag pgo-t --out "$work/out"
grep -qF 'is the bundle of an earlier build' "$work/stderr" || fail "stale bundle: wrong reason"
SEED_STALE=1 run 0 "stale bundle replaced" --tag pgo-t --out "$work/out"
grep -qF 'STALE' "$work/derived/Build/Products/Release/cmux DEV pgo-t.app/Contents/MacOS/cmux" \
  && fail "stale bundle replaced: checked the earlier bundle"

run 2 "bad tag" --tag "Pgo T"
run 2 "config after --" --tag pgo-t -- --config bench
run 2 "build-only after --" --tag pgo-t -- --build-only
run 2 "bad timeout" --tag pgo-t --timeout 0

if (( failures )); then
  echo "pgo-build-profile.test.sh: $failures failure(s)" >&2
  exit 1
fi
echo "pgo-build-profile.test.sh: ok"
