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
import signal
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

# The stub app: MODE (crash | healthy | no-home | new-tab | first-run | first-run-unmarked | sync-crash | no-sync |
# seeded-no-home | empty-sync | own-report | quit-report | helper-report) comes from the bundle's Resources/mode file. sync-crash,
# no-sync, empty-sync (the sync saves a baseline of no site) and seeded-no-home are healthy in an empty home. own-report: healthy, and in the seeded home a crash report that names
# this process appears while it is up. quit-report: healthy, and the empty home's process "crashes while it quits":
# a crash report that names it appears once the seeded home's launch is up, as ReportCrash writes one seconds later.
# helper-report: the same, but the report is of the empty home's HELPER, which died when its app went away: its
# parent is pid 1 by then and its path is in the app copy, so only the time it died says whose it is.
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
        saved = {"version": 1, "source": record["browser"] + "/" + record["profileDirectory"],
                 "hosts": {} if mode == "empty-sync" else hosts}
        open(os.path.join(state, "chrome_Default-0123456789abcdef.fingerprint"), "w").write(json.dumps(saved))
if mode in ("sync-crash", "no-sync", "empty-sync"):
    mode = "healthy"
if mode == "seeded-no-home":
    mode = "no-home" if seeded else "healthy"
if mode in ("own-report", "quit-report", "helper-report"):
    folder = open(os.path.join(here, "..", "Resources", "diagnostics_path")).read().strip()
    os.makedirs(folder, exist_ok=True)
    name = os.path.join(folder, "stub-2026-11-11-000000.ips")
    kind = mode
    def ips(pid, parent, died=None):
        # As an .ips: a header line, then the report's JSON with the crashed process's pid, parent and path, and
        # (DIED given) the time it died as macOS writes it.
        body = {"pid": pid, "parentPid": parent, "procPath": os.path.abspath(__file__), "procName": "stub"}
        if died is not None:
            body["captureTime"] = (time.strftime("%Y-%m-%d %H:%M:%S", time.gmtime(died))
                                   + ".%04d +0000" % int(died % 1 * 10000))
        return json.dumps({"app_name": "stub", "bug_type": "309"}) + "\n" + json.dumps(body, indent=2) + "\n"
    if mode == "own-report" and seeded:
        open(name, "w").write(ips(os.getpid(), os.getppid(), time.time()))
    if mode in ("quit-report", "helper-report") and not seeded:
        # Detached, its command line never names the root: it outlives this launch as ReportCrash does.
        writer = ("import os, time\n"
                  "deadline = time.time() + 20\n"
                  "while time.time() < deadline and not os.path.exists(os.environ['STUB_WAIT_FOR']):\n"
                  "    time.sleep(0.05)\n"
                  "time.sleep(0.3)\n"
                  "open(os.environ['STUB_REPORT'], 'w').write(os.environ['STUB_REPORT_TEXT'])\n")
        def quit_then_report(*_):
            # quit-report: this process, and the report says no time. helper-report: this launch's helper (an
            # orphan once this process is gone), with the time it died, which is now.
            text = ips(helper.pid, 1, time.time()) if kind == "helper-report" else ips(os.getpid(), os.getppid())
            subprocess.Popen([sys.executable, "-c", writer], cwd="/", start_new_session=True, env={
                "STUB_WAIT_FOR": os.path.join(os.path.dirname(home), "seeded", "h", "stub-report.json"),
                "STUB_REPORT": name, "STUB_REPORT_TEXT": text})
            os._exit(0)
        signal.signal(signal.SIGTERM, quit_then_report)
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
    # Where the stub puts a crash report of its own (the test's diagnostics folder), outside the run's root.
    (app / "Contents" / "Resources" / "diagnostics_path").write_text(str(parent.parent / "diagnostics"))
    write_executable(app / "Contents" / "MacOS" / "stub", STUB)
    return app


