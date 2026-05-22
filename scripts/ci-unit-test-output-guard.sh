#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <xcodebuild-exit-code> <test-output-file>" >&2
  exit 2
fi

EXIT_CODE="$1"
OUTPUT_FILE="$2"

if [ ! -f "$OUTPUT_FILE" ]; then
  echo "FAIL: test output file does not exist: $OUTPUT_FILE" >&2
  exit 1
fi

reasons=()

add_reason() {
  local reason="$1"
  local existing
  if [ "${#reasons[@]}" -gt 0 ]; then
    for existing in "${reasons[@]}"; do
      if [ "$existing" = "$reason" ]; then
        return
      fi
    done
  fi
  reasons+=("$reason")
}

if [ "$EXIT_CODE" = "124" ]; then
  add_reason "xcodebuild watchdog timeout"
fi

if grep -Fq "xcodebuild unit test timeout after" "$OUTPUT_FILE"; then
  add_reason "xcodebuild watchdog timeout"
fi

if grep -Fq "** BUILD INTERRUPTED **" "$OUTPUT_FILE"; then
  add_reason "xcodebuild build interruption"
fi

if grep -Eq "Program crashed: Signal|Backtracing from|Press space to interact, D to debug" "$OUTPUT_FILE"; then
  add_reason "Swift crash output"
fi

if [ "${#reasons[@]}" -gt 0 ]; then
  echo "FAIL: CI unit tests hit hard-failure output before XCTest summary parsing:" >&2
  printf '  - %s\n' "${reasons[@]}" >&2
  exit 1
fi
