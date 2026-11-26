#!/usr/bin/env python3
"""scripts/cmux-next/ui-preview-worker.py: the request check, the plan from the diff, the receipt file and one look
end to end with the shell and the clone faked (no git, no swift, no bun)."""
from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import threading
import time
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
        self.prefetched: list[tuple[str, str]] = []

    def prefetch(self, req):
        self.prefetched.append((req["head_sha"], req["base_sha"]))

    def gallery_for(self, sha, avoid=()):
        g = self.web
        g.install = lambda: False
        g.scenes = lambda files: ["entry.a"]
        return g

    def web_side(self, sha, entries, gallery=None):
        out = self.state / "shots" / "web" / sha
        out.mkdir(parents=True, exist_ok=True)
        self.shot.append(f"web:{sha}")
        for e in entries:
            (out / f"{e}.png").write_bytes(b"png-" + sha.encode())
        return {e: out / f"{e}.png" for e in entries}

    def ensure_clone(self):
        pass

    def fetch(self, *shas, branches=()):
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


class SpeedTests(unittest.TestCase):
    """The look's waits that were not the look's (the first real post took 126 s): the receipt publish, the fetch,
    a cold chromium per shot, one look at a time, requests no look shows."""

    def test_a_receipt_write_never_waits_on_publish_and_writes_coalesce(self):
        with tempfile.TemporaryDirectory() as tmp:
            worker = FakeWorker(Path(tmp))
            worker.publish_template = "publish {file} {host}"
            gate, began, docs = threading.Event(), threading.Event(), []

            def slow_publish():
                began.set()
                gate.wait(10)
                docs.append(json.loads(worker.receipts_path.read_text()))

            worker.publish_now = slow_publish
            t0 = time.monotonic()
            worker.look(request(ui_files=["webviews/src/a.tsx"]))
            self.assertTrue(began.wait(5))
            for n in range(5):  # five more receipts while the first publish hangs
                worker.write_receipt(dict(worker.new_receipt(request(head_sha=f"{n}" * 40)), stages={}))
            self.assertLess(time.monotonic() - t0, 5, "a look waited on the publish")
            gate.set()
            self.assertTrue(worker.publisher.flush(10))
            # The hung publish, then one for the five writes behind it, carrying them all (the latest doc).
            self.assertEqual(worker.publisher.runs, 2)
            self.assertEqual(len(docs[-1]["receipts"]), 6)

    def test_the_clone_borrows_the_mirror_and_fetches_nothing_the_mirror_holds(self):
        with tempfile.TemporaryDirectory() as tmp:
            env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t",
                   "GIT_COMMITTER_EMAIL": "t@t"}
            mirror = Path(tmp) / "mirror.git"
            subprocess.run(["git", "init", "-q", "--bare", str(mirror)], check=True)
            blob = subprocess.run(["git", "-C", str(mirror), "hash-object", "-w", "--stdin"], input=b"x",
                                  capture_output=True, check=True).stdout.decode().strip()
            tree = subprocess.run(["git", "-C", str(mirror), "mktree"], input=f"100644 blob {blob}\ta\n".encode(),
                                  capture_output=True, check=True).stdout.decode().strip()
            sha = subprocess.run(["git", "-C", str(mirror), "commit-tree", tree, "-m", "m"], capture_output=True,
                                 check=True, env=env).stdout.decode().strip()
            worker = w.Worker(Path(tmp) / "state", None, None, None, host="t")
            worker.mirror = mirror
            subprocess.run(["git", "init", "-q", "--bare", str(worker.clone)], check=True)
            self.assertFalse(worker.has_commit(sha))
            worker.ensure_clone()  # a clone already there: only the alternates line
            worker.ensure_clone()
            alternates = (worker.clone / "objects/info/alternates").read_text().splitlines()
            self.assertEqual(alternates, [str(mirror / "objects")])
            worker.fetch(sha)  # no origin here: a fetch would fail
            self.assertTrue(worker.has_commit(sha))
            no_mirror = w.Worker(Path(tmp) / "state2", None, None, None, host="t")
            no_mirror.mirror = None
            subprocess.run(["git", "init", "-q", "--bare", str(no_mirror.clone)], check=True)
            no_mirror.ensure_clone()
            self.assertFalse((no_mirror.clone / "objects/info/alternates").exists())
            with self.assertRaises(w.LookError):  # GitHub's turn (here: no origin)
                no_mirror.fetch(sha)

    def test_a_queued_request_is_prefetched_and_a_needs_build_one_is_refused_at_once(self):
        with tempfile.TemporaryDirectory() as tmp:
            worker = FakeWorker(Path(tmp))
            jobs = w.queue.Queue()
            web = dict(request(ui_files=["webviews/src/a.tsx"]), seq=42)
            app = dict(request(head_sha="d" * 40, ui_files=["Packages/macOS/CmuxNext/Sources/CmuxNextApp/A.swift"]),
                       seq=43)
            tests_only = dict(request(head_sha="e" * 40, ui_files=["Packages/macOS/CmuxNext/Tests/T.swift"]), seq=44)
            _, call = FollowTests().broker({"seq": 44, "requests": [web, app, tests_only]})
            self.assertEqual(w.follow_once(worker, jobs, 41, call), 44)
            req, _ = jobs.get_nowait()
            self.assertEqual(req["head_sha"], HEAD)
            self.assertTrue(jobs.empty())
            self.assertEqual(worker.prefetched, [(HEAD, BASE)])
            rows = {r["head_sha"]: r for r in json.loads(worker.receipts_path.read_text())["receipts"]}
            self.assertIn("needs an app build", rows["d" * 40]["error"])
            self.assertIn("no scene shows", rows["e" * 40]["error"])
            self.assertIsNotNone(rows["d" * 40]["stages"])

    def test_a_needs_build_file_beside_a_web_file_still_gets_the_web_look(self):
        with tempfile.TemporaryDirectory() as tmp:
            worker = FakeWorker(Path(tmp))
            receipt = worker.look(request(ui_files=["webviews/src/a.tsx",
                                                    "Packages/macOS/CmuxNext/Sources/CmuxNextApp/A.swift"]))
            self.assertIsNotNone(receipt["posted_at"], receipt.get("error"))
            self.assertEqual([s["scene"] for s in receipt["scenes"]], ["entry.a"])
            self.assertIn("needs an app build", receipt["error"])
            self.assertEqual(worker.shot, [f"web:{HEAD}", f"web:{BASE}"])

    def test_looks_overlap_outside_the_web_tree(self):
        with tempfile.TemporaryDirectory() as tmp:
            worker = FakeWorker(Path(tmp))
            both_fetching = threading.Barrier(2, timeout=5)
            worker.fetch = lambda *shas, **kw: both_fetching.wait()
            jobs = w.queue.Queue()
            for n in "12":
                jobs.put((request(head_sha=n * 40, branch=f"lane/{n}", ui_files=["webviews/src/a.tsx"]),
                          time.monotonic()))
            worker.on_branch_tip_or_landed = lambda head, branch: True
            threads = [threading.Thread(target=w.drain, args=(worker, jobs, True)) for _ in range(2)]
            for t in threads:
                t.start()
            for t in threads:
                t.join(10)
            rows = json.loads(worker.receipts_path.read_text())["receipts"]
            self.assertEqual(sorted(r["head_sha"][0] for r in rows if r.get("posted_at")), ["1", "2"],
                             [r.get("error") for r in rows])

    def test_a_superseded_head_is_dropped_only_after_it_waited_45_s(self):
        with tempfile.TemporaryDirectory() as tmp:
            worker = FakeWorker(Path(tmp))
            now = time.monotonic()
            old = request()
            worker.note_queued(old, now - 50)
            worker.note_queued(request(head_sha="f" * 40), now - 10)
            self.assertIsNone(worker.superseded_by(old, now - 30, now))  # 30 s queued: it still runs
            self.assertEqual(worker.superseded_by(old, now - 50, now), "f" * 40)
            self.assertIsNone(worker.superseded_by(request(branch="lane/other"), now - 50, now))
            jobs = w.queue.Queue()
            jobs.put((old, now - 50))
            w.drain(worker, jobs, once=True)
            [row] = json.loads(worker.receipts_path.read_text())["receipts"]
            self.assertIn("superseded by ffffffffffff", row["error"])
            self.assertEqual(worker.shot, [])

    def test_the_shooter_stays_up_between_shots(self):
        with tempfile.TemporaryDirectory() as tmp:
            launches = Path(tmp) / "launches"
            fake = Path(tmp) / "fake-bun"
            fake.write_text(f"""#!{sys.executable}
import json, os, sys
open({str(launches)!r}, "a").write("x")
assert sys.argv[2] == "--serve"
for line in sys.stdin:
    spec = json.loads(line)
    rows = []
    for shot in spec["shots"]:
        open(os.path.join(spec["out"], shot["name"] + ".png"), "wb").write(b"png")
        rows.append({{"name": shot["name"], "file": shot["name"] + ".png"}})
    print(json.dumps({{"shots": rows}}), flush=True)
""")
            fake.chmod(0o755)
            worker = w.Worker(Path(tmp) / "state", None, None, None, host="t")
            (worker.web_tree / "webviews").mkdir(parents=True)
            worker.bun = lambda: str(fake)
            try:
                self.assertEqual(worker.web.shoot(["a.b"], Path(tmp) / "one"), {"a.b": "a.b.png"})
                self.assertEqual(worker.web.shoot(["c"], Path(tmp) / "two"), {"c": "c.png"})
                self.assertEqual(launches.read_text(), "x")
            finally:
                worker.stop_shooter()



