#!/usr/bin/env python3
"""scripts/ci/nightly_pr_build.py and .github/workflows/nightly-pr-build.yml: the NIGHTLY's own app
compile and Rust helper builds on a pull request.

Holds: each helper is checked with the features and profile its Nightly build script passes; the route
sends a package or helper change to its build and a docs or test change to neither; the input keys
differ by arch and are stable; the Swift job runs check-release-compile.sh with --nightly as a fleet job.
"""

from __future__ import annotations

import re
import sys
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


if __name__ == "__main__":
    unittest.main()
