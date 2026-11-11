#!/usr/bin/env python3
"""scripts/ci/fresh_home_launch_smoke.py, the nightly-next fresh-home launch gate, against stub apps.

A stub that aborts at launch fails it, a healthy stub (it serves snapshot.get with Home selected
in a visible window and streams the launch marks) passes it, a stub that stays up but never shows
Home fails it, and every run leaves no process and no private root behind. The healthy stub also
checks what the gate promises the app: an empty HOME, no runner variables, and its defaults set
aside and put back.

The second arm (--arms empty,seeded) launches the stub again from the home seed_cookie_sync_home makes. A stub
that reads the seeded cookie store as the app's cookie sync does (and saves its baseline) passes it, one that
aborts only in that home fails the run as a crash of that arm, and one that never reads the store leaves the
arm "not-run" and the first arm's verdict standing.
"""
from __future__ import annotations

import importlib.util
import json
import os
from pathlib import Path
import plistlib
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.parse

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "ci" / "fresh_home_launch_smoke.py"
spec = importlib.util.spec_from_file_location("fresh_home_launch_smoke", SCRIPT)
smoke = importlib.util.module_from_spec(spec)
spec.loader.exec_module(smoke)

BUNDLE = "com.example.fresh-smoke-stub"

# The stub app: MODE (crash | healthy | no-home | new-tab | first-run | first-run-unmarked | sync-crash | no-sync)
# comes from the bundle's Resources/mode file. sync-crash and no-sync are healthy in an empty home.
STUB = r'''#!PYTHON
import json, os, signal, socket, subprocess, sys, time
here = os.path.dirname(os.path.abspath(__file__))
mode = open(os.path.join(here, "..", "Resources", "mode")).read().strip()
home = os.environ["HOME"]
report = {"home_entries": sorted(os.listdir(home)), "cffixed": os.environ.get("CFFIXED_USER_HOME"),
          "leaked": sorted(k for k in os.environ if k in ("GH_TOKEN", "FRESH_SMOKE_SECRET", "RUNNER_TEMP"))}
open(os.path.join(home, "stub-report.json"), "w").write(json.dumps(report))
# A detached helper, as the real app's daemons are: cleanup must stop it by the run's root.
helper = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(600)", os.path.abspath(__file__)],
                          start_new_session=True)
open(os.path.join(home, "helper.pid"), "w").write(str(helper.pid))
# A terminal host, as the real app's are: detached, its command line never names the root, its cwd is /. Only its
# record under HOME names it, so cleanup must stop it by that record's host_pid.
host = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(600)", "__terminal-host"], cwd="/",
                        start_new_session=True)
records = os.path.join(home, "Library", "Application Support", "cmux-next", "tags", "stub", "tui", "terminal-hosts-0")
os.makedirs(records, exist_ok=True)
open(os.path.join(records, "abc.json"), "w").write(json.dumps({"terminal_id": "abc", "host_pid": host.pid}))
# Outside the run's root, so the test can read it after cleanup removed the root.
pid_path = os.path.join(here, "..", "Resources", "host_pid_path")
if os.path.exists(pid_path):
    open(open(pid_path).read().strip(), "w").write(str(host.pid))
if mode == "crash":
    time.sleep(0.5)
    os.abort()
# The seeded home (the smoke's second arm): an import store that names sources whose cookies are kept in sync.
import glob
seeded = glob.glob(os.path.join(home, "Library", "Application Support", "*", "BrowserImport", "sources.json"))
if seeded and mode == "sync-crash":  # as build 4294166855401: dead in its cookie sync, only with such a home
    time.sleep(0.5)
    os.abort()
if seeded and mode != "no-sync":
    # As the app's cookie sync: with the setting on, each such source's store is opened and read, then the
    # baseline of what it holds is saved.
    import sqlite3, urllib.parse
    wanted = json.load(open(os.path.join(home, ".config", "cmux", "cmux-next.json")))["browser"]["import"]
    for record in json.load(open(seeded[0])) if wanted["enabled"] and wanted["cookieSync"] else []:
        database = urllib.parse.unquote(urllib.parse.urlparse(record["syncedCookieFile"]).path)
        conn = sqlite3.connect("file:" + urllib.parse.quote(database) + "?mode=ro", uri=True)
        hosts = {host: str(rows) for host, rows in conn.execute(
            "SELECT host_key, count(*) FROM cookies WHERE length(encrypted_value) > 0 GROUP BY host_key")}
        conn.close()
        state = os.path.join(os.path.dirname(seeded[0]), "cookie-sync")
        os.makedirs(state, exist_ok=True)
        saved = {"version": 1, "source": record["browser"] + "/" + record["profileDirectory"], "hosts": hosts}
        open(os.path.join(state, "chrome_Default-0123456789abcdef.fingerprint"), "w").write(json.dumps(saved))
if mode in ("sync-crash", "no-sync"):
    mode = "healthy"
marks = int(os.environ["CMUX_NEXT_LAUNCH_MARKS_FD"])
os.write(marks, b"main_start 10.0\n")
if mode in ("healthy", "new-tab", "first-run", "first-run-unmarked"):
    os.write(marks, b"first_window_frame_committed 120.5\n")
# first-run: a fresh NEXT Nightly since #33215. The Bring your history page covers Home, which parks Home's pane
# (no selected tab), and the app marks that it opened the page. first-run-unmarked: the same topology, no mark.
if mode == "first-run":
    os.write(marks, b"first_run.history_import_shown 300.0\n")
# new-tab: what a fresh launch of feat shows (2026-11-04): its first frame, a New Tab tab selected, Home not.
page = {"healthy": "home-dock", "new-tab": "new-tab", "first-run": "home-dock", "first-run-unmarked": "home-dock"}.get(mode, "terminal")
selected = None if mode.startswith("first-run") else "tab_1"
topology = {"windows": [{"id": "win_1", "visible": True, "workspace": "ws_1"}],
            "workspaces": [{"id": "ws_1", "name": "Home", "screens": [{"panes": [
                {"id": "pane_1", "selected_tab": selected, "tabs": [{"id": "tab_1", "kind": "page", "page": page}]}]}]}]}
server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(os.environ["CMUX_NEXT_SOCKET_PATH"])
server.listen(8)
while True:
    conn, _ = server.accept()
    data = b""
    while b"\n" not in data:
        chunk = conn.recv(65536)
        if not chunk:
            break
        data += chunk
    if data:
        request = json.loads(data.split(b"\n", 1)[0])
        conn.sendall((json.dumps({"id": request["id"], "ok": True, "result": {"topology": topology}}) + "\n").encode())
    conn.close()
'''