GIT_ENV = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t",
           "GIT_COMMITTER_EMAIL": "t@t"}


def commit(repo: Path, files: dict, message: str = "m") -> str:
    for name, text in files.items():
        (repo / name).parent.mkdir(parents=True, exist_ok=True)
        (repo / name).write_text(text)
    subprocess.run(["git", "-C", str(repo), "add", "-A"], check=True, env=GIT_ENV)
    subprocess.run(["git", "-C", str(repo), "commit", "-q", "-m", message], check=True, env=GIT_ENV)
    return subprocess.run(["git", "-C", str(repo), "rev-parse", "HEAD"], capture_output=True, text=True,
                          check=True).stdout.strip()


class StallTests(unittest.TestCase):
    """What set the p95 after the speed pass: a 36 s fetch stage (the base tip fetched from GitHub to prove a landed
    head landed) and 56-62 s base-side web shots (pages shot into vite's own restart, entries the base lacks)."""

    def test_a_head_under_a_base_tip_held_here_asks_github_nothing(self):
        with tempfile.TemporaryDirectory() as tmp:
            src = Path(tmp) / "src"
            subprocess.run(["git", "init", "-q", "-b", w.BASE_BRANCH, str(src)], check=True)
            landed = commit(src, {"a": "1"})
            commit(src, {"a": "2"})
            subprocess.run(["git", "-C", str(src), "checkout", "-q", "-b", "side", landed], check=True)
            fork = commit(src, {"b": "x"})
            mirror = Path(tmp) / "mirror.git"
            subprocess.run(["git", "clone", "-q", "--mirror", str(src), str(mirror)], check=True)
            worker = w.Worker(Path(tmp) / "state", None, None, None, host="t")
            worker.mirror = mirror
            subprocess.run(["git", "init", "-q", "--bare", str(worker.clone)], check=True)
            worker.ensure_clone()
            asked = []
            real_git = w.git
            w.git = lambda repo, *args, **kw: asked.append(args[0]) or real_git(repo, *args, **kw)
            try:
                self.assertTrue(worker.on_branch_tip_or_landed(landed, "lane/x"))
                self.assertEqual(asked, [], "a landed head asked GitHub")
                # A head not under the base tip (another branch's commit): one fetch of the branch and the base,
                # by tracking refspec as the lane VMs' brokered fetch takes it (here: no origin).
                with self.assertRaises(w.LookError):
                    worker.on_branch_tip_or_landed(fork, "lane/x")
                self.assertEqual(asked, ["fetch"])
            finally:
                w.git = real_git

    def test_every_fetch_is_one_the_brokered_fetch_carries_and_a_branch_tip_passes(self):
        """lane-1/2 (2026-11-26): the lane VMs' git fetch goes through the broker, which carries plain branch names
        and tracking refspecs only; the worker's --filter=blob:none fetch killed every warm-up."""
        with tempfile.TemporaryDirectory() as tmp:
            src = Path(tmp) / "src"
            subprocess.run(["git", "init", "-q", "-b", w.BASE_BRANCH, str(src)], check=True)
            base = commit(src, {"a": "1"})
            subprocess.run(["git", "-C", str(src), "checkout", "-q", "-b", "lane/x"], check=True)
            head = commit(src, {"b": "x"})
            subprocess.run(["git", "-C", str(src), "checkout", "-q", "-b", "other", base], check=True)
            other = commit(src, {"c": "z"})  # on no branch the look names, never landed
            worker = w.Worker(Path(tmp) / "state", None, None, None, host="t")
            worker.mirror = None
            subprocess.run(["git", "init", "-q", "--bare", str(worker.clone)], check=True)
            subprocess.run(["git", "-C", str(worker.clone), "remote", "add", "origin", str(src)], check=True)
            fetches = []
            real_git = w.git
            w.git = lambda repo, *args, **kw: (args[0] == "fetch" and fetches.append(args)) or real_git(repo, *args,
                                                                                                         **kw)
            try:
                worker.fetch(head, base, branches=("lane/x",))
                self.assertTrue(worker.has_commit(head) and worker.has_commit(base))
                self.assertTrue(worker.on_branch_tip_or_landed(head, "lane/x"))
                self.assertEqual(len(fetches), 1, "the branch tip was fetched again for the ancestry check")
                subprocess.run(["git", "-C", str(worker.clone), "fetch", "-q", "origin", other], check=True)
                self.assertFalse(worker.on_branch_tip_or_landed(other, "lane/x"))
            finally:
                w.git = real_git
            for args in fetches:
                words = [a for a in args[1:] if not a.startswith("-")]
                self.assertEqual(words[0], "origin")
                self.assertFalse([a for a in args if a.startswith("--filter")], args)
                for spec in words[1:]:
                    self.assertRegex(spec, r"^\+refs/heads/([A-Za-z0-9._][A-Za-z0-9._/-]*):refs/remotes/origin/\1$")

    def test_a_checkout_that_changes_the_gallery_config_restarts_the_gallery(self):
        with tempfile.TemporaryDirectory() as tmp:
            worker = w.Worker(Path(tmp) / "state", None, None, None, host="t")
            worker.clone.mkdir(parents=True)
            subprocess.run(["git", "init", "-q", str(worker.clone)], check=True)
            one = commit(worker.clone, {"webviews/vite.config.ts": "a", "webviews/src/x.ts": "1"})
            two = commit(worker.clone, {"webviews/src/x.ts": "2"})
            three = commit(worker.clone, {"webviews/vite.config.ts": "b"})
            four = commit(worker.clone, {"webviews/dev-server/galleryHost.ts": "c"})
            stops = []
            g = worker.web
            g.stop = lambda: stops.append(1)
            g.checkout(one)  # first checkout: nothing ran on another config
            g.checkout(two)
            self.assertEqual(stops, [])
            g.checkout(three)
            self.assertEqual(stops, [1])
            g.checkout(four)
            self.assertEqual(stops, [1, 1])
            g.checkout(four)
            self.assertEqual(stops, [1, 1])

    def test_an_entry_the_side_lacks_is_a_card_not_a_60_s_wait(self):
        with tempfile.TemporaryDirectory() as tmp:
            worker = w.Worker(Path(tmp) / "state", None, None, None, host="t")
            src = worker.web_tree / "webviews" / "src"
            src.mkdir(parents=True)
            (src / "a.gallery.tsx").write_text('const o = { id: "nested.option" };\nexport default { id: "held.a" };\n')
            (src / "b.gallery.ts").write_text('export default define({ id: "held.b", title: "B" });\n')
            g = worker.web
            self.assertEqual(g.entry_ids(), {"held.a", "held.b"})
            g.checkout = lambda sha: None
            g.install = lambda: False
            g.start = lambda: None
            worker.gallery_for = lambda sha, avoid=(): g
            seen = {}

            def shoot(entries, out, absent=None):
                seen.update(absent or {})
                out.mkdir(parents=True, exist_ok=True)
                files = {}
                for e in entries:
                    files[e] = (w.ABSENT_PREFIX if e in (absent or {}) else "") + f"{e}.png"
                    (out / files[e]).write_bytes(b"png")
                return files

            g.shoot = shoot
            got = worker.web_side(BASE, ["held.a", "new.c"])
            self.assertEqual(seen, {"new.c": BASE})
            self.assertTrue(got["new.c"].name.startswith(w.ABSENT_PREFIX))
            self.assertFalse(got["held.a"].name.startswith(w.ABSENT_PREFIX))

    def test_a_new_entry_posts_with_its_before_marked_absent(self):
        with tempfile.TemporaryDirectory() as tmp:
            worker = FakeWorker(Path(tmp))

            def web_side(sha, entries, gallery=None):
                out = worker.state / "shots" / "web" / sha
                out.mkdir(parents=True, exist_ok=True)
                name = (w.ABSENT_PREFIX if sha == BASE else "") + "entry.a.png"
                (out / name).write_bytes(b"png-" + sha.encode())
                return {e: out / name for e in entries}

            worker.web_side = web_side
            receipt = worker.look(request(ui_files=["webviews/src/a.gallery.tsx"]))
            self.assertIsNotNone(receipt["posted_at"], receipt.get("error"))
            [scene] = receipt["scenes"]
            self.assertTrue(scene["before_absent"])
            self.assertNotIn("after_absent", scene)
            [sent] = list((Path(tmp) / "outbox").iterdir())
            self.assertIn("new: not in the base", sent.read_text())


