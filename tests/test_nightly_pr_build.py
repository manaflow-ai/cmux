#!/usr/bin/env python3
"""scripts/ci/nightly_pr_build.py and .github/workflows/nightly-pr-build.yml: the NIGHTLY's own app
compile and Rust helper builds on a pull request.

Holds: each helper is checked with the features and profile its Nightly build script passes; the route
sends a package or helper change to its build and a docs or test change to neither; the input keys
differ by arch and are stable; the Swift job runs check-release-compile.sh with --nightly as a fleet job.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
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

    def test_trunk_only_starts_on_no_pull_request_unless_per_pr(self) -> None:
        # The tip's coalesced push runs it; no PR head starts it (land's ask, the train's tip) unless the switch is 1.
        name = "nightly-pr-build.yml"
        callees = pr_router.load_manifest()
        self.assertTrue(callees[name].get("trunk_only"))
        repo = {"full_name": "manaflow-ai/cmux"}
        pr = {"draft": False, "head": {"repo": repo}, "base": {"ref": "feat-cmux-next", "repo": repo},
              "labels": [{"name": "ready-to-land"}]}
        tip = {**pr, "head": {"repo": repo, "ref": pr_router.TRAIN_TIP}}
        for event in ({"action": "labeled", "label": {"name": "ready-to-land"}, "pull_request": pr},
                      {"action": "labeled", "label": {"name": "full-ci"}, "pull_request": pr},
                      {"action": "synchronize", "pull_request": tip},
                      {"action": "opened", "pull_request": {**pr, "labels": []}}):
            tier = pr_router.head_tier.tier("pull_request", event, land_switch="1", land_full_switch="0")
            for per_pr, at_land in (("0", "1"), ("", "0"), ("1", "1")):
                env = {"CI_NIGHTLY_PR_BUILD_AT_LAND": at_land}
                if per_pr:
                    env["CI_NIGHTLY_PR_BUILD_PER_PR"] = per_pr
                with self.subTest(action=event["action"], per_pr=per_pr), mock.patch.dict(os.environ, env):
                    if not per_pr:
                        os.environ.pop("CI_NIGHTLY_PR_BUILD_PER_PR", None)
                    start, why = pr_router.route(event, callees, [npb.WORKFLOW], decided=tier)
                    if per_pr != "1":
                        self.assertNotIn(name, start)
                        self.assertIn("trunk only", why[name])
        router = (ROOT / ".github/workflows/pr-router.yml").read_text()
        self.assertIn("CI_NIGHTLY_PR_BUILD_PER_PR: ${{ vars.CI_NIGHTLY_PR_BUILD_PER_PR || '0' }}", router)

    def test_tip_push_runs_once_per_window_from_the_last_tested_tip(self) -> None:
        text = (ROOT / npb.WORKFLOW).read_text()
        self.assertRegex(text, r"on:\n  push:\n    branches: \[feat-cmux-next\]\n  workflow_call:")
        coalesce = re.search(r"^  coalesce:\n((?:    .*\n|\n)*?)(?=^  [a-z])", text, re.M).group(1)
        self.assertIn("uses: ./.github/workflows/base-coalesce.yml", coalesce)
        self.assertIn("key: nightly-pr-build", coalesce)
        self.assertIn("hold_minutes: 30", coalesce)
        self.assertIn("vars.CI_NIGHTLY_PR_BUILD_COALESCE", coalesce)
        route = re.search(r"^  route:\n((?:    .*\n|\n)*?)(?=^  [a-z#])", text, re.M).group(1)
        self.assertIn("needs: [coalesce]", route)
        self.assertIn("needs.coalesce.outputs.run != 'false'", route)
        self.assertIn("needs.coalesce.outputs.base", route)
        # A tip push builds and reports on its own sha; no step reads only the pull request's head.
        self.assertNotRegex(text, r"github\.event\.pull_request\.head\.sha \}\}")

    def test_landing_routes_changed_inputs_without_the_full_tier(self) -> None:
        name = "nightly-pr-build.yml"
        # The per-PR path (CI_NIGHTLY_PR_BUILD_PER_PR=1) keeps the land-ask rule below.
        patch = mock.patch.dict(os.environ, {"CI_NIGHTLY_PR_BUILD_PER_PR": "1"})
        patch.start()
        self.addCleanup(patch.stop)
        callees = pr_router.load_manifest()
        repo = {"full_name": "manaflow-ai/cmux"}
        pr = {"draft": False, "head": {"repo": repo}, "base": {"ref": "feat-cmux-next", "repo": repo},
              "labels": [{"name": "ready-to-land"}]}
        # The land handoff starts it; a push of a labelled PR waits for land's ask unless the switch is 0.
        for action, at_land, starts in (("labeled", "1", True), ("synchronize", "1", False),
                                        ("labeled", "0", True), ("synchronize", "0", True)):
            event = {"action": action, "label": {"name": "ready-to-land"}, "pull_request": pr}
            tier = pr_router.head_tier.tier("pull_request", event, land_switch="1", land_full_switch="0")
            self.assertTrue(pr_router.head_tier.land_affected(tier))
            for path, expected in ((npb.WORKFLOW, starts), ("Packages/macOS/CmuxNext/Sources/X.swift", starts),
                                   ("docs/readme.md", False)):
                with self.subTest(action=action, at_land=at_land, path=path), \
                        mock.patch.dict(os.environ, {"CI_NIGHTLY_PR_BUILD_AT_LAND": at_land}):
                    start, why = pr_router.route(event, callees, [path], decided=tier)
                    self.assertEqual(name in start, expected, why[name])
        # full-ci (a lane VM's handoff pulse) is land's ask too; the merge train's tip builds on its push.
        event = {"action": "labeled", "label": {"name": "full-ci"}, "pull_request": pr}
        tier = pr_router.head_tier.tier("pull_request", event, land_switch="1", land_full_switch="0")
        self.assertIn(name, pr_router.route(event, callees, [npb.WORKFLOW], decided=tier)[0])
        tip = {**pr, "head": {"repo": repo, "ref": pr_router.TRAIN_TIP}}
        event = {"action": "synchronize", "pull_request": tip}
        tier = pr_router.head_tier.tier("pull_request", event, land_switch="1", land_full_switch="0")
        if pr_router.head_tier.land_affected(tier):
            self.assertIn(name, pr_router.route(event, callees, [npb.WORKFLOW], decided=tier)[0])
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


class Record(unittest.TestCase):
    """A detached compile's green verdict saves the key the compile job looks up (#62619 stopped saving it)."""

    def test_recorder_saves_the_lookup_key_on_a_green_verdict(self) -> None:
        record = (ROOT / ".github/workflows/nightly-pr-build-record.yml").read_text()
        compile_job = (ROOT / npb.WORKFLOW).read_text()
        self.assertIn("check_run:", record)
        self.assertIn("conclusion == 'success'", record)
        self.assertIn("CI_NIGHTLY_PR_BUILD_RECORD", record)
        # Same cache path and key function as the compile job's lookup and its wait-mode save.
        self.assertIn("path: ${{ runner.temp }}/nightly-pr-build-pass", record)
        self.assertIn("nightly_pr_build.py keys", record)
        self.assertIn("nightly_pr_build.py keys", compile_job)
        name = re.search(r"REPORT_CHECK: (.*)", compile_job).group(1).replace("${{ matrix.arch }}", "ARCH")
        self.assertTrue(name.startswith("nightly app compile ") and name.endswith(" fleet verdict (advisory)"))
        self.assertIn("startsWith(github.event.check_run.name, 'nightly app compile ')", record)
        self.assertIn("' fleet verdict (advisory)'", record)

    def test_recorder_key_matches_the_compile_job_key(self) -> None:
        key = npb.keys("HEAD")["arm64"]
        self.assertTrue(key.startswith("nightly-pr-build-arm64-"))
        self.assertEqual(key, json.loads(subprocess.check_output(
            [sys.executable, str(ROOT / "scripts/ci/nightly_pr_build.py"), "keys", "--rev", "HEAD"],
            text=True, cwd=ROOT).split("keys=", 1)[1])["arm64"])


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
        # One arch's red cancels the other arch's wait (the reds are arch-independent).
        self.assertIn("fail-fast: true", text)
        # A cancelled arch cancels its fleet step too, so it does not build for nobody.
        self.assertIn(
            "if: ${{ cancelled() && steps.cache.outputs.cache-hit != 'true' && steps.verdict.outputs.passed != 'true' }}", text
        )
        self.assertIn('"$client" cancel "$step" --reason "nightly pr build: job cancelled"', text)
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


    def test_a_head_whose_fleet_verdict_passed_is_not_compiled_again(self) -> None:
        # Leo, 2026-11-27: "we should probably just get these cuts in asap and stuff". A detached run never
        # records the input-key pass, so a ready-to-land or full-ci re-run on the same head compiled it again:
        # 17 of 74 head-arch pairs, 392 of 1,468 job-min (20:05-21:34Z). A success verdict is the pass.
        text = (ROOT / npb.WORKFLOW).read_text()
        job = text.split("\n  swift-fleet:\n", 1)[1].split("\n  helpers:\n", 1)[0]
        self.assertIn("    permissions:\n      checks: read\n", job)
        self.assertIn("/commits/$SHA/check-runs?check_name=$name&filter=all", job)
        self.assertIn('r.get("conclusion") == "success"', job)
        verdict = job.index("id: verdict")
        compile_ = job.index("id: compile")
        self.assertLess(verdict, compile_)
        self.assertIn(
            "if: ${{ steps.cache.outputs.cache-hit != 'true' && steps.verdict.outputs.passed != 'true' }}", job
        )
        self.assertIn("if: ${{ steps.compile.outputs.passed == 'true' || steps.verdict.outputs.passed == 'true' }}", job)
        # The caller grants what the callee asks for (check_reusable_workflow_permissions.py).
        router = (ROOT / ".github/workflows/pr-router.yml").read_text()
        caller = router.split("\n  nightly-pr-build:\n", 1)[1].split("\n\n", 1)[0]
        self.assertIn("      checks: read", caller)

if __name__ == "__main__":
    unittest.main()
