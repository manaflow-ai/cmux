#!/usr/bin/env bash
set -euo pipefail

root="$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)"
stage() {
  python3 "$root/scripts/ci/cmux_workload_profile.py" stage "$1" "$2"
}

cd "$root"
stage start setup
stage end setup

stage start test
./tests/test_ci_self_hosted_guard.sh
python3 tests/test_ci_change_areas.py
python3 tests/test_ci_linux_guard_routing.py
python3 tests/test_ci_merge_queue_required_checks.py
python3 tests/test_ci_reusable_workflow_permissions.py
./tests/test_ci_pbxproj_app_sources_wiring.sh
python3 tests/test_strings_output_encoding.py
python3 tests/test_app_symbol_map.py
python3 tests/test_cmux_tui_release_profile.py
python3 tests/test_dead_code_stripping.py
python3 tests/test_computer_use_helper_icon_depth.py
stage end test
