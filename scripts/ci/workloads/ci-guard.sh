#!/usr/bin/env bash
set -euo pipefail

root="$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)"
stage() {
  python3 "$root/scripts/ci/cmux_workload_profile.py" stage "$1" "$2"
}

cd "$root"
stage start setup
python3 scripts/ci/cmux_unit_test_shard.py --validate
stage end setup

stage start test
./tests/test_ci_self_hosted_guard.sh
python3 tests/test_ci_change_areas.py
python3 tests/test_ci_linux_guard_routing.py
python3 tests/test_ci_merge_queue_required_checks.py
python3 tests/test_ci_reusable_workflow_permissions.py
./scripts/lint-pbxproj-test-wiring.sh
stage end test
