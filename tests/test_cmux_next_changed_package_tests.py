#!/usr/bin/env python3
"""A feat-cmux-next pull request that changes a lane package runs that package's tests (cmux-next.yml).

ci.yml's macos job skips every feat-cmux-next pull request (static-preflight's next-line split), so
package-test-lane.sh's package run reached no NEXT pull request: #45397 changed
Packages/Shared/CmuxLiveCode and no check ran its `swift test`. cmux_next_route.py (path_route's "Classify
pull request paths") now selects the lane packages a pull request reaches with the lane's own selection,
which turns on the Mac fast tier, and the fast tier (fast-tier-fleet on the build fleet, fast-tier on a Mac)
runs package-test-lane.sh on them. This file checks:

  - the lane lists CmuxLiveCode, and its select phase, fed a real diff that touches
    Packages/Shared/CmuxLiveCode/Sources/..., selects CmuxLiveCode and nothing else;
  - the route selects the same, and turns on macos and fast_tier for it;
  - a change outside Packages/** (a workflow, docs) selects nothing;
  - cmux-next.yml passes path_route's selection to both fast-tier jobs, which run the lane on it.

Run: python3 tests/test_cmux_next_changed_package_tests.py
"""
from __future__ import annotations

import importlib.util
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
LANE = ROOT / "scripts/ci/package-test-lane.sh"
WORKFLOW = ROOT / ".github/workflows/cmux-next.yml"
ROUTE = ROOT / "scripts/ci/cmux_next_route.py"
LIVE_CODE_SOURCE = "Packages/Shared/CmuxLiveCode/Sources/CmuxLiveCode/LiveCodeSession.swift"
# What package-test-lane.sh select runs, besides itself.
LANE_HELPERS = ("swift-test-debug-info.sh", "swiftpm-binary-module-guard.sh", "select_package_tests.py",
                "package_input_key.py")


def lane_packages() -> list[str]:
    body = re.search(r"^select_packages\(\)\s*\{\s*\n\s*PACKAGES=\(\n(.*?)\n\s*\)", LANE.read_text(encoding="utf-8"),
                     re.S | re.M)
    assert body, f"no PACKAGES=( ... ) in {LANE}"
    return [line.split("#")[0].strip() for line in body.group(1).splitlines() if line.split("#")[0].strip()]


def git(root: Path, *args: str) -> None:
    subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@t", *args], cwd=root, check=True,
                   capture_output=True)


def lane_select(changed: list[str]) -> tuple[list[str], list[str]]:
    """The packages package-test-lane.sh select picks for a pull request whose merge commit changes `changed`, and
    the ones cmux_next_route.lane_packages picks, in a scratch repository holding a manifest for every lane package
    (CmuxLiveCode under Shared)."""
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        (root / "scripts/ci").mkdir(parents=True)
        for name in ("package-test-lane.sh", "cmux_next_route.py", *LANE_HELPERS):
            shutil.copy(ROOT / "scripts/ci" / name, root / "scripts/ci" / name)
        for name in set(lane_packages()) | {"CmuxLiveCode"}:
            found = sorted(ROOT.glob(f"Packages/*/{name}/Package.swift"))
            group = found[0].parent.parent.name if found else "Shared"
            manifest = root / "Packages" / group / name / "Package.swift"
            manifest.parent.mkdir(parents=True)
            manifest.write_text("// swift-tools-version: 6.0\n", encoding="utf-8")
        git(root, "init", "-q")
        git(root, "add", "-A")
        git(root, "commit", "-q", "-m", "base")
        for path in changed:
            target = root / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text("// changed\n", encoding="utf-8")
        git(root, "add", "-A")
        git(root, "commit", "-q", "-m", "change")
        work = root / "work"
        work.mkdir()
        outputs = work / "outputs"
        env = {key: value for key, value in os.environ.items() if not key.startswith(("GITHUB_", "CMUX_PACKAGE"))}
        env.update(RUNNER_TEMP=str(work), GITHUB_OUTPUT=str(outputs))
        result = subprocess.run(["bash", "scripts/ci/package-test-lane.sh", "select", "--event", "pull_request"],
                                cwd=root, env=env, text=True, capture_output=True, timeout=120)
        assert result.returncode == 0, result.stdout + result.stderr
        listed = [line.split("=", 1)[1] for line in outputs.read_text(encoding="utf-8").splitlines()
                  if line.startswith("selected_packages=")]
        assert listed, outputs.read_text(encoding="utf-8")
        return Path(listed[-1]).read_text(encoding="utf-8").split(), list(route_module().lane_packages(root, changed))


