#!/usr/bin/env python3
"""look_page_log.py: a look's agent-pane console and the DOM snapshot with each shot (cmux#64758).

Run: python3 -m unittest scripts/cmux-next/tests/test_look_page_log.py
"""
from __future__ import annotations

import base64
import hashlib
import hmac
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
import unittest.mock
import urllib.error
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import look_page_log as plog  # noqa: E402

_spec = importlib.util.spec_from_file_location("hot_verify_page_log_under_test", HERE.parent / "hot-verify.py")
hv = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(hv)

TOKEN = "t" * 40
INDEX = ('<!doctype html>\n<html lang="en">\n<head>\n<meta charset="utf-8" />\n'
         '<meta http-equiv="Content-Security-Policy" content="script-src \'self\'; connect-src \'none\'" />\n'
         '<script src="pane.js"></script>\n</head>\n<body><main id="root"></main></body>\n</html>\n')


def bundles_at(root: Path) -> Path:
    pane = root / plog.PANE
    pane.mkdir(parents=True)
    (pane / "index.html").write_text(INDEX)
    (pane / "pane.js").write_text("console.log('pane')\n")
    return root


def b64(message: dict) -> str:
    return base64.urlsafe_b64encode(json.dumps(message).encode()).decode().rstrip("=")


class StageTest(unittest.TestCase):
    def test_the_staged_pane_loads_the_probe_first_and_the_cache_is_untouched(self):
        with tempfile.TemporaryDirectory() as tmp:
            cache = bundles_at(Path(tmp) / "cache")
            staged = plog.stage(cache, Path(tmp) / "staged")
            html = (staged / plog.PANE / "index.html").read_text()
            head = html[html.index("<head>"):]
            # The probe is the head's first element: before the pane's own scripts, so it hears their errors.
            self.assertTrue(head.startswith(f'<head>\n<script src="{plog.PROBE_NAME}"></script>'), head[:120])
            self.assertEqual((staged / plog.PANE / plog.PROBE_NAME).read_text(), plog.PROBE.read_text())
            self.assertEqual((cache / plog.PANE / "index.html").read_text(), INDEX)
            self.assertFalse((cache / plog.PANE / plog.PROBE_NAME).exists())
            self.assertEqual((staged / plog.PANE / "pane.js").read_text(), "console.log('pane')\n")


class SinkTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.web_dev = self.root / "config" / "web-dev.json"
        self.web_dev.parent.mkdir()
        self.out = self.root / "out"
        self.sink = plog.Sink(self.out, self.web_dev)
        self.sink.start()
        self.addCleanup(self.sink.stop)
        self.addCleanup(self.tmp.cleanup)

    def get(self, path: str, nonce: str | None = None):
        request = urllib.request.Request(self.sink.url.rstrip("/") + path,
                                         headers={"X-Cmux-Dev-Nonce": nonce} if nonce else {})
        try:
            with urllib.request.urlopen(request, timeout=10) as answer:
                return answer.status, dict(answer.headers)
        except urllib.error.HTTPError as error:
            return error.code, dict(error.headers)

    def send(self, kind: str, message: dict, chunk: int = 7, mid: str = "p1-0") -> None:
        text = b64(message)
        parts = [text[i:i + chunk] for i in range(0, len(text), chunk)]
        for index, part in enumerate(parts):
            status, _ = self.get(f"/agent-pane/__look_probe/{kind}?id={mid}&i={index}&n={len(parts)}&d={part}")
            self.assertEqual(status, 200)

    def test_every_answer_proves_the_token_web_dev_json_holds_now(self):
        # web-overlay.sh writes the token after the sink starts: the sink reads it on each request.
        status, headers = self.get("/agent-pane/index.html", "n1")
        self.assertEqual(status, 404)
        self.assertNotIn("X-Cmux-Dev-Proof", headers)
        self.web_dev.write_text(json.dumps({"server": self.sink.url, "token": TOKEN}))
        status, headers = self.get("/agent-pane/index.html", "n2")
        # 404: the app serves every file but the probe's from the overlay.
        self.assertEqual(status, 404)
        self.assertEqual(headers["X-Cmux-Dev-Proof"], hmac.new(TOKEN.encode(), b"n2", hashlib.sha256).hexdigest())

    def test_console_lines_arrive_in_chunks_and_are_kept_in_order(self):
        lines = [{"t": 1, "level": "error", "text": "TypeError: Failed to fetch dynamically imported module é"},
                 {"t": 2, "level": "unhandledrejection", "text": "x & y = 100%"}]
        self.send("console", {"page": "p1", "href": "cmux-page://cmux.agent/", "lines": lines})
        kept = [json.loads(line) for line in (self.out / "page/console.jsonl").read_text().splitlines()]
        self.assertEqual([k["text"] for k in kept], [line["text"] for line in lines])
        self.assertEqual(kept[0]["page"], "p1")

    def test_a_chunk_that_is_not_base64url_is_not_taken(self):
        status, _ = self.get("/agent-pane/__look_probe/console?id=p1-0&i=0&n=1&d=%257B%2522")
        self.assertEqual(status, 200)
        self.assertFalse((self.out / "page/console.jsonl").exists())

    def dom(self, mid: str, page: str, at: float, visible: bool = True, **fields) -> None:
        self.send("dom", {"page": page, "t": at * 1000, "visibility": "visible" if visible else "hidden",
                          "boxes": [], "text": "", "html": "<main id=\"root\"></main>", **fields}, mid=mid)

    def shot(self, name: str, at: float) -> Path:
        png = self.out / name
        png.parent.mkdir(parents=True, exist_ok=True)
        png.write_bytes(b"png")
        os.utime(png, (at, at))
        return png

    def test_each_shot_takes_the_snapshot_the_page_took_last_before_it(self):
        now = time.time()
        before = self.shot("before/dark.png", now - 60)
        self.dom("p1-1", "p1", now - 30, text="")
        # By the page's clock, not by when its last chunk came in: a big snapshot sent in 90 chunks may arrive after
        # the shot of the DOM it holds.
        self.dom("p1-2", "p1", now - 10, text="Type a question")
        first = self.shot("after/dark.png", now - 20)
        later = self.shot("steps/new-tab.png", now - 5)
        facts = self.sink.attach(self.out)
        self.assertEqual(json.loads(first.with_suffix(".dom.json").read_text())["text"], "")
        self.assertEqual(json.loads(later.with_suffix(".dom.json").read_text())["text"], "Type a question")
        self.assertFalse(before.with_suffix(".dom.json").exists())
        self.assertEqual(facts["shots_without_dom"], ["before/dark.png"])
        self.assertEqual(sorted(facts["shots_with_dom"]), ["after/dark.png", "steps/new-tab.png"])
        self.assertEqual((facts["console_file"], facts["dom_file"], facts["dom"]),
                         ("page/console.jsonl", "page/dom.jsonl", 2))
        self.assertFalse(facts["overlay_start_fallback"])
        self.assertEqual(len((self.out / "page/dom.jsonl").read_text().splitlines()), 2)
        self.assertFalse((self.out / "page/.dom").exists())

    def test_a_shot_prefers_the_visible_pane_over_a_hidden_spare_s_newer_snapshot(self):
        now = time.time()
        self.dom("shown-1", "shown", now - 20, text="New Tab")
        self.dom("spare-1", "spare", now - 10, visible=False, text="spare")
        png = self.shot("after/light.png", now - 5)
        self.sink.attach(self.out)
        kept = json.loads(png.with_suffix(".dom.json").read_text())
        self.assertEqual(kept["text"], "New Tab")
        self.assertEqual([o["page"] for o in kept["other_pages"]], ["spare"])

    def test_nothing_lands_after_the_shots_take_their_snapshots(self):
        self.sink.attach(self.out)
        self.dom("late-1", "p1", time.time(), text="late")
        self.send("console", {"page": "p1", "lines": [{"t": 1, "level": "log", "text": "late"}]}, mid="late-2")
        self.assertFalse((self.out / "page/dom.jsonl").exists())
        self.assertFalse((self.out / "page/console.jsonl").exists())

    def test_a_sink_that_never_starts_leaves_no_page_folder(self):
        idle = plog.Sink(self.root / "idle", self.web_dev)
        idle.stop()
        self.assertFalse((self.root / "idle" / "page").exists())

    @unittest.skipUnless(shutil.which("node"), "node runs the probe")
    def test_the_probe_s_own_requests_decode_in_the_sink(self):
        # The page side: look-page-probe.js in a minimal DOM, its <script src> URLs fed to the sink as the app's
        # scheme handler forwards them.
        harness = r"""
const urls = [];
const el = () => ({ remove() {}, set src(v) { urls.push(v); setTimeout(() => this.onload && this.onload(), 1); } });
global.window = global; global.location = { href: "cmux-page://cmux.agent/" };
global.MutationObserver = class { observe() {} };
global.innerWidth = 800; global.innerHeight = 600; global.addEventListener = () => {};
global.document = { title: "cmux Agent", head: { appendChild() {} }, body: { innerText: "Type a question é" },
  documentElement: {}, visibilityState: "visible", addEventListener() {},
  createElement: el, getElementById: () => ({ outerHTML: "<main id=\"root\">é & 100%</main>" }),
  querySelector: () => null };
global.getComputedStyle = () => ({});
require(process.argv[1]);
console.error("boom", new Error("bad chunk"));
setTimeout(() => { process.stdout.write(JSON.stringify(urls)); process.exit(0); }, 1600);
"""
        done = subprocess.run(["node", "-e", harness, str(plog.PROBE)], capture_output=True, text=True, timeout=30)
        self.assertEqual(done.returncode, 0, done.stderr)
        for url in json.loads(done.stdout):
            path, _, query = url.partition("?")
            self.sink.part(path.rsplit("/", 1)[1], query)
        console = [json.loads(line) for line in (self.out / "page/console.jsonl").read_text().splitlines()]
        self.assertTrue(any(line["level"] == "error" and "bad chunk" in line["text"] for line in console), console)
        dom = [json.loads(line) for line in (self.out / "page/dom.jsonl").read_text().splitlines()]
        self.assertEqual(dom[0]["text"], "Type a question é")
        self.assertEqual(dom[0]["html_length"], len("<main id=\"root\">é & 100%</main>"))


