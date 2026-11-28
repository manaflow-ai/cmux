#!/usr/bin/env bash
# Runs the keyboard UI tests (ios/cmuxUITests, plans/cmux-next/ios-keyboard.md)
# on an isolated simulator ($NX_SIM_UDID, e.g. from `nx-remote --sim`), one
# xcodebuild run per test, each with its own screen recording. Output in
# $NX_ARTIFACTS (or ./artifacts/keyboard-uitests): <test>.mp4, <test>.log,
# summary.txt (pass/fail and the KBD-AUDIT measurement lines).
#
#   KBD_TESTS="Class/testA Class/testB"   tests to run (default: every test in KBD_CLASS)
#   KBD_CLASS=KeyboardAuditUITests        class whose tests run by default
#   KBD_RECORD=0                          no screen recordings
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

if ! xcodebuild "${common[@]}" build-for-testing >"$out/build.log" 2>&1; then
  grep -E "error:" "$out/build.log" | sort -u | head -40
  exit 1
fi

tests="${KBD_TESTS:-}"
if [[ -z "$tests" ]]; then
  tests="$(grep -oE 'func (test[A-Za-z0-9_]+)\(' "ios/cmuxUITests/$class.swift" | sed -E "s/func (test[A-Za-z0-9_]+)\(/$class\/\1/" | tr '\n' ' ')"
fi

summary="$out/summary.txt"
: >"$summary"
status=0
for test in $tests; do
  name="${test##*/}"
  xcrun simctl ui "$udid" appearance light >/dev/null 2>&1 || true
  rec=""
  if [[ "${KBD_RECORD:-1}" != 0 ]]; then
    xcrun simctl io "$udid" recordVideo --codec=h264 --force "$out/$name.mp4" >/dev/null 2>&1 &
    rec=$!
  fi
  xcodebuild "${common[@]}" test-without-building -only-testing:"cmuxUITests/$test" >"$out/$name.log" 2>&1
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
