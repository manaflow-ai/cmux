#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
expected_arch="${CMUX_EXPECTED_SIMULATOR_ARCH:-$(uname -m)}"

case "$expected_arch" in
  arm64|x86_64) ;;
  *)
    echo "CMUX_EXPECTED_SIMULATOR_ARCH must be arm64 or x86_64" >&2
    exit 2
    ;;
esac

host_arch="$(uname -m)"
if [ "$host_arch" != "$expected_arch" ]; then
  echo "Expected host architecture $expected_arch, got $host_arch" >&2
  exit 1
fi

has_ios_runtime() {
  python3 - <<'PY'
import json
import subprocess

data = json.loads(
    subprocess.check_output(["xcrun", "simctl", "list", "runtimes", "available", "-j"])
)
available = any(
    runtime.get("isAvailable", True)
    and (
        runtime.get("platform") == "iOS"
        or str(runtime.get("identifier", "")).startswith(
            "com.apple.CoreSimulator.SimRuntime.iOS"
        )
    )
    for runtime in data.get("runtimes", [])
)
raise SystemExit(0 if available else 1)
PY
}

if ! has_ios_runtime; then
  echo "No available iOS Simulator runtime; downloading the iOS platform."
  xcodebuild -downloadPlatform iOS
  has_ios_runtime
fi

simulator_id="$({
  CMUX_SIMULATOR_NAME="cmux Iroh ${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}-$$" \
    python3 - <<'PY'
import json
import os
import re
import subprocess
import sys


def simctl_json(*args: str, available: bool = False) -> dict:
    command = ["xcrun", "simctl", "list", *args]
    if available:
        command.append("available")
    command.append("-j")
    return json.loads(subprocess.check_output(command))


def version_key(runtime: dict) -> tuple[int, ...]:
    return tuple(int(part) for part in re.findall(r"\d+", str(runtime.get("version", ""))))


runtimes = sorted(
    (
        runtime
        for runtime in simctl_json("runtimes", available=True).get("runtimes", [])
        if runtime.get("isAvailable", True)
        and (
            runtime.get("platform") == "iOS"
            or str(runtime.get("identifier", "")).startswith(
                "com.apple.CoreSimulator.SimRuntime.iOS"
            )
        )
    ),
    key=version_key,
    reverse=True,
)
all_device_types = [
    device_type
    for device_type in simctl_json("devicetypes").get("devicetypes", [])
    if str(device_type.get("name", "")).startswith("iPhone")
]
preferred_names = (
    "iPhone 16 Pro",
    "iPhone 16",
    "iPhone 15 Pro",
    "iPhone 15",
    "iPhone 14 Pro",
    "iPhone 14",
)
preference = {name: index for index, name in enumerate(preferred_names)}


def ordered_device_types(runtime: dict) -> list[dict]:
    supported = [
        device_type
        for device_type in runtime.get("supportedDeviceTypes", all_device_types)
        if str(device_type.get("name", "")).startswith("iPhone")
    ]
    return sorted(
        supported,
        key=lambda device_type: (
            preference.get(str(device_type.get("name", "")), len(preference)),
            str(device_type.get("name", "")),
        ),
    )

name = os.environ["CMUX_SIMULATOR_NAME"]
attempts: list[str] = []
for runtime in runtimes:
    for device_type in ordered_device_types(runtime):
        result = subprocess.run(
            [
                "xcrun",
                "simctl",
                "create",
                name,
                str(device_type["identifier"]),
                str(runtime["identifier"]),
            ],
            text=True,
            capture_output=True,
        )
        if result.returncode == 0:
            print(result.stdout.strip())
            print(
                f"Created {name} with {device_type['name']} on {runtime['identifier']}",
                file=sys.stderr,
            )
            raise SystemExit(0)
        attempts.append(
            f"{device_type.get('name')} on {runtime.get('identifier')}: "
            f"{result.stderr.strip()}"
        )

print("Could not create an iOS Simulator from any available runtime/device pair", file=sys.stderr)
for attempt in attempts[-10:]:
    print(attempt, file=sys.stderr)
raise SystemExit(1)
PY
})"

cleanup() {
  xcrun simctl shutdown "$simulator_id" >/dev/null 2>&1 || true
  xcrun simctl delete "$simulator_id" >/dev/null 2>&1 || true
}
trap cleanup EXIT

xcrun simctl boot "$simulator_id"
python3 "$repo_root/scripts/ci/run_with_timeout.py" \
  --timeout-seconds 180 \
  -- xcrun simctl bootstatus "$simulator_id" -b

test_root="${RUNNER_TEMP:-/tmp}/cmux-iroh-ios-simulator-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}"
rm -rf "$test_root"
mkdir -p "$test_root"

run_package_tests() {
  local package_path="$1"
  local scheme="$2"
  local test_target="$3"
  local derived_data="$test_root/$scheme-derived"
  local result_bundle="$test_root/$scheme.xcresult"

  (
    cd "$repo_root/$package_path"
    xcodebuild \
      -scheme "$scheme" \
      -destination "platform=iOS Simulator,id=$simulator_id" \
      -derivedDataPath "$derived_data" \
      -resultBundlePath "$result_bundle" \
      ONLY_ACTIVE_ARCH=YES \
      ARCHS="$expected_arch" \
      -only-testing:"$test_target" \
      test
  )

  python3 - "$result_bundle" "$expected_arch" "$scheme" <<'PY'
import json
import subprocess
import sys

result_bundle, expected_arch, scheme = sys.argv[1:]
summary = json.loads(
    subprocess.check_output(
        [
            "xcrun",
            "xcresulttool",
            "get",
            "test-results",
            "summary",
            "--path",
            result_bundle,
            "--compact",
        ]
    )
)
if summary.get("result") != "Passed":
    raise SystemExit(f"{scheme} result was {summary.get('result')}, expected Passed")
if int(summary.get("totalTestCount", 0)) <= 0:
    raise SystemExit(f"{scheme} recorded zero tests")
if int(summary.get("passedTests", 0)) <= 0 or int(summary.get("failedTests", 0)) != 0:
    raise SystemExit(
        f"{scheme} passed={summary.get('passedTests')} failed={summary.get('failedTests')}"
    )

devices = [
    configuration.get("device", {})
    for configuration in summary.get("devicesAndConfigurations", [])
]
matching = [
    device
    for device in devices
    if device.get("platform") == "iOS Simulator"
    and device.get("architecture") == expected_arch
]
if not matching:
    observed = [
        f"{device.get('platform')}:{device.get('architecture')}" for device in devices
    ]
    raise SystemExit(
        f"{scheme} did not execute on an {expected_arch} iOS Simulator; observed {observed}"
    )

print(
    f"{scheme}: {summary['passedTests']} passed, "
    f"{summary.get('skippedTests', 0)} skipped on {expected_arch} iOS Simulator"
)
PY

  local test_binary="$derived_data/Build/Products/Debug-iphonesimulator/$test_target.xctest/$test_target"
  if [ ! -f "$test_binary" ]; then
    echo "Missing built test binary: $test_binary" >&2
    exit 1
  fi
  local binary_archs
  binary_archs="$(lipo -archs "$test_binary")"
  case " $binary_archs " in
    *" $expected_arch "*) ;;
    *)
      echo "$test_target was built for $binary_archs, expected $expected_arch" >&2
      exit 1
      ;;
  esac
}

run_package_tests \
  Packages/Shared/CMUXMobileCore \
  CMUXMobileCore \
  CMUXMobileCoreTests
run_package_tests \
  Packages/Shared/CmuxIrohTransport \
  CmuxIrohTransport \
  CmuxIrohTransportTests