class ApplyWebTest(unittest.TestCase):
    KEY = "a" * 64

    def test_a_look_s_published_web_points_the_copy_at_the_sink_and_installs_the_staged_bundles(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            cache = bundles_at(root / "cache")
            scratch = root / "scratch"
            scratch.mkdir()
            sink = plog.Sink(root / "out", root / "web-dev.json")
            ran = []

            def run(argv, **_kw):
                ran.append([Path(argv[0]).name, *argv[1:]])
                if argv[1:2] == ["install"]:
                    html = (Path(argv[2]) / plog.PANE / "index.html").read_text()
                    ran[-1].append("probe" if plog.PROBE_NAME in html else "no probe")
                return subprocess.CompletedProcess(argv, 0, "", "")

            side = unittest.mock.Mock(env=lambda: {})
            with unittest.mock.patch.object(hv, "published_web_key", return_value=self.KEY), \
                    unittest.mock.patch.object(hv, "fetch_bundles", return_value=cache), \
                    unittest.mock.patch.object(hv.subprocess, "run", side_effect=run):
                try:
                    done = hv.apply_web(root, {"head": "b" * 40, "layers": ["web"]}, None, side, scratch,
                                        page_log=sink)
                finally:
                    sink.stop()
            self.assertEqual(ran[0], ["web-overlay.sh", "server", done["page_log"]])
            self.assertEqual(ran[1][:2], ["web-overlay.sh", "install"])
            self.assertEqual(Path(ran[1][2]), scratch / "page-log-bundles")
            self.assertEqual(ran[1][-1], "probe")
            self.assertEqual(done["how"], "published bundles")

    def test_with_no_page_log_the_cached_bundles_go_in_as_they_are(self):
        with tempfile.TemporaryDirectory() as tmp:
            cache = bundles_at(Path(tmp) / "cache")
            ran = []

            def run(argv, **_kw):
                ran.append([Path(argv[0]).name, *argv[1:3]])
                return subprocess.CompletedProcess(argv, 0, "", "")

            with unittest.mock.patch.object(hv, "published_web_key", return_value=self.KEY), \
                    unittest.mock.patch.object(hv, "fetch_bundles", return_value=cache), \
                    unittest.mock.patch.object(hv.subprocess, "run", side_effect=run):
                done = hv.apply_web(Path(tmp), {"head": "b" * 40}, None, unittest.mock.Mock(env=lambda: {}),
                                    Path(tmp))
            self.assertEqual(ran, [["web-overlay.sh", "install", str(cache)]])
            self.assertNotIn("page_log", done)


if __name__ == "__main__":
    unittest.main()
