#!/usr/bin/env python3
"""Behavior of the cmux-next INTERNAL iOS TestFlight builder's decision logic.

scripts/ci/ios_internal_builder.py decides when a feat-cmux-next head ships to
cmux INTERNAL, stamps the build number, and admits jobs on the dedicated
runner. Design: plans/cmux-next/ios-testflight-builder-DESIGN.md.
"""
from __future__ import annotations

import datetime as dt
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("ios_internal_builder", ROOT / "scripts/ci/ios_internal_builder.py")
ib = importlib.util.module_from_spec(SPEC)
sys.modules["ios_internal_builder"] = ib
SPEC.loader.exec_module(ib)

UTC = dt.timezone.utc
NOW = dt.datetime(2026, 10, 20, 9, 30, 15, tzinfo=UTC)
A = "a" * 40
B = "b" * 40
C = "c" * 40

PACKAGE_SWIFT = """
let package = Package(
    dependencies: [
        .package(path: "../../Packages/Shared/CmuxGhosttyKit"),
        .package(path: "../../Packages/iOS/CmuxTabsKit"),
        .package(path: "../../vendor/stack-auth-swift-sdk-prerelease"),
    ],
    targets: [.binaryTarget(name: "CmuxMobileLinkFFIFFI", path: "Frameworks/CmuxMobileLinkFFI.xcframework")]
)
"""


def run(sha, conclusion="success", status="completed", minutes_ago=60, run_id=1):
    created = (NOW - dt.timedelta(minutes=minutes_ago)).isoformat().replace("+00:00", "Z")
    return {"id": run_id, "sha": sha, "status": status, "conclusion": conclusion, "created_at": created}


class BuildNumberTests(unittest.TestCase):
    def test_is_the_utc_timestamp(self):
        self.assertEqual(ib.next_build_number(NOW, None), "20261020093015")

    def test_steps_past_a_newer_or_equal_last_build(self):
        self.assertEqual(ib.next_build_number(NOW, "20261020093015"), "20261020093016")
        self.assertEqual(ib.next_build_number(NOW, "20991231235959"), "20991231235960")

    def test_ignores_an_older_last_build(self):
        self.assertEqual(ib.next_build_number(NOW, "20261019000000"), "20261020093015")

    def test_rejects_a_non_numeric_last_build(self):
        with self.assertRaises(ValueError):
            ib.next_build_number(NOW, "1.2.3")


class MarketingVersionTests(unittest.TestCase):
    def test_reads_project_yml(self):
        text = "settings:\n  base:\n    MARKETING_VERSION: 1.2.0\n    CURRENT_PROJECT_VERSION: 1\n"
        self.assertEqual(ib.marketing_version(text), "1.2.0")

    def test_missing_or_malformed_is_an_error(self):
        with self.assertRaises(ValueError):
            ib.marketing_version("settings: {}\n")
        with self.assertRaises(ValueError):
            ib.marketing_version("    MARKETING_VERSION: $(VERSION)\n")


class RelevantPathTests(unittest.TestCase):
    def test_package_paths_come_from_cmux_mobile_kit(self):
        self.assertEqual(
            ib.package_paths(PACKAGE_SWIFT),
            ["Packages/Shared/CmuxGhosttyKit/", "Packages/iOS/CmuxTabsKit/", "vendor/stack-auth-swift-sdk-prerelease/"],
        )

    def test_ios_changes_are_relevant(self):
        prefixes = ib.relevant_prefixes(PACKAGE_SWIFT)
        for path in ("cmux-next-ios/App/RootView.swift", "Packages/iOS/CmuxTabsKit/Sources/X.swift",
                     "cmux-tui/crates/cmux-wg/src/lib.rs", ".github/workflows/ios-internal-nightly.yml",
                     "scripts/ci/ios_internal_builder.py", "Packages/Shared/CmuxGhosttyKit/Package.swift"):
            self.assertTrue(ib.touches_ios([path], prefixes), path)

    def test_mac_only_changes_are_not(self):
        prefixes = ib.relevant_prefixes(PACKAGE_SWIFT)
        self.assertFalse(ib.touches_ios(["Sources/App/AppDelegate.swift", "cmux-tui/src/cli.rs",
                                         "Packages/macOS/CmuxSettings/x.swift", "ios/cmux/Old.swift"], prefixes))


