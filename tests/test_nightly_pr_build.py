#!/usr/bin/env python3
"""scripts/ci/nightly_pr_build.py and .github/workflows/nightly-pr-build.yml: the NIGHTLY's own app
compile and Rust helper builds on a pull request.

Holds: each helper is checked with the features and profile its Nightly build script passes; the route
sends a package or helper change to its build and a docs or test change to neither; the input keys
differ by arch and are stable; the Swift job runs check-release-compile.sh with --nightly as a fleet job.
"""

from __future__ import annotations

import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))

import nightly_pr_build as npb  # noqa: E402
import pr_router  # noqa: E402


class HelpersMatchBuildScripts(unittest.TestCase):
    def test_each_helper_matches_its_build_script(self) -> None:
        for helper in npb.HELPERS:
            with self.subTest(helper=helper["name"]):
                script = (ROOT / helper["script"]).read_text()
                self.assertTrue((ROOT / helper["dir"] / "Cargo.toml").is_file(), helper["dir"])
                for name, value in helper["profile"].items():
                    self.assertIn(f"{name}={value}", script)
                profile = re.search(r"^size_profile=\(([^)]*)\)", script, re.M)
                if profile:
                    self.assertEqual(sorted(profile.group(1).split()),
                                     sorted(f"{k}={v}" for k, v in helper["profile"].items()))
                args = helper["args"]
                if "--features" in args:
                    features = args[args.index("--features") + 1]
                    self.assertIn(f'features="{features}"', script)
                    self.assertIn('--features "$features"', script)
                for flag in ("--bin", "--package"):
                    if flag in args:
                        self.assertIn(f"{flag} {args[args.index(flag) + 1]}", script)
                if "--no-default-features" in args:
                    self.assertIn("--no-default-features", script)


class Route(unittest.TestCase):
    def test_package_source_routes_swift_only(self) -> None:
        self.assertEqual(npb.route(["Packages/macOS/CmuxNext/Sources/CmuxNext/App.swift"]),
                         {"swift": True, "helpers": False})

    def test_helper_crate_routes_helpers_only(self) -> None:
        self.assertEqual(npb.route(["cmux-tui/crates/cmux-rd-host/src/main.rs"]),
                         {"swift": False, "helpers": True})

    def test_tests_and_docs_route_nothing(self) -> None:
        self.assertEqual(npb.route(["docs/ci/landing.md", "Packages/macOS/CmuxNext/Tests/X/YTests.swift"]),
                         {"swift": False, "helpers": False})

    def test_own_files_route_both(self) -> None:
        self.assertEqual(npb.route([npb.WORKFLOW]), {"swift": True, "helpers": True})
        self.assertEqual(npb.route(["scripts/ci/nightly_pr_build.py"]), {"swift": True, "helpers": True})

    def test_landing_routes_changed_inputs_without_the_full_tier(self) -> None:
        name = "nightly-pr-build.yml"
        callees = pr_router.load_manifest()
        repo = {"full_name": "manaflow-ai/cmux"}
        pr = {"draft": False, "head": {"repo": repo}, "base": {"ref": "feat-cmux-next", "repo": repo},
              "labels": [{"name": "ready-to-land"}]}
        for action in ("synchronize", "labeled"):
            event = {"action": action, "label": {"name": "ready-to-land"}, "pull_request": pr}
            tier = pr_router.head_tier.tier("pull_request", event, land_switch="1", land_full_switch="0")
            self.assertTrue(pr_router.head_tier.land_affected(tier))
            for path, expected in ((npb.WORKFLOW, True), ("Packages/macOS/CmuxNext/Sources/X.swift", True),
                                   ("docs/readme.md", False)):
                with self.subTest(action=action, path=path):
                    start, _ = pr_router.route(event, callees, [path], decided=tier)
                    self.assertEqual(name in start, expected)
        for changes in ({"draft": True}, {"labels": []}):
            event = {"action": "synchronize", "pull_request": {**pr, **changes}}
            tier = pr_router.head_tier.tier("pull_request", event, land_switch="1", land_full_switch="0")
            start, _ = pr_router.route(event, callees, [npb.WORKFLOW], decided=tier)
            self.assertNotIn(name, start)

    def test_outer_router_admits_compile_and_helper_inputs(self) -> None:
        config = pr_router.load_manifest()["nightly-pr-build.yml"]
        for root in npb.HELPER_INPUTS:
            path = root + "/action.yml" if (ROOT / root).is_dir() else root
            self.assertTrue(npb.route([path])["helpers"], path)
            self.assertTrue(pr_router.matches_filter(config, [path]) and pr_router.affects(config, [path]), path)
        for pattern in (*npb.SWIFT_INPUTS, *npb.job_input_fingerprint.route.MAC_RELEASE_INPUTS):
            path = pattern.replace("*", "Example")
            self.assertTrue(npb.route([path])["swift"], path)
            self.assertTrue(pr_router.matches_filter(config, [path]) and pr_router.affects(config, [path]), path)


