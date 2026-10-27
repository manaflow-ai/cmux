#!/usr/bin/env python3
"""stories/browser_macro.py: pinned copies, the loopback server and its harness, the interleaved night, result-v1.

  python3 -m unittest scripts/perf-lab/tests/test_browser_macro.py

No browser starts here: fake arms fetch from the story's server and post its reports as the harness would.
"""
from __future__ import annotations

import dataclasses
import importlib.util
import io
import json
import plistlib
import re
import subprocess
import sys
import tarfile
import tempfile
import unittest
import urllib.error
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
LAB = HERE.parent
ROOT = LAB.parent.parent

_SPEC = importlib.util.spec_from_file_location("perf_lab_browser_macro_under_test",
                                               LAB / "stories" / "browser_macro.py")
macro = importlib.util.module_from_spec(_SPEC)
sys.modules[_SPEC.name] = macro
_SPEC.loader.exec_module(macro)
perf_result = macro.perf_result
catalog = macro.load_by_path("perf_lab_browser_macro_catalog", LAB / "catalog.py")
run_story = macro.load_by_path("perf_lab_browser_macro_run_story", LAB / "run_story.py")

BUILD = perf_result.Build(sha="a" * 40, config="bench", measure_version=2)
HOST = perf_result.Host(fingerprint="b" * 64, host_class="apple-m6/16gb/120hz", chip="Apple M6", macos="27.0",
                        macos_build="27A123", display_hz=120)
ENTRY = b"<!DOCTYPE html><html><head><title>suite</title></head><body><script src='app.js'></script></body></html>"


def tarball(files: dict[str, bytes], top: str = "Repo-abc", extra: list[tarfile.TarInfo] | None = None) -> bytes:
    """A GitHub-style tar.gz: every file under one top folder."""
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w:gz") as tar:
        folder = tarfile.TarInfo(top)
        folder.type = tarfile.DIRTYPE
        tar.addfile(folder)
        for name, data in files.items():
            info = tarfile.TarInfo(f"{top}/{name}")
            info.size = len(data)
            tar.addfile(info, io.BytesIO(data))
        for info in extra or []:
            tar.addfile(info)
    return buffer.getvalue()


def make_suite(key: str = "speedometer3_1", **changes) -> macro.Suite:
    return dataclasses.replace(macro.suite_named(key), **changes)


def get(url: str) -> tuple[int, bytes]:
    try:
        with urllib.request.urlopen(url, timeout=10) as response:
            return response.status, response.read()
    except urllib.error.HTTPError as error:
        return error.code, error.read()


def post(url: str, body) -> int:
    data = body if isinstance(body, bytes) else json.dumps(body).encode("utf-8")
    request = urllib.request.Request(url, data=data, method="POST", headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=10) as response:
        return response.status


def base(server: macro.SuiteServer) -> str:
    return f"http://127.0.0.1:{server.port}"


def harness_post(url: str, score: float) -> None:
    """What the harness does in a browser at URL: read its suite from the entry page's harness tag, post the scores."""
    _status, page = get(url)
    key = re.search(rb'data-suite="([a-z0-9_]+)"', page).group(1).decode()
    origin = "/".join(url.split("/")[:3])
    post(origin + macro.REPORT_PATH, {"scores": [score] * macro.suite_named(key).iterations})


def launch_error(reason: str) -> BaseException:
    return macro.bench_launch.LaunchError(reason, {"detail": f"{reason} detail", "log_tail": ""})


class FakeArm:
    """Loads the entry page and its script from the server, as a browser would, then posts SCORES (or `posts`, a
    function of the server) the way the harness does. `extra` paths are fetched too (a page's request)."""

    def __init__(self, scores_by_suite=None, info=None, extra=(), fail=None, fail_suites=None):
        self.scores_by_suite = scores_by_suite or {}
        self.info = info or {}
        self.extra = extra
        self.fail = fail
        self.fail_suites = fail_suites  # the suites FAIL applies to (None: every suite)
        self.calls = []

    def run(self, server, out):
        self.calls.append((server.suite.key, out.name))
        status, page = get(server.url)
        assert status == 200 and macro.HARNESS_PATH.encode() in page, page[:200]
        get(base(server) + "/app.js")
        for path in self.extra:
            get(base(server) + path)
        if self.fail and (self.fail_suites is None or server.suite.key in self.fail_suites):
            raise macro.StoryError(self.fail)
        scores = self.scores_by_suite.get(server.suite.key, [1.0] * server.suite.iterations)
        post(base(server) + macro.REPORT_PATH, {"suite": server.suite.key, "scores": scores,
                                                "info": self.info.get(server.suite.key, {})})
        return macro.ArmRun(server.wait(5), {"fake": True})


