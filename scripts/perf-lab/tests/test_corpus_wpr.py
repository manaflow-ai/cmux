"""Tests for scripts/perf-lab/corpus/wpr.py (task 113): the replay switches, the spki, the public-URL rule, the wpr
log, the server's port lines and SIGINT stop, and a whole verify run against a fake wpr and a fake app.

Run: python3 -m unittest scripts/perf-lab/tests/test_corpus_wpr.py
"""

import importlib.util
import json
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest
import unittest.mock
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("corpus_wpr_under_test", HERE.parent / "corpus" / "wpr.py")
wpr = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = wpr
spec.loader.exec_module(wpr)
REPO_ROOT = HERE.parents[2]

# Self-signed certificates (openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -subj /CN=wpr-test, and
# -newkey rsa:2048 -subj /CN=wpr-rsa, the kind wpr_cert.pem is) and the spki that
# `openssl x509 -pubkey -noout | openssl pkey -pubin -outform der | openssl dgst -sha256 -binary | base64` prints.
CERT = textwrap.dedent("""\
    -----BEGIN CERTIFICATE-----
    MIIBfTCCASOgAwIBAgIUbGfcfzFvxMK7uiOqNotYLL0qcYIwCgYIKoZIzj0EAwIw
    EzERMA8GA1UEAwwId3ByLXRlc3QwIBcNMjYxMDI2MTg1ODA4WhgPMjEyNjEwMDIx
    ODU4MDhaMBMxETAPBgNVBAMMCHdwci10ZXN0MFkwEwYHKoZIzj0CAQYIKoZIzj0D
    AQcDQgAESWj2vV7GXgHprV+GcZGg1e+RM/Lradr4PMEoMQIceQ2WuTiW9hdqMSKC
    DgVRY9M/EJD4xdk9Y5Qo45sR49Mwy6NTMFEwHQYDVR0OBBYEFDT1WF3V3oodT+L3
    xgrYKEm7iIeoMB8GA1UdIwQYMBaAFDT1WF3V3oodT+L3xgrYKEm7iIeoMA8GA1Ud
    EwEB/wQFMAMBAf8wCgYIKoZIzj0EAwIDSAAwRQIhAICT7e0nuONb+NkHRcOKDVkZ
    5yNKEw7B/GpY05W/TzsVAiA4nREc4Jo/PSBJmPji6xL5ZUpkwDdGdWAK23otC7as
    zg==
    -----END CERTIFICATE-----
""")
CERT_SPKI = "Ds9sTA8XKyP/pk46bEUfZUqCfqEEbFNM7YSPCEcCY9Y="
RSA_CERT = textwrap.dedent("""\
    -----BEGIN CERTIFICATE-----
    MIIDBzCCAe+gAwIBAgIUJZSZI4hcLPq1WD0bdb3xXQ7RQZgwDQYJKoZIhvcNAQEL
    BQAwEjEQMA4GA1UEAwwHd3ByLXJzYTAgFw0yNjEwMjYxODU4MjBaGA8yMTI2MTAw
    MjE4NTgyMFowEjEQMA4GA1UEAwwHd3ByLXJzYTCCASIwDQYJKoZIhvcNAQEBBQAD
    ggEPADCCAQoCggEBAJfM66sqtUupyAK561clAB+Fx0qZx4BD4eCZyLcLQagefLHA
    VCGXc7w60aI/G5OnKd/zLr7d9H6qvTryNmBDz1a81FgdXY//Q1dIOV39V2rzge8k
    WrYtBhnBtunE4/du104BuE2QqeXQ/4M3fq0jpJvo8d+emeFACf/2KyoYuw4UtmmA
    Ibnj0M/w8CSma0NrU4/fXun0ZQO2dP/HZ81/UjZk0cLo+PnZAweo7tULY8v9b2IN
    sItIyORrX/zWqTDlDAPuuiintSxVtR06rIRrMS9QGkk/II0ZXoHrdUV6mVi+ltQI
    JlId2lHK695OIpD0cug2s6Ri7xuFoqRh3ZftBm8CAwEAAaNTMFEwHQYDVR0OBBYE
    FCKCHqW1TalApoSXLYQ8dwVxrENFMB8GA1UdIwQYMBaAFCKCHqW1TalApoSXLYQ8
    dwVxrENFMA8GA1UdEwEB/wQFMAMBAf8wDQYJKoZIhvcNAQELBQADggEBAE+/ZQkR
    acxOGswpBfiyT+m8EDYOFotFk51z+mH34stYLPqb18SGbs5XtyapSAnLLmgSlVjU
    vs2//cCND9Y90kBKs0ue6He89SiCIGhUBJzjCfXzVeFjgIZxwFHlVmKbu2yF0Qr7
    8lnoVvkO2Cb8dfHN2mamz3MUvZpfVorBZyrMMPmM/2NLt4gbuvODgQ8eciMLzT/O
    itWkdblCdqZcrlqaR9vn8XTE6UPqXSN3HKI1Qw6FtrXUGCUhkmxXL5BuVy9CVo2M
    D3YVaVTU05Hr7ySXfjKgp+qnPLp4Gn+8VMrGN1Wnmvi5/0MWKgQHC9L5VjV4bJWY
    zL6ESw6lBhEAQ3Q=
    -----END CERTIFICATE-----
""")
RSA_SPKI = "8YcLe1GmDetH8qYI6AXbMTqtJ4BUmN0VD3Zk9CHAPQ8="