class PlanTests(unittest.TestCase):
    def plan(self, **kw):
        args = dict(head=C, runs=[run(A)], changed=["cmux-next-ios/App/A.swift"], has_cmux_next_ios=True, now=NOW,
                    prefixes=ib.relevant_prefixes(PACKAGE_SWIFT))
        args.update(kw)
        return ib.plan(**args)

    def test_builds_an_ios_change_since_the_last_upload(self):
        decision = self.plan()
        self.assertTrue(decision.build, decision.reason)
        self.assertEqual(decision.base, A)

    def test_first_build_when_nothing_was_uploaded(self):
        decision = self.plan(runs=[], changed=None)
        self.assertTrue(decision.build, decision.reason)
        self.assertIsNone(decision.base)

    def test_skips_until_cmux_next_ios_is_on_the_branch(self):
        decision = self.plan(has_cmux_next_ios=False)
        self.assertFalse(decision.build)
        self.assertIn("cmux-next-ios", decision.reason)

    def test_skips_while_the_signing_branch_predates_the_rename(self):
        decision = self.plan(builder_ready=False)
        self.assertFalse(decision.build)
        self.assertIn("fast-forwards", decision.reason)
        self.assertEqual(decision.base, A)

    def test_skips_the_head_already_uploaded(self):
        decision = self.plan(runs=[run(C)])
        self.assertFalse(decision.build)

    def test_skips_mac_only_changes_while_the_last_upload_is_fresh(self):
        decision = self.plan(changed=["Sources/App/AppDelegate.swift"], runs=[run(A, minutes_ago=60)])
        self.assertFalse(decision.build)

    def test_periodic_fallback_ships_any_change_after_twelve_hours(self):
        decision = self.plan(changed=["Sources/App/AppDelegate.swift"], runs=[run(A, minutes_ago=12 * 60 + 1)])
        self.assertTrue(decision.build, decision.reason)
        self.assertIn("fallback", decision.reason)

    def test_unknown_diff_fails_open(self):
        decision = self.plan(changed=None)
        self.assertTrue(decision.build, decision.reason)

    def test_does_not_queue_behind_the_same_head(self):
        decision = self.plan(runs=[run(C, status="queued", conclusion=None, minutes_ago=2, run_id=3), run(A, run_id=2)])
        self.assertFalse(decision.build)

    def test_a_newer_head_replaces_the_pending_one(self):
        decision = self.plan(runs=[run(B, status="in_progress", conclusion=None, minutes_ago=5, run_id=3), run(A, run_id=2)])
        self.assertTrue(decision.build, decision.reason)

    def test_does_not_retry_a_failed_head(self):
        decision = self.plan(runs=[run(C, conclusion="failure", minutes_ago=30, run_id=3), run(A, run_id=2)])
        self.assertFalse(decision.build)

    def test_retries_a_failed_head_after_the_fallback_interval(self):
        decision = self.plan(runs=[run(C, conclusion="failure", minutes_ago=12 * 60 + 1, run_id=3),
                                   run(A, minutes_ago=13 * 60, run_id=2)])
        self.assertTrue(decision.build, decision.reason)

    def test_cancelled_runs_do_not_count(self):
        decision = self.plan(runs=[run(C, conclusion="cancelled", minutes_ago=30, run_id=3), run(A, run_id=2)])
        self.assertTrue(decision.build, decision.reason)

    def test_base_is_the_newest_success(self):
        decision = self.plan(runs=[run(B, conclusion="failure", run_id=3), run(A, minutes_ago=120, run_id=2)])
        self.assertEqual(decision.base, A)


class AdmitTests(unittest.TestCase):
    def env(self, **kw):
        env = {
            "GITHUB_REPOSITORY": "manaflow-ai/cmux",
            "GITHUB_WORKFLOW_REF": "manaflow-ai/cmux/.github/workflows/ios-internal-nightly.yml@refs/heads/rc/cnx-ios-builder",
            "GITHUB_JOB": "archive",
            "GITHUB_EVENT_NAME": "workflow_dispatch",
            "GITHUB_REF": "refs/heads/rc/cnx-ios-builder",
        }
        env.update(kw)
        return env

    def test_admits_the_archive_job(self):
        ok, reason = ib.admit(self.env(), 100 * 1024 ** 3)
        self.assertTrue(ok, reason)

    def test_refuses_everything_else(self):
        for change in ({"GITHUB_REPOSITORY": "someone/fork"},
                       {"GITHUB_WORKFLOW_REF": "manaflow-ai/cmux/.github/workflows/nightly.yml@refs/heads/nightly-next"},
                       {"GITHUB_JOB": "upload"},
                       {"GITHUB_EVENT_NAME": "pull_request"},
                       {"GITHUB_REF": "refs/heads/feat-cmux-next"}):
            ok, _ = ib.admit(self.env(**change), 100 * 1024 ** 3)
            self.assertFalse(ok, change)

    def test_refuses_on_low_disk(self):
        ok, reason = ib.admit(self.env(), 10 * 1024 ** 3)
        self.assertFalse(ok)
        self.assertIn("GiB", reason)


