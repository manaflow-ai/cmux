#!/usr/bin/env python3
"""scripts/ci/nightly_pr_build.py and .github/workflows/nightly-pr-build.yml: the NIGHTLY's own app
compile and Rust helper builds on a pull request.

Holds: each helper is checked with the features and profile its Nightly build script passes; the route
sends a package or helper change to its build and a docs or test change to neither; the input keys
differ by arch and are stable; the Swift job runs check-release-compile.sh with --nightly as a fleet job.
"""

from __future__ import annotations

import os
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



class BaseRed(unittest.TestCase):
    """A red the head only repeats from the base is not built again (2026-11-27: 49 of 99 reds were one base error)."""

    DIAG = ("/Library/Application Support/cmux-build-worker/work/steps/3c0d/src/Packages/macOS/CmuxNext/Sources/"
            "CmuxNextSettings/Schema/SettingDescriptor+Palette.swift:37:38: error: main actor-isolated static "
            "property 'curatedThemes' can not be referenced from a nonisolated context\n")
    FILE = "Packages/macOS/CmuxNext/Sources/CmuxNextSettings/Schema/SettingDescriptor+Palette.swift"
    NOW = npb.dt.datetime(2026, 11, 27, 12, 0, tzinfo=npb.dt.timezone.utc)

    H1, B1, H2, H3 = ("1" * 40, "b" * 40, "2" * 40, "3" * 40)

    def red(self, **extra):
        return {"verdict": "red", "head": self.H1, "base": self.B1, "job": "https://x/runs/1", "diagnostics": self.DIAG,
                "created_at": "2026-11-27T11:00:00Z", **extra}

    def blobs(self, table):
        return lambda rev, paths: {p: table.get(rev, "same") for p in paths}

    def test_failing_files_are_repo_paths(self) -> None:
        self.assertEqual(npb.failing_files(self.DIAG + "warning: x.swift:1:1: warning: w\n"), [self.FILE])

    def test_same_files_at_red_head_base_and_this_head_skip(self) -> None:
        self.assertEqual(npb.decide_base_red(self.red(), [], self.H2, self.blobs({}), self.NOW), "https://x/runs/1")

    def test_head_that_caused_it_or_changed_the_file_builds(self) -> None:
        self.assertIsNone(npb.decide_base_red(self.red(), [], self.H2, self.blobs({self.B1: "old"}), self.NOW))
        self.assertIsNone(npb.decide_base_red(self.red(), [], self.H2, self.blobs({self.H2: "edited"}), self.NOW))

    def test_a_later_pass_with_the_same_files_builds(self) -> None:
        later = [{"head": self.H3, "created_at": "2026-11-27T11:30:00Z"}]
        self.assertIsNone(npb.decide_base_red(self.red(), later, self.H2, self.blobs({}), self.NOW))
        # A pass on an older base (other blobs) says nothing about this red.
        self.assertIsNotNone(npb.decide_base_red(self.red(), later, self.H2, self.blobs({self.H3: "older"}), self.NOW))

    def test_old_or_non_swift_red_builds(self) -> None:
        old = self.red(created_at="2026-11-27T05:00:00Z")
        self.assertIsNone(npb.decide_base_red(old, [], self.H2, self.blobs({}), self.NOW))
        self.assertIsNone(npb.decide_base_red(self.red(diagnostics="cmux-ci: source depot full"), [], self.H2,
                                              self.blobs({}), self.NOW))

    def test_fork_runs_and_bad_ids_are_not_read(self) -> None:
        run = {"repository_id": 1, "head_repository_id": 1, "head_sha": self.H1}
        self.assertTrue(npb.trusted({"workflow_run": run}))
        self.assertFalse(npb.trusted({"workflow_run": {**run, "head_repository_id": 2}}))
        self.assertFalse(npb.trusted({"workflow_run": {**run, "head_sha": "--upload-pack=x"}}))
        self.assertIsNone(npb.decide_base_red(self.red(base="--upload-pack=x"), [], self.H2, self.blobs({}), self.NOW))

    def test_audit_share_is_about_ten_percent(self) -> None:
        share = sum(npb.audited(str(run), "1") for run in range(2000)) / 2000
        self.assertTrue(0.06 < share < 0.14, share)

    def test_workflow_wires_the_skip_and_the_verdicts(self) -> None:
        text = (ROOT / npb.WORKFLOW).read_text()
        self.assertIn("swift: ${{ !steps.basered.outputs.base_red && steps.route.outputs.swift || 'false' }}", text)
        self.assertIn("nightly_pr_build.py base-red --rev", text)
        self.assertIn("actions: read", text)
        self.assertIn(f"name=" + npb.RED_ARTIFACT, text)
        self.assertIn(f"name=" + npb.PASS_ARTIFACT, text)
        self.assertIn("name: ${{ steps.verdict.outputs.name }}-${{ matrix.arch }}", text)
        # The fleet refusing the step for its own disk is no verdict, not a red on the head.
        self.assertIn("failed on no worker: invalid ci-step: source depot full' \"$log\"", text)
        self.assertIn("continue-on-error: true  # past its time it builds", text)
        self.assertEqual(text.count("continue-on-error: true  # best effort: never changes the compile's verdict"), 2)
        self.assertIn("ADDED_LABEL: ${{ github.event.label.name }}", text)
        router = (ROOT / ".github/workflows/pr-router.yml").read_text()
        self.assertRegex(router, r"uses: ./.github/workflows/nightly-pr-build.yml\n    permissions:\n"
                                 r"      contents: read\n      actions: read")

    def test_read_failure_fails_open(self) -> None:
        env = {**os.environ, "GITHUB_REPOSITORY": "o/r", "GH_TOKEN": "x", "GITHUB_API_URL": "http://127.0.0.1:9",
               "GITHUB_RUN_ID": "1", "GITHUB_RUN_ATTEMPT": "1"}  # run 1 is no audit
        out = subprocess.run([sys.executable, str(ROOT / "scripts/ci/nightly_pr_build.py"), "base-red", "--rev", "a",
                              "--base-tip", "b"], env=env, capture_output=True, text=True, timeout=60)
        self.assertEqual(out.returncode, 0)
        self.assertEqual(out.stdout, "")


if __name__ == "__main__":
    unittest.main()