def slog(level: str, msg: str, **attrs: str) -> str:
    """A line of the pinned wpr's log (log.go: slog.NewTextHandler; a value with a space, `=` or `"` in Go quotes)."""
    def value(text: str) -> str:
        return json.dumps(text) if not text or any(c in text for c in ' ="\\') else text
    pairs = [f"time=2026-10-26T00:00:00.000Z level={level} msg={value(msg)}"]
    pairs += [f"{key}={value(text)}" for key, text in attrs.items()]
    return " ".join(pairs)


def hit(url: str, status: str = "200") -> str:
    return slog("INFO", "Proxy: SERVING response", url=url, status=status)


def miss(url: str) -> str:
    return slog("WARN", "Proxy: FAILED to find request", url=url,
                error="could not find a matching request for " + url)


# The pinned wpr: urfave/cli v2 flags with hyphens (an underscore name is "flag provided but not defined"), the
# "Starting server on" lines from fmt.Printf, everything else through slog on stderr.
FAKE_WPR = textwrap.dedent("""\
    import signal, sys, time
    mode, archive = sys.argv[1], sys.argv[-1]
    flags = {arg.split("=", 1)[0] for arg in sys.argv[2:-1]}
    known = {"--host", "--http-port", "--https-port", "--https-cert-file", "--https-key-file", "--inject-scripts"}
    if flags - known:
        print(f"Incorrect Usage: flag provided but not defined: {sorted(flags - known)[0]}", file=sys.stderr)
        sys.exit(1)
    stopped = []
    signal.signal(signal.SIGINT, lambda *_: stopped.append(1))
    print('time=2026-10-26T00:00:00.000Z level=INFO msg="Opened archive" path=' + archive, file=sys.stderr, flush=True)
    print("Starting server on http://127.0.0.1:41001", flush=True)
    print("Starting server on https://127.0.0.1:41002", flush=True)
    while not stopped:
        time.sleep(0.01)
    if mode == "record":
        open(archive, "wb").write(b"archive")
    for line in open(archive + ".log").read().splitlines() if mode == "replay" else []:
        print(line, file=sys.stderr, flush=True)
""")


def make_wpr_dir(root: Path, commit: str = "c" * 40) -> Path:
    directory = root / "wpr"
    directory.mkdir()
    (directory / "fake_wpr.py").write_text(FAKE_WPR, encoding="utf-8")
    (directory / "wpr").write_text("#!/bin/sh\nexec python3 \"$(dirname \"$0\")/fake_wpr.py\" \"$@\"\n", encoding="utf-8")
    (directory / "wpr").chmod(0o755)
    (directory / "wpr_cert.pem").write_text(CERT, encoding="utf-8")
    (directory / "wpr_key.pem").write_text("key", encoding="utf-8")
    (directory / "deterministic.js").write_text("", encoding="utf-8")
    (directory / ".cmux-perf-lab-commit").write_text(commit + "\n", encoding="utf-8")
    return directory


