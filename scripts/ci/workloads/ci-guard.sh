#!/usr/bin/env bash
set -uo pipefail

root="$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)"
stage() {
  python3 "$root/scripts/ci/cmux_workload_profile.py" stage "$1" "$2"
}

cd "$root"
# Every command runs, and each outcome is one "<passed 0|1><TAB><command>" line in
# $CMUX_GUARD_CHECK_RESULTS (run_ci_guards.py's per-check results; a command that
# reports its own checks, such as test_ci_self_hosted_guard.sh and test_ci_change_areas.py,
# adds them there). ci-guards.yml copies the file to its step's results, so
# guards_new_reds.py compares checks: a red the base has in this step no longer
# excuses a different red the change adds to it (#41175 merged two red change-areas
# tests that way: the base replay of this step was red too).
export CMUX_GUARD_CHECK_RESULTS="${CMUX_WORKLOAD_STATE_ROOT:-${TMPDIR:-/tmp}}/guard-checks.tsv"
failed=0
check() { if "$@"; then passed=1; else passed=0; failed=1; fi; printf '%s\t%s\n' "$passed" "$*" >> "$CMUX_GUARD_CHECK_RESULTS"; }
stage start setup
stage end setup

stage start test
check ./tests/test_ci_self_hosted_guard.sh
check python3 tests/test_ci_change_areas.py
check python3 tests/test_ci_linux_guard_routing.py
check python3 tests/test_ci_merge_queue_required_checks.py
check python3 tests/test_ci_reusable_workflow_permissions.py
check ./tests/test_ci_pbxproj_app_sources_wiring.sh
check python3 tests/test_strings_output_encoding.py
check python3 tests/test_app_symbol_map.py
check python3 tests/test_cmux_tui_release_profile.py
check python3 tests/test_dead_code_stripping.py
check python3 tests/test_computer_use_helper_icon_depth.py
[[ "$failed" -eq 0 ]] || exit 1
stage end test
