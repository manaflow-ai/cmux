"""The environment for a guard run a test spawns.

The guard runner (scripts/ci/run_ci_guards.py) points CMUX_GUARD_CHECK_RESULTS,
GITHUB_STEP_SUMMARY, GITHUB_OUTPUT, GITHUB_ENV and GITHUB_PATH at the running
step's own files. A test that spawns a guard writer (scripts/ci/run_ci_guard_payload.sh,
scripts/ci/workloads/ci-guard.sh, tests/test_ci_self_hosted_guard.sh,
tests/test_ci_change_areas.py, the guard runner) must not inherit them: its
fixtures' deliberate reds would land in the real step's results (#41333: the
payload fixture's `./a.sh` was charged to the change), and a GITHUB_PATH line
would change PATH for the guard steps after it.

`guard_child_env` drops every CMUX_GUARD_* variable and moves every GITHUB_*
variable that names a file (an absolute path that is not a folder: GITHUB_STATE,
GITHUB_EVENT_PATH and any one a runner adds later included) into the test's own
temporary folder, by that pattern and not by a list. The child's file starts as
a copy of the caller's, so an input such as the event payload still reads the
same and a write goes nowhere but the copy. GITHUB_WORKSPACE and other folders
stay as they are. A test that wants a results file passes it in `overrides`.
tests/test_ci_run_guards.py ATestSpawnedGuardRunLeavesTheCallersFilesAlone
checks the caller's files stay byte-identical, an unknown GITHUB_*_FILE included.

Load this module by path, as tests/git_fixture_env.py is.
"""
from __future__ import annotations

import os
import shutil
from pathlib import Path

# Always given to the child, so a fixture that writes them never falls back to a missing variable.
STEP_FILES = ("GITHUB_STEP_SUMMARY", "GITHUB_OUTPUT", "GITHUB_ENV", "GITHUB_PATH")


def names_a_file(key: str, value: str) -> bool:
    """A GITHUB_* variable that holds an absolute path other than a folder."""
    return key.startswith("GITHUB_") and os.path.isabs(value) and not os.path.isdir(value)


def guard_child_env(temp_dir: str | os.PathLike[str], **overrides: str) -> dict[str, str]:
    """os.environ without CMUX_GUARD_*, every GITHUB_* file moved into `temp_dir`, then `overrides`."""
    folder = Path(temp_dir)
    env = {key: value for key, value in os.environ.items() if not key.startswith("CMUX_GUARD_")}
    for key in sorted({key for key, value in env.items() if names_a_file(key, value)} | set(STEP_FILES)):
        child = folder / f"child-{key.lower()}"
        source = env.get(key)
        if source and os.path.isfile(source):
            shutil.copyfile(source, child)
        env[key] = str(child)
    env.update(overrides)
    return env
