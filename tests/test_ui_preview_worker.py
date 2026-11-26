#!/usr/bin/env python3
"""scripts/cmux-next/ui-preview-worker.py: the request check, the plan from the diff, the receipt file and one look
end to end with the shell and the clone faked (no git, no swift, no bun)."""
from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("ui_preview_worker", ROOT / "scripts/cmux-next/ui-preview-worker.py")
w = importlib.util.module_from_spec(spec)
sys.modules["ui_preview_worker"] = w
spec.loader.exec_module(w)

HEAD, BASE = "a" * 40, "b" * 40


def request(**over) -> dict:
    req = {"schema": "ui-preview-request/v1", "repo": "manaflow-ai/cmux", "head_sha": HEAD, "base_sha": BASE,
           "branch": "lane/x", "ui_files": ["Packages/macOS/CmuxNext/Sources/CmuxNextTabs/TabBar.swift"],
           "recipient": "gcp-agent-lane-12/lane-x", "recipient_host": "gcp-agent-lane-12",
           "pushed_at": w.utc_now()}
    req.update(over)
    return req


class PlanTests(unittest.TestCase):
    def test_a_tabs_file_shoots_the_tabs_scene(self):
        p = w.plan(["Packages/macOS/CmuxNext/Sources/CmuxNextTabs/Playground/TabBarPlaygroundView.swift"])
        self.assertEqual(p["swift"], ["tabs"])
        self.assertFalse(p["web"])
        self.assertEqual(p["needs_build"], [])

    def test_the_design_system_shoots_every_scene(self):
        self.assertEqual(w.plan(["Packages/macOS/CmuxNext/Sources/CmuxNextDesign/X.swift"])["swift"],
                         list(w.ALL_SWIFT_SCENES))

    def test_swift_outside_the_shell_needs_a_build(self):
        p = w.plan(["Packages/macOS/CmuxNext/Sources/CmuxNextApp/AppDelegate.swift"])
        self.assertEqual(p["needs_build"], ["Packages/macOS/CmuxNext/Sources/CmuxNextApp/AppDelegate.swift"])
        self.assertEqual(w.plan(["Packages/macOS/CmuxNext/Package.swift"])["needs_build"],
                         ["Packages/macOS/CmuxNext/Package.swift"])

    def test_web_paths_are_a_web_look(self):
        self.assertTrue(w.plan(["webviews/src/App.tsx"])["web"])
        self.assertTrue(w.plan(["cmux-tui/frontends/web/src/x.ts"])["web"])
        self.assertTrue(w.plan(["design/icons/neko-candidates/a.svg"])["web"])
        self.assertTrue(w.plan(["first-party-apps/notes/preview/index.html"])["web"])

    def test_the_web_tree_leaves_out_only_folders_no_web_file_imports(self):
        # bun install, protocol:codegen and the gallery read release-notes/, schemas/, Packages/ fixtures,
        # cmux-tui/crates/ and web/data/; a tree missing one failed every web look (Linux pool, 2026-11-25).
        self.assertEqual(w.WEB_SPARSE[0], "/*")
        left_out = [p[2:].rstrip("/") for p in w.WEB_SPARSE if p.startswith("!/")]
        import re
        spec = re.compile(r"""(?:from\s+|import\s*\(\s*|import\s+|require\(\s*)["'](\.\.?/[^"'?]+)""")
        for base in ("webviews", "first-party-apps", "design"):
            for f in (ROOT / base).rglob("*"):
                if "node_modules" in f.parts or f.suffix not in {".ts", ".tsx", ".mjs", ".js", ".css"} or not f.is_file():
                    continue
                for m in spec.finditer(f.read_text(errors="ignore")):
                    target = (f.parent / m.group(1)).resolve()
                    if ROOT in target.parents:
                        top = target.relative_to(ROOT).parts[0]
                        self.assertNotIn(top, left_out, f"{f.relative_to(ROOT)} imports {m.group(1)}")

    def test_a_linked_module_with_no_scene_is_nothing(self):
        p = w.plan(["Packages/macOS/CmuxNext/Sources/CmuxNextSettings/S.swift"])
        self.assertEqual((p["swift"], p["web"], p["needs_build"]), ([], False, []))


class RequestTests(unittest.TestCase):
    def test_a_good_request_passes(self):
        self.assertEqual(w.check_request(request())["head_sha"], HEAD)

    def test_refusals(self):
        for bad in ({"schema": "x"}, {"repo": "someone/fork"}, {"head_sha": "abc"}, {"recipient": "a b"},
                    {"ui_files": []}, {"ui_files": ["../etc/passwd"]}, {"pushed_at": "yesterday"},
                    {"branch": "-x"}):
            with self.subTest(bad=bad), self.assertRaises(w.LookError):
                w.check_request(request(**bad))


class FakeWorker(w.Worker):
    """The look with the clone and the shell faked: each side is a PNG named by its commit."""

    def __init__(self, state: Path):
        super().__init__(state, "http://100.1.2.3:8765", None, None, host="preview-test")
        self.shot: list[str] = []

    def ensure_clone(self):
        pass

    def fetch(self, *shas):
        pass

    def on_branch_tip_or_landed(self, head, branch):
        return head == HEAD

    def ensure_tree(self, tree, sparse, sha):
        self.checked_out = sha

    def build_shell(self, cold=False):
        pass

    def shoot_shell(self, scenes, out):
        self.shot.append(self.checked_out)
        out.mkdir(parents=True, exist_ok=True)
        for s in scenes:
            (out / f"{s}.png").write_bytes(b"png-" + self.checked_out.encode())
        return {s: f"{s}.png" for s in scenes}