class PruneTests(unittest.TestCase):
    """cmux23 fell to 39.9 GiB free on 2026-10-22 (run 39731717858) and refused every archive job."""

    def setUp(self):
        import tempfile
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(__import__("shutil").rmtree, self.tmp, True)
        self.root = self.tmp / "cmux-mobile-builds"
        self.legacy = self.tmp / "cnx-ios-builds"
        for name, value in (("BUILDS_ROOT", self.root), ("LEGACY_ROOTS", (self.legacy,)),
                            ("RUNNER_DIR", self.tmp / "runner")):
            patcher = mock.patch.object(ib, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)

    def make(self, rel, age_s=0, now=1_000_000.0):
        path = self.root / rel
        path.mkdir(parents=True, exist_ok=True)
        os.utime(path, (now - age_s, now - age_s))
        return path

    def test_keeps_only_the_newest_build_folders(self):
        for i in range(ib.KEEP_OUTPUTS + 2):
            self.make(f"2026102{i}-abc-testflight", age_s=3600 * (10 - i))
        cache = self.make(".cache/spm")
        ib._prune(1_000_000.0)
        left = sorted(p.name for p in self.root.iterdir() if not p.name.startswith("."))
        self.assertEqual(len(left), ib.KEEP_OUTPUTS)
        self.assertNotIn("20261020-abc-testflight", left)
        self.assertTrue(cache.is_dir())

    def test_pressure_trim_removes_legacy_root_work_old_xcframeworks_and_cargo_target(self):
        (self.legacy / ".cache").mkdir(parents=True)
        self.make(".work/20261021-dead-testflight/dd")
        for i in range(ib.KEEP_XCFRAMEWORKS + 2):
            self.make(f".cache/xcframework/key{i}", age_s=100 * (10 - i))
        self.make(".cache/cmux-mobile-rust-target/release")
        spm = self.make(".cache/spm/checkouts")
        output = self.make("20261022-abc-testflight")
        ib.prune_caches()
        self.assertFalse(self.legacy.exists())
        self.assertEqual(list((self.root / ".work").iterdir()), [])
        keys = sorted(p.name for p in (self.root / ".cache/xcframework").iterdir())
        self.assertEqual(keys, [f"key{i}" for i in range(2, ib.KEEP_XCFRAMEWORKS + 2)])
        self.assertFalse((self.root / ".cache/cmux-mobile-rust-target").exists())
        self.assertTrue(spm.is_dir())
        self.assertTrue(output.is_dir())

    def test_tick_trims_caches_only_when_low_and_idle(self):
        usage = lambda free: mock.Mock(free=free)
        with mock.patch.object(ib, "STATE_DIR", self.tmp / "state"), \
                mock.patch.object(ib, "LOG_PATH", self.tmp / "log"), \
                mock.patch.object(ib, "_public_runs", return_value=[]), \
                mock.patch.object(ib.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "", "")), \
                mock.patch.object(ib, "prune_caches", return_value=0) as trim:
            for free, busy, expect in ((100 * 1024 ** 3, False, 0), (39 * 1024 ** 3, True, 0),
                                       (39 * 1024 ** 3, False, 1)):
                trim.reset_mock()
                with mock.patch.object(ib.shutil, "disk_usage", return_value=usage(free)), \
                        mock.patch.object(ib, "job_running", return_value=busy):
                    ib.tick()
                self.assertEqual(trim.call_count, expect, (free, busy))

    def test_admit_trims_and_rechecks_when_only_disk_refuses(self):
        env = AdmitTests.env(None)
        frees = iter([39 * 1024 ** 3, 80 * 1024 ** 3])
        with mock.patch.dict(os.environ, env, clear=True), \
                mock.patch.object(ib, "LOG_PATH", self.tmp / "log"), \
                mock.patch.object(ib.shutil, "disk_usage", side_effect=lambda _p: mock.Mock(free=next(frees))), \
                mock.patch.object(ib, "prune_caches", return_value=3) as trim:
            self.assertEqual(ib.main(["admit"]), 0)
        trim.assert_called_once()

    def test_admit_does_not_trim_for_a_refused_job(self):
        env = AdmitTests.env(None, GITHUB_JOB="upload")
        with mock.patch.dict(os.environ, env, clear=True), \
                mock.patch.object(ib, "LOG_PATH", self.tmp / "log"), \
                mock.patch.object(ib.shutil, "disk_usage", return_value=mock.Mock(free=10 * 1024 ** 3)), \
                mock.patch.object(ib, "prune_caches") as trim:
            self.assertEqual(ib.main(["admit"]), 1)
        trim.assert_not_called()


    def test_newest_cap_counts_only_testflight_folders(self):
        other = self.make("20261001-abc-prod", age_s=3600)
        for i in range(ib.KEEP_OUTPUTS + 1):
            self.make(f"2026102{i}-abc-testflight", age_s=60 * (10 - i))
        ib._prune(1_000_000.0)
        self.assertTrue(other.is_dir())
        self.assertFalse((self.root / "20261020-abc-testflight").exists())

    def test_pressure_trim_leaves_a_symlinked_cargo_target_and_empties_trash(self):
        real = self.tmp / "elsewhere"
        real.mkdir()
        (self.root / ".cache").mkdir(parents=True)
        (self.root / ".cache/cmux-mobile-rust-target").symlink_to(real)
        ib.prune_caches()
        self.assertTrue(real.is_dir())
        self.make(".trash/leftover")
        ib._prune(1_000_000.0)
        self.assertEqual(list((self.root / ".trash").iterdir()), [])

    def test_job_running_matches_a_worker_from_any_runner_bin(self):
        seen = []

        def pgrep(argv, **_kw):
            seen.append(argv[-1])
            return subprocess.CompletedProcess(argv, 0 if argv[-1] == "Runner.Worker" else 1, "", "")
        with mock.patch.object(ib.subprocess, "run", side_effect=pgrep):
            self.assertTrue(ib.job_running())
        self.assertEqual(seen, ["Runner.Worker"])
        with mock.patch.object(ib.subprocess, "run", return_value=subprocess.CompletedProcess([], 1, "", "")):
            self.assertFalse(ib.job_running())

    def test_admit_refuses_cleanly_when_the_trim_fails_or_frees_too_little(self):
        env = AdmitTests.env(None)
        for effect in (PermissionError("denied"), None):
            with mock.patch.dict(os.environ, env, clear=True), \
                    mock.patch.object(ib, "LOG_PATH", self.tmp / "log"), \
                    mock.patch.object(ib.shutil, "disk_usage", return_value=mock.Mock(free=39 * 1024 ** 3)), \
                    mock.patch.object(ib, "prune_caches", side_effect=effect):
                self.assertEqual(ib.main(["admit"]), 1)


