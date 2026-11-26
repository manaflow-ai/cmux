#!/usr/bin/env bash
# Run a build-for-testing product's XCTest targets on a fleet pool phone (the fleet phone tool) instead of a simulator Mac.
#
# Input: a directory (CMUX_CI_PRODUCTS_DIR, or $1) holding ios-sim-build.tar.gz (Build/Products of
# `xcodebuild build-for-testing`, with its .xctestrun) and ios-sim-xctest-platform.tar.gz (the simulator platform's
# Developer frameworks), as zips from actions/upload-artifact or bare.
# Args: suite=NAME (labels the report), skip=TARGET (repeatable: a test target the run leaves out),
#       only=ID (repeatable: run just these, Target[/Class[/method]]), timeout=SECONDS (default 1800).
# Output: artifacts/ios-sim-linux/result.tgz with junit.xml, summary.txt and the run's log; exit 0 only when every
# test that ran passed.
set -euo pipefail

products="${CMUX_CI_PRODUCTS_DIR:-}"
suite="kit"
timeout=1800
skips=()
onlys=()
for arg in "$@"; do
  case "$arg" in
    suite=*) suite="${arg#suite=}" ;;
    skip=*) skips+=("${arg#skip=}") ;;
    only=*) onlys+=("${arg#only=}") ;;
    timeout=*) timeout="${arg#timeout=}" ;;
    *=*) echo "ios-sim-linux-test: unknown argument $arg" >&2; exit 2 ;;
    *) products="$arg" ;;
  esac
done
if [[ -z "$products" || ! -d "$products" ]]; then
  echo "ios-sim-linux-test: no products directory (CMUX_CI_PRODUCTS_DIR or the first argument)" >&2
  exit 2
fi

out="${CMUX_CI_ARTIFACT_DIR:-$PWD/artifacts/ios-sim-linux}"
work="$(mktemp -d "${RUNNER_TEMP:-/tmp}/ios-sim-linux.XXXXXX")"
mkdir -p "$out" "$work/build" "$work/plat"
log="$out/run.log"
: > "$log"

pack() {
  local rc=$?
  tar -C "$out" --exclude result.tgz -czf "$work/result.tgz" . 2>/dev/null && mv "$work/result.tgz" "$out/result.tgz" || true
  exit "$rc"
}
trap pack EXIT

find_tarball() {
  local name="$1" hit zip
  hit="$(find "$products" -name "$name.tar.gz" -print -quit)"
  if [[ -z "$hit" ]]; then
    zip="$(find "$products" -name "$name.zip" -print -quit)"
    if [[ -n "$zip" ]]; then
      mkdir -p "$work/zip/$name"
      unzip -oq "$zip" -d "$work/zip/$name"
      hit="$(find "$work/zip/$name" -name "$name.tar.gz" -print -quit)"
    fi
  fi
  if [[ -z "$hit" ]]; then
    echo "ios-sim-linux-test: $name.tar.gz not found under $products" >&2
    exit 2
  fi
  echo "$hit"
}

tar -xzf "$(find_tarball ios-sim-build)" -C "$work/build"
tar -xzf "$(find_tarball ios-sim-xctest-platform)" -C "$work/plat"
run="$(find "$work/build" -maxdepth 3 -name '*.xctestrun' | sort | head -1)"
if [[ -z "$run" ]]; then
  echo "ios-sim-linux-test: no .xctestrun in the build products" >&2
  exit 2
fi
# A Swift package's test targets are logic tests whose .xctestrun host is Xcode's xctest agent; agent-sim reads any
# TestHostPath as app-hosted and refuses the target, so drop that host and agent-sim runs them under its own xctest.
logic="${run%.xctestrun}.logic.xctestrun"
python3 -I "$(dirname "${BASH_SOURCE[0]}")/ios_sim_logic_xctestrun.py" "$run" "$logic" 2>&1 | tee -a "$log"
run="$logic"

# The fleet phone tool has -only-testing but no -skip-testing: a skip becomes the list of every other target in the xctestrun.
if [[ ${#onlys[@]} -eq 0 ]]; then
  mapfile -t onlys < <(python3 -I - "$run" "${skips[@]}" <<'PY'
import plistlib, sys
with open(sys.argv[1], "rb") as f:
    plist = plistlib.load(f)
skips = set(sys.argv[2:])
names = []
for config in plist.get("TestConfigurations", []):
    for target in config.get("TestTargets", []):
        names.append(target.get("BlueprintName", ""))
for key, value in plist.items():
    if isinstance(value, dict) and "TestBundlePath" in value:
        names.append(key)
for name in dict.fromkeys(names):
    if name and name not in skips:
        print(name)
PY
)
  if [[ ${#onlys[@]} -eq 0 ]]; then
    echo "ios-sim-linux-test: no test targets left in $run" >&2
    exit 2
  fi
fi

# The runner supplies the phone tool path (FLEET_PHONE_CLI) and its XCTest helper path.
phone="${FLEET_PHONE_CLI:?ios-sim-linux-test: FLEET_PHONE_CLI unset (not a fleet phone runner)}"
command -v "$phone" >/dev/null || { echo "ios-sim-linux-test: FLEET_PHONE_CLI=$phone is not on this host (not a linux-simsdk VM)" >&2; exit 2; }
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

start=$(date +%s)
"$phone" pool up 1 2>&1 | tee -a "$log"
up=$(( $(date +%s) - start ))

only_args=()
for id in "${onlys[@]}"; do only_args+=(--only-testing "$id"); done
# A UI test target (Target ending UITests, e.g. CmuxMobileAppUITests) needs the fleet phone tool's UI runner mode.
ui_args=()
for id in "${onlys[@]}"; do [[ "${id%%/*}" == *UITests ]] && ui_args=(--ui); done
rc=0
# pool up 1 makes the phone pool1 and the fleet phone tool's default device is p, so the run names pool1.
"$phone" -d pool1 test --xctestrun "$run" --platform "$work/plat" "${ui_args[@]}" "${only_args[@]}" \
  --junit "$out/junit.xml" --timeout "$timeout" 2>&1 | tee -a "$log" || rc=${PIPESTATUS[0]}
total=$(( $(date +%s) - start ))

python3 -I - "$out/junit.xml" "$suite" "$rc" "$up" "$total" <<'PY' | tee "$out/summary.txt"
import sys, xml.etree.ElementTree as ET
path, suite, rc, up, total = sys.argv[1:]
counts = {"passed": 0, "failed": 0, "skipped": 0}
failed = []
try:
    root = ET.parse(path).getroot()
    for case in root.iter("testcase"):
        name = f'{case.get("classname", "")}/{case.get("name", "")}'
        if case.find("failure") is not None or case.find("error") is not None:
            counts["failed"] += 1
            failed.append(name)
        elif case.find("skipped") is not None:
            counts["skipped"] += 1
        else:
            counts["passed"] += 1
except (OSError, ET.ParseError) as e:
    print(f"no JUnit: {e}")
print(f"suite {suite}: exit {rc}, pool up {up} s, total {total} s, "
      f'passed {counts["passed"]}, failed {counts["failed"]}, skipped {counts["skipped"]}')
for name in failed:
    print("FAILED:", name)
PY
exit "$rc"
