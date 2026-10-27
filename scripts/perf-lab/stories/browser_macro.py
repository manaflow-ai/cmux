#!/usr/bin/env python3
"""Story browser-macro: Speedometer 3.1, MotionMark 1.3 and JetStream 2.2 in a cmux Chromium tab and in Chrome stable.

Chromium runs these suites across browsers with crossbench (third_party/crossbench: crossbench/benchmarks/speedometer,
motionmark and jetstream): one pinned suite version, each browser launched fresh with its own profile, the suite's own
score read from the page. WebKit's run-benchmark does the same from a local copy served by a local HTTP server that
the page posts its result to (Tools/Scripts/webkitpy/benchmark_runner, JetStream's `?report=true` path). This story
does both:

- Each suite is a pinned commit of its WebKit repository (SUITES: commit and the digest of its file tree). The copy is
  fetched once into the account's cache and checked against the digest before every invocation; `fetch` fills the
  cache ahead of time. A copy whose digest differs is refused, never served.
- A loopback HTTP server (one per run) serves the copy and adds one script to the suite's entry page (HARNESS_JS,
  never a change on disk). The script starts the suite and posts its per-iteration scores back to the server; a
  JetStream run posts its own report to `/report`.
- 0 network: both browsers resolve only loopback (host-resolver-rules `MAP * ~NOTFOUND`, EXCLUDE localhost and
  127.0.0.1). The cmux arm gets the rule through CMUX_NEXT_BENCH_CEF_SWITCHES (CEFSwitches keeps it in a bench
  build only, corpus/README-wpr.md); Chrome gets it on its command line with Telemetry's background-networking
  switches (catapult telemetry/internal/backends/chrome/chrome_startup_args.py). A page request the copy cannot
  answer is a miss, and a run with a miss has no result.
- The cmux arm launches a fresh bench app (BenchApp, its Chromium storage emptied first: no HTTP cache) and checks
  debug.cef before the tab opens and after the suite ends: Chromium available and no tab fell back to WebKit, so a
  WebKit score is never stored as Chromium's. The Chrome arm is the vendor-signed Chrome stable of
  scripts/perf-bench/fetch_browsers.py (or --chrome), started with a temporary profile and the same window size.
- Interleaved: each round runs every suite in both arms, and the arm order flips each round (ABBA), so drift over
  the night (heat, background work) falls on both arms alike.

result-v1, all `engine: chromium` (Chrome is the Chromium engine; the browser is in the metric name):

  browser_macro.<arm>.<suite>.score                    each iteration's suite score (higher is better); arm is cmux
                                                       or chrome
  browser_macro.cmux_over_chrome.<suite>.score_ratio   per round, the cmux arm's mean score over Chrome's

Every result names the measured cmux build (its sha and config), the Chrome series too: a Chrome series is the
night's reference beside cmux's, as Chrome's own reference build runs beside tip (reference.py), and Chrome's version
is in the runs file.

A suite's runs compare only when every run measured the same thing: MotionMark's score depends on the frame rate it
detected and on the canvas size the window picked, so a night whose runs disagree on either writes no MotionMark
result (the reason is in the runs file).

Suite keys: speedometer3_1, motionmark1_3, jetstream2_2 (a re-pin to another version is a new series). Beside the
result, browser-macro.runs.json keeps each run (arm, round, scores, the suite's details, requests served) with the
pins and Chrome's version.

The story takes the runner's `--app APP --tag TAG --out DIR` (stories.d/README.md). Exit codes: 0 every suite
written, 1 some suites written (the others listed), 2 nothing to write, 3 env-invalid (the build, the host, Chrome
or a pinned copy cannot be named, checked before any browser starts; or a launch refused for the host, such as no
GUI session or Low Power Mode, which the runs file then names), 128 + N when signal N ended it. A run whose arm
did not start (a failed launch or spawn) fails only its suite.

  python3 -I scripts/perf-lab/stories/browser_macro.py --app APP --tag TAG --out DIR       # as the runner
  python3 -I scripts/perf-lab/stories/browser_macro.py fetch                               # fill the pinned copies
  python3 -I scripts/perf-lab/stories/browser_macro.py serve SUITE                         # serve one copy by hand

Not a CI gate (Lawrence 2026-10-23); the lab runs it as a T2 story (stories.d/browser-macro.json).
Tests: python3 -m unittest scripts/perf-lab/tests/test_browser_macro.py
"""
from __future__ import annotations

import sys

sys.dont_write_bytecode = True  # importing bench_launch, wpr and their siblings must not write __pycache__

import argparse
import hashlib
import http.server
import importlib.util
import io
import json
import math
import mimetypes
import os
import plistlib
import posixpath
import pwd
import re
import shutil
import signal
import subprocess
import tarfile
import tempfile
import threading
import urllib.parse
import urllib.request
import xml.parsers.expat
from dataclasses import dataclass, field
from pathlib import Path
from types import ModuleType
from typing import Any, Callable, Mapping, Sequence

HERE = Path(__file__).resolve().parent
PERF_LAB = HERE.parent
SCRIPTS = PERF_LAB.parent
ROOT = SCRIPTS.parent

