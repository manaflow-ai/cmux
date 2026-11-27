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

    def test_a_kit_source_runs_its_test_target_and_builds_the_app(self) -> None:
        # The app and its UI tests link the kit: a kit API change that broke only them landed (cmux#55664).
        p = self.plan(KIT + "Sources/CmuxMobileShell/Foo.swift", KIT + "Sources/CmuxMobileChief/Bar.swift")
        self.assertTrue(p["run"])
        self.assertEqual(p["tests"], ["CmuxMobileChiefTests", "CmuxMobileShellTests"])
        self.assertFalse(p["build"])
        self.assertTrue(p["app"])

    def test_a_kit_test_file_runs_its_target_only(self) -> None:
        p = self.plan(KIT + "Tests/CmuxMobileVoiceTests/VoiceTests.swift")
        self.assertEqual(p["tests"], ["CmuxMobileVoiceTests"])
        self.assertFalse(p["app"])

    def test_a_shared_package_builds_the_kit_and_the_app(self) -> None:
        p = self.plan("Packages/Shared/CmuxTheme/Sources/CmuxTheme/Theme.swift")
        self.assertTrue(p["build"])
        self.assertTrue(p["app"])

    def test_a_rust_crate_the_ffi_compiles_builds_the_kit_and_the_app(self) -> None:
        # cmux#55399: a cmux-tui crate change broke the iOS build and nothing iOS ran.
        for path in ("cmux-tui/crates/cmux-wg/src/wireguard_dormant.rs", "cmux-tui/Cargo.lock",
                     "cmux-tui/vendor/smoltcp/src/lib.rs"):
            with self.subTest(path=path):
                p = self.plan(path)
                self.assertTrue(p["build"])
                self.assertTrue(p["app"])
                self.assertTrue(fv.affects([path]))

    def test_a_rust_crate_the_ffi_does_not_compile_plans_nothing(self) -> None:
        import ios_link_ffi_key
        packages, _ = ios_link_ffi_key.closure("HEAD")
        crates = ROOT / "cmux-tui" / "crates"
        other = sorted(d.name for d in crates.iterdir() if d.is_dir() and f"cmux-tui/crates/{d.name}" not in packages)
        if not other:
            self.skipTest("the FFI compiles every cmux-tui crate")
        path = f"cmux-tui/crates/{other[0]}/src/lib.rs"
        self.assertFalse(self.plan(path)["run"])
        self.assertFalse(fv.affects([path]))

    def test_affects_matches_the_plan(self) -> None:
        for path in ("docs/a.md", "web/app/page.tsx", KIT + "README.md", KIT + "Package.swift",
                     "cmux-next-ios/App/A.swift", KIT + "Tests/CmuxMobileInstantPerfTests/A.swift"):
            with self.subTest(path=path):
                # A skipped test target is still an iOS path: the router holds the status for it.
                self.assertEqual(fv.affects([path]), self.plan(path)["run"] or "/Tests/" in path)

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

    def test_status_without_a_token_warns_and_passes(self) -> None:
        env = {k: v for k, v in os.environ.items() if k not in ("TOKENS", "REPO", "SHA")}
        r = subprocess.run([sys.executable, str(ROOT / "scripts/ci/ios_fast_verdict.py"), "status", "success", "x"],
                           capture_output=True, text=True, env=env)
        self.assertEqual(r.returncode, 0)
        self.assertIn("not posted", r.stdout)

    def test_status_posts_the_context_capped(self) -> None:
        seen = []

        def fake(req, seconds=0, **kw):
            seen.append((req.full_url, json.loads(req.data), req.headers["Authorization"]))
            if len(seen) == 1:
                raise OSError("spent")
            return 201, b"{}", {}

        old = fv.gh_http.request
        fv.gh_http.request = fake
        try:
            self.assertTrue(fv.post_status("pending", "d" * 300, "o/r", "abc", ["t1", "t2"], pause=0))
        finally:
            fv.gh_http.request = old
        self.assertEqual([s[2] for s in seen], ["Bearer t1", "Bearer t2"])
        self.assertEqual(seen[1][0], "https://api.github.com/repos/o/r/statuses/abc")
        self.assertEqual(seen[1][1]["context"], "cmux/ios-fast")
        self.assertEqual(len(seen[1][1]["description"]), 140)


