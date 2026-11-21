#!/usr/bin/env python3
"""A feat-cmux-next pull request that changes a lane package runs that package's tests (cmux-next.yml).

ci.yml's macos job skips every feat-cmux-next pull request (static-preflight's next-line split), so
package-test-lane.sh's package run reached no NEXT pull request: #45397 changed
Packages/Shared/CmuxLiveCode and no check ran its `swift test`. cmux-next.yml now selects the lane
packages a pull request changes in path_route (package-test-lane.sh select) and runs them on the build
fleet in package-tests-fleet (scripts/ci/next-package-tests-fleet.sh). This file checks:

  - the lane lists CmuxLiveCode, and its select phase, fed a real diff that touches
    Packages/Shared/CmuxLiveCode/Sources/..., selects CmuxLiveCode and nothing else;
  - a change outside Packages/** (a workflow, docs) selects nothing, so the fleet job does not run;
  - cmux-next.yml wires path_route's selection to package-tests-fleet;
  - the fleet script passes only on a step the controller records as done at the commit, exit 0.

Run: python3 tests/test_cmux_next_changed_package_tests.py
"""
from __future__ import annotations

import json
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
FLEET = ROOT / "scripts/ci/next-package-tests-fleet.sh"
LIVE_CODE_SOURCE = "Packages/Shared/CmuxLiveCode/Sources/CmuxLiveCode/LiveCodeSession.swift"
# What package-test-lane.sh select runs, besides itself.
LANE_HELPERS = ("swift-test-debug-info.sh", "swiftpm-binary-module-guard.sh", "select_package_tests.py",
                "package_input_key.py")
SHA = "0123456789abcdef0123456789abcdef01234567"


def lane_packages() -> list[str]:
    body = re.search(r"^select_packages\(\)\s*\{\s*\n\s*PACKAGES=\(\n(.*?)\n\s*\)", LANE.read_text(encoding="utf-8"),
                     re.S | re.M)
    assert body, f"no PACKAGES=( ... ) in {LANE}"
    return [line.split("#")[0].strip() for line in body.group(1).splitlines() if line.split("#")[0].strip()]


def git(root: Path, *args: str) -> None:
    subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@t", *args], cwd=root, check=True,
                   capture_output=True)


def lane_select(changed: list[str]) -> list[str]:
    """The packages package-test-lane.sh select picks for a pull request whose merge commit changes `changed`,
    in a scratch repository holding a manifest for every lane package (CmuxLiveCode under Shared)."""
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        (root / "scripts/ci").mkdir(parents=True)
        for name in ("package-test-lane.sh", *LANE_HELPERS):
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
        return Path(listed[-1]).read_text(encoding="utf-8").split()


class ChangedPackageSelection(unittest.TestCase):
    def test_the_lane_lists_cmux_live_code(self) -> None:
        self.assertIn("CmuxLiveCode", lane_packages())

    def test_a_cmux_live_code_change_selects_cmux_live_code(self) -> None:
        self.assertEqual(lane_select([LIVE_CODE_SOURCE]), ["CmuxLiveCode"])

    def test_a_change_outside_packages_selects_nothing(self) -> None:
        self.assertEqual(lane_select([".github/workflows/cmux-next.yml", "docs/ci/notes.md"]), [])


class WorkflowWiring(unittest.TestCase):
    def setUp(self) -> None:
        self.jobs = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]

    def test_path_route_selects_with_the_lane(self) -> None:
        route = self.jobs["path_route"]
        steps = {step.get("id"): step for step in route["steps"]}
        self.assertTrue("packages" in steps, "path_route has no `packages` selection step")
        self.assertIn("package-test-lane.sh select --event pull_request", steps["packages"]["run"])
        self.assertIn("steps.packages.outputs.names", route["outputs"]["swift_packages"])

    def test_the_fleet_job_runs_the_selected_packages(self) -> None:
        job = self.jobs.get("package-tests-fleet")
        self.assertIsNotNone(job, "cmux-next.yml has no package-tests-fleet job")
        self.assertIn("path_route", job["needs"])
        self.assertIn("needs.path_route.outputs.swift_packages != ''", job["if"])
        self.assertIn("feat-cmux-next", job["if"])
        self.assertEqual(job["runs-on"], "${{ vars.CI_COMPILE_CHECK_GATEWAY }}")
        runs = "\n".join(step.get("run", "") for step in job["steps"])
        self.assertIn("scripts/ci/next-package-tests-fleet.sh", runs)


FAKE_CLIENT = """#!/usr/bin/env bash
case "$1" in
  run) printf '%s\\n' "$@" > "$FAKE_DIR/args"; echo "cmux-ci: step abcdef123456 queued"; echo "Selected 1 of 20"
       exit "$(cat "$FAKE_DIR/client_exit")" ;;
  status) cat "$FAKE_DIR/status.json" ;;
esac
"""


class FleetVerdict(unittest.TestCase):
    def judge(self, client_exit: int, record: dict) -> tuple[int, str, list[str]]:
        with tempfile.TemporaryDirectory() as directory:
            fake = Path(directory)
            client = fake / "cmux-ci"
            client.write_text(FAKE_CLIENT, encoding="utf-8")
            client.chmod(0o755)
            (fake / "client_exit").write_text(str(client_exit), encoding="utf-8")
            (fake / "status.json").write_text(json.dumps(record), encoding="utf-8")
            env = {key: value for key, value in os.environ.items() if not key.startswith("GITHUB_")}
            env.update(CMUX_CI_CLIENT=str(client), FAKE_DIR=str(fake), RUNNER_TEMP=str(fake))
            result = subprocess.run(["bash", str(FLEET), SHA, "CmuxLiveCode"], env=env, text=True,
                                    capture_output=True, timeout=60)
            args = (fake / "args").read_text(encoding="utf-8").split("\n") if (fake / "args").exists() else []
            return result.returncode, result.stdout + result.stderr, args

    def test_a_step_done_at_the_commit_with_exit_0_passes(self) -> None:
        code, out, args = self.judge(0, {"ref": SHA, "state": "done", "exit_code": 0})
        self.assertEqual(code, 0, out)
        self.assertIn("every selected package passed", out)
        for expected in ("--class", "light", "scripts/ci/package-test-lane.sh", "--arg=run",
                         "--arg=--event=pull_request", SHA):
            self.assertIn(expected, args)

    def test_a_failed_step_fails(self) -> None:
        code, out, _ = self.judge(1, {"ref": SHA, "state": "failed", "exit_code": 1})
        self.assertEqual(code, 1, out)
        self.assertIn("a package test failed", out)

    def test_another_commit_is_no_verdict(self) -> None:
        code, out, _ = self.judge(0, {"ref": "f" * 40, "state": "done", "exit_code": 0})
        self.assertEqual(code, 1, out)
        self.assertIn("not " + SHA, out)

    def test_a_queued_step_is_no_verdict(self) -> None:
        code, out, _ = self.judge(75, {"ref": SHA, "state": "queued"})
        self.assertEqual(code, 1, out)
        self.assertIn("no verdict", out)


if __name__ == "__main__":
    sys.exit(unittest.main())
