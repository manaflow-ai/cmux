#!/usr/bin/env bash
# The argument checks of scripts/measure/swift-test-bench.sh: a bad PACKAGE,
# FILTER, source=, restore_from= or restore= is refused before anything runs, and good arguments
# reach the fleet-only guard (exit 2 with its message, since no step key is set).
# Builds nothing. Run: bash scripts/measure/tests/swift-test-bench-args.test.sh
set -euo pipefail
script="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/swift-test-bench.sh"
sha=d6623d8cb536956dd96c2d7dbdf84c9d5ac7ac89
fail=0

# expect WANT ARGS...: WANT is "guard" (arguments accepted) or "refused".
expect() {
  local want=$1 out status
  shift
  set +e
  out="$(env -u CMUX_CI_STEP_KEY -u GITHUB_ACTIONS bash "$script" "$@" 2>&1)"
  status=$?
  set -e
  local got=refused
  [[ "$out" == *"runs only on the build fleet"* ]] && got=guard
  if [[ $status -ne 2 || "$got" != "$want" ]]; then
    echo "FAIL: want $want, got $got (exit $status): $*"; echo "$out" | sed 's/^/    /'; fail=1
  fi
}

K=cmux-next-ios/CmuxMobileKit
expect guard $K TerminalInputThroughputTests/keystrokeThroughputAt500msRTT
expect guard Packages/macOS/CmuxNext CmuxNextAppTests.SomeSuite
expect guard $K Suite/test source=$sha
expect guard $K Suite/test restore_from=$sha \
  restore=Sources/CmuxMobileLive/DaemonTerminalSession.swift,Tests/CmuxMobileLiveTests/DaemonTerminalSessionTests.swift
expect guard $K Suite/test source=$sha restore_from=$sha restore=Sources/A.swift

expect refused
expect refused $K
expect refused /tmp/pkg Suite
expect refused ../$K Suite
expect refused cmux-next-ios/../Packages/x Suite
expect refused cmux-next-ios//x Suite
expect refused vendor/stack-auth-swift-sdk-prerelease Suite
expect refused $K '--filter'
expect refused $K 'Suite;rm'
expect refused $K 'Suite test'
expect refused $K Suite.
expect refused $K Suite extra
expect refused $K Suite --restore-from
expect refused $K Suite source=d6623d8
expect refused $K Suite source=$sha source=$sha
expect refused $K Suite source=
expect refused $K Suite source= source=
expect refused $K Suite restore_from= restore=
expect refused $K Suite restore_from=$sha
expect refused $K Suite restore=Sources/A.swift
expect refused $K Suite restore_from=$sha restore=
expect refused $K Suite restore_from=$sha restore=Sources/A.swift,,B.swift
expect refused $K Suite restore_from=$sha restore=../Package.swift
expect refused $K Suite restore_from=$sha restore=Sources/../../x
expect refused $K Suite restore_from=$sha restore=/etc/passwd
expect refused $K Suite restore_from=$sha restore=Sources/
expect refused $K Suite restore_from=$sha restore=$'Sources/A.swift\n../evil'
expect refused $K $'Suite\nOther'

# config= and enable= (a Release benchmark such as MainTurnMeterBench, 2026-10-29).
M=Packages/macOS/CmuxNext
expect guard $M MainTurnMeterBench config=release
expect guard $M MainTurnMeterBench config=debug
expect guard $M MainTurnMeterBench enable=CMUX_MAIN_TURN_BENCH
expect guard $M MainTurnMeterBench config=release enable=CMUX_MAIN_TURN_BENCH source=$sha
expect refused $M Suite config=fast
expect refused $M Suite config=Release
expect refused $M Suite config=
expect refused $M Suite config=release config=release
expect refused $M Suite enable=CMUX_CI_TOKEN
expect refused $M Suite enable=MAIN_TURN_BENCH
expect refused $M Suite enable=cmux_main_turn_bench
expect refused $M Suite enable=CMUX_MAIN_TURN_BENCH=0
expect refused $M Suite enable=CMUX__BENCH
expect refused $M Suite enable=CMUX_A_BENCH enable=CMUX_B_BENCH

[[ $fail -eq 0 ]] && echo "swift-test-bench args: ok"
exit $fail
