#!/usr/bin/env bash
set -euo pipefail

run_unit_tests_once() {
  if [[ -n "${CMUX_UNIT_TEST_FAKE_COMMAND:-}" ]]; then
    bash -c "$CMUX_UNIT_TEST_FAKE_COMMAND"
    return
  fi

  local source_packages_dir="${SOURCE_PACKAGES_DIR:-$PWD/.ci-source-packages}"
  local derived_data_path="${CMUX_DERIVED_DATA_PATH:-$PWD/.ci-derived-data/cmux-unit}"
  local command=(
    scripts/ci/xcodebuild_noninteractive.py
    xcodebuild -project cmux.xcodeproj -scheme cmux-unit -configuration Debug
    -derivedDataPath "$derived_data_path"
    -clonedSourcePackagesDirPath "$source_packages_dir"
    -disableAutomaticPackageResolution
    -destination "platform=macOS"
  )
  command+=(test)

  local child_pid_file
  child_pid_file="$(mktemp)"
  XCODEBUILD_NONINTERACTIVE_CHILD_PID_FILE="$child_pid_file" "${command[@]}" 2>&1 &
  local xcodebuild_pid=$!
  local timeout_seconds="${CMUX_UNIT_TEST_TIMEOUT_SECONDS:-1800}"
  local deadline=$((SECONDS + timeout_seconds))
  while kill -0 "$xcodebuild_pid" 2>/dev/null; do
    if [[ "$SECONDS" -ge "$deadline" ]]; then
      echo "xcodebuild unit test timeout after ${timeout_seconds}s; terminating"
      terminate_unit_test_processes "$xcodebuild_pid" "$child_pid_file" TERM
      sleep 5
      terminate_unit_test_processes "$xcodebuild_pid" "$child_pid_file" KILL
      wait "$xcodebuild_pid" 2>/dev/null || true
      rm -f "$child_pid_file"
      return 124
    fi
    sleep 5
  done
  wait "$xcodebuild_pid"
  local status=$?
  rm -f "$child_pid_file"
  return "$status"
}

terminate_unit_test_processes() {
  local wrapper_pid="$1"
  local child_pid_file="$2"
  local signal="$3"
  if [[ -s "$child_pid_file" ]]; then
    local child_pid
    child_pid="$(cat "$child_pid_file")"
    if [[ "$child_pid" =~ ^[0-9]+$ ]]; then
      kill "-$signal" "-$child_pid" 2>/dev/null || kill "-$signal" "$child_pid" 2>/dev/null || true
    fi
  fi
  kill "-$signal" "$wrapper_pid" 2>/dev/null || true
}

run_with_output_capture() {
  local output_file="$1"
  set +e
  run_unit_tests_once | tee "$output_file"
  local exit_code=${PIPESTATUS[0]}
  set -e
  return "$exit_code"
}

main() {
  local output_file="${CMUX_UNIT_TEST_OUTPUT_FILE:-/tmp/test-output.txt}"
  local exit_code=0
  local output=""

  run_with_output_capture "$output_file" || exit_code=$?
  output="$(cat "$output_file")"

  if [[ "$exit_code" -ne 0 ]] && grep -q "Could not resolve package dependencies" <<<"$output"; then
    echo "SwiftPM package resolution failed, clearing caches and retrying once"
    rm -rf ~/Library/Caches/org.swift.swiftpm
    mkdir -p ~/Library/Caches/org.swift.swiftpm
    local derived_data_path="${CMUX_DERIVED_DATA_PATH:-$PWD/.ci-derived-data/cmux-unit}"
    rm -rf "$derived_data_path"
    mkdir -p "$derived_data_path"
    exit_code=0
    run_with_output_capture "$output_file" || exit_code=$?
  fi

  if [[ "$exit_code" -ne 0 ]]; then
    echo "Unit tests failed"
    exit "$exit_code"
  fi
}

main "$@"
