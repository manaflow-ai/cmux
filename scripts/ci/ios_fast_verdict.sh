#!/usr/bin/env bash
# The fast iOS verdict (pr-pipeline.yml's `ios-fast` job): build the iOS target(s) the diff changed and run only
# their tests, on the warm owned mini ios-fast-runner picked, before the full matrix reports. The plan is
# scripts/ci/ios_fast_verdict.py's (env PLAN, JSON): `tests` (kit test targets, run with -only-testing on one iPhone
# simulator), `build` (the kit's test bundle, built for testing, no run), `app` (xcodegen and the app for the
# simulator, no UI tests).
#
# Warm state, kept between runs on an owned Mac (the job checks out with clean: false):
#   - DerivedData and the resolved packages: the runner's per-stream slot (CMUX_DERIVED_DATA_SLOT, the glaeda disk
#     registry), the path the ios-kit step builds the kit in; its SourcePackages are the resolved SwiftPM checkouts,
#     so a warm slot skips the package update (-skipPackageUpdates) and reads only Package.resolved's versions.
#   - CmuxMobileLinkFFI.xcframework (gitignored): reused when its stamp names this tree's FFI key and the framework
#     was not rewritten since; else scripts/ci/ios_link_ffi.sh (the build fleet's copy, or this Mac builds it).
#   - xcodegen: the pinned release cmux-next-ios-sim.sh uses, checksum-verified, in the runner's tool cache.
#
#   PLAN='{"tests":["CmuxMobileShellTests"],"build":false,"app":false}' bash scripts/ci/ios_fast_verdict.sh
set -uo pipefail

tmp="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
summary="${GITHUB_STEP_SUMMARY:-/dev/null}"
plan="${PLAN:?PLAN is the plan JSON of scripts/ci/ios_fast_verdict.py}"
field() { python3 -I -c 'import json, sys; v = json.loads(sys.argv[1]).get(sys.argv[2]); print(" ".join(v) if isinstance(v, list) else ("1" if v else ""))' "$plan" "$1"; }
tests="$(field tests)"
build="$(field build)"
app="$(field app)"
started=$SECONDS
phase() { printf -- '- %s: %s s\n' "$1" "$2" | tee -a "$summary"; }
printf '### iOS fast verdict\n\nplan: tests [%s], kit build %s, app build %s\n\n' "$tests" "${build:-no}" "${app:-no}" >> "$summary"

# --- CmuxMobileLinkFFI.xcframework -------------------------------------------------------------------------------
t=$SECONDS
xcf=cmux-next-ios/CmuxMobileKit/Frameworks/CmuxMobileLinkFFI.xcframework
stamp=cmux-next-ios/CmuxMobileKit/Frameworks/.ios-fast-verdict-ffi
mtime() { python3 -I -c 'import os, sys; print(int(os.stat(sys.argv[1]).st_mtime))' "$1" 2>/dev/null; }
key="$(python3 -I scripts/ci/ios_link_ffi_key.py 2>/dev/null)" || key=""
if [[ -n "$key" && -f "$xcf/Info.plist" && -f "$stamp" && "$(cat "$stamp")" == "$key $(mtime "$xcf/Info.plist")" ]]; then
  echo "CmuxMobileLinkFFI.xcframework: this workspace's copy, same FFI inputs ($key)"
  ffi_how="reused"
else
  rm -f "$stamp"
  (cd cmux-next-ios/rust && rustup toolchain install "$(sed -n 's/^channel = "\(.*\)"$/\1/p' rust-toolchain.toml)" --profile minimal) || exit 1
  bash scripts/ci/ios_link_ffi.sh 8 || exit 1
  [[ -n "$key" && -f "$xcf/Info.plist" ]] && printf '%s %s\n' "$key" "$(mtime "$xcf/Info.plist")" > "$stamp"
  ffi_how="fetched or built"
fi
phase "FFI ($ffi_how)" $((SECONDS - t))

status=0
# A hosted Mac has no slot: CMUX_IOS_FAST_DD_ROOT (pr-pipeline.yml, restored from ios-fast-verdict-seed.yml's warm
# DerivedData) holds the kit's (kit/) and the app's (app/) DerivedData; unset, both start empty under $tmp.
dd_root="${CMUX_IOS_FAST_DD_ROOT:-}"
if [[ -n "${CMUX_DERIVED_DATA_SLOT:-}" ]]; then
  dd="$CMUX_DERIVED_DATA_SLOT"
  app_dd="$CMUX_DERIVED_DATA_SLOT/dd"
elif [[ -n "$dd_root" ]]; then
  dd="$dd_root/kit"
  app_dd="$dd_root/app"