STORY = "browser-macro"
STORY_CONFIG = "bench"  # stories.d/browser-macro.json
SESSION = "light"
ENGINE = "chromium"
ARMS = ("cmux", "chrome")
RATIO = "cmux_over_chrome"
ROUNDS = 2
RUNS_FILE = "browser-macro.runs.json"
ENV_INVALID = 3
FORWARDED_SIGNALS = (signal.SIGTERM, signal.SIGINT, signal.SIGHUP)
WINDOW = (40, 40, 1440, 900)  # x, y, width, height of both arms' windows (BenchApp's default window)
START_DELAY_MS = 1000  # the harness starts a suite this long after the page's load event
# Only loopback resolves: every other host fails before a connection (HostMappingRules: exclusions first).
LOOPBACK_ONLY_RULES = "MAP * ~NOTFOUND,EXCLUDE localhost,EXCLUDE 127.0.0.1"
HARNESS_PATH = "/__cmux_macro__/harness.js"
REPORT_PATH = "/__cmux_macro__/report"
JETSTREAM_REPORT_PATH = "/report"  # JetStreamDriver.js reportScoreToRunBenchmarkRunner posts here with ?report=true
FETCH_URL = "https://codeload.github.com/WebKit/{repo}/tar.gz/{commit}"
FETCH_BROWSERS = SCRIPTS / "perf-bench" / "fetch_browsers.py"
MAX_REPORT_BYTES = 8 << 20
SHUTDOWN_POLL_S = 0.05  # serve_forever's poll interval: how long shutdown() waits for the loop to see it
USER_AGENT = "cmux-perf-lab (+https://github.com/manaflow-ai/cmux)"


@dataclass(frozen=True)
class Suite:
    key: str  # the metric segment
    title: str
    repo: str  # github.com/WebKit/<repo>
    commit: str
    tree: str  # tree_digest of the extracted commit
    root: str  # the served folder inside the copy
    entry: str  # the entry page inside `root`
    query: str  # the entry page's query
    iterations: int  # the scores one run posts
    timeout_s: int  # one run, from the tab's open to the report


# Speedometer's release/3.1 branch head, MotionMark's release/MotionMark1.3 tag, JetStream's JetStream2.2 branch head.
# Each suite runs its own default iteration count (Speedometer 10, MotionMark 1, JetStream 1 page run).
SUITES = (
    Suite(key="speedometer3_1", title="Speedometer 3.1", repo="Speedometer",
          commit="1386415be8fef2f6b6bbdbe1828872471c5d802a",
          tree="sha256:2c09803be0d706bc884d7a0148a4f8bd363207c0b5c1b60f58f860725bd38060",
          root="", entry="index.html", query="", iterations=10, timeout_s=1800),
    Suite(key="motionmark1_3", title="MotionMark 1.3", repo="MotionMark",
          commit="5d9c88136d59c11daf78d539c73e4e3e88c091ab",
          tree="sha256:de3687985c1221797de60bb5380235409e32880476d36f78dfb38f5277cb29f1",
          root="MotionMark", entry="index.html", query="", iterations=1, timeout_s=1200),
    Suite(key="jetstream2_2", title="JetStream 2.2", repo="JetStream",
          commit="332d8ee1e4d5c40d9492c56f6865e64a9525ee9f",
          tree="sha256:d1984112922ae1577727c9b222b4dedb54ddcfd43e71e305a80e7c5c535fd5bd",
          root="", entry="index.html", query="report=true", iterations=1, timeout_s=1800),
)
SUITE_KEYS = tuple(suite.key for suite in SUITES)
COMPARED_INFO = ("frame_rate", "configuration")  # a run's `info` that every run of its suite must share
JETSTREAM = "jetstream2_2"

# Each suite's own completion hook (the suite's page objects, at the pinned commits):
#   Speedometer  globalThis.benchmarkClient (resources/main.mjs): start(), didFinishLastIteration(metrics) after
#                _measuredValuesList got one {score} per iteration, handleError(error).
#   MotionMark   benchmarkController.frameRateDeterminationComplete(rate) ends the start-up frame-rate probe, then
#                startBenchmark(); benchmarkRunnerClient.didFinishLastIteration() with results.results[i].score
#                (resources/runner/motionmark.js).
#   JetStream    ?report=true starts the run 4 s after initialize and posts resultsJSON() to /report
#                (JetStreamDriver.js); JetStream.reportError(benchmark) and the #status `error` class are its failures.
HARNESS_JS = r"""(function () {
  "use strict";
  var suite = document.currentScript.dataset.suite;
  var startDelay = Number(document.currentScript.dataset.startDelay);
  var sent = false;
  function post(body) {
    if (sent) return;
    sent = true;
    body.suite = suite;
    var request = new XMLHttpRequest();
    request.open("POST", "__REPORT__", true);
    request.setRequestHeader("Content-Type", "application/json");
    request.send(JSON.stringify(body));
  }
  function fail(where, error) {
    post({error: where + ": " + String((error && error.stack) || error)});
  }
  function later(work) {
    setTimeout(function () {
      try { work(); } catch (error) { fail(suite + " start", error); }
    }, startDelay);
  }
  function speedometer() {
    var client = globalThis.benchmarkClient;
    var finish = client.didFinishLastIteration.bind(client);
    var handle = client.handleError.bind(client);
    client.didFinishLastIteration = function (metrics) {
      post({scores: client._measuredValuesList.map(function (values) { return values.score; })});
      return finish(metrics);
    };
    client.handleError = function (error) {
      fail("speedometer", error);
      return handle(error);
    };
    window.addEventListener("load", function () { later(function () { client.start(); }); });
  }
  function motionmark() {
    var controller = window.benchmarkController;
    var client = window.benchmarkRunnerClient;
    var ready = controller.frameRateDeterminationComplete.bind(controller);
    var finish = client.didFinishLastIteration.bind(client);
    controller.frameRateDeterminationComplete = function (rate) {
      ready(rate);
      later(function () { controller.startBenchmark(); });
    };
    client.didFinishLastIteration = function () {
      var dashboard = client.results;
      post({scores: dashboard.results.map(function (iteration) { return iteration.score; }),
            info: {frame_rate: dashboard.options["frame-rate"], configuration: dashboard.options.configuration}});
      return finish();
    };
  }
  function jetstream() {
    var driver = window.JetStream;
    var reportError = driver.reportError.bind(driver);
    driver.reportError = function (benchmark) {
      fail("jetstream", "benchmark " + benchmark.name + " failed");
      return reportError(benchmark);
    };
    var status = document.getElementById("status");
    new MutationObserver(function () {
      if (status.classList.contains("error")) fail("jetstream", status.textContent.trim());
    }).observe(status, {attributes: true, attributeFilter: ["class"]});
  }
  var hooks = {speedometer3_1: speedometer, motionmark1_3: motionmark, jetstream2_2: jetstream};
  document.addEventListener("DOMContentLoaded", function () {
    try { hooks[suite](); } catch (error) { fail(suite + " hooks", error); }
  });
})();
""".replace("__REPORT__", REPORT_PATH)


