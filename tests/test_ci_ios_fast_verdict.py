#!/usr/bin/env python3
"""The fast iOS verdict (scripts/ci/ios_fast_verdict.py and pr-pipeline.yml's ios-fast-runner and ios-fast jobs):
the diff maps to the changed kit test target or a build, and the check is additive (its own job, not required, the
full matrix untouched).

    python3 tests/test_ci_ios_fast_verdict.py
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
import ios_fast_verdict as fv  # noqa: E402

KIT = "cmux-next-ios/CmuxMobileKit/"


class PlanTest(unittest.TestCase):
    def plan(self, *paths: str) -> dict:
        return fv.plan(list(paths))

    def test_a_kit_source_runs_its_test_target_only(self) -> None:
        p = self.plan(KIT + "Sources/CmuxMobileShell/Foo.swift", KIT + "Sources/CmuxMobileChief/Bar.swift")
        self.assertTrue(p["run"])
        self.assertEqual(p["tests"], ["CmuxMobileChiefTests", "CmuxMobileShellTests"])
        self.assertFalse(p["build"])
        self.assertFalse(p["app"])

    def test_a_kit_test_file_runs_its_target(self) -> None:
        p = self.plan(KIT + "Tests/CmuxMobileVoiceTests/VoiceTests.swift")
        self.assertEqual(p["tests"], ["CmuxMobileVoiceTests"])

    def test_every_planned_target_exists(self) -> None:
        have = fv.test_targets(fv.ROOT)
        self.assertTrue(have, "the kit has test targets")
        sources = ROOT / KIT / "Sources"
        for module in sorted(d.name for d in sources.iterdir() if d.is_dir()):
            with self.subTest(module=module):
                p = self.plan(f"{KIT}Sources/{module}/X.swift")
                self.assertTrue(set(p["tests"]) <= have)
                self.assertTrue(p["tests"] or p["build"], "a changed kit module always gets a verdict")

    def test_the_skipped_targets_never_run(self) -> None:
        p = self.plan(KIT + "Tests/CmuxMobileInstantPerfTests/A.swift", KIT + "Tests/CmuxMobileLinkFFILinuxTests/B.swift")
        self.assertEqual(p["tests"], [])
        self.assertFalse(p["run"])

    def test_a_module_without_tests_builds_the_kit(self) -> None:
        have = fv.test_targets(fv.ROOT)
        bare = [d.name for d in (ROOT / KIT / "Sources").iterdir() if d.is_dir() and d.name + "Tests" not in have]
        if not bare:
            self.skipTest("every kit module has a test target")
        p = self.plan(f"{KIT}Sources/{bare[0]}/X.swift")
        self.assertEqual(p["tests"], [])
        self.assertTrue(p["build"])

    def test_the_app_builds_the_app(self) -> None:
        p = self.plan("cmux-next-ios/App/Sources/RootView.swift", "cmux-next-ios/project.yml")
        self.assertTrue(p["app"])
        self.assertEqual(p["tests"], [])
        self.assertFalse(p["build"])

    def test_the_package_manifest_builds_the_kit(self) -> None:
        p = self.plan(KIT + "Package.swift")
        self.assertTrue(p["build"])

    def test_a_path_ios_kit_does_not_route_plans_nothing(self) -> None:
        for path in ("docs/a.md", "web/app/page.tsx", "cmux-next-ios/verify/parity-mac/row.md", KIT + "README.md"):
            with self.subTest(path=path):
                p = self.plan(path)
                self.assertFalse(p["run"])
                self.assertEqual(fv.summary(p), "no iOS target changed")

    def test_its_own_files_build_the_kit(self) -> None:
        # The check runs on the pull request that changes it.
        for path in fv.SELF:
            with self.subTest(path=path):
                self.assertTrue(self.plan(path)["build"])

    def test_many_targets_fall_back_to_a_build(self) -> None:
        have = sorted(fv.test_targets(fv.ROOT) - fv.SKIPPED_TESTS)
        self.assertGreater(len(have), fv.MAX_TEST_TARGETS)
        p = self.plan(*(f"{KIT}Tests/{t}/A.swift" for t in have))
        self.assertEqual(p["tests"], [])
        self.assertTrue(p["build"])

    def test_tests_and_a_build_run_the_tests_only(self) -> None:
        # A test run builds the kit's bundle: no separate build-for-testing.
        p = self.plan(KIT + "Sources/CmuxMobileShell/Foo.swift", KIT + "Package.swift")
        self.assertEqual(p["tests"], ["CmuxMobileShellTests"])
        self.assertFalse(p["build"])

    def test_why_is_capped(self) -> None:
        p = self.plan(*(f"{KIT}Sources/CmuxMobileShell/F{i}.swift" for i in range(50)))
        self.assertEqual(len(p["why"]), fv.MAX_WHY + 1)

    def test_the_cli_writes_one_line_outputs(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            paths = Path(tmp, "paths")
            paths.write_bytes(f"{KIT}Sources/CmuxMobileShell/Foo.swift\0cmux-next-ios/App/A.swift\0".encode())
            out = Path(tmp, "out")
            env = {**os.environ, "GITHUB_OUTPUT": str(out)}
            subprocess.run([sys.executable, str(ROOT / "scripts/ci/ios_fast_verdict.py"), "plan", "--paths-file",
                            str(paths)], check=True, capture_output=True, env=env)
            lines = dict(line.split("=", 1) for line in out.read_text().splitlines())
        self.assertEqual(lines["run"], "true")
        self.assertEqual(json.loads(lines["plan"])["tests"], ["CmuxMobileShellTests"])
        self.assertEqual(lines["summary"], "tests CmuxMobileShellTests; app build")


class WorkflowTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.jobs = yaml.safe_load((ROOT / ".github/workflows/pr-pipeline.yml").read_text())["jobs"]

    def test_the_picker_plans_then_picks_only_when_a_target_changed(self) -> None:
        runner = self.jobs["ios-fast-runner"]
        self.assertEqual(runner["steps"][0]["with"]["fetch-depth"], 2)
        self.assertIs(runner["steps"][0]["with"]["persist-credentials"], False)
        self.assertEqual(runner["steps"][1]["id"], "plan")
        self.assertIn("scripts/ci/ios_fast_verdict.py plan", runner["steps"][1]["run"])
        pick = next(s for s in runner["steps"] if s.get("id") == "pool")
        # The token mints and the pick; the markers after it follow the pick's own outputs.
        for step in runner["steps"][2:runner["steps"].index(pick) + 1]:
            with self.subTest(step=step["name"]):
                self.assertIn("steps.plan.outputs.run == 'true'", step.get("if", ""))
        for step in runner["steps"][runner["steps"].index(pick) + 1:]:
            with self.subTest(step=step["name"]):
                self.assertRegex(step["if"], r"steps\.(pool\.outputs\.persistent|marker\.outputs\.path)")
        self.assertIn("--lane pipeline", pick["run"])
        self.assertIn("--device-family iphone", pick["run"])
        self.assertEqual(runner["runs-on"], self.jobs["ios-runner"]["runs-on"])

    def test_the_mac_job_runs_the_plan_warm(self) -> None:
        job = self.jobs["ios-fast"]
        self.assertEqual(job["name"], "ios fast verdict")
        self.assertEqual(job["needs"], ["ios-fast-runner"])
        self.assertEqual(job["if"], "${{ needs.ios-fast-runner.outputs.run == 'true' }}")
        self.assertIn("needs.ios-fast-runner.outputs.runs_on", job["runs-on"])
        self.assertIs(job["steps"][0]["with"]["clean"], False)
        names = [s.get("name") for s in job["steps"]]
        run = next(s for s in job["steps"] if "ios_fast_verdict.sh" in s.get("run", ""))
        # owned_pool_rescue.py reads "Select Xcode" by name; the run needs the selected Xcode.
        self.assertLess(names.index("Select Xcode"), names.index(run["name"]))
        self.assertEqual(run["env"]["PLAN"], "${{ needs.ios-fast-runner.outputs.plan }}")
        self.assertLessEqual(job["timeout-minutes"], 60)

    def test_it_is_additive(self) -> None:
        # The full matrix's ios job is unchanged and never waits on the fast check.
        self.assertEqual(self.jobs["ios"]["needs"], ["ios-runner"])
        self.assertNotIn("ios-fast", json.dumps({k: v for k, v in self.jobs.items() if not k.startswith("ios-fast")}))
        # No branch rule or merge gate names it.
        for path in (ROOT / ".github").rglob("*.json"):
            with self.subTest(path=str(path.relative_to(ROOT))):
                self.assertNotIn("ios fast verdict", path.read_text(errors="replace"))

    def test_the_runner_script_parses(self) -> None:
        subprocess.run(["bash", "-n", str(ROOT / "scripts/ci/ios_fast_verdict.sh")], check=True)


if __name__ == "__main__":
    unittest.main()