class ConfigPushTests(unittest.TestCase):
    """A push that changes the gallery config (vite.config.ts) restarted the one vite for each side, and each restart
    recompiled the pages cold: 105 s. Now each config keeps its own warm gallery, and the two sides shoot at once."""

    def test_sides_on_two_configs_shoot_at_once_on_two_galleries_and_restart_nothing(self):
        with tempfile.TemporaryDirectory() as tmp:
            class ConfigWorker(FakeWorker):
                web_side = w.Worker.web_side
                gallery_for = w.Worker.gallery_for
                ensure_tree = w.Worker.ensure_tree

                def on_branch_tip_or_landed(self, head, branch):
                    return True

            worker = ConfigWorker(Path(tmp))
            worker.clone.mkdir(parents=True)
            subprocess.run(["git", "init", "-q", str(worker.clone)], check=True)
            base = commit(worker.clone, {"webviews/vite.config.ts": "a", "webviews/src/a.tsx": "1"})
            head = commit(worker.clone, {"webviews/vite.config.ts": "b", "webviews/src/a.tsx": "2"})
            head2 = commit(worker.clone, {"webviews/src/a.tsx": "3"})
            self.assertNotEqual(worker.gallery_key(base), worker.gallery_key(head))
            self.assertEqual(worker.gallery_key(head), worker.gallery_key(head2))
            both_shooting = threading.Barrier(2, timeout=10)
            events = []
            saved = {k: getattr(w.Gallery, k) for k in ("install", "start", "stop", "scenes", "shoot")}

            def shoot(g, entries, out, absent=None):
                events.append(("shoot", g.name, g.key))
                if len(events) <= 2:
                    both_shooting.wait()  # the first look: both sides must be shooting at once
                out.mkdir(parents=True, exist_ok=True)
                for e in entries:
                    (out / f"{e}.png").write_bytes(g.key.encode())
                return {e: f"{e}.png" for e in entries}

            w.Gallery.install = lambda g: False
            w.Gallery.start = lambda g: events.append(("start", g.name))
            w.Gallery.stop = lambda g: events.append(("stop", g.name))
            w.Gallery.scenes = lambda g, files: ["entry.a"]
            w.Gallery.shoot = shoot
            try:
                first = worker.look(request(head_sha=head, base_sha=base, ui_files=["webviews/src/a.tsx"]))
                self.assertIsNotNone(first["posted_at"], first.get("error"))
                second = worker.look(request(head_sha=head2, base_sha=base, ui_files=["webviews/src/a.tsx"]))
                self.assertIsNotNone(second["posted_at"], second.get("error"))
            finally:
                for k, v in saved.items():
                    setattr(w.Gallery, k, v)
            shots = [e for e in events if e[0] == "shoot"]
            self.assertEqual({(n, k) for _, n, k in shots[:2]},
                             {("web", worker.gallery_key(head)), ("web-2", worker.gallery_key(base))})
            self.assertEqual(shots[2:], [("shoot", "web", worker.gallery_key(head))])  # base cached; head2 warm
            self.assertNotIn("stop", [e[0] for e in events], events)
            self.assertEqual(len(worker.galleries), 2)
            self.assertNotEqual(worker.galleries[0].port, worker.galleries[1].port)


