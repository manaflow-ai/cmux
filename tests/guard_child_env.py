"""The environment for a guard run a test spawns.

The guard runner (scripts/ci/run_ci_guards.py) points CMUX_GUARD_CHECK_RESULTS,
GITHUB_STEP_SUMMARY, GITHUB_OUTPUT and GITHUB_ENV at the running step's own
files. A test that spawns a guard writer (scripts/ci/run_ci_guard_payload.sh,
scripts/ci/workloads/ci-guard.sh, tests/test_ci_self_hosted_guard.sh,
tests/test_ci_change_areas.py, the guard runner) must not inherit them: its
fixtures' deliberate reds would land in the real step's results (#41333: the
payload fixture's `./a.sh` was charged to the change). `guard_child_env` drops
every CMUX_GUARD_* variable and points the three GITHUB_* files into the test's
own temporary folder; a test that wants a results file passes it in `overrides`.
tests/test_ci_run_guards.py ATestSpawnedGuardRunLeavesTheCallersFilesAlone
checks the caller's four files stay byte-identical.

Load this module by path, as tests/git_fixture_env.py is.
"""
from __future__ import annotations

import os
from pathlib import Path

STEP_FILES = ("GITHUB_STEP_SUMMARY", "GITHUB_OUTPUT", "GITHUB_ENV")


def guard_child_env(temp_dir: str | os.PathLike[str], **overrides: str) -> dict[str, str]:
    """os.environ without CMUX_GUARD_*, with the step files in `temp_dir`, then `overrides`."""
    folder = Path(temp_dir)
    env = {key: value for key, value in os.environ.items()
           if not key.startswith("CMUX_GUARD_") and key not in STEP_FILES}
    for name in STEP_FILES:
        env[name] = str(folder / f"child-{name.lower()}")
    env.update(overrides)
    return env