class StoryError(RuntimeError):
    """A run has no result (a timeout, a suite error, a miss, a WebKit fallback, an arm that did not start)."""


class EnvInvalid(RuntimeError):
    """The build, the host, Chrome or a pinned copy cannot be named: nothing ran."""


class NoChromium(RuntimeError):
    """debug.cef says the measured build cannot show the suite in Chromium (unavailable, or a tab fell back to
    WebKit): no cmux run of the night can count, so the night ends."""


class Interrupted(BaseException):
    """A forwarded signal ended the story; the arms' teardown still runs."""

    def __init__(self, signum: int):
        super().__init__(signum)
        self.signum = signum


def load_by_path(name: str, path: Path) -> ModuleType:
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module  # dataclasses resolve their module through sys.modules
    spec.loader.exec_module(module)
    return module


# wpr.bench_launcher loads bench_launch under this name: one copy, so its LaunchError is the class CmuxArm catches.
bench_launch = load_by_path("perf_lab_bench_launch", SCRIPTS / "cmux-next" / "bench_launch.py")
perf_result = load_by_path("perf_lab_browser_macro_perf_result", PERF_LAB / "perf_result.py")
wpr = load_by_path("perf_lab_browser_macro_wpr", PERF_LAB / "corpus" / "wpr.py")
# BenchApp.launch refuses these for the host before the app starts, so every later run would be refused too.
HOST_LAUNCH_REASONS = frozenset({"no-gui-session", "low-power-mode", "low-power-mode-not-restored"})


def suite_named(key: str) -> Suite:
    for suite in SUITES:
        if suite.key == key:
            return suite
    raise KeyError(f"no suite {key!r}; the suites are {', '.join(SUITE_KEYS)}")


# ---------------------------------------------------------------- pinned copies

def account_home() -> Path:
    try:
        return Path(pwd.getpwuid(os.getuid()).pw_dir)
    except KeyError:
        return Path.home()


def default_cache(home: Path | None = None) -> Path:
    """The account's cache, not $HOME: a fleet step's HOME is a scratch folder the worker deletes."""
    return (home or account_home()) / "Library" / "Caches" / "cmux-perf-lab" / "browser-macro"


def copy_dir(cache: Path, suite: Suite) -> Path:
    return cache / f"{suite.repo}-{suite.commit}"


def tree_digest(root: Path) -> str:
    """sha256 over every regular file under ROOT in path order: its relative path, then its own sha256. A link or any
    other kind of file is refused, so the digest names everything a server could send."""
    lines = []
    for path in sorted(root.rglob("*"), key=lambda p: p.relative_to(root).as_posix()):
        if path.is_symlink() or not (path.is_file() or path.is_dir()):
            raise EnvInvalid(f"{path}: not a regular file or folder")
        if path.is_file():
            lines.append(f"{path.relative_to(root).as_posix()}\0{hashlib.sha256(path.read_bytes()).hexdigest()}\n")
    return "sha256:" + hashlib.sha256("".join(lines).encode("utf-8")).hexdigest()


def extract(archive: bytes, dest: Path) -> None:
    """The regular files and folders of a GitHub tarball into DEST, its top folder dropped. A link, a device, an
    absolute path or a `..` member is refused (tarfile's own `data` filter is not in every Python a lab host has)."""
    with tarfile.open(fileobj=io.BytesIO(archive), mode="r:gz") as tar:
        for member in tar.getmembers():
            if member.type == tarfile.XGLTYPE or member.type == tarfile.XHDTYPE:
                continue
            parts = member.name.split("/")[1:]
            relative = posixpath.normpath("/".join(parts)) if parts else "."
            if member.name.startswith("/") or relative.startswith("..") or "\0" in relative:
                raise EnvInvalid(f"tar member {member.name!r} leaves the copy")
            if relative == ".":
                continue
            target = dest / relative
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
            elif member.isfile():
                target.parent.mkdir(parents=True, exist_ok=True)
                source = tar.extractfile(member)
                target.write_bytes(source.read() if source is not None else b"")
            else:
                raise EnvInvalid(f"tar member {member.name!r} is not a regular file or folder")


def http_fetch(url: str) -> bytes:
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=600) as response:
        return response.read()