class ColdSideTests(unittest.TestCase):
    """A config push's side on a restarted vite recompiled agent-pane's React Compiler pass cold (41-63 s; App.tsx
    alone ~33 s) and re-optimized deps a sibling had already bundled. Every gallery vite now reads one transform
    cache on disk, and each config keeps its own deps folder."""

    def test_every_gallery_vite_shares_the_transform_cache_and_each_config_its_deps(self):
        with tempfile.TemporaryDirectory() as tmp:
            worker = FakeWorker(Path(tmp))
            g2 = w.Gallery(worker, worker.state / "web-2", w.GALLERY_PORT + 1, "web-2")
            worker.galleries.append(g2)
            for g in worker.galleries:
                (g.tree / "webviews" / "node_modules").mkdir(parents=True)
            worker.web.key, g2.key = "k1", "k1"
            e1, e2 = worker.web.vite_env(), g2.vite_env()
            self.assertEqual(e1["CMUX_VITE_TRANSFORM_CACHE"], e2["CMUX_VITE_TRANSFORM_CACHE"])
            self.assertEqual(e1["CMUX_VITE_TRANSFORM_CACHE"], str(worker.state / "vite-transforms"))
            self.assertEqual(e1["CMUX_REACT_COMPILER"], "oxc")
            self.assertNotEqual(e1["CMUX_VITE_CACHE_DIR"], e2["CMUX_VITE_CACHE_DIR"])  # never one folder for two vites
            # Inside webviews/ (the gallery's fs.allow), so vite serves it.
            self.assertTrue(e1["CMUX_VITE_CACHE_DIR"].startswith(str(worker.web.tree / "webviews") + os.sep))
            # A spare on the same config starts from the sibling's bundled deps, not a scan and bundle.
            deps = worker.web.deps_dir() / "deps"
            deps.mkdir(parents=True)
            (deps / "_metadata.json").write_text('{"configHash": "x"}')
            (worker.web.deps_dir() / "deps_temp_1").mkdir()
            g2.seed_deps()
            self.assertEqual((g2.deps_dir() / "deps" / "_metadata.json").read_text(), '{"configHash": "x"}')
            self.assertFalse((g2.deps_dir() / "deps_temp_1").exists())
            # A gallery back on a config it served keeps that config's folder; the newest DEPS_KEYS stay.
            for i in range(w.DEPS_KEYS + 2):
                worker.web.key = f"n{i}"
                worker.web.seed_deps()
                os.utime(worker.web.deps_dir(), (1000 + i, 1000 + i))
            left = sorted(p.name for p in (worker.web.tree / "webviews" / "node_modules").glob(".vite-*"))
            self.assertEqual(len(left), w.DEPS_KEYS)
            self.assertIn(f".vite-n{w.DEPS_KEYS + 1}", left)
            self.assertNotIn(".vite-n0", left)

    def test_the_transform_cache_is_pruned_oldest_first_under_its_cap(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp) / "vite-transforms"
            for i in range(8):
                f = folder / f"{i:02x}" / f"{i}.json"
                f.parent.mkdir(parents=True)
                f.write_bytes(b"x" * (256 << 10))
                os.utime(f, (1000 + i, 1000 + i))
            self.assertEqual(w.prune_transforms(folder, cap_mb=4), 0)  # 2 MB under a 4 MB cap: nothing
            self.assertEqual(w.prune_transforms(folder, cap_mb=1), 5)  # down to 3/4 MB: the 5 oldest go
            self.assertEqual(sorted(p.name for p in folder.rglob("*.json")), ["5.json", "6.json", "7.json"])
            self.assertEqual(w.prune_transforms(Path(tmp) / "absent"), 0)


if __name__ == "__main__":
    unittest.main()
