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

    def web_install(self):
        return False

    def web_scenes(self, files):
        return ["entry.a"]

    def web_side(self, sha, entries):
        out = self.state / "shots" / "web" / sha
        out.mkdir(parents=True, exist_ok=True)
        self.shot.append(f"web:{sha}")
        for e in entries:
            (out / f"{e}.png").write_bytes(b"png-" + sha.encode())
        return {e: out / f"{e}.png" for e in entries}

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
            worker.fetch = lambda *shas: both_fetching.wait()
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
                self.assertEqual(worker.shoot_gallery(["a.b"], Path(tmp) / "one"), {"a.b": "a.b.png"})
                self.assertEqual(worker.shoot_gallery(["c"], Path(tmp) / "two"), {"c": "c.png"})
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
                # A head not under the base tip (another branch's commit): GitHub's turn (here: no origin).
                with self.assertRaises(w.LookError):
                    worker.on_branch_tip_or_landed(fork, "lane/x")
                self.assertEqual(asked, ["ls-remote"])
            finally:
                w.git = real_git

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
            worker.stop_gallery = lambda: stops.append(1)
            worker.checkout_web(one)  # first checkout: nothing ran on another config
            worker.checkout_web(two)
            self.assertEqual(stops, [])
            worker.checkout_web(three)
            self.assertEqual(stops, [1])
            worker.checkout_web(four)
            self.assertEqual(stops, [1, 1])
            worker.checkout_web(four)
            self.assertEqual(stops, [1, 1])

    def test_an_entry_the_side_lacks_is_a_card_not_a_60_s_wait(self):
        with tempfile.TemporaryDirectory() as tmp:
            worker = w.Worker(Path(tmp) / "state", None, None, None, host="t")
            src = worker.web_tree / "webviews" / "src"
            src.mkdir(parents=True)
            (src / "a.gallery.tsx").write_text('const o = { id: "nested.option" };\nexport default { id: "held.a" };\n')
            (src / "b.gallery.ts").write_text('export default define({ id: "held.b", title: "B" });\n')
            self.assertEqual(worker.entry_ids(), {"held.a", "held.b"})
            worker.checkout_web = lambda sha: None
            worker.web_install = lambda: False
            worker.start_gallery = lambda: None
            seen = {}

            def shoot(entries, out, absent=None):
                seen.update(absent or {})
                out.mkdir(parents=True, exist_ok=True)
                files = {}
                for e in entries:
                    files[e] = (w.ABSENT_PREFIX if e in (absent or {}) else "") + f"{e}.png"
                    (out / files[e]).write_bytes(b"png")
                return files

            worker.shoot_gallery = shoot
            got = worker.web_side(BASE, ["held.a", "new.c"])
            self.assertEqual(seen, {"new.c": BASE})
            self.assertTrue(got["new.c"].name.startswith(w.ABSENT_PREFIX))
            self.assertFalse(got["held.a"].name.startswith(w.ABSENT_PREFIX))

    def test_a_new_entry_posts_with_its_before_marked_absent(self):
        with tempfile.TemporaryDirectory() as tmp:
            worker = FakeWorker(Path(tmp))

            def web_side(sha, entries):
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


if __name__ == "__main__":
    unittest.main()
