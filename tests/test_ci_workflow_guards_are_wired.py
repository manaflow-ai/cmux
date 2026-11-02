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
UNWIRED: set[str] = {
    # Both are lane = "manual" in tests/test-execution.toml: CLAUDE.md forbids adding CI tests (Lawrence
    # 2026-10-23: "not to add gates/tests in CI, but you have to run them yourself"). Each reads a workflow
    # only as data (a fixture nightly.yml; cmux-next.yml for stamp readers). Exit: wire it here if that
    # rule changes and the toml entry moves to a CI lane.
    "tests/test_cmux_next_guardrails.py",
    "tests/test_settings_stamp_not_committed.py",
    # lane = "manual" for the same rule. It runs tree-preflight's inspect step with fakes and asserts
    # wall-clock bounds of its fallback owner election; run it by hand when that step changes.
    "tests/test_cmux_tui_election_budget.py",
    # lane = "manual" for the same rule. They check the cmux-next swift test job's shard plan and its
    # main-thread-heavy split; run them by hand after changing scripts/cmux-next/swift-test-shards.py,
    # main-thread-heavy-suites.py or that job.
    "tests/test_ci_swift_test_main_thread_isolation.py",
    "tests/test_ci_swift_test_shards.py",
    # lane = "manual" for the same rule. It reads nightly-next-launch-smoke.yml and nightly.yml to assert
    # the post-publish smoke never gates a publish; run it by hand when the smoke or its workflow changes.
    "tests/test_nightly_next_launch_smoke.py",
    # lane = "manual" for the same rule. It reads nightly.yml only to keep the pinned Sparkle key of
    # nightly_next_artifact_check.py equal to NIGHTLY_NEXT_SPARKLE_PUBLIC_KEY; run it by hand when that
    # helper or the workflows that call it change.
    "tests/test_nightly_next_artifact_check.py",
    # lane = "manual" for the same rule (their tests/test-execution.toml entries say so: wiring them as
    # linux-guard reddened tooling-tests on every pull request). Run each by hand after changing what it reads:
    # .github/runners.json linux_sizes or a Blacksmith Linux runs-on (#30360);
    "tests/test_ci_blacksmith_linux_sizes.py",
    # a Linux runs-on or the RUNNER_POOLS.linux picker (#30878);
    "tests/test_ci_overflow_pick_reads_pool.py",
    # scripts/ci/nightly_next_control_rescue.py or nightly.yml's control rescue (#30657);
    "tests/test_nightly_next_control_rescue.py",
    # scripts/ci/cloud_probe_rescue.py, run by the main controller's workflow_run adapter, not a PR job
    # (#30796): python3 -m unittest tests.test_ci_cloud_probe_rescue from the repository root.
    "tests/test_ci_cloud_probe_rescue.py",
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