class Keys(unittest.TestCase):
    def test_keys_differ_by_arch_and_are_stable(self) -> None:
        first = npb.keys("HEAD")
        self.assertEqual(sorted(first), sorted([*npb.ARCHS, "helpers"]))
        self.assertNotEqual(first["arm64"], first["x86_64"])
        self.assertEqual(first, npb.keys("HEAD"))

    def test_source_head_can_predate_the_merge_ref_recipe(self) -> None:
        # Keep this fixture independent of the checkout depth. The source commit has neither the
        # reusable workflow nor the driver, while the merge-ref recipe adds both.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for args in (("git", "init", "-q"), ("git", "config", "user.email", "test@example.com"),
                         ("git", "config", "user.name", "Nightly test")):
                subprocess.run([*args, str(root)] if args[1] == "init" else [*args], cwd=root,
                               check=True, capture_output=True)
            (root / "README").write_text("source\n")
            subprocess.run(["git", "add", "README"], cwd=root, check=True, capture_output=True)
            subprocess.run(["git", "commit", "-qm", "source"], cwd=root, check=True, capture_output=True)
            source = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
            (root / ".github/workflows").mkdir(parents=True)
            (root / "scripts/ci").mkdir(parents=True)
            (root / ".github/workflows/nightly-pr-build.yml").write_text("on: workflow_call\n")
            (root / "scripts/ci/nightly_pr_build.py").write_text("# trusted recipe\n")
            subprocess.run(["git", "add", "."], cwd=root, check=True, capture_output=True)
            subprocess.run(["git", "commit", "-qm", "recipe"], cwd=root, check=True, capture_output=True)
            recipe = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
            keys = npb.keys(source, root, recipe_rev=recipe)
        self.assertEqual(sorted(keys), sorted([*npb.ARCHS, "helpers"]))
        self.assertTrue(all(keys.values()))


class Workflow(unittest.TestCase):
    def test_swift_job_is_the_nightly_compile_as_a_fleet_job(self) -> None:
        text = (ROOT / npb.WORKFLOW).read_text()
        self.assertIn("--script scripts/cmux-next/check-release-compile.sh", text)
        self.assertIn("--arg=--nightly", text)
        self.assertIn("arch: [arm64, x86_64]", text)
        self.assertEqual(sorted(npb.ARCHS), ["arm64", "x86_64"])
        # The gateway runner refuses any job whose id does not end in -fleet.
        gateway = re.findall(r"^  ([a-z0-9_-]+):\n(?:    .*\n)*?    runs-on: \$\{\{ vars.CI_EVAL_STEP_GATEWAY", text, re.M)
        self.assertTrue(gateway)
        for job in gateway:
            self.assertTrue(job.endswith("-fleet"), job)
        self.assertIn("69|75|124)", text)
        for name in re.findall(r"^    name: (.*)$", text, re.M):
            self.assertIn("(advisory)", name)

    def test_release_compile_nightly_applies_size_opt(self) -> None:
        text = (ROOT / "scripts/cmux-next/check-release-compile.sh").read_text()
        self.assertIn("swift-size-opt.sh", text)
        self.assertIn("nightly-swift-defines.sh", text)

    def test_gateway_job_keeps_the_runner_fallback_reachable(self) -> None:
        text = (ROOT / npb.WORKFLOW).read_text()
        match = re.search(r"(?ms)^  swift-fleet:\n(.*?)(?=^  [A-Za-z0-9_-]+:\n|\Z)", text)
        self.assertIsNotNone(match)
        self.assertIn("if: ${{ needs.route.outputs.swift == 'true' }}", match.group(1))
        self.assertIn("vars.CI_EVAL_STEP_GATEWAY || vars.CI_OVERFLOW_LINUX || 'cmux-linux'", match.group(1))

    def test_queue_wait_is_bounded_and_an_unstarted_step_is_cancelled(self) -> None:
        # Leo, 2026-11-25: "Ok well we can't be letting important rfds like that take breaks unless I put in
        # fleet wide pauses, esp when this is stuff that materially improves the app". A 3600 s queue wait held a
        # Mac mini gateway runner for an hour per arch and gave no verdict (36 of 102 jobs, 2026-11-27).
        text = (ROOT / npb.WORKFLOW).read_text()
        match = re.search(r'QUEUE_WAIT_S: "(\d+)"', text)
        self.assertIsNotNone(match)
        self.assertLessEqual(int(match.group(1)), 1200)
        self.assertIn('--queue-timeout "$QUEUE_WAIT_S"', text)
        self.assertNotRegex(text, r"--queue-timeout [0-9]{4,}")
        self.assertIn('"$client" cancel "$step"', text)
        timeout = re.search(r"(?ms)^  swift-fleet:\n.*?timeout-minutes: (\d+)", text)
        self.assertIsNotNone(timeout)
        self.assertLessEqual(int(timeout.group(1)), 90)

    def test_swift_job_detaches_and_the_fleet_posts_the_verdict(self) -> None:
        # Leo, 2026-11-27: "de facto, im asking for 99% fewer minutes of ci time, period." The job held a runner
        # ~20 min per arch while its step sat queued (run 46030977376 job 140614747339), ~20k runner-min/day.
        text = (ROOT / npb.WORKFLOW).read_text()
        self.assertIn("DETACH: ${{ vars.CI_NIGHTLY_PR_BUILD_DETACH || '1' }}", text)
        self.assertIn('detach=(--report-check "$REPORT_CHECK" --detach)', text)
        self.assertIn('${detach[@]+"${detach[@]}"}', text)  # empty-array safe under set -u on macOS bash 3.2
        name = re.search(r"REPORT_CHECK: (.*)$", text, re.M)
        self.assertIsNotNone(name)
        self.assertIn("(advisory)", name.group(1))
        # report_check.go reportCheckName, with the matrix expression standing in for the arch.
        self.assertRegex(name.group(1).replace("${{ matrix.arch }}", "arm64"), r"^[A-Za-z0-9][A-Za-z0-9 ._()/:+-]{0,99}$")


if __name__ == "__main__":
    unittest.main()