def pinned_copy(suite: Suite, cache: Path, fetch: Callable[[str], bytes] | None = http_fetch) -> Path:
    """The served folder of SUITE's checked copy in CACHE, fetched first when it is missing and FETCH is given. A copy
    whose tree digest is not the pin's is refused; a fetched one is moved into place only once it matches."""
    folder = copy_dir(cache, suite)
    if not folder.is_dir():
        if fetch is None:
            raise EnvInvalid(f"{folder}: no pinned copy of {suite.title} (run `browser_macro.py fetch`)")
        cache.mkdir(parents=True, exist_ok=True)
        staging = Path(tempfile.mkdtemp(prefix=f".{suite.repo}-", dir=cache))
        try:
            extract(fetch(FETCH_URL.format(repo=suite.repo, commit=suite.commit)), staging)
            got = tree_digest(staging)
            if got != suite.tree:
                raise EnvInvalid(f"{suite.title} at {suite.commit[:12]}: fetched tree {got}, the pin is {suite.tree}")
            os.replace(staging, folder)
        finally:
            shutil.rmtree(staging, ignore_errors=True)
    got = tree_digest(folder)
    if got != suite.tree:
        raise EnvInvalid(f"{folder}: tree {got} is not the pinned {suite.tree}; remove it and run fetch")
    served = folder / suite.root if suite.root else folder
    if not (served / suite.entry).is_file():
        raise EnvInvalid(f"{served}: no {suite.entry}")
    return served


# ---------------------------------------------------------------- the loopback server

@dataclass
class PageReport:
    scores: tuple[float, ...] = ()
    error: str | None = None
    info: dict[str, Any] = field(default_factory=dict)


def finite_scores(values: Any) -> tuple[float, ...] | None:
    if not isinstance(values, list) or not values:
        return None
    if not all(isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v) and v > 0 for v in values):
        return None
    return tuple(float(v) for v in values)


def page_report(body: Any) -> PageReport:
    """The harness's post: {scores: [...], info?} or {error}."""
    if not isinstance(body, dict):
        return PageReport(error=f"report is not an object: {json.dumps(body)[:200]}")
    if body.get("error"):
        return PageReport(error=str(body["error"])[:2000])
    scores = finite_scores(body.get("scores"))
    if scores is None:
        return PageReport(error=f"report has no positive finite scores: {json.dumps(body.get('scores'))[:200]}")
    info = body.get("info") if isinstance(body.get("info"), dict) else {}
    return PageReport(scores=scores, info=info)


def jetstream_report(body: Any) -> PageReport:
    """JetStream's resultsJSON(): {"JetStream2.0": {"tests": {name: {"metrics": {"Score": {"current": [s]}}}}}}. The
    run's score is the geometric mean of the benchmarks' scores, as Driver.start computes it."""
    try:
        tests = body["JetStream2.0"]["tests"]
        per = {name: test["metrics"]["Score"]["current"][0] for name, test in tests.items()}
    except (KeyError, TypeError, IndexError):
        return PageReport(error=f"JetStream report has no per-benchmark scores: {json.dumps(body)[:200]}")
    scores = finite_scores(list(per.values()))
    if scores is None:
        return PageReport(error=f"JetStream report has a benchmark without a positive score: {json.dumps(per)[:300]}")
    total = math.exp(sum(math.log(s) for s in scores) / len(scores))
    return PageReport(scores=(total,), info={"benchmarks": {k: float(v) for k, v in sorted(per.items())}})


CONTENT_TYPES = {".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8",
                 ".mjs": "text/javascript; charset=utf-8", ".css": "text/css; charset=utf-8",
                 ".json": "application/json", ".wasm": "application/wasm", ".svg": "image/svg+xml"}
HEAD_TAG = re.compile(rb"<head\b[^>]*>", re.IGNORECASE)


def content_type(path: Path) -> str:
    return CONTENT_TYPES.get(path.suffix.lower()) or mimetypes.guess_type(path.name)[0] or "application/octet-stream"


def with_harness(page: bytes, suite: Suite) -> bytes:
    """The entry page with the harness as the first script of its <head>, so its DOMContentLoaded hook runs before the
    suite's own."""
    match = HEAD_TAG.search(page)
    if match is None:
        raise StoryError(f"{suite.title} {suite.entry} has no <head>")
    tag = (f'<script src="{HARNESS_PATH}" data-suite="{suite.key}" data-start-delay="{START_DELAY_MS}">'
           "</script>").encode("utf-8")
    return page[:match.end()] + tag + page[match.end():]