def gate_verdicts():
    """The publish gate's verdict helper (scripts/ci/nightly_next_launch_smoke.py)."""
    spec = importlib.util.spec_from_file_location("nightly_next_launch_smoke",
                                                  ROOT / "scripts" / "ci" / "nightly_next_launch_smoke.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


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

    def run_smoke(self, mode: str, *extra: str, env: dict | None = None, ready: str = "",
                  setup: str = "") -> tuple[int, str, dict]:
        """The smoke on a stub of MODE. `ready`: a caller's READY (a Python expression over `smoke`), set by a small
        caller script as scripts/cmux-next/idle_cpu.py sets it; `setup`: statements over `smoke` that such a caller
        runs first; both empty runs the smoke itself."""
        self.runs = getattr(self, "runs", 0) + 1
        app = make_app(self.dir / f"run-{self.runs}", mode)
        if getattr(self, "host_pid_path", None):
            (app / "Contents" / "Resources" / "host_pid_path").write_text(str(self.host_pid_path))
        out = self.dir / f"out-{mode}-{self.runs}"
        argv = [str(SCRIPT), "--app", str(app), "--out", str(out), *extra]
        if ready or setup:
            caller = ("import importlib.util, sys\n"
                      f"spec = importlib.util.spec_from_file_location('smoke', {str(SCRIPT)!r})\n"
                      "smoke = importlib.util.module_from_spec(spec); spec.loader.exec_module(smoke)\n"
                      + (f"smoke.READY = {ready}\n" if ready else "") + (f"{setup}\n" if setup else "")
                      + "sys.exit(smoke.main(sys.argv[1:]))\n")
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
        verdicts = gate_verdicts()
        self.assertEqual(verdicts.attempt_result(status, report), verdicts.CRASH)
        self.assert_cleaned_up(report)

    def test_a_crash_report_of_the_first_arms_app_never_fails_the_seeded_arm(self):
        # The first arm's app crashes while it quits: its report lands while the seeded launch is watched. The
        # seeded app is healthy, so the run passes; the report is said and kept, never counted for this launch.
        status, output, report, out = self.seeded("quit-report")
        self.assertEqual(status, smoke.PASS, output)
        arm = report["arms"]["seeded"]
        self.assertEqual((report["verdict"], report["arm"], arm["verdict"]), ("pass", "empty", "pass"), output)
        self.assertEqual(arm["crash_reports"], [])
        self.assertEqual([Path(found).name for found in arm["crash_reports_not_counted"]], ["stub-2026-11-11-000000.ips"])
        self.assertIn("stub-2026-11-11-000000.ips is not counted for the seeded launch: "
                      f"it is of pid {report['pid']}, this run's earlier launch", output)
        # Kept, but not beside the counted reports: the gate shows every report at the top of --out as a crash.
        self.assertTrue((out / "not-counted" / "stub-2026-11-11-000000.ips").is_file())
        self.assertFalse((out / "stub-2026-11-11-000000.ips").exists())
        verdicts = gate_verdicts()
        self.assertEqual(verdicts.attempt_result(status, report), verdicts.PASS)
        self.assert_cleaned_up(report)

    def test_a_crash_report_of_a_first_arm_helper_never_fails_the_seeded_arm(self):
        # The first arm's helper crashes when its app goes away. By then its parent is pid 1, and its path is in the
        # app copy that both arms launch, so neither says whose it is: the time it died does (before the seeded
        # launch started).
        status, output, report, out = self.seeded("helper-report")
        self.assertEqual(status, smoke.PASS, output)
        arm = report["arms"]["seeded"]
        self.assertEqual((report["verdict"], report["arm"], arm["verdict"]), ("pass", "empty", "pass"), output)
        self.assertEqual(arm["crash_reports"], [])
        self.assertEqual([Path(found).name for found in arm["crash_reports_not_counted"]], ["stub-2026-11-11-000000.ips"])
        self.assertRegex(output, r"stub-2026-11-11-000000\.ips is not counted for the seeded launch: "
                                 r"its process died at .* before this launch started")
        self.assertTrue((out / "not-counted" / "stub-2026-11-11-000000.ips").is_file())
        self.assertFalse((out / "stub-2026-11-11-000000.ips").exists())
        verdicts = gate_verdicts()
        self.assertEqual(verdicts.attempt_result(status, report), verdicts.PASS)
        self.assert_cleaned_up(report)

    def test_a_crash_report_of_the_seeded_launch_fails_it_while_the_app_is_up(self):
        status, output, report, out = self.seeded("own-report")
        self.assertEqual(status, smoke.FAIL, output)
        self.assertEqual((report["verdict"], report["arm"], report["exit"]), ("fail", "seeded", None))
        self.assertEqual([Path(found).name for found in report["crash_reports"]], ["stub-2026-11-11-000000.ips"])
        self.assertEqual(report["failures"], ["seeded home: crash report: stub-2026-11-11-000000.ips"])
        self.assertEqual(report["arms"]["seeded"]["crash_reports_not_counted"], [])
        self.assertTrue((out / "stub-2026-11-11-000000.ips").is_file())
        verdicts = gate_verdicts()
        self.assertEqual(verdicts.attempt_result(status, report), verdicts.CRASH)
        self.assert_cleaned_up(report)

    def test_which_crash_reports_are_of_a_launch(self):
        app = self.dir / "root" / "app" / "cmux NEXT.app"
        (app / "Contents" / "MacOS").mkdir(parents=True)
        binary = str(app / "Contents" / "MacOS" / "cmux NEXT")
        elsewhere = "/Applications/cmux NEXT.app/Contents/MacOS/cmux NEXT"

        def ips(name: str, **body) -> Path:
            found = self.dir / f"{name}.ips"
            found.write_text(json.dumps({"app_name": "cmux NEXT"}) + "\n" + json.dumps(body, indent=2) + "\n")
            return found

        def why(found: Path) -> str | None:
            return smoke.not_of_launch(found, 200, app, frozenset({100}))

        self.assertEqual(smoke.crash_report_process(ips("own", pid=200, parentPid=1, procPath=binary)),
                         {"pid": 200, "parent": 1, "path": binary})
        # Counted: the launch itself, a child of it, another process of this run's copy, a report with no pid.
        self.assertIsNone(why(ips("own", pid=200, parentPid=1, procPath=binary)))
        self.assertIsNone(why(ips("own-moved", pid=200, parentPid=1, procPath=elsewhere)))
        self.assertIsNone(why(ips("child", pid=300, parentPid=200, procPath=elsewhere)))
        self.assertIsNone(why(ips("copy", pid=300, parentPid=1, procPath=binary)))
        self.assertIsNone(why(ips("no-pid", exception={"type": "EXC_BAD_ACCESS"})))
        unreadable = self.dir / "unreadable.ips"
        unreadable.write_text("{}")
        self.assertIsNone(smoke.crash_report_process(unreadable))
        self.assertIsNone(why(unreadable))
        self.assertIsNone(why(self.dir / "gone.ips"))
        # Not counted: the earlier launch (also a child of it, also from this run's copy), another copy of the app,
        # another process that names no path.
        self.assertIn("this run's earlier launch", why(ips("earlier", pid=100, parentPid=1, procPath=binary)))
        self.assertIn("this run's earlier launch", why(ips("earlier-child", pid=300, parentPid=100, procPath=binary)))
        self.assertIn("not this run's copy of the app", why(ips("other", pid=300, parentPid=1, procPath=elsewhere)))
        self.assertIn("names no path", why(ips("pathless", pid=300, parentPid=1)))
        # The older text format says the same in its head.
        text = self.dir / "old.crash"
        text.write_text(f"Process:               cmux NEXT [200]\nPath:                  {binary}\n"
                        "Identifier:            com.cmuxterm.app\nParent Process:        launchd [1]\n\nThread 0 Crashed:\n")
        self.assertEqual(smoke.crash_report_process(text), {"pid": 200, "parent": 1, "path": binary})
        text.write_text(f"Process:               cmux NEXT [100]\nPath:                  {binary}\n"
                        "Parent Process:        launchd [1]\n")
        self.assertIn("this run's earlier launch", why(text))

    def test_a_report_of_a_process_that_died_before_the_launch_started_is_not_of_it(self):
        app = self.dir / "root" / "app" / "cmux NEXT.app"
        (app / "Contents" / "MacOS").mkdir(parents=True)
        helper = str(app / "Contents" / "Resources" / "bin" / "cmux-tui")
        started = 1794387600.0  # 2026-11-11 09:00:00 UTC: every earlier launch of the run was stopped by then

        def ips(name: str, header: dict, **body) -> Path:
            found = self.dir / f"{name}.ips"
            found.write_text(json.dumps({"app_name": "cmux", **header}) + "\n" + json.dumps(body, indent=2) + "\n")
            return found

        def why(found: Path, pid: int = 200) -> str | None:
            return smoke.not_of_launch(found, pid, app, frozenset({100}), started)

        orphan = {"pid": 300, "parentPid": 1, "procPath": helper}
        # The time the process died: the body's captureTime as written, else the header's timestamp, which macOS
        # writes to the whole second (the second value is how exact the time is).
        self.assertEqual(smoke.crash_report_time(ips("exact", {"timestamp": "2026-11-11 08:59:58.00 +0000"},
                                                     captureTime="2026-11-11 08:59:58.7500 +0000", **orphan)),
                         (started - 1.25, 0.0))
        self.assertEqual(smoke.crash_report_time(ips("zone", {}, captureTime="2026-11-11 00:59:58.7500 -0800", **orphan)),
                         (started - 1.25, 0.0))
        self.assertEqual(smoke.crash_report_time(ips("header", {"timestamp": "2026-11-11 08:59:58.00 +0000"}, **orphan)),
                         (started - 2, 1.0))
        self.assertIsNone(smoke.crash_report_time(ips("no-time", {}, **orphan)))
        self.assertIsNone(smoke.crash_report_time(ips("bad-time", {"timestamp": "yesterday"}, captureTime=7, **orphan)))
        self.assertIsNone(smoke.crash_report_time(self.dir / "gone.ips"))
        # Not counted: an orphan helper of this run's app copy that died before the launch started, and a report
        # that names this launch's pid but an earlier time (the pid of a process that is gone).
        self.assertIn("before this launch started", why(ips("early", {}, captureTime="2026-11-11 08:59:59.9990 +0000", **orphan)))
        self.assertIn("before this launch started",
                      why(ips("early-own", {}, captureTime="2026-11-11 08:59:50.0000 +0000", pid=200, parentPid=1, procPath=helper)))
        self.assertIn("before this launch started", why(ips("early-header", {"timestamp": "2026-11-11 08:59:58.00 +0000"}, **orphan)))
        half = self.dir / "half.ips"
        half.write_text(json.dumps({"app_name": "cmux", "timestamp": "2026-11-11 08:59:50.00 +0000"}) + '\n{\n  "pid" : 3')
        self.assertIn("before this launch started", why(half))
        # Counted, as before: the same orphan when it died after the launch started, when the report says no time,
        # and when a whole-second time can still be after the start.
        self.assertIsNone(why(ips("late", {}, captureTime="2026-11-11 09:00:00.0010 +0000", **orphan)))
        self.assertIsNone(why(ips("no-time", {}, **orphan)))
        self.assertIsNone(why(ips("same-second", {"timestamp": "2026-11-11 08:59:59.00 +0000"}, **orphan)))
        self.assertIsNone(smoke.not_of_launch(ips("no-start", {}, captureTime="2026-11-11 08:00:00.0000 +0000", **orphan),
                                              200, app, frozenset({100})))
        # The older text format.
        text = self.dir / "old.crash"
        text.write_text(f"Process:               cmux-tui [300]\nPath:                  {helper}\n"
                        "Date/Time:             2026-11-11 08:59:58.750 +0000\nParent Process:        launchd [1]\n")
        self.assertEqual(smoke.crash_report_time(text), (started - 1.25, 0.0))
        self.assertIn("before this launch started", why(text))

    def test_a_seed_that_cannot_be_made_leaves_the_arm_cannot_run(self):
        (self.defaults_dir / f"{BUNDLE}.plist").write_bytes(b"account defaults")
        refuse = "def refuse(*_a, **_k):\n    raise RuntimeError('no seed today')\nsmoke.seed_cookie_sync_home = refuse"
        status, output, report = self.run_smoke("healthy", "--seconds", "2", "--startup-timeout", "10",
                                                "--arms", "empty,seeded", "--seeded-seconds", "2", setup=refuse)
        self.assertEqual(status, smoke.PASS, output)
        self.assertEqual((report["verdict"], report["arm"]), ("pass", "empty"))
        arm = report["arms"]["seeded"]
        self.assertEqual((arm["verdict"], arm["reason"]), ("cannot-run", "RuntimeError: no seed today"))
        self.assertNotIn("pid", arm)
        self.assertIn("seeded-home arm CANNOT RUN: RuntimeError: no seed today; the first arm's verdict stands", output)
        self.assertEqual((self.defaults_dir / f"{BUNDLE}.plist").read_bytes(), b"account defaults")
        self.assert_cleaned_up(report)

    def test_a_seeded_crash_stays_a_crash_when_its_evidence_cannot_be_kept(self):
        refuse = "def refuse(*_a, **_k):\n    raise RuntimeError('no evidence today')\nsmoke.explain = refuse"
        status, output, report = self.run_smoke("sync-crash", "--seconds", "2", "--startup-timeout", "10",
                                                "--arms", "empty,seeded", "--seeded-seconds", "2", setup=refuse)
        self.assertEqual(status, smoke.FAIL, output)
        self.assertEqual((report["verdict"], report["arm"], report["exit"]), ("fail", "seeded", -6))
        self.assertIn("the seeded launch's evidence is not complete: RuntimeError: no evidence today", output)
        self.assertIn("FAIL: seeded home: the app exited", output)
        verdicts = gate_verdicts()
        self.assertEqual(verdicts.attempt_result(status, report), verdicts.CRASH)
        self.assert_cleaned_up(report)

    def test_a_seeded_app_that_stays_up_without_home_fails_the_run_but_is_no_crash(self):
        status, output, report, _out = self.seeded("seeded-no-home")
        self.assertEqual(status, smoke.FAIL, output)
        self.assertEqual((report["verdict"], report["arm"], report["exit"]), ("fail", "seeded", None))
        self.assertRegex(report["failures"][0], r"^seeded home: Home did not render within \d+s")
        self.assertEqual(report["arms"]["empty"]["verdict"], "pass")
        # A live app is not a launch crash: the publish gate calls this attempt cannot-run and holds nothing.
        verdicts = gate_verdicts()
        self.assertEqual(verdicts.attempt_result(status, report), verdicts.CANNOT_RUN)
        self.assert_cleaned_up(report)

    def test_a_run_stopped_in_the_seeded_arm_stops_that_app_and_puts_the_defaults_back(self):
        # What the gate's watchdog does to an attempt that takes too long: SIGTERM to the harness.
        (self.defaults_dir / f"{BUNDLE}.plist").write_bytes(b"account defaults")
        app, out = make_app(self.dir / "run-1", "healthy"), self.dir / "out-stopped"
        harness = subprocess.Popen([sys.executable, str(SCRIPT), "--app", str(app), "--out", str(out), "--seconds", "2",
                                    "--startup-timeout", "10", "--arms", "empty,seeded", "--seeded-seconds", "60"],
                                   env=self.env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        lines = []
        try:
            for line in harness.stdout:
                lines.append(line)
                if line.startswith("ok: the cookie sync read the seeded store"):
                    harness.terminate()
            status = harness.wait(timeout=60)
        finally:
            if harness.poll() is None:
                harness.kill()
            harness.stdout.close()
        output = "".join(lines)
        self.assertEqual(status, 128 + signal.SIGTERM, output)
        report = json.loads((out / "report.json").read_text())
        # The report on disk is the first arm's pass; the seeded arm reached no verdict.
        self.assertEqual((report["verdict"], report["arm"]), ("pass", "empty"))
        arm = report["arms"]["seeded"]
        self.assertEqual(arm["verdict"], "not-run")
        self.assertFalse(smoke.alive(arm["pid"]), "the seeded launch outlived the stopped run")
        self.assertEqual((self.defaults_dir / f"{BUNDLE}.plist").read_bytes(), b"account defaults")
        verdicts = gate_verdicts()
        self.assertEqual(verdicts.attempt_result(124, report), verdicts.CANNOT_RUN)
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

    def test_an_app_whose_sync_kept_none_of_the_seeded_rows_leaves_the_arm_not_run(self):
        status, output, report, _out = self.seeded("empty-sync")
        self.assertEqual(status, smoke.PASS, output)
        arm = report["arms"]["seeded"]
        self.assertEqual((report["verdict"], report["arm"], arm["verdict"]), ("pass", "empty", "not-run"))
        self.assertEqual(arm["cookie_sync"]["scanned_hosts"], 0)
        self.assertIn("did not read the seeded store's rows", arm["reason"])
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
