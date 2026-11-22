#!/usr/bin/env python3
"""A same-tree run reported red reads its tree's publish record at run time.

2026-11-11, cmux#40449 at ec4a30d2: cmux-next run 43009515785 was dispatched in same-tree mode with
same_tree_state=failed after a cmux-tui artifacts run failed on a fetch. A re-run of the artifacts
run published the tree, but `cmux app scheme compile (Debug) (same-tree)` stayed red, and re-running
43009515785 went red again forever: a re-run keeps the dispatch inputs, so it re-read the old
verdict. Now the failed report reads the tree's completion.json first (scripts/ci/
cmux_next_same_tree_failed.py): a tree published since dispatches the ready tree jobs.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
import unittest.mock
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))

import cmux_next_same_tree_failed as failed  # noqa: E402
import cmux_next_tree_notify as notify  # noqa: E402

WORKFLOW = ROOT / ".github/workflows/cmux-next.yml"
KEY = "a" * 40
COMMIT = "ec4a30d2" + "0" * 32
REASON = (f"tree {KEY}: the cmux-tui artifacts run https://github.com/o/r/actions/runs/42 ended without "
          f"publishing tree {KEY} (build or publish failed); re-run it, and its publish starts the tree jobs")


def args(*extra: str, tiers: str = "daemon,scheme", origin: str = "dispatch", reason: str = REASON):
    return failed.parse(["--repo", "o/r", "--ref", "lane/x", "--reason", reason, "--commit", COMMIT,
                         "--status-sha", COMMIT, "--tiers", tiers, "--origin", origin, "--origin-run", "11",
                         *extra])


def completion(key: str = KEY) -> dict:
    return {"key": key, "binaries": {"cmux-tui-aarch64-apple-darwin": "f" * 64}}


class Api:
    def __init__(self, dispatch_status: int = 204):
        self.posts: list[tuple[str, dict]] = []
        self.dispatch_status = dispatch_status

    def post(self, path: str, body: dict) -> int:
        self.posts.append((path, body))
        return self.dispatch_status if path.endswith("/dispatches") else 201

    def dispatches(self) -> list[dict]:
        return [body for path, body in self.posts if path == "repos/o/r/actions/workflows/cmux-next.yml/dispatches"]

    def statuses(self) -> list[dict]:
        return [body for path, body in self.posts if path == f"repos/o/r/statuses/{COMMIT}"]


def check(api: Api, parsed, record: object | None):
    return failed.check(api, parsed, run_id="43009515785", target_url="https://x/runs/43009515785",
                        fetch_completion=lambda _key: record, log=lambda _line: None)


class PublishRecord(unittest.TestCase):
    def test_a_rerun_after_the_publish_dispatches_the_ready_tree_jobs(self):
        api = Api()
        self.assertEqual(check(api, args(), completion()), (True, KEY))
        [body] = api.dispatches()
        self.assertEqual(body["ref"], "lane/x")
        inputs = body["inputs"]
        self.assertEqual(inputs["same_tree_state"], "ready")
        self.assertEqual((inputs["same_tree_sha"], inputs["same_tree_status_sha"]), (COMMIT, COMMIT))
        self.assertEqual(inputs["same_tree_tiers"], "daemon,scheme")
        self.assertEqual((inputs["same_tree_origin"], inputs["same_tree_origin_run"]), ("dispatch", "11"))
        self.assertIn(f"tree {KEY} is published", inputs["same_tree_reason"])
        # The stale reds turn pending at once; the ready run posts the verdicts.
        self.assertEqual({(s["context"], s["state"]) for s in api.statuses()},
                         {("cmux-next daemon tests (same-tree)", "pending"),
                          ("cmux app scheme compile (Debug) (same-tree)", "pending")})

    def test_an_unpublished_tree_dispatches_nothing(self):
        for record in (None, completion("b" * 40), {"key": KEY}):
            with self.subTest(record=record):
                api = Api()
                self.assertEqual(check(api, args(), record), (False, KEY))
                self.assertEqual(api.posts, [])

    def test_a_reason_without_a_key_reads_nothing(self):
        api = Api()
        seen: list[str] = []
        healed = failed.check(api, args(reason="no reason given"), fetch_completion=lambda key: seen.append(key),
                              log=lambda _line: None)
        self.assertEqual(healed, (False, ""))
        self.assertEqual(seen, [])
        self.assertEqual(failed.key_of("no key", KEY), KEY)

    def test_a_refused_dispatch_leaves_the_red(self):
        api = Api(dispatch_status=422)
        self.assertEqual(check(api, args(), completion()), (False, KEY))
        self.assertEqual(api.statuses(), [])

    def test_the_ready_run_keeps_its_run_name(self):
        """base_red_excuse.py and the kick look the run up by name: a base tier stays a base tier."""
        for extra, tiers, key_input, contexts in (
                (["--tip-suite", "base"], "daemon,scheme", "base_tier",
                 {"cmux-next daemon tests (same-tree)", "cmux app scheme compile (Debug) (same-tree)"}),
                (["--tip-suite", "daemon"], "daemon", "tip_daemon_suite", {"cmux-next daemon tests (same-tree)"}),
                (["--dev-daily-sha", COMMIT], "scheme", "dev_daily", {"cmux NEXT DEV Release compile (same-tree)"})):
            with self.subTest(extra=extra):
                api = Api()
                self.assertTrue(check(api, args(*extra, tiers=tiers, origin="push" if "--dev-daily-sha" in extra
                                                 else "dispatch"), completion())[0])
                [body] = api.dispatches()
                self.assertEqual(body["inputs"][key_input], "true")
                self.assertEqual({s["context"] for s in api.statuses()}, contexts)
                self.assertEqual(notify.run_name(dict(failed.reported_marker(
                    args(*extra, tiers=tiers), KEY, "1"), sha=COMMIT)).split(" · ")[0],
                    {"base_tier": "cmux-next base tier", "tip_daemon_suite": "cmux-next tip daemon suite",
                     "dev_daily": "cmux NEXT DEV daily"}[key_input])

    def test_an_unpublished_tree_writes_a_reported_marker_notify_accepts(self):
        with tempfile.TemporaryDirectory() as tmp:
            marker = Path(tmp) / "m" / "marker.json"
            output = Path(tmp) / "out"
            original = notify.fetch_completion
            notify.fetch_completion = lambda _key: None
            try:
                with unittest.mock.patch.dict(os.environ, {"GH_TOKEN": "", "GITHUB_RUN_ID": "43009515785"}):
                    code = failed.main(["--repo", "o/r", "--ref", "lane/x", "--reason", REASON, "--commit", COMMIT,
                                        "--status-sha", COMMIT, "--tiers", "daemon,scheme", "--origin", "dispatch",
                                        "--origin-run", "11", "--marker", str(marker), "--output", str(output)])
            finally:
                notify.fetch_completion = original
            self.assertEqual(code, 1)
            self.assertEqual(output.read_text(), f"key={KEY}\n")
            written = json.loads(marker.read_text())
        self.assertTrue(written["reported"])
        self.assertEqual(written["reported_run"], 43009515785)
        self.assertEqual((written["tiers"], written["branch"], written["origin"]),
                         (["daemon", "scheme"], "lane/x", "dispatch"))

        class Zip:
            def download(self, _url):
                import io
                import zipfile
                buffer = io.BytesIO()
                with zipfile.ZipFile(buffer, "w") as archive:
                    archive.writestr("marker.json", json.dumps(written))
                return buffer.getvalue()

        self.assertEqual(notify.read_marker(Zip(), {"archive_download_url": "z"}, KEY), written)


class Workflow(unittest.TestCase):
    def job(self) -> dict:
        return yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]["same-tree-cmux-tui"]

    def test_the_failed_report_reads_the_publish_record_before_any_red(self):
        steps = {step.get("name"): step for step in self.job()["steps"]}
        report = steps["Report the unavailable same-tree cmux-tui"]
        run = report["run"]
        self.assertIn("scripts/ci/cmux_next_same_tree_failed.py", run)
        self.assertLess(run.index("cmux_next_same_tree_failed.py"), run.index("cmux_tui_tree_takeover.py"))
        self.assertLess(run.index("cmux_next_same_tree_failed.py"), run.index("::error"))
        self.assertEqual(report["id"], "unavailable")
        self.assertEqual(self.job()["permissions"].get("actions"), "write")
        self.assertEqual(self.job()["permissions"].get("statuses"), "write")
        upload = steps["Upload the reported tree wait marker"]
        self.assertEqual(upload["with"]["name"], "cmux-next-tree-wait-${{ steps.unavailable.outputs.key }}")
        self.assertIn("!cancelled()", upload["if"])
        self.assertTrue(upload.get("continue-on-error"))

    def run_step(self, script_exit: int) -> tuple[subprocess.CompletedProcess, list[str]]:
        """The step's shell with stub scripts: which ran, and how the step ended."""
        report = next(step for step in self.job()["steps"] if step.get("id") == "unavailable")
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "scripts/ci").mkdir(parents=True)
            calls = root / "calls"
            for name, code in (("cmux_next_same_tree_failed.py", script_exit), ("cmux_tui_tree_takeover.py", 1)):
                (root / "scripts/ci" / name).write_text(
                    f"import sys\nopen({str(calls)!r}, 'a').write({name!r} + '\\n')\nsys.exit({code})\n")
            bin_dir = root / "bin"
            bin_dir.mkdir()
            (bin_dir / "curl").write_text(f"#!/bin/sh\necho curl >> {calls}\n")
            (bin_dir / "curl").chmod(0o755)
            env = {**os.environ, "PATH": f"{bin_dir}:{os.environ['PATH']}", "RUNNER_TEMP": tmp,
                   "GITHUB_OUTPUT": str(root / "output"), "GITHUB_REPOSITORY": "o/r", "GITHUB_API_URL": "http://x",
                   "REASON": REASON, "KEY": "", "COMMIT": COMMIT, "STATUS_SHA": COMMIT, "TIERS": "daemon,scheme",
                   "ORIGIN": "dispatch", "ORIGIN_RUN": "11", "REF_NAME": "lane/x", "REF_KIND": "heads",
                   "DEV_DAILY_SHA": "", "TIP_SUITE": "", "DEV_DAILY": "false", "GH_TOKEN": "t",
                   "TARGET_URL": "https://x"}
            result = subprocess.run(["bash", "-c", report["run"]], cwd=root, env=env, capture_output=True,
                                    text=True, timeout=30)
            return result, calls.read_text().split() if calls.exists() else []

    def test_a_published_tree_ends_the_step_green_without_a_red_status(self):
        result, calls = self.run_step(0)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, ["cmux_next_same_tree_failed.py"])
        self.assertNotIn("::error", result.stdout)

    def test_an_unpublished_tree_still_reports_red(self):
        result, calls = self.run_step(1)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(calls, ["cmux_next_same_tree_failed.py", "cmux_tui_tree_takeover.py", "curl", "curl"])
        self.assertIn("::error title=same-tree cmux-tui unavailable::", result.stdout)


if __name__ == "__main__":
    unittest.main()
