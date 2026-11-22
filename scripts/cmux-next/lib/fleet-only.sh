# shellcheck shell=bash
# Sourced by the cmux-next check scripts that build (swift test, xcodebuild
# or zig build). They run only as a fleet CI step (`cmux-ci run` sets
# CMUX_CI_STEP_KEY) or on a GitHub runner, never on a developer Mac: agents
# ran them on the laptop on 2026-10-04 and 2026-10-06.
#
# Usage: cmux_next_require_fleet <script name> <what it builds> <CI job name> [fleet command]
cmux_next_require_fleet() {
  local script=$1 builds=$2 ci_job=$3 fleet_command=${4:-}
  if [[ -n "${CMUX_CI_STEP_KEY:-}" || "${GITHUB_ACTIONS:-}" == "true" ]]; then
    return 0
  fi
  {
    printf '%s runs only on the build fleet or a GitHub runner (it runs %s).\n' "$script" "$builds"
    printf 'CI job: %s\n' "$ci_job"
    if [[ -n "$fleet_command" ]]; then
      printf 'Run it there:\n  %s\n' "$fleet_command"
    fi
  } >&2
  exit 2
}
