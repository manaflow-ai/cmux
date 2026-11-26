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
        for name in re.findall(r"^    name: (.*)$", text, re.M):
            self.assertIn("(advisory)", name)

    def test_release_compile_nightly_applies_size_opt(self) -> None:
        text = (ROOT / "scripts/cmux-next/check-release-compile.sh").read_text()
        self.assertIn("swift-size-opt.sh", text)
        self.assertIn("nightly-swift-defines.sh", text)


if __name__ == "__main__":
    unittest.main()