class Copy:
    """A temporary folder that stands for a suite's served copy."""

    def __init__(self, test: unittest.TestCase):
        tmp = tempfile.TemporaryDirectory()
        test.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        (self.root / "index.html").write_bytes(ENTRY)
        (self.root / "app.js").write_text("void 0;\n", encoding="utf-8")
        (self.root / "sub").mkdir()
        (self.root / "sub" / "index.html").write_text("<html><head></head></html>", encoding="utf-8")


class PinTest(unittest.TestCase):
    def test_every_suite_is_pinned_to_a_commit_and_tree(self) -> None:
        self.assertEqual([s.key for s in macro.SUITES], ["speedometer3_1", "motionmark1_3", "jetstream2_2"])
        for suite in macro.SUITES:
            self.assertRegex(suite.commit, r"^[0-9a-f]{40}$")
            self.assertRegex(suite.tree, r"^sha256:[0-9a-f]{64}$")
            self.assertRegex(suite.key, r"^[a-z0-9_]+$")  # one metric segment
            self.assertGreaterEqual(suite.iterations, 1)

    def test_tree_digest_names_paths_and_contents(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "a").mkdir()
            (root / "a" / "x.js").write_text("1", encoding="utf-8")
            first = macro.tree_digest(root)
            self.assertEqual(macro.tree_digest(root), first)
            (root / "a" / "x.js").write_text("2", encoding="utf-8")
            self.assertNotEqual(macro.tree_digest(root), first)
            (root / "a" / "x.js").write_text("1", encoding="utf-8")
            (root / "a" / "x.js").rename(root / "a" / "y.js")
            self.assertNotEqual(macro.tree_digest(root), first)

    def test_tree_digest_refuses_a_link(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "f").write_text("x", encoding="utf-8")
            (root / "link").symlink_to(root / "f")
            with self.assertRaises(macro.EnvInvalid):
                macro.tree_digest(root)

    def test_extract_drops_the_top_folder(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            macro.extract(tarball({"index.html": ENTRY, "res/app.js": b"1"}), Path(tmp))
            self.assertEqual((Path(tmp) / "index.html").read_bytes(), ENTRY)
            self.assertEqual((Path(tmp) / "res" / "app.js").read_bytes(), b"1")

    def test_extract_refuses_links_and_escapes(self) -> None:
        link = tarfile.TarInfo("Repo-abc/evil")
        link.type = tarfile.SYMTYPE
        link.linkname = "/etc/passwd"
        escape = tarfile.TarInfo("Repo-abc/../../outside")
        for member in (link, escape):
            with self.subTest(member=member.name), tempfile.TemporaryDirectory() as tmp:
                with self.assertRaises(macro.EnvInvalid):
                    macro.extract(tarball({}, extra=[member]), Path(tmp))

    def test_pinned_copy_fetches_once_and_checks_the_digest(self) -> None:
        archive = tarball({"MotionMark/index.html": ENTRY, "README.md": b"r"})
        with tempfile.TemporaryDirectory() as tmp:
            probe = Path(tmp) / "probe"
            probe.mkdir()
            macro.extract(archive, probe)
            suite = make_suite("motionmark1_3", tree=macro.tree_digest(probe))
            cache = Path(tmp) / "cache"
            fetched = []

            def fetch(url):
                fetched.append(url)
                return archive

            served = macro.pinned_copy(suite, cache, fetch)
            self.assertEqual(served, macro.copy_dir(cache, suite) / "MotionMark")
            self.assertEqual(fetched, [f"https://codeload.github.com/WebKit/MotionMark/tar.gz/{suite.commit}"])
            self.assertEqual(macro.pinned_copy(suite, cache, None), served)  # cached: no fetch
            self.assertEqual(len(fetched), 1)
            (served / "index.html").write_bytes(b"changed")
            with self.assertRaises(macro.EnvInvalid):
                macro.pinned_copy(suite, cache, fetch)  # a changed copy is refused, never served

    def test_a_fetched_copy_with_another_digest_is_not_kept(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            cache = Path(tmp)
            suite = make_suite("jetstream2_2")
            with self.assertRaises(macro.EnvInvalid):
                macro.pinned_copy(suite, cache, lambda _url: tarball({"index.html": ENTRY}))
            self.assertEqual(list(cache.iterdir()), [])

    def test_a_missing_copy_without_fetch_is_env_invalid(self) -> None:
        with tempfile.TemporaryDirectory() as tmp, self.assertRaises(macro.EnvInvalid):
            macro.pinned_copy(make_suite(), Path(tmp), None)


class ServerTest(unittest.TestCase):
    def setUp(self) -> None:
        self.copy = Copy(self)

    def test_entry_page_gets_the_harness_first_in_head(self) -> None:
        with macro.SuiteServer(self.copy.root, make_suite()) as server:
            status, page = get(server.url)
            self.assertEqual(status, 200)
            head = page.index(b"<head>") + len(b"<head>")
            first = b'<script src="/__cmux_macro__/harness.js" data-suite="speedometer3_1"'
            self.assertTrue(page[head:].startswith(first))
            status, script = get(base(server) + macro.HARNESS_PATH)
            self.assertEqual((status, script), (200, macro.HARNESS_JS.encode("utf-8")))
            _status, other = get(base(server) + "/sub/")
            self.assertNotIn(b"harness", other)  # only the entry page
            self.assertEqual(server.summary()["served"], 3)

    def test_a_page_without_head_is_refused(self) -> None:
        with self.assertRaises(macro.StoryError):
            macro.with_harness(b"<html><body></body></html>", make_suite())

    def test_harness_hooks_every_suite_and_posts_to_the_report_path(self) -> None:
        for suite in macro.SUITES:
            self.assertIn(f"{suite.key}:", macro.HARNESS_JS)
        self.assertIn(f'"{macro.REPORT_PATH}"', macro.HARNESS_JS)
        self.assertNotIn("__REPORT__", macro.HARNESS_JS)
        self.assertNotRegex(macro.HARNESS_JS, r"https?://")  # the harness itself reaches nothing but its server

    def test_unknown_paths_and_escapes_are_misses(self) -> None:
        with macro.SuiteServer(self.copy.root, make_suite()) as server:
            self.assertEqual(get(base(server) + "/missing.js")[0], 404)
            self.assertEqual(get(base(server) + "/%2e%2e/%2e%2e/etc/passwd")[0], 404)
            self.assertEqual(get(base(server) + "/favicon.ico")[0], 204)  # the browser's own, not a miss
            self.assertEqual(server.summary()["misses"], ["/missing.js", "/%2e%2e/%2e%2e/etc/passwd"])

    def test_report_is_delivered_once(self) -> None:
        suite = make_suite(iterations=2)
        with macro.SuiteServer(self.copy.root, suite) as server:
            post(base(server) + macro.REPORT_PATH, {"scores": [10.5, 11]})
            post(base(server) + macro.REPORT_PATH, {"scores": [99, 99]})
            self.assertEqual(server.wait(5).scores, (10.5, 11.0))
            self.assertEqual(server.summary()["extra_reports"], 1)

    def test_bad_reports_fail_the_run(self) -> None:
        cases = [({"error": "speedometer: boom"}, "boom"), ({"scores": []}, "no positive finite"),
                 ({"scores": [1, -2]}, "no positive finite"), ({"scores": [1.0]}, "1 scores, the suite runs 2")]
        for body, why in cases:
            with self.subTest(body=body), macro.SuiteServer(self.copy.root, make_suite(iterations=2)) as server:
                post(base(server) + macro.REPORT_PATH, body)
                with self.assertRaisesRegex(macro.StoryError, why):
                    server.wait(5)

    def test_no_report_is_a_timeout(self) -> None:
        with macro.SuiteServer(self.copy.root, make_suite()) as server, \
                self.assertRaisesRegex(macro.StoryError, "no report"):
            server.wait(0.05)

    def test_jetstream_report_is_the_geomean_of_its_benchmarks(self) -> None:
        body = {"JetStream2.0": {"metrics": {"Score": ["Geometric"]}, "tests": {
            "Air": {"metrics": {"Score": {"current": [100.0]}}, "tests": {}},
            "Basic": {"metrics": {"Score": {"current": [400.0]}}, "tests": {}}}}}
        with macro.SuiteServer(self.copy.root, make_suite("jetstream2_2")) as server:
            post(base(server) + macro.JETSTREAM_REPORT_PATH, body)
            report = server.wait(5)
        self.assertAlmostEqual(report.scores[0], 200.0)
        self.assertEqual(report.info["benchmarks"], {"Air": 100.0, "Basic": 400.0})

    def test_jetstream_report_path_is_a_miss_for_other_suites(self) -> None:
        with macro.SuiteServer(self.copy.root, make_suite()) as server:
            post(base(server) + macro.JETSTREAM_REPORT_PATH, {"JetStream2.0": {}})
            self.assertEqual(server.summary()["misses"], [macro.JETSTREAM_REPORT_PATH])

    def test_a_jetstream_benchmark_without_a_score_fails(self) -> None:
        report = macro.jetstream_report({"JetStream2.0": {"tests": {"Air": {"metrics": {"Score": {"current": [0]}}}}}})
        self.assertIsNotNone(report.error)
        self.assertIsNotNone(macro.jetstream_report({"other": 1}).error)


class NightTest(unittest.TestCase):
    def setUp(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.out = Path(tmp.name)
        self.copy = Copy(self)
        self.suites = [make_suite("speedometer3_1", iterations=2), make_suite("jetstream2_2")]
        self.roots = {s.key: self.copy.root for s in self.suites}

    def test_schedule_is_abba_over_rounds(self) -> None:
        order = [(r, s.key, a) for r, s, a in macro.schedule(2, self.suites)]
        self.assertEqual(order, [(0, "speedometer3_1", "cmux"), (0, "speedometer3_1", "chrome"),
                                 (0, "jetstream2_2", "cmux"), (0, "jetstream2_2", "chrome"),
                                 (1, "speedometer3_1", "chrome"), (1, "speedometer3_1", "cmux"),
                                 (1, "jetstream2_2", "chrome"), (1, "jetstream2_2", "cmux")])

    def night(self, cmux: FakeArm, chrome: FakeArm, rounds: int = 2) -> macro.Night:
        return macro.run_night(macro.schedule(rounds, self.suites), {"cmux": cmux, "chrome": chrome}, self.roots,
                               self.out, lambda _text: None)

    def test_both_arms_every_round_and_the_ratio(self) -> None:
        cmux = FakeArm({"speedometer3_1": [30.0, 32.0], "jetstream2_2": [300.0]})
        chrome = FakeArm({"speedometer3_1": [20.0, 20.0], "jetstream2_2": [200.0]})
        night = self.night(cmux, chrome)
        self.assertEqual(night.failed, {})
        self.assertEqual(night.written(), ["speedometer3_1", "jetstream2_2"])
        self.assertEqual(night.scores("speedometer3_1", "cmux"), [30.0, 32.0, 30.0, 32.0])
        self.assertEqual(night.round_ratios("speedometer3_1"), [1.55, 1.55])
        self.assertEqual(night.round_ratios("jetstream2_2"), [1.5, 1.5])
        self.assertEqual(cmux.calls[0], ("speedometer3_1", "r0-speedometer3_1-cmux"))
        self.assertEqual(len(cmux.calls), 4)

    def test_a_failed_run_leaves_its_suite_unwritten(self) -> None:
        night = self.night(FakeArm(), FakeArm(fail="Chrome exited"))
        self.assertEqual(night.written(), [])
        self.assertIn("r0-speedometer3_1-chrome: Chrome exited", night.failed["speedometer3_1"])

    def test_a_request_the_copy_cannot_answer_fails_the_run(self) -> None:
        night = self.night(FakeArm(extra=("/needs-network.js",)), FakeArm(), rounds=1)
        self.assertEqual(night.written(), [])
        self.assertRegex(night.failed["speedometer3_1"][0],
                         r"1 requests the pinned copy has no file for: /needs-network")

    def test_runs_at_different_frame_rates_do_not_compare(self) -> None:
        self.suites = [make_suite("motionmark1_3")]
        self.roots = {"motionmark1_3": self.copy.root}
        cmux = FakeArm(info={"motionmark1_3": {"frame_rate": 120, "configuration": "large"}})
        chrome = FakeArm(info={"motionmark1_3": {"frame_rate": 60, "configuration": "large"}})
        night = self.night(cmux, chrome, rounds=1)
        self.assertEqual(night.written(), [])
        self.assertIn("frame_rate", night.failed["motionmark1_3"][0])

    def test_results_match_the_story_and_validate(self) -> None:
        night = self.night(FakeArm({"speedometer3_1": [30.0, 32.0], "jetstream2_2": [300.0]}),
                           FakeArm({"speedometer3_1": [20.0, 20.0], "jetstream2_2": [200.0]}))
        features = ({"chromium.renderer_sharing": {"state": "on", "source": "default"}}, "c" * 64, "off")
        rows = macro.results(night, BUILD, HOST, features)
        names = sorted(r.metric for r in rows)
        self.assertEqual(names, ["browser_macro.chrome.jetstream2_2.score", "browser_macro.chrome.speedometer3_1.score",
                                 "browser_macro.cmux.jetstream2_2.score", "browser_macro.cmux.speedometer3_1.score",
                                 "browser_macro.cmux_over_chrome.jetstream2_2.score_ratio",
                                 "browser_macro.cmux_over_chrome.speedometer3_1.score_ratio"])
        story = json.loads((LAB / "stories.d" / "browser-macro.json").read_text(encoding="utf-8"))
        for row in rows:
            row.validate(ROOT)
            claimed = [m for m in story["metrics"] if re.fullmatch(m["name"], row.metric)]
            self.assertEqual(len(claimed), 1, row.metric)
            self.assertEqual((claimed[0]["unit"], claimed[0]["better"]), (row.unit, row.better))
            self.assertEqual((row.story, row.engine, row.session), (story["id"], story["engine"], story["session"]))
        by_name = {r.metric: r for r in rows}
        self.assertEqual(by_name["browser_macro.cmux.speedometer3_1.score"].features_hash, "c" * 64)
        self.assertEqual(by_name["browser_macro.chrome.speedometer3_1.score"].features, {})  # not cmux's features
        self.assertEqual(len({r.run.id for r in rows}), 1)


class FakeBench:
    def __init__(self, env, cef_answers, status=None):
        self.launched_env = env
        self.cef_answers = list(cef_answers)
        self.status = status or {"certificate": "0", "enginePage": "0", "gone": "0", "error": ""}
        self.features = ({}, None, None)
        self.stopped = False
        self.server_base = ""  # the run's server; opening the tab posts its report there, as the harness would
        self.opened = []

    def rpc(self, method, params=None, timeout=60):
        if method == "debug.cef":
            return self.cef_answers.pop(0)
        if method == "action.run":
            self.opened.append(params["args"]["url"])
            post(self.server_base + macro.REPORT_PATH, {"scores": [5.0] * 10})
            return {"created": ["tab_1"]}
        if method == "debug.browser.page_status":
            return self.status
        raise AssertionError(method)

    def stop(self):
        self.stopped = True


class CmuxArmTest(unittest.TestCase):
    def setUp(self) -> None:
        self.copy = Copy(self)
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.dir = Path(tmp.name)

    def arm(self, cef_answers, status=None):
        launched = []

        def launch(env, out):
            bench = FakeBench(env, cef_answers, status)
            launched.append((env, out, bench))
            return bench

        root = self.dir / "Chromium"
        root.mkdir()
        (root / "cache").write_text("x", encoding="utf-8")
        return macro.CmuxArm(self.dir / "cmux DEV t.app", launch, root), launched

    def run_arm(self, arm, launched):
        with macro.SuiteServer(self.copy.root, make_suite()) as server:
            original = arm.launch

            def launch(env, out):
                bench = original(env, out)
                bench.server_base = base(server)
                return bench

            arm.launch = launch
            return arm.run(server, self.dir / "run")

    def test_loopback_only_switch_fresh_storage_and_cef_checked_twice(self) -> None:
        arm, launched = self.arm([{"state": "ready"}, {"state": "ready"}])
        done = self.run_arm(arm, launched)
        env, _out, bench = launched[0]
        self.assertEqual(env, {macro.wpr.BENCH_SWITCHES_ENV: f"host-resolver-rules={macro.LOOPBACK_ONLY_RULES}"})
        self.assertTrue(macro.wpr.kept_bench_switches(env[macro.wpr.BENCH_SWITCHES_ENV]))  # CEFSwitches keeps it
        self.assertEqual(done.report.scores, (5.0,) * 10)
        self.assertEqual(bench.cef_answers, [])  # before the tab and after the suite
        self.assertTrue(bench.stopped)
        self.assertFalse((self.dir / "Chromium").exists())  # moved aside: no HTTP cache
        self.assertEqual(arm.features, ({}, None, None))

    def test_chromium_unavailable_ends_the_night(self) -> None:
        arm, launched = self.arm([{"unavailable": {"reason": "no framework"}}])
        with self.assertRaises(macro.NoChromium):
            self.run_arm(arm, launched)
        self.assertTrue(launched[0][2].stopped)
        self.assertEqual(launched[0][2].opened, [])

    def test_a_webkit_fallback_during_the_suite_fails_the_run(self) -> None:
        arm, launched = self.arm([{"state": "ready"}, {"fallback": {"tab_1": "crash"}}])
        with self.assertRaisesRegex(macro.StoryError, "fell back to WebKit"):
            self.run_arm(arm, launched)

    def test_a_sad_tab_fails_the_run(self) -> None:
        arm, launched = self.arm([{"state": "ready"}, {"state": "ready"}],
                                 status={"certificate": "0", "enginePage": "0", "gone": "1", "error": ""})
        with self.assertRaisesRegex(macro.StoryError, "sad tab"):
            self.run_arm(arm, launched)

    def run_failing_launch(self, error: BaseException) -> None:
        def launch(_env, _out):
            raise error

        arm = macro.CmuxArm(self.dir / "cmux DEV t.app", launch, None)
        with macro.SuiteServer(self.copy.root, make_suite()) as server:
            arm.run(server, self.dir / "run")

    def test_a_failed_launch_fails_only_the_run(self) -> None:
        with self.assertRaisesRegex(macro.StoryError, "cmux arm did not start: tag-in-use"):
            self.run_failing_launch(launch_error("tag-in-use"))
        with self.assertRaisesRegex(macro.StoryError, "cmux arm did not start: .*socket"):
            self.run_failing_launch(OSError("no socket"))
        with self.assertRaisesRegex(macro.StoryError, "cmux arm did not start: .*leaked"):
            self.run_failing_launch(macro.wpr.WprError("switches leaked"))

    def test_the_shared_bench_launch_copy_is_the_one_wpr_launches_with(self) -> None:
        self.assertIs(macro.bench_launch, sys.modules["perf_lab_bench_launch"])

    def test_a_launch_the_host_refuses_is_env_invalid(self) -> None:
        for reason in ("no-gui-session", "low-power-mode"):
            with self.assertRaisesRegex(macro.EnvInvalid, f"host refused the launch: {reason}"):
                self.run_failing_launch(launch_error(reason))


class ChromeTest(unittest.TestCase):
    def test_chrome_resolves_only_loopback_and_skips_background_network(self) -> None:
        argv = macro.chrome_argv(Path("/C/Google Chrome"), Path("/p"), "http://127.0.0.1:1/index.html")
        self.assertIn(f"--host-resolver-rules={macro.LOOPBACK_ONLY_RULES}", argv)
        for switch in ("--disable-background-networking", "--disable-component-update", "--no-first-run",
                       "--user-data-dir=/p", "--window-size=1440,900"):
            self.assertIn(switch, argv)
        self.assertEqual(argv[-1], "http://127.0.0.1:1/index.html")

    def test_chrome_binary_of_a_bundle(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            bundle = Path(tmp) / "Google Chrome.app"
            (bundle / "Contents").mkdir(parents=True)
            with open(bundle / "Contents" / "Info.plist", "wb") as f:
                plistlib.dump({"CFBundleExecutable": "Google Chrome", "CFBundleShortVersionString": "151.0.1"}, f)
            self.assertEqual(macro.chrome_binary(bundle), bundle / "Contents" / "MacOS" / "Google Chrome")
            self.assertEqual(macro.chrome_version(bundle), "151.0.1")

    def test_a_broken_bundle_cannot_be_named(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            bundle = Path(tmp) / "Google Chrome.app"
            with self.assertRaises(macro.EnvInvalid):
                macro.chrome_binary(bundle)  # no Info.plist
            (bundle / "Contents").mkdir(parents=True)
            for content in (b"not a plist", b"<?xml version='1.0'?><plist><dict><key>x", plistlib.dumps(["a"]),
                            plistlib.dumps({"CFBundleShortVersionString": "151"})):
                (bundle / "Contents" / "Info.plist").write_bytes(content)
                with self.assertRaises(macro.EnvInvalid, msg=content[:40]):
                    macro.chrome_binary(bundle)

    def test_a_failed_spawn_fails_only_the_run(self) -> None:
        profiles = []

        def spawn(argv, **_kwargs):
            profiles.append(Path(next(a for a in argv if a.startswith("--user-data-dir=")).split("=", 1)[1]))
            raise PermissionError("not executable")

        arm = macro.ChromeArm(Path("/nonexistent/chrome"), spawn=spawn)
        with tempfile.TemporaryDirectory() as tmp, macro.SuiteServer(Path(tmp), make_suite()) as server:
            with self.assertRaisesRegex(macro.StoryError, "chrome arm did not start: not executable"):
                arm.run(server, Path(tmp) / "run")
        self.assertFalse(profiles[0].exists())  # the temporary profile does not outlive the failed spawn


class StoryTest(unittest.TestCase):
    def test_catalog_lint_accepts_the_story(self) -> None:
        loaded = catalog.load_catalog(ROOT)
        self.assertEqual([p for p in loaded.problems if "browser-macro" in p], [])
        story = next(s for s in loaded.stories if s.id == "browser-macro")
        self.assertEqual(story.tier, "T2")
        self.assertEqual(run_story.contract_problems(story), [])

    def main(self, make_arms, measure=lambda _app, _env: (BUILD, HOST), suites=("speedometer3_1",)):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        out = Path(tmp.name) / "out"
        copy = Copy(self)
        original = macro.SUITES
        macro.SUITES = (make_suite("speedometer3_1", iterations=2), make_suite("jetstream2_2"))
        self.addCleanup(setattr, macro, "SUITES", original)
        original_pinned = macro.pinned_copy
        macro.pinned_copy = lambda _suite, _cache, _fetch: copy.root
        self.addCleanup(setattr, macro, "pinned_copy", original_pinned)
        code = macro.main(["--app", "/x/cmux DEV t.app", "--tag", "t", "--out", str(out), "--rounds", "2",
                           "--suites", ",".join(suites)], environ={}, make_arms=make_arms, measure=measure)
        return code, out

    def arms(self, cmux, chrome):
        chrome.bundle = Path("/nonexistent/chrome")
        return lambda _args, _env: {"cmux": cmux, "chrome": chrome}

    def setUp(self) -> None:
        self.real_chrome_version = macro.chrome_version
        macro.chrome_version = lambda _bundle: "151.0.1"
        self.addCleanup(setattr, macro, "chrome_version", self.real_chrome_version)

    def real_arms(self, cmux_failures: dict[int, BaseException], chrome_failures: dict[int, BaseException]):
        """The story's own CmuxArm and ChromeArm. Their Nth launch or spawn raises cmux_failures[N] or
        chrome_failures[N]; any other one posts the harness's report (cmux 3.0, Chrome 2.0) from the served page."""
        launches, spawns = [], []

        class HarnessBench(FakeBench):
            def rpc(self, method, params=None, timeout=60):
                if method == "action.run":
                    harness_post(params["args"]["url"], 3.0)
                    return {"created": ["tab_1"]}
                return super().rpc(method, params, timeout)

        def launch(env, _out):
            launches.append(1)
            if len(launches) in cmux_failures:
                raise cmux_failures[len(launches)]
            return HarnessBench(env, [{"state": "ready"}, {"state": "ready"}])

        def spawn(argv, **kwargs):
            spawns.append(1)
            if len(spawns) in chrome_failures:
                raise chrome_failures[len(spawns)]
            harness_post(argv[-1], 2.0)
            return subprocess.Popen(["sleep", "60"], **kwargs)  # a real process group for stop_group to end

        arms = {"cmux": macro.CmuxArm(Path("/x/cmux DEV t.app"), launch, None),
                "chrome": macro.ChromeArm(Path("/nonexistent/chrome"), spawn=spawn)}
        return lambda _args, _env: arms

    def test_a_failed_launch_or_spawn_keeps_the_suites_that_finished(self) -> None:
        # Run order: r0 speedometer cmux, chrome; r0 jetstream cmux (launch 2), chrome; r1 speedometer chrome, cmux;
        # r1 jetstream chrome (spawn 4), cmux.
        code, out = self.main(self.real_arms({2: launch_error("tag-in-use")}, {4: OSError("Chrome is gone")}),
                              suites=("speedometer3_1", "jetstream2_2"))
        self.assertEqual(code, 1)
        self.assertEqual({r.metric: r.samples for r in perf_result.read_dir(out)},
                         {"browser_macro.cmux.speedometer3_1.score": [3.0] * 4,
                          "browser_macro.chrome.speedometer3_1.score": [2.0] * 4,
                          "browser_macro.cmux_over_chrome.speedometer3_1.score_ratio": [1.5, 1.5]})
        runs = json.loads((out / macro.RUNS_FILE).read_text(encoding="utf-8"))
        self.assertEqual(runs["written"], ["speedometer3_1"])
        failed = runs["failed"]["jetstream2_2"]
        self.assertEqual(len(failed), 2)
        self.assertIn("r0-jetstream2_2-cmux: cmux arm did not start: tag-in-use", failed[0])
        self.assertIn("r1-jetstream2_2-chrome: chrome arm did not start: Chrome is gone", failed[1])
        self.assertEqual(len(runs["runs"]), 6)

    def test_a_launch_the_host_refuses_is_env_invalid(self) -> None:
        code, out = self.main(self.real_arms({1: launch_error("no-gui-session")}, {}))
        self.assertEqual(code, macro.ENV_INVALID)
        self.assertEqual(list(out.glob("*.ndjson")), [])
        self.assertIn("no-gui-session", json.loads((out / macro.RUNS_FILE).read_text())["failed"]["*"][0])

    def test_a_chrome_that_cannot_be_named_is_env_invalid(self) -> None:
        macro.chrome_version = self.real_chrome_version
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        broken = Path(tmp.name) / "Google Chrome.app"
        (broken / "Contents").mkdir(parents=True)
        (broken / "Contents" / "Info.plist").write_bytes(b"not a plist")
        not_executable = Path(tmp.name) / "chrome"
        not_executable.write_text("#!/bin/sh\necho 151\n", encoding="utf-8")
        not_executable.chmod(0o644)
        for chrome in (broken, not_executable):
            started = []
            code, out = self.main(lambda _args, _env, chrome=chrome: {"cmux": FakeArm(), "chrome": macro.ChromeArm(
                chrome, spawn=lambda *a, **k: started.append(1))})
            self.assertEqual(code, macro.ENV_INVALID, chrome)
            self.assertEqual(started, [])
            self.assertFalse(out.exists())  # nothing ran, nothing written

    def test_main_writes_result_v1_and_the_runs(self) -> None:
        cmux, chrome = FakeArm({"speedometer3_1": [3.0, 3.0]}), FakeArm({"speedometer3_1": [2.0, 2.0]})
        code, out = self.main(self.arms(cmux, chrome))
        self.assertEqual(code, 0)
        written = perf_result.read_dir(out)
        self.assertEqual({r.metric: r.samples for r in written},
                         {"browser_macro.cmux.speedometer3_1.score": [3.0, 3.0, 3.0, 3.0],
                          "browser_macro.chrome.speedometer3_1.score": [2.0, 2.0, 2.0, 2.0],
                          "browser_macro.cmux_over_chrome.speedometer3_1.score_ratio": [1.5, 1.5]})
        runs = json.loads((out / macro.RUNS_FILE).read_text(encoding="utf-8"))
        self.assertEqual(runs["chrome"]["version"], "151.0.1")
        self.assertEqual(len(runs["runs"]), 4)
        self.assertEqual(runs["suites"]["jetstream2_2"]["commit"], macro.suite_named("jetstream2_2").commit)

    def test_main_partial_night_exits_1(self) -> None:
        code, out = self.main(self.arms(FakeArm(), FakeArm(fail="crashed", fail_suites={"jetstream2_2"})),
                              suites=("speedometer3_1", "jetstream2_2"))
        self.assertEqual(code, 1)
        self.assertEqual({r.metric.split(".")[2] for r in perf_result.read_dir(out)}, {"speedometer3_1"})
        self.assertEqual(list(json.loads((out / macro.RUNS_FILE).read_text())["failed"]), ["jetstream2_2"])

    def test_main_every_suite_failed_writes_nothing(self) -> None:
        code, out = self.main(self.arms(FakeArm(), FakeArm(fail="crashed")))
        self.assertEqual(code, 2)
        self.assertEqual(list(out.glob("*.ndjson")), [])
        self.assertIn("speedometer3_1", json.loads((out / macro.RUNS_FILE).read_text())["failed"])

    def test_main_no_chromium_writes_nothing(self) -> None:
        class NoCef(FakeArm):
            def run(self, server, out):
                raise macro.NoChromium("cmux arm: Chromium is unavailable")

        code, out = self.main(self.arms(NoCef(), FakeArm()))
        self.assertEqual(code, 2)
        self.assertEqual(list(out.glob("*.ndjson")), [])
        self.assertIn("*", json.loads((out / macro.RUNS_FILE).read_text())["failed"])

    def test_main_unnamed_build_is_env_invalid_before_any_browser(self) -> None:
        started = []

        def measure(_app, _env):
            raise macro.EnvInvalid("no CMUXCommit")

        code, _out = self.main(lambda *_: started.append(1), measure=measure)
        self.assertEqual(code, macro.ENV_INVALID)
        self.assertEqual(started, [])


if __name__ == "__main__":
    unittest.main()