class LookTests(unittest.TestCase):
    def test_a_swift_look_posts_and_caches_the_before_by_commit(self):
        with tempfile.TemporaryDirectory() as tmp:
            worker = FakeWorker(Path(tmp))
            receipt = worker.look(request())
            self.assertIsNotNone(receipt["posted_at"], receipt.get("error"))
            self.assertEqual(worker.shot, [BASE, HEAD])
            [scene] = receipt["scenes"]
            self.assertEqual(scene["scene"], "tabs")
            self.assertTrue(scene["changed"])
            self.assertTrue(scene["before"].startswith("http://100.1.2.3:8765/looks/"))
            self.assertIn("swift_after", receipt["stages"])
            self.assertGreaterEqual(receipt["push_to_post_s"], 0)
            [sent] = list((Path(tmp) / "outbox").iterdir())
            self.assertIn("tabs", sent.read_text())
            # The file NOW reads: one ui-preview/v1 receipt for the head, covered.
            doc = json.loads(worker.receipts_path.read_text())
            self.assertEqual(doc["schema"], "ui-preview/v1")
            [row] = doc["receipts"]
            self.assertEqual(row["head_sha"], HEAD)
            self.assertNotIn("before_path", row["scenes"][0])
            # A second look of the same pair shoots nothing again.
            worker.shot.clear()
            worker.look(request())
            self.assertEqual(worker.shot, [])

    def test_a_commit_that_is_not_the_repos_own_gets_no_look(self):
        with tempfile.TemporaryDirectory() as tmp:
            worker = FakeWorker(Path(tmp))
            receipt = worker.look(request(head_sha="c" * 40))
            self.assertIsNone(receipt["posted_at"])
            self.assertIn("not the repo's own", receipt["error"])
            self.assertEqual(worker.shot, [])

    def test_a_needs_build_change_says_so_and_builds_nothing(self):
        with tempfile.TemporaryDirectory() as tmp:
            worker = FakeWorker(Path(tmp))
            receipt = worker.look(request(ui_files=["Packages/macOS/CmuxNext/Sources/CmuxNextApp/A.swift"]))
            self.assertIn("needs an app build", receipt["error"])
            self.assertEqual(worker.shot, [])

    def test_a_web_only_worker_shoots_no_swift(self):
        with tempfile.TemporaryDirectory() as tmp:
            worker = FakeWorker(Path(tmp))
            worker.swift_on = False
            receipt = worker.look(request())
            self.assertEqual(worker.shot, [])
            self.assertIn("shoots web scenes only", receipt["error"])


class FollowTests(unittest.TestCase):
    """serve --follow: the broker's push trigger (lane-gh call ui_preview_requests) feeds the jobs queue."""

    def broker(self, answer):
        calls = []

        def call(tool, args, timeout):
            calls.append((tool, args))
            return answer

        return calls, call

    def test_a_first_start_takes_the_newest_seq_and_no_backlog(self):
        with tempfile.TemporaryDirectory() as tmp:
            jobs = w.queue.Queue()
            calls, call = self.broker({"seq": 41, "requests": [dict(request(), seq=41)]})
            self.assertEqual(w.follow_once(FakeWorker(Path(tmp)), jobs, None, call), 41)
            self.assertTrue(jobs.empty())
            self.assertEqual(calls, [("ui_preview_requests", {"after": 0, "wait": 0})])

    def test_requests_after_the_seq_are_queued_and_the_seq_moves(self):
        with tempfile.TemporaryDirectory() as tmp:
            jobs = w.queue.Queue()
            web = dict(request(ui_files=["webviews/src/a.tsx"]), seq=42)
            bad = {"seq": 43, "schema": "nope"}
            _, call = self.broker({"seq": 43, "requests": [web, bad]})
            self.assertEqual(w.follow_once(FakeWorker(Path(tmp)), jobs, 41, call), 43)
            req, _ = jobs.get_nowait()
            self.assertEqual(req["ui_files"], ["webviews/src/a.tsx"])
            self.assertTrue(jobs.empty())

    def test_a_web_only_worker_leaves_swift_only_requests(self):
        with tempfile.TemporaryDirectory() as tmp:
            worker = FakeWorker(Path(tmp))
            worker.swift_on = False
            jobs = w.queue.Queue()
            _, call = self.broker({"seq": 42, "requests": [dict(request(), seq=42)]})
            self.assertEqual(w.follow_once(worker, jobs, 41, call), 42)
            self.assertTrue(jobs.empty())

    def test_lane_gh_call_reads_the_answers_data_and_names_a_refusal(self):
        from unittest import mock
        ran = []

        def fake(argv, **kw):
            ran.append(argv)
            body = {"ok": True, "status": 200, "data": {"seq": 7}} if argv[2] == "ui_preview_requests" else \
                {"ok": False, "status": 403, "error": "not this VM's file"}
            return mock.Mock(returncode=0 if body["status"] == 200 else 1, stdout=json.dumps(body), stderr="")

        with mock.patch.object(w.subprocess, "run", fake):
            self.assertEqual(w.lane_gh_call("ui_preview_requests", {"after": 0}, 5), {"seq": 7})
            with self.assertRaises(w.LookError):
                w.lane_gh_call("state_put", {"name": "now-census"}, 5, repo="manaflow-ai/cmuxterm-hq")
        self.assertEqual(ran[0][:3], ["lane-gh", "call", "ui_preview_requests"])
        self.assertEqual(ran[1][3], "manaflow-ai/cmuxterm-hq")

    def test_a_reset_broker_queue_restarts_at_its_newest(self):
        with tempfile.TemporaryDirectory() as tmp:
            _, call = self.broker({"seq": 3, "requests": [], "reset": True})
            self.assertEqual(w.follow_once(FakeWorker(Path(tmp)), w.queue.Queue(), 90, call), 3)


if __name__ == "__main__":
    unittest.main()