class SuiteServer:
    """One run's server on 127.0.0.1: the copy, the harness, and the one report the run posts (`wait`)."""

    def __init__(self, root: Path, suite: Suite):
        self.root = root.resolve()
        self.suite = suite
        self.served = 0
        self.misses: list[str] = []
        self.extra_reports = 0
        self._report: PageReport | None = None
        self._done = threading.Event()
        self._lock = threading.Lock()  # the handler threads' counters and the report
        self._httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), self._handler())
        self._httpd.daemon_threads = True
        self._thread = threading.Thread(target=self._httpd.serve_forever, args=(SHUTDOWN_POLL_S,),
                                        name=f"browser-macro-{suite.key}", daemon=True)

    @property
    def port(self) -> int:
        return self._httpd.server_address[1]

    @property
    def url(self) -> str:
        query = f"?{self.suite.query}" if self.suite.query else ""
        return f"http://127.0.0.1:{self.port}/{self.suite.entry}{query}"

    def __enter__(self) -> "SuiteServer":
        self._thread.start()
        return self

    def __exit__(self, *_exc) -> None:
        self._httpd.shutdown()
        self._httpd.server_close()
        self._thread.join(timeout=10)

    def wait(self, timeout_s: float) -> PageReport:
        if not self._done.wait(timeout_s):
            raise StoryError(f"{self.suite.title}: no report in {timeout_s:g} s ({self.served} requests served)")
        with self._lock:
            report = self._report
        if report.error:
            raise StoryError(f"{self.suite.title}: {report.error}")
        if len(report.scores) != self.suite.iterations:
            raise StoryError(f"{self.suite.title}: {len(report.scores)} scores, the suite runs {self.suite.iterations}")
        return report

    def summary(self) -> dict[str, Any]:
        with self._lock:
            return {"port": self.port, "served": self.served, "misses": list(self.misses),
                    "extra_reports": self.extra_reports}

    def _count(self, path: str | None = None, missed: bool = False) -> None:
        with self._lock:
            if missed:
                self.misses.append(path or "")
            else:
                self.served += 1

    def _deliver(self, report: PageReport) -> None:
        with self._lock:
            if self._report is not None:
                self.extra_reports += 1
                return
            self._report = report
        self._done.set()

    def file_for(self, url_path: str) -> Path | None:
        """The copy's file for URL_PATH, or None for a path outside the copy or with no file."""
        relative = posixpath.normpath(urllib.parse.unquote(url_path)).lstrip("/")
        if relative in ("", "."):
            relative = self.suite.entry
        if relative.startswith("..") or "\0" in relative:
            return None
        path = (self.root / relative).resolve()
        if path.is_dir():
            path = path / "index.html"
        if self.root not in path.parents or not path.is_file():
            return None
        return path

    def body_for(self, url_path: str) -> tuple[bytes, str] | None:
        if url_path == HARNESS_PATH:
            return HARNESS_JS.encode("utf-8"), CONTENT_TYPES[".js"]
        path = self.file_for(url_path)
        if path is None:
            return None
        body = path.read_bytes()
        if path == (self.root / self.suite.entry).resolve():
            body = with_harness(body, self.suite)
        return body, content_type(path)

    def _handler(self):
        server = self

        class Handler(http.server.BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *_args) -> None:
                pass  # the counters and runs.json keep what a run needs

            def _send(self, status: int, body: bytes, kind: str, head: bool = False) -> None:
                self.send_response(status)
                self.send_header("Content-Type", kind)
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                if not head:
                    self.wfile.write(body)

            def _get(self, head: bool) -> None:
                url_path = urllib.parse.urlsplit(self.path).path
                if url_path == "/favicon.ico":  # the browser's own request, not the page's
                    self._send(204, b"", "image/x-icon", head)
                    return
                try:
                    found = server.body_for(url_path)
                except StoryError as error:
                    server._deliver(PageReport(error=str(error)))
                    self._send(500, str(error).encode("utf-8"), "text/plain; charset=utf-8", head)
                    return
                if found is None:
                    server._count(url_path, missed=True)
                    self._send(404, b"not in the pinned copy", "text/plain; charset=utf-8", head)
                    return
                server._count()
                self._send(200, found[0], found[1], head)

            def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler's name
                self._get(head=False)

            def do_HEAD(self) -> None:  # noqa: N802
                self._get(head=True)

            def do_POST(self) -> None:  # noqa: N802
                url_path = urllib.parse.urlsplit(self.path).path
                length = int(self.headers.get("Content-Length") or 0)
                if url_path not in (REPORT_PATH, JETSTREAM_REPORT_PATH) or not 0 < length <= MAX_REPORT_BYTES:
                    server._count(url_path, missed=True)
                    self._send(404, b"", "text/plain; charset=utf-8")
                    return
                raw = self.rfile.read(length)
                try:
                    body = json.loads(raw)
                except ValueError:
                    body = None
                if url_path == JETSTREAM_REPORT_PATH and server.suite.key == JETSTREAM:
                    server._deliver(jetstream_report(body))
                elif url_path == REPORT_PATH:
                    server._deliver(page_report(body))
                else:
                    server._count(url_path, missed=True)
                self._send(204, b"", "text/plain; charset=utf-8")

        return Handler


# ---------------------------------------------------------------- the arms

@dataclass
class ArmRun:
    report: PageReport
    detail: dict[str, Any] = field(default_factory=dict)


class CmuxArm:
    """A fresh bench app per run, its Chromium storage emptied first, the suite in a foreground Chromium tab. debug.cef
    is checked before the tab opens and after the suite ends."""

    name = "cmux"

    def __init__(self, app: Path, launch: Callable[[dict[str, str], Path], Any], chromium_root: Path | None):
        self.app = app
        self.launch = launch
        self.chromium_root = chromium_root
        self.features: tuple | None = None  # the first launch's features.list snapshot (BenchApp.features)

    @staticmethod
    def switches() -> str:
        return f"host-resolver-rules={LOOPBACK_ONLY_RULES}"

    def start(self, out: Path) -> Any:
        """A launched bench app with the loopback-only switch and empty Chromium storage. A launch the host refuses
        is EnvInvalid; any other failure to start is this run's StoryError."""
        try:
            if self.chromium_root is not None:
                wpr.empty_chromium_root(self.chromium_root)
            return self.launch(wpr.bench_env(self.switches()), out)
        except bench_launch.LaunchError as error:
            detail = f"{error.reason}: {error.report.get('detail', '')}"
            if error.reason in HOST_LAUNCH_REASONS:
                raise EnvInvalid(f"cmux arm: the host refused the launch: {detail}") from None
            raise StoryError(f"cmux arm did not start: {detail}") from None
        except (wpr.WprError, OSError) as error:
            raise StoryError(f"cmux arm did not start: {error}") from None

    def run(self, server: SuiteServer, out: Path) -> ArmRun:
        switches = self.switches()
        bench = self.start(out)
        try:
            if (getattr(bench, "launched_env", None) or {}).get(wpr.BENCH_SWITCHES_ENV) != switches:
                raise StoryError("the bench app was not launched with the loopback-only resolver switch")
            if self.features is None:
                self.features = getattr(bench, "features", None)
            pages = wpr.AppPages(bench.rpc)
            problem = wpr.cef_problem(pages.cef())
            if problem:
                raise NoChromium(f"cmux arm: {problem}")
            tab, why = pages.open(server.url)
            if tab is None:
                raise StoryError(f"cmux arm: the Chromium tab did not open: {why}")
            report = server.wait(server.suite.timeout_s)
            problem = wpr.cef_problem(pages.cef()) or wpr.page_problem(
                bench.rpc("debug.browser.page_status", {"tab": tab}, timeout=30))
            if problem:
                raise StoryError(f"cmux arm after {server.suite.title}: {problem}")
            return ArmRun(report, {"tab": tab})
        finally:
            bench.stop()