class RouterStatusTest(unittest.TestCase):
    """pr_router.ios_status: the `cmux/ios-fast` state the route posts."""

    @classmethod
    def setUpClass(cls) -> None:
        import pr_router
        cls.status = staticmethod(pr_router.ios_status)

    def event(self, draft: bool = False, base: str = "feat-cmux-next", fork: bool = False) -> dict:
        return {"pull_request": {"draft": draft, "base": {"ref": base, "repo": {"full_name": "o/r"}},
                                 "head": {"repo": {"full_name": "x/r" if fork else "o/r"}}}}

    def test_a_head_that_touches_nothing_ios_is_success_at_once(self) -> None:
        state, desc = self.status(self.event(), ["web/app/page.tsx", "docs/a.md"], [], "pending")
        self.assertEqual(state, "success")
        self.assertLessEqual(len(desc), 140)

    def test_an_ios_head_the_pipeline_runs_is_pending(self) -> None:
        self.assertEqual(self.status(self.event(), [KIT + "Package.swift"], ["pr-pipeline.yml"], "success")[0],
                         "pending")

    def test_a_cheap_ios_head_waits_for_the_land(self) -> None:
        state, desc = self.status(self.event(), ["cmux-tui/crates/cmux-wg/src/a.rs"], [], "pending")
        self.assertEqual(state, "pending")
        self.assertIn("ready-to-land", desc)

    def test_a_carried_ios_head_carries(self) -> None:
        self.assertEqual(self.status(self.event(), [KIT + "Package.swift"], [], "success")[0], "success")

    def test_unknown_files_are_ios(self) -> None:
        self.assertEqual(self.status(self.event(), None, [], "pending")[0], "pending")

    def test_no_status_where_the_land_rule_does_not_apply(self) -> None:
        for event in (self.event(draft=True), self.event(base="main"), self.event(fork=True)):
            self.assertEqual(self.status(event, [KIT + "Package.swift"], [], ""), ("", ""))

    def test_the_switch_off_is_success(self) -> None:
        old = os.environ.get("CI_IOS_FAST_VERDICT")
        os.environ["CI_IOS_FAST_VERDICT"] = "0"
        try:
            self.assertEqual(self.status(self.event(), [KIT + "Package.swift"], ["pr-pipeline.yml"], "")[0],
                             "success")
        finally:
            if old is None:
                os.environ.pop("CI_IOS_FAST_VERDICT")
            else:
                os.environ["CI_IOS_FAST_VERDICT"] = old

    def test_every_description_fits(self) -> None:
        for args in ((["docs/a.md"], [], ""), ([KIT + "P.swift"], ["pr-pipeline.yml"], ""),
                     ([KIT + "P.swift"], [], "success"), ([KIT + "P.swift"], [], "pending")):
            self.assertLessEqual(len(self.status(self.event(), *args)[1]), 140)