def route_module():
    spec = importlib.util.spec_from_file_location("_changed_package_tests_route", ROUTE)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class ChangedPackageSelection(unittest.TestCase):
    def test_the_lane_lists_cmux_live_code(self) -> None:
        self.assertIn("CmuxLiveCode", lane_packages())

    def test_a_cmux_live_code_change_selects_cmux_live_code(self) -> None:
        lane, route = lane_select([LIVE_CODE_SOURCE])
        self.assertEqual(lane, ["CmuxLiveCode"])
        self.assertEqual(route, ["CmuxLiveCode"], "path_route must select what the lane selects")

    def test_a_change_outside_packages_selects_nothing(self) -> None:
        self.assertEqual(lane_select([".github/workflows/cmux-next.yml", "docs/ci/notes.md"]), ([], []))

    def test_an_unreadable_selection_selects_no_package(self) -> None:
        # The cd2c93ec review's F1: a failed selection read as the package "unknown", which ran the lane.
        module = route_module()
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch)
            for case in ("no lane script", "no PACKAGES list"):
                with self.subTest(case=case):
                    shutil.rmtree(root / "scripts", ignore_errors=True)
                    (root / "scripts/ci").mkdir(parents=True)
                    shutil.copy2(ROOT / "scripts/ci/select_package_tests.py", root / "scripts/ci")
                    if case == "no PACKAGES list":
                        (root / module.PACKAGE_LANE).write_text("#!/bin/bash\n", encoding="utf-8")
                    self.assertEqual(module.lane_packages(root, [LIVE_CODE_SOURCE]), ())
                    self.assertEqual(module.outputs(module.Route())["swift_packages"], "")

    def test_a_lane_package_turns_on_the_fast_tier(self) -> None:
        module = route_module()
        result = module.Route(lane_packages=("CmuxLiveCode",))
        self.assertTrue(result.macos() and result.fast_tier())
        self.assertEqual(module.outputs(result)["swift_packages"], "CmuxLiveCode")
        self.assertFalse(module.Route().macos() or module.Route().fast_tier())


class WorkflowWiring(unittest.TestCase):
    def setUp(self) -> None:
        self.jobs = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]

    def test_path_route_outputs_the_routes_selection(self) -> None:
        self.assertEqual(self.jobs["path_route"]["outputs"].get("swift_packages"),
                         "${{ steps.route.outputs.swift_packages }}", "path_route has no swift_packages from the route")

    def test_both_fast_tier_jobs_run_the_lane_on_it(self) -> None:
        self.assertNotIn("package-tests-fleet", self.jobs, "the lane runs in the fast tier, not a job of its own")
        for name, needles in (("fast-tier-fleet", ("--arg=run --arg=--event=pull_request", 'judge 3 "package-test-lane.sh')),
                              ("fast-tier", ("bash scripts/ci/package-test-lane.sh run --event pull_request",))):
            with self.subTest(job=name):
                steps = [step for step in self.jobs[name]["steps"]
                         if step.get("env", {}).get("SWIFT_PACKAGES") == "${{ needs.path_route.outputs.swift_packages }}"]
                self.assertEqual(len(steps), 1, f"{name} reads no swift_packages")
                for needle in needles:
                    self.assertIn(needle, steps[0]["run"])
                self.assertIn('-n "${SWIFT_PACKAGES:-}"', steps[0]["run"])


if __name__ == "__main__":
    sys.exit(unittest.main())