class FakeApp:
    """A launched bench app: answers debug.cef, action.run, browser.page.wait and debug.browser.page_status."""

    def __init__(self, env, cef=None, failing=()):
        self.launched_env, self.cef, self.failing = env, cef if cef is not None else {"state": "ready"}, set(failing)
        self.tabs, self.stopped, self.calls = {}, False, []

    def rpc(self, method, params=None, timeout=60):
        self.calls.append(method)
        if method == "debug.cef":
            return self.cef
        if method == "action.run":
            tab = f"tab_{len(self.tabs)}"
            self.tabs[tab] = params["args"]["url"]
            return {"created": [tab]}
        if method == "browser.page.wait":
            return {"waited": True}
        if method == "debug.browser.page_status":
            failed = self.tabs[params["tab"]] in self.failing
            return {"error": "", "certificate": "1" if failed else "0", "gone": "0", "enginePage": "0"}
        return {"error": f"unknown {method}"}

    def stop(self):
        self.stopped = True


class SwitchTests(unittest.TestCase):
    def test_switches_are_only_the_wpr_pair_and_survive_cef_parsing(self):
        value = wpr.bench_switches(41001, 41002, "A" * 43 + "=")
        kept = wpr.kept_bench_switches(value)
        self.assertEqual(kept, value.splitlines())
        self.assertEqual([line.split("=", 1)[0] for line in kept], list(wpr.BENCH_SWITCH_NAMES))
        rules = kept[0].split("=", 1)[1].split(",")
        self.assertEqual(rules[:3], ["MAP *:80 127.0.0.1:41001", "MAP *:443 127.0.0.1:41002", "MAP * ~NOTFOUND"])
        self.assertIn("EXCLUDE localhost", rules)

    def test_the_names_match_cef_switches(self):
        swift = (REPO_ROOT / "Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/CEF/CEFSwitches.swift").read_text()
        for name in wpr.BENCH_SWITCH_NAMES:
            self.assertIn(f'"{name}"', swift)
        self.assertIn(f'"{wpr.BENCH_SWITCHES_ENV}"', swift)

    def test_switches_never_go_to_this_process(self):
        with self.assertRaises(wpr.WprError):
            wpr.bench_env("x", {wpr.BENCH_SWITCHES_ENV: "host-resolver-rules=MAP * 1.2.3.4"})
        self.assertEqual(wpr.bench_env("x", {}), {wpr.BENCH_SWITCHES_ENV: "x"})

    def test_only_development_and_bench_bundles(self):
        self.assertIsNone(wpr.bench_bundle_problem("com.cmuxterm.app.debug.wpr.verify"))
        self.assertIsNone(wpr.bench_bundle_problem("com.cmuxterm.next.dev"))
        for shipped in ("com.cmuxterm.app", "com.cmuxterm.app.nightly", None):
            self.assertIsNotNone(wpr.bench_bundle_problem(shipped))


class SpkiTests(unittest.TestCase):
    def test_spki_is_base64_sha256_of_the_public_key(self):
        self.assertEqual(wpr.spki_of_pem(CERT), CERT_SPKI)
        self.assertEqual(wpr.spki_of_pem(RSA_CERT), RSA_SPKI)

    def test_garbage_is_refused(self):
        for text in ("", "-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----"):
            with self.assertRaises(wpr.WprError):
                wpr.spki_of_pem(text)


class PublicUrlTests(unittest.TestCase):
    @staticmethod
    def resolver(addresses):
        return lambda _host: addresses

    def test_public_https_page(self):
        self.assertIsNone(wpr.public_url_problem("https://en.wikipedia.org/wiki/Web_browser", self.resolver(["208.80.154.224"])))

    def test_refusals(self):
        public = self.resolver(["93.184.215.14"])
        for url in ("file:///etc/passwd", "https://user:pw@example.org/", "https://example.org:8443/",
                    "https://example.org/?token=abc", "https://example.org/#x", "http://127.0.0.1/", "http://localhost/",
                    "https://intranet/", "https://box.tailnet.ts.net/", "https://printer.local/", "https://[::1]/"):
            self.assertIsNotNone(wpr.public_url_problem(url, public), url)
        self.assertIsNotNone(wpr.public_url_problem("https://internal.example.org/", self.resolver(["10.0.0.5"])))
        self.assertIsNotNone(wpr.public_url_problem("https://gone.example.org/", self.resolver([])))

    def test_url_list(self):
        self.assertEqual(wpr.read_urls("# pages\nhttps://a.org/\n\nhttps://b.org/\n"), ["https://a.org/", "https://b.org/"])
        for text in ("", "https://a.org/\nhttps://a.org/\n"):
            with self.assertRaises(wpr.WprError):
                wpr.read_urls(text)

    def test_record_only_on_a_lab_host(self):
        self.assertIsNone(wpr.lab_host_problem(["CMUX17"]))
        self.assertIsNotNone(wpr.lab_host_problem(["lawrences-macbook"]))


