#!/usr/bin/env python3
"""A pull request run skips a Swift package whose test inputs already passed on an earlier run.

package_input_key.py keys each package by the git blobs of everything that can change its tests: the
package and its path dependencies, the job's global inputs, every path the selector does not know to be
unrelated, and the toolchain. swift-package-tests publishes the keys of the packages that passed, and
reuse_package_results.py drops a selected package whose key an earlier run of the same branch published.
"""

from __future__ import annotations

import importlib.util
import json
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CI = ROOT / "scripts" / "ci"
LANE = CI / "package-test-lane.sh"
WORKFLOW = ROOT / ".github" / "workflows" / "ci-macos.yml"

sys.path.insert(0, str(CI))


def load(name: str):
    spec = importlib.util.spec_from_file_location(name, CI / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


keys = load("package_input_key")
reuse = load("reuse_package_results")


def git(root: Path, *args: str) -> str:
    return subprocess.run(["git", *args], cwd=root, check=True, capture_output=True, text=True).stdout.strip()


FILES = {
    "Packages/macOS/Base/Package.swift": "let package = Package(dependencies: [])\n",
    "Packages/macOS/Base/Sources/Base/Base.swift": "public struct Base {}\n",
    "Packages/macOS/Top/Package.swift": 'let package = Package(dependencies: [.package(path: "../Base")])\n',
    "Packages/macOS/Top/Sources/Top/Top.swift": "public struct Top {}\n",
    "Packages/macOS/Other/Package.swift": "let package = Package(dependencies: [])\n",
    "Packages/macOS/Other/Sources/Other/Other.swift": "public struct Other {}\n",
    "scripts/ci/package-test-lane.sh": "lane\n",
    "Resources/App.txt": "app\n",
    "docs/notes.md": "notes\n",
    "Native/Thing/lib.rs": "fn main() {}\n",
}


class Repo:
    def __init__(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        git(self.root, "init", "-q", "-b", "main")
        for path, text in FILES.items():
            self.write(path, text)
        self.commit()

    def write(self, path: str, text: str) -> None:
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text)

    def commit(self) -> None:
        git(self.root, "add", "-A")
        git(self.root, "-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-qm", "c", "--allow-empty")

    def keys(self, *extra: str) -> dict[str, str]:
        return keys.package_keys(self.root, ["Base", "Top", "Other"], list(extra))


class PackageKeyTests(unittest.TestCase):
    def setUp(self) -> None:
        self.repo = Repo()

    def tearDown(self) -> None:
        self.repo.tmp.cleanup()

    def changed_after(self, path: str) -> set[str]:
        before = self.repo.keys()
        self.repo.write(path, "changed\n")
        self.repo.commit()
        after = self.repo.keys()
        return {name for name in before if before[name] != after[name]}

    def test_the_key_is_stable(self) -> None:
        self.assertEqual(self.repo.keys(), self.repo.keys())
        self.assertEqual(len(set(self.repo.keys().values())), 3)

    def test_a_package_edit_moves_its_dependents_only(self) -> None:
        self.assertEqual(self.changed_after("Packages/macOS/Base/Sources/Base/Base.swift"), {"Base", "Top"})
        self.assertEqual(self.changed_after("Packages/macOS/Top/Sources/Top/Top.swift"), {"Top"})

    def test_an_unrelated_path_moves_nothing(self) -> None:
        self.assertEqual(self.changed_after("Resources/App.txt"), set())
        self.assertEqual(self.changed_after("docs/notes.md"), set())

    def test_a_job_input_or_an_unknown_path_moves_every_package(self) -> None:
        self.assertEqual(self.changed_after("scripts/ci/package-test-lane.sh"), {"Base", "Top", "Other"})
        self.assertEqual(self.changed_after("Native/Thing/lib.rs"), {"Base", "Top", "Other"})

    def test_the_toolchain_is_part_of_the_key(self) -> None:
        self.assertNotEqual(self.repo.keys("xcode=/Applications/Xcode-26.0.app"),
                            self.repo.keys("xcode=/Applications/Xcode-26.1.app"))

    def test_the_key_reads_the_commit_not_the_working_tree(self) -> None:
        before = self.repo.keys()
        self.repo.write("Packages/macOS/Base/.build/debug/output", "built\n")
        self.repo.write("Packages/macOS/Base/Sources/Base/Base.swift", "uncommitted\n")
        self.assertEqual(self.repo.keys(), before)


def run(run_id: int, head_repo: str = "manaflow-ai/cmux") -> dict:
    return {"id": run_id, "head_repository": {"full_name": head_repo}}


class ReuseTests(unittest.TestCase):
    def test_a_package_whose_key_passed_earlier_is_reused(self) -> None:
        remaining, reused = reuse.split(["Base", "Top", "Other"], {"Base": "k1", "Top": "k2", "Other": "k3"},
                                        {("Base", "k1"), ("Top", "old")})
        self.assertEqual(remaining, ["Top", "Other"])
        self.assertEqual(reused, ["Base"])

    def test_a_package_without_a_key_runs(self) -> None:
        remaining, reused = reuse.split(["Base", "Top"], {"Base": "k1"}, {("Base", "k1"), ("Top", "k1")})
        self.assertEqual((remaining, reused), (["Top"], ["Base"]))

    def test_only_this_repositorys_earlier_runs_count(self) -> None:
        calls: list[str] = []
        artifacts = {
            1: [{"id": 11, "name": "swift-package-passed-1", "expired": False}],
            2: [{"id": 21, "name": "swift-package-passed-1", "expired": False}],
            3: [{"id": 31, "name": "swift-package-passed-2", "expired": False},
                {"id": 32, "name": "build-inputs-abc-1", "expired": False},
                {"id": 33, "name": "swift-package-passed-1", "expired": True}],
        }
        payloads = {11: {"Base": "now"}, 21: {"Top": "fork"}, 31: {"Other": "k3", "Bad": 5}}

        def runs(branch: str) -> list[dict]:
            calls.append(branch)
            return [run(9), run(1), run(2, "someone/cmux"), run(3)]

        found = reuse.recorded_passes("manaflow-ai/cmux", "feature", 9, runs,
                                      lambda run_id: artifacts.get(run_id, []),
                                      lambda artifact_id: payloads[artifact_id])
        self.assertEqual(found, {("Base", "now"), ("Other", "k3")})
        self.assertEqual(calls, ["feature"])

    def test_a_lookup_error_reuses_nothing(self) -> None:
        def broken(branch: str) -> list[dict]:
            raise RuntimeError("api down")

        with tempfile.TemporaryDirectory() as tmp:
            selected = Path(tmp) / "selected.txt"
            selected.write_text("Base\nTop\n")
            key_file = Path(tmp) / "keys.json"
            key_file.write_text(json.dumps({"Base": "k1", "Top": "k2"}))
            reused = reuse.apply(selected, key_file, lambda: reuse.recorded_passes(
                "manaflow-ai/cmux", "feature", 9, broken, lambda _: [], lambda _: {}))
            self.assertEqual(reused, [])
            self.assertEqual(selected.read_text(), "Base\nTop\n")


class WiringTests(unittest.TestCase):
    def setUp(self) -> None:
        self.lane = LANE.read_text()
        workflow = WORKFLOW.read_text()
        start = workflow.index("\n  swift-package-tests:\n")
        end = re.compile(r"\n  [a-z][a-z0-9-]*:\n").search(workflow, start + 1)
        self.job = workflow[start:end.start() if end else len(workflow)]

    def test_the_lane_reuses_only_when_asked_and_never_on_the_full_suite(self) -> None:
        self.assertIn('if [ "${CMUX_PACKAGE_REUSE:-0}" = 1 ] && [ "$full_suite" != "true" ]', self.lane)
        self.assertIn("scripts/ci/reuse_package_results.py", self.lane)

    def test_the_lane_records_each_passing_package(self) -> None:
        self.assertIn("record_passed", self.lane)
        self.assertIn('output "passed_packages=', self.lane)

    def test_the_job_reads_artifacts_and_publishes_its_passes(self) -> None:
        self.assertRegex(self.job, r"\n    permissions:\n      contents: read\n      actions: read\n")
        self.assertIn("name: swift-package-passed-${{ github.run_attempt }}", self.job)
        self.assertIn("steps.run-packages.outputs.passed_packages != ''", self.job)
        reuse_env = re.search(r"CMUX_PACKAGE_REUSE: (.*)", self.job).group(1)
        self.assertIn("github.event_name == 'pull_request'", reuse_env)
        self.assertIn("github.event.pull_request.head.repo.full_name == github.repository", reuse_env)
        self.assertIn("inputs.full_suite != 'true'", reuse_env)
        self.assertIn("(vars.CI_PACKAGE_RESULT_REUSE || '1') != '0'", reuse_env)

    def test_the_fleet_dispatch_preflights_worker_access(self) -> None:
        fleet = self.job.index("- name: Run Swift package tests on the build fleet")
        dispatch = self.job.index('"$client" run', fleet)
        preflight = self.job.index('"$client" workers', fleet)
        self.assertLess(preflight, dispatch)
        guard = self.job[preflight:dispatch]
        self.assertIn('>"$preflight_log" 2>&1', guard)
        self.assertIn('grep -Fq "compute.instances.get"', guard)
        self.assertIn("No CI job was dispatched", guard)
        self.assertIn("cmux-ci will report the dispatch result", guard)
        self.assertNotIn("raw.githubusercontent.com", guard)
        self.assertNotIn("fleet-instance-preflight.sh", guard)

    def test_the_new_scripts_are_job_inputs(self) -> None:
        select = load("select_package_tests")
        for path in ("scripts/ci/package_input_key.py", "scripts/ci/reuse_package_results.py"):
            self.assertIn(path, select.GLOBAL_INPUTS)


if __name__ == "__main__":
    unittest.main()