class FakeGh:
    """Stands in for subprocess.run(["gh", "api", ...]): answers from a script of (returncode, stdout, stderr)."""

    def __init__(self, *answers):
        self.answers = list(answers)
        self.calls = 0

    def __call__(self, argv, **_kw):
        self.calls += 1
        code, out, err = self.answers.pop(0) if len(self.answers) > 1 else self.answers[0]
        return subprocess.CompletedProcess(argv, code, out, err)


RATE_LIMITED = (1, "", "gh: API rate limit exceeded for installation ID 1234. (HTTP 403)")
RUNS_JSON = json.dumps({"workflow_runs": [{"id": 7, "display_title": f"cmux-next-ios INTERNAL {A}",
                                           "status": "completed", "conclusion": "success",
                                           "created_at": "2026-10-20T08:00:00Z"}]})


class GitHubApiTests(unittest.TestCase):
    """Run 39724971722: a rate-limited `gh api` read turned the whole decide job red."""

    def test_retries_a_rate_limited_read(self):
        gh = FakeGh(RATE_LIMITED, (0, RUNS_JSON, ""))
        runs = ib.builder_runs(runner=gh, sleep=lambda _s: None)
        self.assertEqual([r["sha"] for r in runs], [A])
        self.assertEqual(gh.calls, 2)

    def test_unregistered_workflow_is_no_runs(self):
        gh = FakeGh((1, "", "gh: Not Found (HTTP 404)"))
        self.assertEqual(ib.builder_runs(runner=gh, sleep=lambda _s: None), [])
        self.assertEqual(gh.calls, 1)

    def test_lasting_outage_skips_the_head_instead_of_failing(self):
        gh = FakeGh(RATE_LIMITED)
        with mock.patch.object(ib, "_show", return_value="x"), \
                mock.patch.object(ib, "builder_has_script", return_value=True), \
                mock.patch.dict(os.environ, {"GITHUB_OUTPUT": ""}):
            code = ib.cmd_plan(A, ".", runner=gh, sleep=lambda _s: None)
        self.assertEqual(code, 0)
        self.assertGreater(gh.calls, 1)

    def test_other_api_errors_still_fail(self):
        gh = FakeGh((1, "", "gh: Resource not accessible by integration (HTTP 403)"))
        with self.assertRaises(subprocess.CalledProcessError):
            ib.builder_runs(runner=gh, sleep=lambda _s: None)
        self.assertEqual(gh.calls, 1)


if __name__ == "__main__":
    unittest.main()