class LogTests(unittest.TestCase):
    def test_hits_misses_and_tls_errors(self):
        log = wpr.parse_log("\n".join([
            "Starting server on http://127.0.0.1:41001",
            slog("DEBUG", "Proxy: Handling request", method="GET", url="https://a.org/"),
            hit("https://a.org/"),
            hit("https://a.org/app.js?v=2", "304"),
            miss("https://ads.example/x.js?id=\"q\" 1"),
            miss("https://cdn.example/font.woff2"),
            slog("INFO", "translating Content-Encoding", url="https://a.org/", origin="gzip", client="br"),
            "2026/10/26 00:00:01 http: TLS handshake error from 127.0.0.1:5000: remote error: tls: bad certificate",
        ]))
        self.assertEqual(log.served, 2)
        self.assertEqual(log.misses, ["https://ads.example/x.js?id=\"q\" 1", "https://cdn.example/font.woff2"])
        self.assertEqual(len(log.tls_errors), 1)

    def test_the_old_catapult_lines_count_for_nothing(self):
        # The pinned wpr never prints these; a parser that reads them would not see a real replay.
        log = wpr.parse_log("2026/10/26 ServeHTTP(https://a.org/): serving 200 response\n"
                            "2026/10/26 ServeHTTP(https://b.org/): couldn't find matching request\n")
        self.assertEqual((log.served, log.misses), (0, []))

    def test_slog_attrs(self):
        self.assertEqual(wpr.slog_attrs('time=t level=WARN msg="a b" url="https://x/?a=b" error="say \\"no\\""'),
                         {"time": "t", "level": "WARN", "msg": "a b", "url": "https://x/?a=b", "error": 'say "no"'})

    def test_verdict(self):
        good = {"label": "replay-1", "tabs": 2, "loaded": 2, "pages": [], "served": 9, "misses": 0, "miss_urls": [],
                "tls_errors": 0, "cef_problem": None}
        self.assertEqual(wpr.verify_problems([good, {**good, "label": "replay-2"}]), [])
        missed = {**good, "label": "replay-2", "misses": 1, "miss_urls": ["https://x/"]}
        self.assertTrue(any("network misses" in p for p in wpr.verify_problems([good, missed])))
        short = {**good, "label": "replay-2", "loaded": 1,
                 "pages": [{"url": "https://x/", "loaded": False, "problem": "sad tab"}]}
        problems = wpr.verify_problems([good, short])
        self.assertTrue(any("1 of 2 pages" in p for p in problems))
        self.assertTrue(any("page counts differ" in p for p in problems))
        self.assertTrue(any("served nothing" in p for p in wpr.verify_problems([{**good, "served": 0}] * 2)))


class PageTests(unittest.TestCase):
    def test_page_status(self):
        loaded = {"error": "", "certificate": "0", "gone": "0", "enginePage": "0"}
        self.assertIsNone(wpr.page_problem(loaded))
        self.assertIn("certificate", wpr.page_problem({**loaded, "certificate": "1"}))
        self.assertIn("sad tab", wpr.page_problem({**loaded, "gone": "1"}))
        self.assertIn("error page", wpr.page_problem({**loaded, "error": "This site can't be reached"}))
        self.assertIn("page_status", wpr.page_problem({"error": "no browser tab"}))

    def test_cef(self):
        self.assertIsNone(wpr.cef_problem({"state": "ready"}))
        self.assertIsNotNone(wpr.cef_problem({"unavailable": {"reason": "missing"}}))
        self.assertIsNotNone(wpr.cef_problem({"fallback": {"count": 1}}))
        self.assertIsNotNone(wpr.cef_problem({}))


class ServerAndRunTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix="wpr-test-"))
        self.addCleanup(shutil.rmtree, self.root, True)
        self.wpr_dir = make_wpr_dir(self.root)
        self.chromium = wpr.chromium_root("com.cmuxterm.app.debug.wpr", self.root / "home")

    def test_wpr_flags_are_the_pinned_builds(self):
        argv = wpr.wpr_argv(self.wpr_dir, "replay", self.root / "a.wprgo")
        self.assertEqual([arg.split("=", 1)[0] for arg in argv[2:-1]],
                         ["--host", "--http-port", "--https-port", "--https-cert-file", "--https-key-file",
                          "--inject-scripts"])

    def test_checked_wpr_dir(self):
        self.assertEqual(wpr.checked_wpr_dir(self.wpr_dir, "c" * 40), self.wpr_dir)
        with self.assertRaises(wpr.WprError):
            wpr.checked_wpr_dir(self.wpr_dir, "d" * 40)
        (self.wpr_dir / "wpr_cert.pem").unlink()
        with self.assertRaises(wpr.WprError):
            wpr.checked_wpr_dir(self.wpr_dir, "c" * 40)

    def test_record_writes_the_archive_on_sigint(self):
        archive = self.root / "new.wprgo"
        with wpr.WprServer(self.wpr_dir, "record", archive, self.root / "record.log") as server:
            self.assertEqual((server.http_port, server.https_port), (41001, 41002))
        self.assertEqual(server.returncode, 0)
        self.assertEqual(archive.read_bytes(), b"archive")

    def test_verify_twice_with_the_same_page_count(self):
        archive = self.root / "story.wprgo"
        archive.write_bytes(b"archive")
        Path(f"{archive}.log").write_text(hit("https://a.org/") + "\n", encoding="utf-8")
        apps = []

        def launch(env, _out):
            apps.append(FakeApp(env))
            return apps[-1]

        plan = wpr.RunPlan(self.wpr_dir, "app", ["https://a.org/", "https://b.org/"], 3, wpr.spki_of_pem(CERT),
                           self.root / "out", self.chromium, settle_s=0)
        runs = [wpr.run_once(plan, "replay", archive, f"replay-{n}", launch) for n in (1, 2)]
        self.assertEqual(wpr.verify_problems(runs), [])
        self.assertEqual([run["served"] for run in runs], [1, 1])
        self.assertEqual([run["loaded"] for run in runs], [3, 3])
        self.assertTrue(all(app.stopped for app in apps))
        switches = apps[0].launched_env[wpr.BENCH_SWITCHES_ENV]
        self.assertIn("MAP *:443 127.0.0.1:41002", switches)
        self.assertEqual(list(apps[0].tabs.values()), ["https://a.org/", "https://b.org/", "https://a.org/"])

    def test_a_miss_or_a_refused_certificate_fails_verify(self):
        archive = self.root / "story.wprgo"
        archive.write_bytes(b"archive")
        Path(f"{archive}.log").write_text(hit("https://a.org/") + "\n" + miss("https://b.org/x") + "\n",
                                          encoding="utf-8")
        plan = wpr.RunPlan(self.wpr_dir, "app", ["https://a.org/", "https://b.org/"], 2, "s", self.root / "out",
                           self.chromium, settle_s=0)
        runs = [wpr.run_once(plan, "replay", archive, f"replay-{n}",
                             lambda env, _out: FakeApp(env, failing={"https://b.org/"})) for n in (1, 2)]
        problems = wpr.verify_problems(runs)
        self.assertTrue(any("1 network misses" in p for p in problems))
        self.assertTrue(any("certificate warning" in p for p in problems))

    def test_unavailable_chromium_loads_nothing(self):
        archive = self.root / "story.wprgo"
        archive.write_bytes(b"archive")
        Path(f"{archive}.log").write_text("", encoding="utf-8")
        plan = wpr.RunPlan(self.wpr_dir, "app", ["https://a.org/"], 2, "s", self.root / "out", self.chromium,
                           settle_s=0)
        app = FakeApp({}, cef={"unavailable": {"reason": "missing"}})

        def launch(env, _out):
            app.launched_env = env
            return app

        run = wpr.run_once(plan, "replay", archive, "replay-1", launch)
        self.assertNotIn("action.run", app.calls)
        self.assertTrue(any("unavailable" in p for p in wpr.verify_problems([run, run])))

    def test_an_app_without_the_switches_is_refused(self):
        archive = self.root / "story.wprgo"
        archive.write_bytes(b"archive")
        Path(f"{archive}.log").write_text("", encoding="utf-8")
        plan = wpr.RunPlan(self.wpr_dir, "app", ["https://a.org/"], 1, "s", self.root / "out", self.chromium,
                           settle_s=0)
        app = FakeApp({})
        with self.assertRaises(wpr.WprError):
            wpr.run_once(plan, "replay", archive, "replay-1", lambda _env, _out: app)
        self.assertTrue(app.stopped)

    def test_every_launch_gets_an_empty_chromium_root(self):
        # A warm HTTP cache would answer subresources itself: record would leave them out of the archive and a
        # second replay would not go through wpr.
        self.assertEqual(self.chromium, self.root / "home" / "Library" / "Application Support"
                         / "com.cmuxterm.app.debug.wpr" / "Chromium")
        cache = self.chromium / "Profile-1" / "Cache" / "earlier-use"
        cache.parent.mkdir(parents=True)
        cache.write_text("cached", encoding="utf-8")
        archive = self.root / "story.wprgo"
        launched_with = []

        def launch(env, _out):
            launched_with.append(sorted(str(p.relative_to(self.chromium)) for p in self.chromium.rglob("*"))
                                 if self.chromium.exists() else None)
            filled = self.chromium / "Profile-1" / "Cache" / f"run-{len(launched_with)}"
            filled.parent.mkdir(parents=True, exist_ok=True)
            filled.write_text("cached", encoding="utf-8")  # the app fills its cache during the run
            return FakeApp(env)

        plan = wpr.RunPlan(self.wpr_dir, "app", ["https://a.org/"], 1, "s", self.root / "out", self.chromium,
                           settle_s=0)
        wpr.run_once(plan, "record", archive, "record", launch)
        Path(f"{archive}.log").write_text(hit("https://a.org/") + "\n", encoding="utf-8")
        runs = [wpr.run_once(plan, "replay", archive, f"replay-{n}", launch) for n in (1, 2)]
        self.assertEqual(launched_with, [None, None, None])
        self.assertEqual([run["chromium_root"] for run in runs], [str(self.chromium)] * 2)
        # One earlier root is kept beside it, as BenchApp.start_fresh keeps one earlier tag state.
        prev = self.chromium.with_name("Chromium.wpr-prev")
        self.assertEqual(sorted(p.name for p in (prev / "Profile-1" / "Cache").iterdir()), ["run-2"])

    def test_a_root_that_cannot_move_aside_stops_the_run(self):
        self.chromium.mkdir(parents=True)
        plan = wpr.RunPlan(self.wpr_dir, "app", ["https://a.org/"], 1, "s", self.root / "out", self.chromium,
                           settle_s=0)
        launched = []
        with unittest.mock.patch.object(wpr.os, "rename", side_effect=PermissionError("denied")):
            with self.assertRaises(OSError):
                wpr.run_once(plan, "record", self.root / "a.wprgo", "record", lambda env, _out: launched.append(env))
        self.assertEqual(launched, [])

    def test_spki_command(self):
        out = subprocess.run([sys.executable, "-I", str(HERE.parent / "corpus" / "wpr.py"), "spki", "--wpr",
                              str(self.wpr_dir)], capture_output=True, text=True)
        # pool.json pins another commit than the fake build's, so the build is refused with its reason.
        self.assertEqual(out.returncode, 1)
        self.assertIn("pool.json pins", out.stderr)
        (self.wpr_dir / ".cmux-perf-lab-commit").write_text(wpr.wpr_commit() + "\n", encoding="utf-8")
        out = subprocess.run([sys.executable, "-I", str(HERE.parent / "corpus" / "wpr.py"), "spki", "--wpr",
                              str(self.wpr_dir)], capture_output=True, text=True)
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertEqual(out.stdout.strip(), wpr.spki_of_pem(CERT))


class ManifestTests(unittest.TestCase):
    def test_the_spki_fits_the_story_schema(self):
        schema = json.loads((REPO_ROOT / "schemas/perf/corpus-story-v1.schema.json").read_text())
        pattern = schema["properties"]["web_archive"]["oneOf"][1]["properties"]["spki"]["oneOf"][1]["pattern"]
        self.assertRegex(wpr.spki_of_pem(CERT), pattern)


if __name__ == "__main__":
    unittest.main()
