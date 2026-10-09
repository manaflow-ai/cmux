#!/usr/bin/env bash
# Runs the keyboard UI tests (ios/cmuxUITests, plans/cmux-next/ios-keyboard.md)
# on an isolated simulator ($NX_SIM_UDID, e.g. from `nx-remote --sim`), one
# xcodebuild run per test, each with its own screen recording. Output in
# $NX_ARTIFACTS (or ./artifacts/keyboard-uitests): <Class.test>.mp4, <Class.test>.log,
# summary.txt (pass/fail and the KBD-AUDIT measurement lines).
#
#   KBD_TESTS="Class/testA Class/testB"   tests to run (default: every test in KBD_CLASS);
#                                         a bare `Class` runs every test in that class
#   KBD_CLASS=KeyboardAuditUITests        class whose tests run by default
#   KBD_RECORD=0                          no screen recordings
#   KBD_RESULT_BUNDLES=1                  also keep <test>.xcresult per test
# .github/workflows/ios-next-uitests.yml runs the Next*UITests classes through
# this script on a fresh CI simulator.
#
# Never targets a shared or user-visible simulator: it requires an explicit UDID.
set -uo pipefail
udid="${NX_SIM_UDID:?set NX_SIM_UDID to an isolated simulator}"
out="${NX_ARTIFACTS:-$PWD/artifacts/keyboard-uitests}"
derived="${KBD_DERIVED:-${NX_DERIVED_DATA:-/tmp}/cmux-ios-uitests}"
class="${KBD_CLASS:-KeyboardAuditUITests}"
mkdir -p "$out"
common=(-workspace ios/cmux.xcworkspace -scheme cmux-ios -configuration Debug
  -destination "id=$udid" -derivedDataPath "$derived" CODE_SIGNING_ALLOWED=NO)

# Keep compiling the other modules after an error, so one build reports
# every module's errors rather than only the first failing one's.
if ! xcodebuild "${common[@]}" -IDEBuildingContinueBuildingAfterErrors=YES build-for-testing >"$out/build.log" 2>&1; then
  grep -E "error:" "$out/build.log" | sort -u | head -200
  exit 1
fi

class_tests() {
  grep -oE 'func (test[A-Za-z0-9_]+)\(' "ios/cmuxUITests/$1.swift" | sed -E "s/func (test[A-Za-z0-9_]+)\(/$1\/\1/" | tr '\n' ' '
}

tests=""
for entry in ${KBD_TESTS:-$class}; do
  if [[ "$entry" == */* ]]; then
    tests+="$entry "
  elif [[ -f "ios/cmuxUITests/$entry.swift" ]]; then
    tests+="$(class_tests "$entry")"
  else
    echo "no UI test class ios/cmuxUITests/$entry.swift" >&2
    exit 2
  fi
done

if [[ -z "${tests// /}" ]]; then
  echo "no UI tests selected" >&2
  exit 2
fi

summary="$out/summary.txt"
: >"$summary"
status=0
for test in $tests; do
  name="${test//\//.}"
  xcrun simctl ui "$udid" appearance light >/dev/null 2>&1 || true
  rec=""
  if [[ "${KBD_RECORD:-1}" != 0 ]]; then
    xcrun simctl io "$udid" recordVideo --codec=h264 --force "$out/$name.mp4" >/dev/null 2>&1 &
    rec=$!
  fi
  bundle=()
  if [[ "${KBD_RESULT_BUNDLES:-0}" == 1 ]]; then
    rm -rf "$out/$name.xcresult"
    bundle=(-resultBundlePath "$out/$name.xcresult")
  fi
  xcodebuild "${common[@]}" test-without-building -only-testing:"cmuxUITests/$test" ${bundle[@]+"${bundle[@]}"} >"$out/$name.log" 2>&1
  code=$?
  if [[ -n "$rec" ]]; then
    kill -INT "$rec" 2>/dev/null
    wait "$rec" 2>/dev/null
  fi
  [[ $code -eq 0 ]] && result=PASS || { result=FAIL; status=1; }
  {
    echo "== $name: $result"
    grep -E "KBD-AUDIT" "$out/$name.log" | sed -E 's/^.*KBD-AUDIT/  KBD-AUDIT/' | sort -u
    grep -E "error: .*XCTAssert|: error: " "$out/$name.log" | sed -E 's/^.*error: /  error: /' | sort -u | head -8
  } >>"$summary"
done
cat "$summary"
exit "$status"