# A `defaults` stand-in: export writes the domain's file, delete removes it, import restores it.
DEFAULTS = r'''#!PYTHON
import os, plistlib, shutil, sys
store = os.environ["FAKE_DEFAULTS_DIR"]
verb, domain = sys.argv[1], sys.argv[2]
path = os.path.join(store, domain + ".plist")
with open(os.path.join(store, "calls.log"), "a") as log:
    log.write(" ".join(sys.argv[1:3]) + "\n")
if os.environ.get("FAKE_DEFAULTS_FAIL") == verb:
    sys.exit(1)
if verb == "export":  # as macOS does: a missing domain exports as an empty dictionary
    if os.path.exists(path):
        plistlib.dump({"stored": open(path, "rb").read()}, open(sys.argv[3], "wb"))
    else:
        plistlib.dump({}, open(sys.argv[3], "wb"))
elif verb == "delete" or verb == "read":
    if not os.path.exists(path):
        sys.exit(1)
    if verb == "delete":
        os.remove(path)
elif verb == "import":
    data = plistlib.load(open(sys.argv[3], "rb"))
    if data:
        open(path, "wb").write(data["stored"])
'''


def write_executable(path: Path, text: str) -> None:
    path.write_text(text.replace("PYTHON", sys.executable, 1))
    path.chmod(0o755)


def make_app(parent: Path, mode: str) -> Path:
    app = parent / f"Stub {mode}.app"
    (app / "Contents" / "MacOS").mkdir(parents=True)
    (app / "Contents" / "Resources").mkdir()
    with open(app / "Contents" / "Info.plist", "wb") as handle:
        plistlib.dump({"CFBundleIdentifier": BUNDLE, "CFBundleExecutable": "stub"}, handle)
    (app / "Contents" / "Resources" / "mode").write_text(mode)
    write_executable(app / "Contents" / "MacOS" / "stub", STUB)
    return app


class FreshHomeLaunchSmokeTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        self.defaults_dir = self.dir / "defaults-store"
        self.defaults_dir.mkdir()
        write_executable(self.dir / "defaults", DEFAULTS)
        self.env = {
            **os.environ,
            "CMUX_FRESH_SMOKE_DEFAULTS_TOOL": str(self.dir / "defaults"),
            "CMUX_FRESH_SMOKE_LOCK_DIR": str(self.dir),
            "CMUX_FRESH_SMOKE_DIAGNOSTIC_DIR": str(self.dir / "diagnostics"),
            "CMUX_FRESH_SMOKE_SKIP_SESSION_CHECK": "1",
            "CMUX_FRESH_SMOKE_CRASH_REPORT_WAIT_SECONDS": "0",
            "CMUX_FRESH_SMOKE_SEEDED_SCAN_WAIT_SECONDS": "4",
            "FAKE_DEFAULTS_DIR": str(self.defaults_dir),
            "FRESH_SMOKE_SECRET": "must-not-reach-the-app",
            "GH_TOKEN": "must-not-reach-the-app",
        }
        self.env.pop("RUNNER_TEMP", None)
        self.env.pop("CMUX_SIGNING_KEYCHAIN_STATE_DIR", None)
        self.roots_before = set(Path("/tmp").glob("cmux-fresh-*"))

    def tearDown(self):
        self.tmp.cleanup()

    def run_smoke(self, mode: str, *extra: str, env: dict | None = None, ready: str = "") -> tuple[int, str, dict]:
        """The smoke on a stub of MODE. `ready`: a caller's READY (a Python expression over `smoke`), set by a small
        caller script as scripts/cmux-next/idle_cpu.py sets it; empty runs the smoke itself."""
        self.runs = getattr(self, "runs", 0) + 1
        app = make_app(self.dir / f"run-{self.runs}", mode)
        if getattr(self, "host_pid_path", None):
            (app / "Contents" / "Resources" / "host_pid_path").write_text(str(self.host_pid_path))
        out = self.dir / f"out-{mode}-{self.runs}"
        argv = [str(SCRIPT), "--app", str(app), "--out", str(out), *extra]
        if ready:
            caller = ("import importlib.util, sys\n"
                      f"spec = importlib.util.spec_from_file_location('smoke', {str(SCRIPT)!r})\n"
                      "smoke = importlib.util.module_from_spec(spec); spec.loader.exec_module(smoke)\n"
                      f"smoke.READY = {ready}\n"
                      "sys.exit(smoke.main(sys.argv[1:]))\n")
            argv = ["-c", caller, *argv[1:]]
        result = subprocess.run([sys.executable, *argv],
                                env=env or self.env, capture_output=True, text=True, timeout=120)
        report = json.loads((out / "report.json").read_text())
        return result.returncode, result.stdout + result.stderr, report

    def assert_cleaned_up(self, report: dict) -> None:
        root = Path(report["root"])
        self.assertFalse(root.exists(), f"{root} was left behind")
        self.assertEqual(set(Path("/tmp").glob("cmux-fresh-*")) - self.roots_before, set())
        if report.get("pid"):
            self.assertFalse(smoke.alive(report["pid"]), "the app outlived the run")

    def test_a_stub_that_aborts_at_launch_fails(self):
        status, output, report = self.run_smoke("crash", "--seconds", "3", "--startup-timeout", "5")
        self.assertEqual(status, smoke.FAIL, output)
        self.assertEqual(report["verdict"], "fail")
        self.assertRegex(report["failures"][0], r"the app exited \(signal 6\)")
        self.assertIn("FAIL: the app exited", output)
        self.assert_cleaned_up(report)

    def test_a_healthy_stub_passes_with_a_fresh_home_and_no_runner_secrets(self):
        (self.defaults_dir / f"{BUNDLE}.plist").write_bytes(b"account defaults")
        status, output, report = self.run_smoke("healthy", "--seconds", "3", "--startup-timeout", "10")
        self.assertEqual(status, smoke.PASS, output)
        self.assertEqual(report["verdict"], "pass")
        self.assertEqual(report["home_tab"]["page"], "home-dock")
        self.assertIn("first_window_frame_committed", report["marks"])
        self.assertGreaterEqual(report["seconds_up"], 3)
        # Without --arms there is one launch, from the empty home, and the report says nothing of arms.
        self.assertNotIn("arms", report)
        self.assertNotIn("seeded-home", output)
        # The account's defaults were set aside for the run and are back, byte for byte.
        calls = (self.defaults_dir / "calls.log").read_text().split("\n")
        self.assertEqual(calls[:2], [f"export {BUNDLE}", f"delete {BUNDLE}"])
        self.assertEqual((self.defaults_dir / f"{BUNDLE}.plist").read_bytes(), b"account defaults")
        self.assert_cleaned_up(report)

    def test_defaults_a_killed_run_left_aside_are_put_back_first(self):
        domain = self.defaults_dir / f"{BUNDLE}.plist"
        domain.write_bytes(b"what the killed run's app wrote")
        aside = self.dir / f"cmux-fresh-smoke-{BUNDLE}.aside.plist"
        aside.write_bytes(plistlib.dumps({"stored": b"account defaults"}))
        status, output, report = self.run_smoke("healthy", "--seconds", "2", "--startup-timeout", "10")
        self.assertEqual(status, smoke.PASS, output)
        self.assertEqual(domain.read_bytes(), b"account defaults")
        self.assertFalse(aside.exists())

    def test_a_domain_that_did_not_exist_is_removed_again(self):
        domain = self.defaults_dir / f"{BUNDLE}.plist"
        status, output, report = self.run_smoke("healthy", "--seconds", "2", "--startup-timeout", "10")
        self.assertEqual(status, smoke.PASS, output)
        self.assertFalse(domain.exists())
        self.assertFalse((self.dir / f"cmux-fresh-smoke-{BUNDLE}.aside.plist").exists())

    def test_an_export_that_fails_is_cannot_run_and_touches_nothing(self):
        domain = self.defaults_dir / f"{BUNDLE}.plist"
        domain.write_bytes(b"account defaults")
        status, output, report = self.run_smoke("healthy", "--seconds", "1",
                                                env={**self.env, "FAKE_DEFAULTS_FAIL": "export"})
        self.assertEqual(status, smoke.CANNOT_RUN, output)
        self.assertNotIn("pid", report)
        self.assertEqual(domain.read_bytes(), b"account defaults")

    def test_a_delete_that_fails_keeps_the_copy_and_does_not_launch(self):
        domain = self.defaults_dir / f"{BUNDLE}.plist"
        domain.write_bytes(b"account defaults")
        status, output, report = self.run_smoke("healthy", "--seconds", "1",
                                                env={**self.env, "FAKE_DEFAULTS_FAIL": "delete"})
        self.assertEqual(status, smoke.CANNOT_RUN, output)
        self.assertNotIn("pid", report)
        aside = self.dir / f"cmux-fresh-smoke-{BUNDLE}.aside.plist"
        self.assertEqual(plistlib.loads(aside.read_bytes()), {"stored": b"account defaults"})

    def test_defaults_that_cannot_be_put_back_fail_closed_and_stay_aside(self):
        domain = self.defaults_dir / f"{BUNDLE}.plist"
        domain.write_bytes(b"account defaults")
        status, output, report = self.run_smoke("healthy", "--seconds", "2", "--startup-timeout", "10",
                                                env={**self.env, "FAKE_DEFAULTS_FAIL": "import"})
        self.assertEqual(status, smoke.CANNOT_RUN, output)
        aside = self.dir / f"cmux-fresh-smoke-{BUNDLE}.aside.plist"
        self.assertEqual(plistlib.loads(aside.read_bytes()), {"stored": b"account defaults"})
        self.assert_cleaned_up(report)

    def test_the_app_sees_an_empty_home_and_none_of_the_runner_environment(self):
        app = make_app(self.dir, "healthy")
        root = Path(tempfile.mkdtemp(prefix="cmux-fresh-", dir="/tmp"))
        try:
            fd_r, fd_w = os.pipe()
            env = smoke.fresh_env(root, root / "s.sock", fd_w)
            self.assertEqual(env["HOME"], env["CFFIXED_USER_HOME"])
            self.assertNotIn("GH_TOKEN", env)
            self.assertNotIn("FRESH_SMOKE_SECRET", env)
            entries = sorted(os.listdir(env["HOME"]))
            self.assertEqual(entries, ["Library"])
            os.close(fd_r)
            os.close(fd_w)
        finally:
            subprocess.run(["rm", "-rf", str(root)], check=False)
        self.assertTrue(app.exists())

    def seeded(self, mode: str, *extra: str) -> tuple[int, str, dict, Path]:
        status, output, report = self.run_smoke(mode, "--seconds", "2", "--startup-timeout", "10",
                                                "--arms", "empty,seeded", "--seeded-seconds", "2", *extra)
        return status, output, report, self.dir / f"out-{mode}-{self.runs}"

    def test_the_seed_tool_makes_a_home_with_cookie_sync_on_and_a_store_with_rows(self):
        home = self.dir / "seeded-home"
        seed = smoke.seed_cookie_sync_home(home, BUNDLE, now=1_800_000_000)
        settings = json.loads((home / ".config" / "cmux" / "cmux-next.json").read_text())
        self.assertEqual(settings, {"browser": {"import": {"enabled": True, "cookieSync": True}}})
        store = home / "Library" / "Application Support" / BUNDLE / "BrowserImport"
        (record,) = json.loads((store / "sources.json").read_text())
        # What ImportSourceRecord decodes: the four required strings, and the store the cookies are kept in sync from.
        for key in ("browser", "profileDirectory", "displayName", "proposedProfileID", "targetProfileID"):
            self.assertIsInstance(record[key], str)
        self.assertEqual(seed["source"], f"{record['browser']}/{record['profileDirectory']}")
        self.assertEqual(seed["source"], "chrome/Default")
        # Not "default": the app moves such an import into a new browser profile at launch (migrateImports).
        self.assertNotEqual(record["targetProfileID"], "default")
        self.assertTrue(record["syncedCookieFile"].startswith("file:///"))
        # A file URL as Foundation writes one (the space of "Application Support" percent-encoded).
        self.assertIn("/Application%20Support/", record["syncedCookieFile"])
        database = Path(urllib.parse.unquote(urllib.parse.urlparse(record["syncedCookieFile"]).path))
        self.assertTrue(database.is_file())
        # Outside every browser's own folder, so the app's browser detection finds no browser in this home.
        for browser in ("Google", "Chromium", "BraveSoftware", "Microsoft Edge", "Arc", "Firefox"):
            self.assertFalse((home / "Library" / "Application Support" / browser).exists())
        conn = sqlite3.connect(str(database))
        try:
            # The columns the app's sync and importer read (cmux-cookie-sync fingerprint.rs, ChromiumCookieReader).
            rows = conn.execute("SELECT host_key, top_frame_site_key, name, path, value, encrypted_value, expires_utc, "
                                "has_expires, is_secure, is_httponly, samesite FROM cookies").fetchall()
        finally:
            conn.close()
        self.assertEqual(len(rows), seed["rows"])
        self.assertGreater(len(rows), 100)
        self.assertEqual(len({row[0] for row in rows}), seed["hosts"])
        for host, _site, _name, _path, value, blob, expires, *_ in rows:
            self.assertRegex(host, r"^(\.|www\.|app\.|login\.)example\.(com|org|net)$")
            self.assertEqual(value, "")
            self.assertTrue(blob.startswith(b"v10") and len(blob) > 3)
            self.assertGreater(expires, (1_800_000_000 + smoke.CHROMIUM_EPOCH_OFFSET) * 1_000_000)
        # No baseline: the sync's first read then saves its own and asks the Keychain for nothing.
        self.assertFalse(Path(seed["state_dir"]).exists())
        self.assertIsNone(smoke.cookie_sync_scanned(seed))
        # The proof of a read is a baseline of this source that names sites, and nothing else.
        state = Path(seed["state_dir"])
        state.mkdir()
        (state / "other.fingerprint").write_text(json.dumps({"version": 1, "source": "arc/Default", "hosts": {"a": "1"}}))
        (state / "torn.fingerprint").write_text("{")
        self.assertIsNone(smoke.cookie_sync_scanned(seed))
        (state / "x.fingerprint").write_text(json.dumps({"version": 1, "source": "chrome/Default", "hosts": {"a": "1"}}))
        self.assertEqual(smoke.cookie_sync_scanned(seed), {"hosts": 1})

    def test_the_seeded_arm_passes_when_the_app_reads_the_seeded_store(self):
        (self.defaults_dir / f"{BUNDLE}.plist").write_bytes(b"account defaults")
        self.host_pid_path = self.dir / "host.pid"
        status, output, report, out = self.seeded("healthy")
        self.assertEqual(status, smoke.PASS, output)
        self.assertEqual((report["verdict"], report["arm"]), ("pass", "empty"))
        self.assertEqual(report["arms"]["empty"]["verdict"], "pass")
        arm = report["arms"]["seeded"]
        self.assertEqual(arm["verdict"], "pass", output)
        self.assertEqual(arm["cookie_sync"]["scanned_hosts"], len(smoke.SEED_HOSTS))
        self.assertGreaterEqual(arm["seconds_up"], 2)
        self.assertNotEqual(arm["pid"], report["pid"])
        self.assertIn("seeded-home arm OK", output)
        # The report still describes the first arm; each arm has its log.
        self.assertEqual(report["home_tab"]["page"], "home-dock")
        self.assertTrue((out / "app.log").is_file() and (out / "app-seeded.log").is_file())
        # The defaults were set aside for each launch and are back; the second launch and its hosts are gone.
        calls = (self.defaults_dir / "calls.log").read_text().split("\n")
        self.assertEqual(calls.count(f"delete {BUNDLE}"), 4)
        self.assertEqual((self.defaults_dir / f"{BUNDLE}.plist").read_bytes(), b"account defaults")
        time.sleep(0.2)
        self.assertFalse(smoke.alive(arm["pid"]), "the seeded launch outlived the run")
        self.assertFalse(smoke.alive(int(self.host_pid_path.read_text())), "the seeded launch's terminal host outlived the run")
        self.assert_cleaned_up(report)

    def test_a_crash_from_the_seeded_home_fails_the_run_as_that_arms_crash(self):
        status, output, report, out = self.seeded("sync-crash")
        self.assertEqual(status, smoke.FAIL, output)
        # The report now describes the seeded launch, in the fields the publish gate reads for a crash verdict.
        self.assertEqual((report["verdict"], report["arm"]), ("fail", "seeded"))
        self.assertEqual(report["exit"], -6)
        self.assertEqual(report["pid"], report["arms"]["seeded"]["pid"])
        self.assertRegex(report["failures"][0], r"^seeded home: the app exited \(signal 6\)")
        self.assertEqual(report["arms"]["empty"]["verdict"], "pass")
        self.assertEqual(report["arms"]["seeded"]["verdict"], "fail")
        self.assertIn("FAIL: seeded home: the app exited", output)
        self.assertTrue((out / "app.log").is_file() and (out / "app-empty.log").is_file())
        gate = ROOT / "scripts" / "ci" / "nightly_next_launch_smoke.py"
        spec = importlib.util.spec_from_file_location("nightly_next_launch_smoke", gate)
        verdicts = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(verdicts)
        self.assertEqual(verdicts.attempt_result(status, report), verdicts.CRASH)
        self.assert_cleaned_up(report)

    def test_an_app_that_never_reads_the_seeded_store_leaves_the_arm_not_run(self):
        status, output, report, _out = self.seeded("no-sync")
        self.assertEqual(status, smoke.PASS, output)
        self.assertEqual((report["verdict"], report["arm"]), ("pass", "empty"))
        arm = report["arms"]["seeded"]
        self.assertEqual(arm["verdict"], "not-run")
        self.assertIn("did not read the seeded store", arm["reason"])
        self.assertIn("seeded-home arm NOT RUN", output)
        self.assert_cleaned_up(report)

    def test_the_seeded_arm_is_not_run_after_a_first_arm_that_failed(self):
        status, output, report, _out = self.seeded("crash")
        self.assertEqual(status, smoke.FAIL, output)
        self.assertEqual((report["verdict"], report["arm"]), ("fail", "empty"))
        self.assertEqual(report["arms"]["seeded"], {"verdict": "not-run", "reason": "the first arm did not pass"})
        self.assertNotIn("seeded-home launch of", output)
        self.assert_cleaned_up(report)

    def test_the_arms_are_the_empty_home_alone_or_with_the_seeded_one(self):
        self.assertEqual(smoke.arms_asked("empty"), ("empty",))
        self.assertEqual(smoke.arms_asked("empty, seeded"), ("empty", "seeded"))
        for value in ("seeded", "seeded,empty", "empty,empty", "empty,real", ""):
            with self.assertRaises(Exception, msg=value):
                smoke.arms_asked(value)

    def test_a_stub_that_stays_up_without_home_fails(self):
        status, output, report = self.run_smoke("no-home", "--seconds", "2", "--startup-timeout", "3")
        self.assertEqual(status, smoke.FAIL, output)
        self.assertIn("Home did not render", report["failures"][0])
        self.assert_cleaned_up(report)

    def test_a_caller_ready_check_replaces_only_the_home_check(self):
        # scripts/cmux-next/idle_cpu.py: a fresh launch of feat opens a New Tab tab, not Home (cmux-ad m9, job
        # 857451d6: "Home did not render"). A caller's READY decides the window part; the nightly smoke keeps Home.
        status, output, report = self.run_smoke("new-tab", "--seconds", "2", "--startup-timeout", "3")
        self.assertEqual(status, smoke.FAIL, output)
        self.assertIn("Home did not render", report["failures"][0])
        visible = "lambda snap: smoke.visible_windows(snap) > 0"
        status, output, report = self.run_smoke("new-tab", "--seconds", "2", "--startup-timeout", "10", ready=visible)
        self.assertEqual(status, smoke.PASS, output)
        self.assert_cleaned_up(report)
        # The frame mark still counts: a visible window with no first frame is not ready.
        status, output, report = self.run_smoke("no-home", "--seconds", "2", "--startup-timeout", "3", ready=visible)
        self.assertEqual(status, smoke.FAIL, output)
        self.assert_cleaned_up(report)

    def test_a_fresh_launch_with_the_first_run_page_over_home_passes(self):
        # Every NEXT Nightly since #33215 failed here as "Home did not render ... Home tab not selected" (cannot-run in
        # nightly_next_launch_smoke.py, so the job stayed green): the page covers Home and Home's pane has no selection.
        status, output, report = self.run_smoke("first-run", "--seconds", "2", "--startup-timeout", "10")
        self.assertEqual(status, smoke.PASS, output)
        self.assertEqual(report["verdict"], "pass")
        self.assert_cleaned_up(report)
        # Without the app's mark the same parked pane is not a healthy launch.
        status, output, report = self.run_smoke("first-run-unmarked", "--seconds", "2", "--startup-timeout", "3")
        self.assertEqual(status, smoke.FAIL, output)
        self.assertIn("Home did not render", report["failures"][0])
        self.assertIn("first_run.history_import_shown missing", report["failures"][0])
        self.assert_cleaned_up(report)

    def test_the_detached_helper_is_stopped_by_the_runs_root(self):
        status, output, report = self.run_smoke("healthy", "--seconds", "2", "--startup-timeout", "10")
        self.assertEqual(status, smoke.PASS, output)
        time.sleep(0.2)
        self.assertEqual(smoke.pids_under(Path(report["root"])), [])

    def test_the_apps_terminal_host_is_stopped_by_its_record(self):
        # cmux#36625: a host's command line never names the run's root, so only its record ties it to the run
        self.host_pid_path = self.dir / "host.pid"
        status, output, report = self.run_smoke("healthy", "--seconds", "2", "--startup-timeout", "10")
        self.assertEqual(status, smoke.PASS, output)
        host = int(self.host_pid_path.read_text())
        time.sleep(0.2)
        self.assertFalse(smoke.alive(host), "the app's terminal host outlived the run")
        self.assert_cleaned_up(report)

    def test_a_recorded_pid_that_is_not_a_terminal_host_is_left_alone(self):
        with tempfile.TemporaryDirectory() as d:
            records = Path(d) / "h/Library/Application Support/cmux-next/tags/x/tui/terminal-hosts-0"
            records.mkdir(parents=True)
            other = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"])
            self.addCleanup(other.wait)
            self.addCleanup(other.kill)
            (records / "a.json").write_text(json.dumps({"host_pid": other.pid}))
            (records / "b.json").write_text("not json")
            self.assertEqual(smoke.terminal_host_pids(Path(d)), [])
            # A live host elsewhere doesn't make the recorded non-host pid count.
            host = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)", "__terminal-host"])
            self.addCleanup(host.wait)
            self.addCleanup(host.kill)
            (records / "c.json").write_text(json.dumps({"host_pid": host.pid}))
            self.assertEqual(smoke.terminal_host_pids(Path(d)), [host.pid])

    def test_a_build_from_before_the_next_folder_records_its_hosts_under_cmux_tags(self):
        with tempfile.TemporaryDirectory() as d:
            records = Path(d) / "h/Library/Application Support/cmux/tags/x/tui/terminal-hosts-0"
            records.mkdir(parents=True)
            host = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)", "__terminal-host"])
            self.addCleanup(host.wait)
            self.addCleanup(host.kill)
            (records / "a.json").write_text(json.dumps({"host_pid": host.pid}))
            self.assertEqual(smoke.terminal_host_pids(Path(d)), [host.pid])

    def test_a_signing_keychain_in_the_job_means_it_cannot_run(self):
        state = self.dir / "keychain-state"
        state.mkdir()
        (state / "cmux-signing.password").write_text("x")
        status, output, report = self.run_smoke("healthy", "--seconds", "1",
                                                env={**self.env, "CMUX_SIGNING_KEYCHAIN_STATE_DIR": str(state)})
        self.assertEqual(status, smoke.CANNOT_RUN, output)
        self.assertEqual(report["verdict"], "cannot-run")
        self.assertNotIn("pid", report)
        self.assert_cleaned_up(report)

    def test_a_crash_report_written_during_the_run_fails_it(self):
        diagnostics = self.dir / "diagnostics"
        diagnostics.mkdir()
        found = smoke.crash_reports(diagnostics, "stub", time.time() - 5)
        self.assertEqual(found, [])
        (diagnostics / "stub-2026-10-28-000000.ips").write_text("{}")
        (diagnostics / "stubborn-2026-10-28-000000.ips").write_text("{}")
        self.assertEqual([p.name for p in smoke.crash_reports(diagnostics, "stub", time.time() - 5)],
                         ["stub-2026-10-28-000000.ips"])

    def test_home_must_be_selected_in_a_visible_window(self):
        tab = {"id": "tab_1", "kind": "page", "page": "home-dock"}
        snap = {"topology": {"windows": [{"visible": False, "workspace": "ws_1"}],
                             "workspaces": [{"id": "ws_1", "screens": [{"panes": [{"selected_tab": "tab_1", "tabs": [tab]}]}]}]}}
        self.assertIsNone(smoke.home_tab(snap))
        snap["topology"]["windows"][0]["visible"] = True
        self.assertEqual(smoke.home_tab(snap), tab)
        snap["topology"]["workspaces"][0]["screens"][0]["panes"][0]["selected_tab"] = "tab_2"
        self.assertIsNone(smoke.home_tab(snap))

    def test_the_first_run_page_over_home_counts_only_with_the_apps_mark(self):
        tab = {"id": "tab_1", "kind": "page", "page": "home-dock"}
        snap = {"topology": {"windows": [{"visible": True, "workspace": "ws_1"}],
                             "workspaces": [{"id": "ws_1", "screens": [{"panes": [{"selected_tab": None, "tabs": [tab]}]}]}]}}
        frame = {smoke.RENDER_MARK: 1.0}
        shown = {**frame, smoke.FIRST_RUN_MARK: 2.0}
        self.assertFalse(smoke.home_rendered(snap, frame))
        self.assertFalse(smoke.home_rendered(snap, {smoke.FIRST_RUN_MARK: 2.0}))
        self.assertTrue(smoke.home_rendered(snap, shown))
        snap["topology"]["windows"][0]["visible"] = False
        self.assertFalse(smoke.home_rendered(snap, shown))
        snap["topology"]["windows"][0]["visible"] = True
        snap["topology"]["workspaces"][0]["screens"][0]["panes"][0]["tabs"] = [{"id": "tab_2", "page": "terminal"}]
        self.assertFalse(smoke.home_rendered(snap, shown))


if __name__ == "__main__":
    unittest.main()