def bundle_info(bundle: Path) -> dict[str, Any]:
    """A Chrome .app's Info.plist; EnvInvalid when it cannot be read as a dictionary."""
    path = bundle / "Contents" / "Info.plist"
    try:
        with open(path, "rb") as f:
            info = plistlib.load(f)
    except (OSError, ValueError, xml.parsers.expat.ExpatError) as error:  # InvalidFileException is a ValueError
        raise EnvInvalid(f"{path}: {error}") from None
    if not isinstance(info, dict):
        raise EnvInvalid(f"{path}: not a dictionary")
    return info


def chrome_binary(bundle: Path) -> Path:
    """The executable of a Chrome .app bundle (its CFBundleExecutable), or BUNDLE itself when it is an executable."""
    if bundle.suffix == ".app":
        executable = bundle_info(bundle).get("CFBundleExecutable")
        if not isinstance(executable, str) or not executable:
            raise EnvInvalid(f"{bundle}: Info.plist names no CFBundleExecutable")
        return bundle / "Contents" / "MacOS" / executable
    return bundle


def chrome_version(bundle: Path) -> str:
    if bundle.suffix == ".app":
        return str(bundle_info(bundle).get("CFBundleShortVersionString") or "unknown")
    try:
        done = subprocess.run([str(bundle), "--version"], capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise EnvInvalid(f"{bundle} --version: {error}") from None
    return done.stdout.strip() or "unknown"


def chrome_argv(binary: Path, profile: Path, url: str) -> list[str]:
    """Chrome stable as a person runs it, with no first-run UI, no keychain, no background network and only loopback
    resolving (Telemetry's chrome_startup_args.py and crossbench's chromium.py use the same switches)."""
    x, y, width, height = WINDOW
    return [str(binary), f"--user-data-dir={profile}", "--no-first-run", "--no-default-browser-check",
            "--password-store=basic", "--use-mock-keychain", "--disable-background-networking",
            "--disable-component-update", "--disable-sync", "--disable-domain-reliability", "--metrics-recording-only",
            "--hide-crash-restore-bubble", "--mute-audio", f"--host-resolver-rules={LOOPBACK_ONLY_RULES}",
            f"--window-position={x},{y}", f"--window-size={width},{height}", url]


class ChromeArm:
    """Chrome stable with a new temporary profile per run; its process group ends with the run."""

    name = "chrome"

    def __init__(self, bundle: Path, spawn: Callable[..., Any] = subprocess.Popen):
        self.bundle = bundle
        self.binary = chrome_binary(bundle)
        self.spawn = spawn

    def start(self, url: str, out: Path) -> tuple[Any, Path]:
        """Chrome at URL with a new profile, or this run's StoryError when it did not start."""
        profile = None
        try:
            out.mkdir(parents=True, exist_ok=True)
            profile = Path(tempfile.mkdtemp(prefix="browser-macro-chrome-"))
            with open(out / "chrome.log", "ab") as log:
                process = self.spawn(chrome_argv(self.binary, profile, url), stdout=log, stderr=log,
                                     stdin=subprocess.DEVNULL, start_new_session=True)
        except OSError as error:
            if profile is not None:
                shutil.rmtree(profile, ignore_errors=True)
            raise StoryError(f"chrome arm did not start: {error}") from None
        return process, profile

    def run(self, server: SuiteServer, out: Path) -> ArmRun:
        process, profile = self.start(server.url, out)
        try:
            report = server.wait(server.suite.timeout_s)
            if process.poll() is not None:
                raise StoryError(f"chrome arm: Chrome exited {process.returncode} before the run ended")
            return ArmRun(report, {"pid": process.pid})
        finally:
            stop_group(process)
            shutil.rmtree(profile, ignore_errors=True)


def stop_group(process: Any, grace_s: float = 15) -> None:
    """TERM to the browser (it closes its helpers), then KILL to its process group if it is still there."""
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(grace_s)
        except subprocess.TimeoutExpired:
            pass
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        pass
    if process.poll() is None:
        process.wait(grace_s)


# ---------------------------------------------------------------- the interleaved night

def schedule(rounds: int, suites: Sequence[Suite], arms: Sequence[str] = ARMS) -> list[tuple[int, Suite, str]]:
    """(round, suite, arm) in run order: each round runs every suite in both arms, and the arm order flips each round
    (ABBA), so a drift over the night lands on both arms alike."""
    order = []
    for round_index in range(rounds):
        ordered = list(arms) if round_index % 2 == 0 else list(reversed(arms))
        for suite in suites:
            order.extend((round_index, suite, arm) for arm in ordered)
    return order


@dataclass
class Night:
    runs: list[dict[str, Any]] = field(default_factory=list)
    failed: dict[str, list[str]] = field(default_factory=dict)  # suite key -> why its runs have no result

    def scores(self, suite: str, arm: str) -> list[float]:
        return [s for run in self.runs if run["suite"] == suite and run["arm"] == arm for s in run["scores"]]

    def round_ratios(self, suite: str) -> list[float]:
        """Per round, the cmux arm's mean score over Chrome's."""
        ratios = []
        for round_index in sorted({run["round"] for run in self.runs if run["suite"] == suite}):
            means = {}
            for arm in ARMS:
                scores = [s for run in self.runs if run["suite"] == suite and run["arm"] == arm
                          and run["round"] == round_index for s in run["scores"]]
                if scores:
                    means[arm] = sum(scores) / len(scores)
            if len(means) == len(ARMS):
                ratios.append(means["cmux"] / means["chrome"])
        return ratios

    def mismatch(self, suite: str) -> str | None:
        """Why a suite's runs do not compare: they measured at different frame rates or canvas configurations
        (MotionMark's `info`; the other suites post none)."""
        for name in COMPARED_INFO:
            values = {json.dumps(run["info"].get(name)) for run in self.runs if run["suite"] == suite}
            if len(values) > 1:
                return f"runs measured different {name} values: {', '.join(sorted(values))}"
        return None

    def written(self) -> list[str]:
        """The suites whose every planned run has a result that compares with the others."""
        return [key for key in SUITE_KEYS if key not in self.failed and any(r["suite"] == key for r in self.runs)]


def run_night(order: Sequence[tuple[int, Suite, str]], arms: Mapping[str, Any], roots: Mapping[str, Path], out: Path,
              log: Callable[[str], None], night: Night | None = None) -> Night:
    """Every run in ORDER into NIGHT. A failed run marks its suite failed (an interleaved pair needs both of its runs)
    and the night goes on; NoChromium ends it."""
    night = Night() if night is None else night
    for round_index, suite, arm in order:
        label = f"r{round_index}-{suite.key}-{arm}"
        with SuiteServer(roots[suite.key], suite) as server:
            log(f"{label}: {server.url}")
            try:
                done = arms[arm].run(server, out / label)
                served = server.summary()
                if served["misses"]:
                    raise StoryError(f"{len(served['misses'])} requests the pinned copy has no file for: "
                                     f"{', '.join(served['misses'][:5])}")
            except StoryError as error:
                night.failed.setdefault(suite.key, []).append(f"{label}: {error}")
                log(f"{label}: no result: {error}")
                continue
            night.runs.append({"round": round_index, "suite": suite.key, "arm": arm, "scores": list(done.report.scores),
                               "info": done.report.info, "server": served, **done.detail})
            log(f"{label}: {', '.join(f'{s:.2f}' for s in done.report.scores)}")
    for key in SUITE_KEYS:
        why = night.mismatch(key)
        if why and key not in night.failed:
            night.failed[key] = [why]
    return night


# ---------------------------------------------------------------- result-v1

def metric(arm: str, suite: str, kind: str = "score") -> str:
    return f"browser_macro.{arm}.{suite}.{kind}"


def results(night: Night, build, host, features: tuple | None, run=None) -> list:
    run = run or perf_result.Run.start()
    snapshot, features_hash, safe_mode = features or ({}, None, None)
    cmux_features = {name: perf_result.Feature(**value) for name, value in snapshot.items()}

    def result(name: str, unit: str, samples, cmux: bool):
        return perf_result.Result(story=STORY, metric=name, unit=unit, better="higher", samples=list(samples),
                                  build=build, host=host, engine=ENGINE, session=SESSION, run=run,
                                  features=cmux_features if cmux else {},
                                  features_hash=features_hash if cmux else None,
                                  safe_mode=safe_mode if cmux else None)

    rows = []
    for key in night.written():
        for arm in ARMS:
            rows.append(result(metric(arm, key), "score", night.scores(key, arm), arm == "cmux"))
        rows.append(result(metric(RATIO, key, "score_ratio"), "ratio", night.round_ratios(key), True))
    return rows


def write_runs(out: Path, night: Night, chrome: dict[str, Any]) -> Path:
    doc = {"story": STORY, "chrome": chrome, "window": list(WINDOW), "written": night.written(),
           "failed": night.failed, "runs": night.runs,
           "suites": {s.key: {"title": s.title, "repo": f"https://github.com/WebKit/{s.repo}", "commit": s.commit,
                              "tree": s.tree} for s in SUITES}}
    temporary = out / f".{RUNS_FILE}.tmp"
    temporary.write_text(json.dumps(doc, indent=1, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(temporary, out / RUNS_FILE)
    return out / RUNS_FILE


# ---------------------------------------------------------------- CLI

def measured(app: Path, environ: Mapping[str, str]):
    """(result-v1 build, host) of the measured app: bench_launch's build stamp, and the host block the runner's
    host_env wrote (PERF_LAB_HOST_FILE) or this Mac's. Raises EnvInvalid for a build or host that cannot be
    named."""
    stated = environ.get(bench_launch.LAB_CONFIG) or STORY_CONFIG
    try:
        binary = bench_launch.main_binary(str(app))
        build = perf_result.Build(sha=bench_launch.build_sha(str(app)),
                                  config=bench_launch.build_config(str(app), binary, stated),
                                  measure_version=bench_launch.PERF_LAB_MEASURE_VERSION)
        host_file = environ.get(bench_launch.LAB_HOST_FILE)
        if host_file:
            with open(host_file, encoding="utf-8") as f:
                host = json.load(f)
        else:
            host = bench_launch.read_host()
        return build, perf_result.Host.from_dict(host)
    except SystemExit as error:  # main_binary is also bench_launch's CLI path, which exits
        raise EnvInvalid(str(error.code)) from None
    except (bench_launch.RecordError, OSError, ValueError, KeyError) as error:
        raise EnvInvalid(f"the build or host cannot be named: {error}") from None


def fetched_chrome(cache: str | None = None) -> Path:
    """Chrome stable from fetch_browsers.py (its vendor-signed, read-only copy; fetched once a day)."""
    argv = [sys.executable, "-I", str(FETCH_BROWSERS), "chrome"] + (["--cache", cache] if cache else [])
    done = subprocess.run(argv, capture_output=True, text=True, timeout=3600)
    for line in done.stdout.splitlines():
        if line.startswith("chrome="):
            return Path(line.split("=", 1)[1])
    raise EnvInvalid(f"fetch_browsers.py chrome gave no bundle: {done.stderr.strip()[-300:]}")


def parse_args(argv: list[str] | None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0],
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("action", nargs="?", choices=("run", "fetch", "serve"), default="run")
    parser.add_argument("suite", nargs="?", choices=SUITE_KEYS, default=None, help="serve: the suite to serve")
    parser.add_argument("--cache", type=Path, default=None, help="the pinned copies (default the account's cache)")
    parser.add_argument("--no-fetch", action="store_true", help="refuse a missing copy instead of fetching it")
    parser.add_argument("--suites", default=",".join(SUITE_KEYS), help="comma-separated suite keys")
    parser.add_argument("--rounds", type=int, default=ROUNDS, help="interleaved rounds (each runs every suite twice)")
    parser.add_argument("--chrome", type=Path, default=None,
                        help="Chrome stable's .app or executable (default fetch_browsers.py chrome)")
    runner = parser.add_argument_group("story runner", "what scripts/perf-lab/run_story.py passes (stories.d/README.md)")
    runner.add_argument("--app", type=Path, default=None, help="the measured bench build")
    runner.add_argument("--tag", default=None, help="the measured build's tag (BenchApp reads it from the bundle)")
    runner.add_argument("--out", type=Path, default=None, help="write result-v1 and the runs here")
    args = parser.parse_args(argv)
    try:
        args.suite_list = [suite_named(key) for key in args.suites.split(",") if key]
    except KeyError as error:
        parser.error(str(error))
    if args.action == "run" and (args.app is None or args.out is None):
        parser.error("run needs --app and --out")
    if args.action == "serve" and args.suite is None:
        parser.error("serve needs a suite")
    if args.rounds < 1:
        parser.error("--rounds is at least 1")
    return args


def log(text: str) -> None:
    print(f"browser-macro: {text}", file=sys.stderr, flush=True)


def default_arms(args: argparse.Namespace, environ: Mapping[str, str]) -> dict[str, Any]:
    bundle = bench_launch.bundle_id(str(args.app))
    problem = wpr.bench_bundle_problem(bundle)
    if problem:
        raise EnvInvalid(problem)
    chrome = args.chrome or fetched_chrome()
    if not chrome.exists():
        raise EnvInvalid(f"{chrome}: no Chrome")
    launch = wpr.bench_launcher(str(args.app), environ.get(bench_launch.LAB_CONFIG) or STORY_CONFIG)
    return {"cmux": CmuxArm(args.app, launch, wpr.chromium_root(bundle)), "chrome": ChromeArm(chrome)}


def raise_interrupted(signum: int, _frame) -> None:
    raise Interrupted(signum)


def main(argv: list[str] | None = None, environ: Mapping[str, str] | None = None,
         make_arms: Callable[[argparse.Namespace, Mapping[str, str]], dict[str, Any]] = default_arms,
         measure: Callable[[Path, Mapping[str, str]], tuple] = measured,
         fetch: Callable[[str], bytes] = http_fetch) -> int:
    args = parse_args(argv)
    environ = os.environ if environ is None else environ
    cache = args.cache or default_cache()
    try:
        roots = {suite.key: pinned_copy(suite, cache, None if args.no_fetch else fetch) for suite in args.suite_list}
    except EnvInvalid as error:
        log(str(error))
        return ENV_INVALID
    if args.action == "fetch":
        for key, root in roots.items():
            print(f"{key}={root}")
        return 0
    if args.action == "serve":
        with SuiteServer(roots[args.suite], suite_named(args.suite)) as server:
            print(server.url, flush=True)
            threading.Event().wait()  # until ^C: a person opens the URL
        return 0
    try:
        build, host = measure(args.app, environ)
        arms = make_arms(args, environ)
        chrome = arms["chrome"].bundle
        chrome_info = {"bundle": str(chrome), "version": chrome_version(chrome)}
    except EnvInvalid as error:
        log(str(error))
        return ENV_INVALID
    log(f"Chrome {chrome_info['version']}; {args.rounds} rounds of {', '.join(s.key for s in args.suite_list)}")
    args.out.mkdir(parents=True, exist_ok=True)
    night = Night()
    previous = {number: signal.signal(number, raise_interrupted) for number in FORWARDED_SIGNALS}
    try:
        run_night(schedule(args.rounds, args.suite_list), arms, roots, args.out, log, night)
    except Interrupted as stop:
        log(f"signal {stop.signum}: stopped; no result")
        return 128 + stop.signum
    except NoChromium as error:
        night.failed["*"] = [str(error)]
        write_runs(args.out, night, chrome_info)
        log(f"{error}; no result")
        return 2
    except EnvInvalid as error:
        night.failed["*"] = [f"env-invalid: {error}"]
        write_runs(args.out, night, chrome_info)
        log(f"{error}; env-invalid, no result")
        return ENV_INVALID
    finally:
        for number, handler in previous.items():
            signal.signal(number, handler)
    write_runs(args.out, night, chrome_info)
    rows = results(night, build, host, getattr(arms["cmux"], "features", None))
    for key, why in night.failed.items():
        log(f"{key}: no result ({len(why)} failed runs): {why[0]}")
    if not rows:
        log("nothing to write")
        return 2
    log(f"wrote {perf_result.write_ndjson(args.out, rows, repo_root=ROOT)}")
    return 1 if night.failed else 0


if __name__ == "__main__":
    sys.exit(main())
