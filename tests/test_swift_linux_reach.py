#!/usr/bin/env python3
"""scripts/ci/swift_linux_reach.py: a pull request runs only the Swift-on-Linux groups and listed suites its
change can fail, and every group when it cannot tell (fails open)."""

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
import swift_linux_reach as reach  # noqa: E402

WORKFLOW = ROOT / ".github" / "workflows" / "swift-linux-packages.yml"


class Reach(unittest.TestCase):
    def setUp(self):
        self.all = list(reach.matrix_groups(ROOT))

    def test_reads_every_matrix_group(self):
        self.assertEqual(self.all[0], "listed")
        self.assertIn("ios-kit", self.all)
        self.assertGreaterEqual(len(self.all), 10)

    def test_one_package_runs_its_groups_and_dependents_only(self):
        out = reach.reach(["Packages/Shared/CmuxEgress/Sources/CmuxEgress/x.swift"])
        self.assertIn("CmuxEgress", out["groups"])
        self.assertNotIn("CmuxVisibleRows", out["groups"])
        self.assertNotIn("stack-auth", out["groups"])
        self.assertLess(len(out["groups"]), len(self.all))

    def test_a_dependency_reaches_its_dependents(self):
        # Every package naming CmuxEgress by path, directly or through another, runs.
        pkgs = reach.packages(ROOT)
        direct = sorted(p for p, deps in pkgs.items() if "Packages/Shared/CmuxEgress" in deps)
        self.assertTrue(direct, "some package depends on CmuxEgress")
        out = reach.reach(["Packages/Shared/CmuxEgress/Package.swift"])
        rows = reach.listed_rows(ROOT)
        for p in direct:
            if p in rows:
                self.assertIn(p, out["listed"].split())

    def test_whole_run_files_run_everything(self):
        for f in reach.WHOLE_RUN:
            out = reach.reach([f])
            self.assertEqual(out["groups"], self.all, f)
            self.assertEqual(out["listed"], "*", f)

    def test_the_list_runs_every_row(self):
        out = reach.reach([reach.LIST])
        self.assertEqual(out["listed"], "*")
        self.assertEqual(out["groups"][0], "listed")

    def test_a_file_in_no_package_runs_everything(self):
        out = reach.reach(["Packages/Shared/README-not-a-package.md"])
        self.assertEqual(out["groups"], self.all)

    def test_cmuxnext_outside_its_linux_targets_reaches_nothing(self):
        out = reach.reach(["Packages/macOS/CmuxNext/Sources/CmuxNextSomethingMacOnly/x.swift"])
        self.assertNotIn("Packages/macOS/CmuxNext", out["listed"].split())
        out = reach.reach(["Packages/macOS/CmuxNext/Sources/CmuxNextHostPressure/x.swift"])
        self.assertIn("Packages/macOS/CmuxNext", out["listed"].split())

    def test_cli_fails_open_and_writes_outputs(self):
        with tempfile.TemporaryDirectory() as tmp:
            changed, gh_out = Path(tmp) / "changed", Path(tmp) / "out"
            changed.write_text("Packages/Shared/CmuxEgress/x.swift\0")
            subprocess.run([sys.executable, str(ROOT / "scripts/ci/swift_linux_reach.py"), "--changed", str(changed),
                            "--github-output", str(gh_out)], check=True, capture_output=True)
            lines = dict(line.split("=", 1) for line in gh_out.read_text().splitlines())
            self.assertIn('"CmuxEgress"', lines["groups"])
            gh_out.unlink()
            subprocess.run([sys.executable, str(ROOT / "scripts/ci/swift_linux_reach.py"), "--changed", str(Path(tmp) / "missing"),
                            "--github-output", str(gh_out)], check=True, capture_output=True)
            lines = dict(line.split("=", 1) for line in gh_out.read_text().splitlines())
            self.assertEqual(json.loads(lines["groups"]), self.all)
            self.assertEqual(lines["listed"], "*")


class Workflow(unittest.TestCase):
    def test_every_build_step_is_gated_and_the_plan_fails_open(self):
        wf = WORKFLOW.read_text()
        self.assertIn("python3 scripts/ci/swift_linux_reach.py", wf)
        self.assertIn("needs.plan.result != 'success' || needs.plan.outputs.groups == '*'", wf)
        self.assertIn("groups: ${{ steps.reach.outputs.groups || '*' }}", wf)
        for name in ("Checkout", "Install python3, SQLite and zlib headers, xz", "Cache key", "Restore .build",
                     "Fetch the fleet client from the controller", "package-test-lane.sh suite, every listed package",
                     "Build and test"):
            block = wf.split(f"- name: {name}\n", 1)[1].split("\n      - name:", 1)[0]
            self.assertIn("env.REACHED == '1'", block, name)
        self.assertEqual(wf.count('[ "$LISTED_ROWS" = \'*\' ] ||'), 2)


if __name__ == "__main__":
    unittest.main()
