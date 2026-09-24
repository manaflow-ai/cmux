#!/usr/bin/env python3
"""Every guard that reads a workflow must be run by a workflow.

A test under tests/ that opens a file from .github/workflows/ exists to hold
some CI invariant still. If nothing in .github/workflows/ ever executes that
test, the invariant is unenforced and the file is decoration: it keeps passing
locally while main drifts away from what it asserts, and it reports nothing
when the drift breaks a release.

That is not hypothetical here. tests/test_tui_publish_dispatch_budget.py
arrived with the dispatch-budget fix it was written to hold, was never named by
any workflow, and cmux-tui v0.13.0 failed to publish on that exact regression
anyway. tests/test_ci_universal_release_settings.sh kept asserting that
scripts/setup.sh builds GhosttyKit universal for however long it has been since
that build moved to scripts/ensure-ghosttykit.sh -- an assertion about a file
that had stopped doing the job, which nothing was in a position to notice.

So the rule is structural rather than a list of known guards: discover the
guards from what they read, discover the wiring from what the workflows run,
and require the second to cover the first.
"""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW_DIR = ROOT / ".github" / "workflows"

# A guard is identified by what it reads, not by where it lives, so a test that
# is moved or renamed keeps its obligation. Both spellings occur in-tree: a
# literal "…/.github/workflows/x.yml" and a pathlib join of the segments.
READS_A_WORKFLOW = re.compile(r"\.github[/\"'\s,)]+.{0,4}workflows")

# Paths a workflow executes directly: `python3 tests/x.py`, `./tests/x.sh`,
# `bash tests/x.sh`. Matching the path alone (rather than the whole command)
# keeps this indifferent to which interpreter a step chooses.
INVOKED_PATH = re.compile(r"(?:\./)?(tests(?:_v2)?/[A-Za-z0-9_.-]+\.(?:py|sh))")

# Guards that are knowingly unwired. Each entry needs a reason and an exit:
# an allowlist that can be appended to without argument is the failure mode
# this test exists to prevent.
UNWIRED = {
    # Splits .github/workflows/cli-pipe-regressions.yml on the step name
    # "Exercise bounded read-only current-work consumers" and runs that step's
    # script. The step is gone from the workflow -- the closest surviving one
    # is "Exercise closed consumers and socket disconnects" -- so this errors
    # in setUpClass before a single assertion runs. It orphaned
    # tests/test_cli_current.py and tests/test_current_command_fixture.py with
    # it, since the deleted step was their only caller. Wiring it means
    # deciding whether bounded read-only current-work consumers should still
    # be exercised at all, which is a question for whoever removed the step.
    "tests/test_current_cli_workflow.py",
}


def tracked_tests() -> list[str]:
    out = subprocess.run(
        ["git", "ls-files", "tests", "tests_v2"],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=True,
    ).stdout.split()
    return [p for p in out if Path(p).name.startswith("test_") and p.endswith((".py", ".sh"))]


def workflow_guards() -> set[str]:
    found = set()
    for path in tracked_tests():
        try:
            text = (ROOT / path).read_text(encoding="utf-8", errors="ignore")
        except OSError:
            continue
        if READS_A_WORKFLOW.search(text):
            found.add(path)
    return found


def invoked_by_workflows() -> set[str]:
    sys.path.insert(0, str(ROOT / "scripts" / "ci"))
    import workload_entrypoints

    invoked = set()
    for workflow in sorted(WORKFLOW_DIR.glob("*.yml")):
        text = workflow.read_text(encoding="utf-8")
        invoked.update(INVOKED_PATH.findall(text))
        # A workload profile step runs everything its entrypoint names.
        for _, script in workload_entrypoints.entrypoints(text, ROOT):
            invoked.update(INVOKED_PATH.findall(script))
    return invoked


def test_every_workflow_guard_is_run_by_a_workflow() -> None:
    unwired = sorted(workflow_guards() - invoked_by_workflows() - UNWIRED)
    assert not unwired, (
        "these tests read .github/workflows/ but no workflow runs them, so the "
        "invariants they assert are not enforced:\n  "
        + "\n  ".join(unwired)
        + "\n\nAdd a step to .github/workflows/ci-guards.yml, or add an "
        "entry to UNWIRED in this file explaining why not."
    )


def test_allowlist_does_not_outlive_its_entries() -> None:
    # An entry that has been wired, deleted, or renamed must leave, or the
    # allowlist silently accumulates permission for files that no longer exist.
    guards = workflow_guards()
    invoked = invoked_by_workflows()
    for entry in sorted(UNWIRED):
        assert (ROOT / entry).exists(), f"{entry} is allowlisted but does not exist"
        assert entry in guards, f"{entry} is allowlisted but no longer reads a workflow"
        assert entry not in invoked, f"{entry} is wired now; drop it from UNWIRED"


if __name__ == "__main__":
    test_every_workflow_guard_is_run_by_a_workflow()
    test_allowlist_does_not_outlive_its_entries()
    print("all workflow guards are wired")