class LandAffectedRouteTest(unittest.TestCase):
    """pr_router.route on a landing head the hourly full tier rule keeps on the affected tier: an iOS-affecting one
    starts pr-pipeline.yml for the ios fast verdict alone, so nothing iOS merges uncompiled (Leo, 2026-11-27: "like
    idk if he just kept getting bottled on random stuff that we can juts fix fundamentally")."""

    @classmethod
    def setUpClass(cls) -> None:
        import head_tier
        import pr_router
        cls.router = pr_router
        cls.callees = pr_router.load_manifest()
        cls.affected = ("cheap", head_tier.LAND_AFFECTED_REASON + ": the full tier runs once an hour")

    def event(self) -> dict:
        return {"action": "synchronize", "pull_request": {
            "draft": False, "labels": [{"name": "ready-to-land"}],
            "base": {"ref": "feat-cmux-next", "repo": {"full_name": "o/r"}},
            "head": {"ref": "lane/x", "repo": {"full_name": "o/r"}}}}

    def route(self, files: list[str] | None, decided: tuple[str, str] | None = None) -> tuple[list[str], dict]:
        return self.router.route(self.event(), self.callees, files, decided=decided or self.affected)

    def test_an_ios_landing_head_starts_the_verdict(self) -> None:
        start, why = self.route([KIT + "Tests/CmuxMobileKitTests/A.swift"])
        self.assertIn("pr-pipeline.yml", start)
        self.assertIn("ios fast verdict", why["pr-pipeline.yml"])
        # No table job: linux, web-browser, ios and mac stay off (pr-pipeline.yml's job ifs read `[]`).
        self.assertEqual(self.router.table_jobs_routed(self.callees, [KIT + "Package.swift"], full=False), [])
        self.assertEqual(self.router.ios_status(self.event(), [KIT + "Package.swift"], start, "success")[0],
                         "pending")

    def test_an_ffi_crate_landing_head_starts_the_verdict(self) -> None:
        self.assertIn("pr-pipeline.yml", self.route(["cmux-tui/crates/cmux-wg/src/a.rs"])[0])

    def test_unknown_files_start_the_verdict(self) -> None:
        self.assertIn("pr-pipeline.yml", self.route(None)[0])

    def test_a_landing_head_off_ios_starts_nothing(self) -> None:
        self.assertNotIn("pr-pipeline.yml", self.route(["web/app/page.tsx"])[0])

    def test_a_cheap_head_not_landing_still_waits(self) -> None:
        start, why = self.route([KIT + "Package.swift"], decided=("cheap", "ready head before ready-to-land"))
        self.assertNotIn("pr-pipeline.yml", start)

    def test_the_switch_off_starts_nothing(self) -> None:
        old = os.environ.get("CI_IOS_FAST_VERDICT")
        os.environ["CI_IOS_FAST_VERDICT"] = "0"
        try:
            self.assertNotIn("pr-pipeline.yml", self.route([KIT + "Package.swift"])[0])
        finally:
            if old is None:
                os.environ.pop("CI_IOS_FAST_VERDICT")
            else:
                os.environ["CI_IOS_FAST_VERDICT"] = old


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

    def test_the_verdict_reaches_the_router(self) -> None:
        call = yaml.safe_load((ROOT / ".github/workflows/pr-pipeline.yml").read_text())
        outputs = call.get("on", call.get(True))["workflow_call"]["outputs"]
        self.assertEqual(outputs["ios_fast_verdict"]["value"], "${{ jobs.ios-fast.outputs.verdict }}")
        self.assertEqual(outputs["ios_fast_run"]["value"], "${{ jobs.ios-fast-runner.outputs.run }}")
        record = next(s for s in self.jobs["ios-fast"]["steps"] if s.get("id") == "verdict")
        self.assertIn("success() || failure()", record["if"])
        router = yaml.safe_load((ROOT / ".github/workflows/pr-router.yml").read_text())["jobs"]
        status = router["ios-fast-status"]
        self.assertEqual(status["needs"], ["route", "pipeline"])
        self.assertIn("needs.route.outputs.ios_status == 'pending'", status["if"])
        self.assertEqual(status["permissions"]["statuses"], "write")
        self.assertIn("scripts/ci/ios_fast_verdict.py", router["route"]["steps"][0]["with"]["sparse-checkout"])
        post = next(s for s in router["route"]["steps"] if s.get("name") == "Post the iOS fast verdict status")
        self.assertIn("ios_fast_verdict.py status", post["run"])

    def test_the_runner_script_parses(self) -> None:
        subprocess.run(["bash", "-n", str(ROOT / "scripts/ci/ios_fast_verdict.sh")], check=True)


if __name__ == "__main__":
    unittest.main()