else
  dd="$tmp/dd-ios-sim"
  app_dd="$tmp/dd"
fi
packages=()
# A warm slot has the resolved checkouts: no network round trip for the package graph.
[[ -d "$dd/SourcePackages/checkouts" ]] && packages=(-skipPackageUpdates)
packages+=(-onlyUsePackageVersionsFromResolvedFile)

# --- the kit: the changed targets' tests, or its test bundle built ------------------------------------------------
if [[ -n "$tests" || -n "$build" ]]; then
  t=$SECONDS
  udid="$(python3 -I scripts/ci/ios_sim_udid.py)" || exit 1
  bundle="$tmp/ios-fast.xcresult"
  rm -rf "$bundle"
  common=(-scheme CmuxMobileKit-Package -destination "id=$udid,arch=arm64" -enableCodeCoverage NO
    -derivedDataPath "$dd" "${packages[@]}" CODE_SIGNING_ALLOWED=NO -quiet)
  if [[ -n "$tests" ]]; then
    only=()
    for target in $tests; do only+=("-only-testing:$target"); done
    (cd cmux-next-ios/CmuxMobileKit && xcodebuild test "${common[@]}" "${only[@]}" -resultBundlePath "$bundle") || status=1
    # -quiet drops Swift Testing's output: the counts and every failure from the result bundle.
    xcrun xcresulttool get test-results tests --path "$bundle" --compact 2>/dev/null | python3 -I -c '
import json, sys
counts = {}
def walk(node, path):
    if node.get("nodeType") == "Test Case":
        counts[node.get("result")] = counts.get(node.get("result"), 0) + 1
        if node.get("result") == "Failed":
            print("FAILED:", " / ".join(path))
    for child in node.get("children", []):
        if child.get("nodeType") == "Failure Message":
            print("   ", child.get("name"))
        else:
            walk(child, path + [child.get("name", "")])
for root in json.load(sys.stdin).get("testNodes", []):
    walk(root, [root.get("name", "")])
print("iOS simulator test cases:", ", ".join(f"{k} {v}" for k, v in sorted(counts.items())))
' | tee -a "$summary" || echo "::warning::could not read the result bundle"
    phase "kit tests ($tests)" $((SECONDS - t))
  else
    (cd cmux-next-ios/CmuxMobileKit && xcodebuild build-for-testing "${common[@]}") || status=1
    phase "kit build for testing" $((SECONDS - t))
  fi
fi

# --- the app: xcodegen, then the simulator build (cmux-next-ios-sim.sh's build command, no install or launch) -------
if [[ -n "$app" ]]; then
  t=$SECONDS
  xcodegen_version=2.46.0
  xcodegen_sha256=4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806
  tools="${RUNNER_TOOL_CACHE:-$tmp}/xcodegen-$xcodegen_version"
  xcodegen="$tools/xcodegen/bin/xcodegen"
  if [[ ! -x "$xcodegen" ]]; then
    part="$(mktemp -d "$tmp/xcodegen.XXXXXX")"
    curl -fsSL --retry 3 --retry-delay 2 -o "$part/xcodegen.zip" \
      "https://github.com/yonaskolb/XcodeGen/releases/download/$xcodegen_version/xcodegen.zip" ||
      { echo "::error::could not download xcodegen $xcodegen_version"; exit 1; }
    got="$(shasum -a 256 "$part/xcodegen.zip" | awk '{ print $1 }')"
    [[ "$got" == "$xcodegen_sha256" ]] || { echo "::error::xcodegen zip sha256 $got, expected $xcodegen_sha256"; exit 1; }
    unzip -q "$part/xcodegen.zip" -d "$part" && mkdir -p "$(dirname "$tools")" && rm -rf "$tools" && mv "$part" "$tools"
  fi
  (cd cmux-next-ios && "$xcodegen" generate -q) || { echo "::error::xcodegen failed"; exit 1; }
  xcodebuild -project cmux-next-ios/CmuxMobileApp.xcodeproj -scheme CmuxMobileApp -configuration Demo \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath "$app_dd" "${packages[@]}" \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= ARCHS=arm64 ONLY_ACTIVE_ARCH=YES -quiet \
    'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) DEBUG CMUX_MOBILE_DEMO' build-for-testing || status=1
  # build-for-testing: the scheme's test target CmuxMobileAppUITests compiles too (cmux#55664 broke only it).
  phase "app build-for-testing (CmuxMobileApp + CmuxMobileAppUITests, iOS Simulator)" $((SECONDS - t))
fi

phase "fast verdict total" $((SECONDS - started))
(( status )) && echo "::error title=iOS fast verdict::the changed iOS target failed; the full matrix (ios job, kit and phone cells after merge) still runs"
exit "$status"
