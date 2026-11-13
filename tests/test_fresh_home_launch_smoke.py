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

Time: a run here asks for no up-time (--seconds 0, --seeded-seconds 0), so its watch ends at Home; only a test that
reads the up-time, or that cuts a run that is up, asks for some. A stub that is up does all the work of a launch
(its helpers, its reports, the cookie sync, its marks) before it opens its socket, so Home is its last event; a
report that a stub writes while it quits, or after it, is part of the stop and not of the up-time. What a run needs
after Home is waited for as an event (a file that is there), not as seconds of up-time. The waits that stay: of the
tool itself (a launch with no Home ends only at --startup-timeout, a seeded launch with no cookie sync at the scan
wait, a report that names no process at NO_PROCESS_REREAD_SECONDS, a daemon that is not connected is read again);
the stub's stand-ins for what macOS does late (a report's body after its head, a process that dies a moment after
its start); and a few fixed sleeps of single tests that give another process its start, as they were.
"""
from __future__ import annotations

import contextlib
from datetime import datetime, timezone
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import queue
import signal
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock
import urllib.parse

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "ci" / "fresh_home_launch_smoke.py"
# The crash report that macOS 27 wrote for the seeded launch of commit 2616865988e1 on a fleet host (controller step
# 5490aa2042ea, 2026-11-11): the crash of nightly 4294166855401. Only the fields a reader needs; the host's and the
# account's identifiers are left out. Its process is pid 79502, a child of the validator (pid 78738).
REAL_REPORT = ROOT / "tests" / "fixtures" / "launch-smoke" / "cmux-dev-cookie-sync-crash.ips"
spec = importlib.util.spec_from_file_location("fresh_home_launch_smoke", SCRIPT)
smoke = importlib.util.module_from_spec(spec)
spec.loader.exec_module(smoke)

BUNDLE = "com.example.fresh-smoke-stub"

# The stub app: MODE (crash | healthy | no-home | new-tab | first-run | first-run-unmarked | sync-crash | no-sync |
# seeded-no-home | empty-sync | own-report | quit-report | helper-report | first-report | other-report |
# home-report | blank-report | blank-crash | torn-report | late-quit-report) comes from the bundle's Resources/mode
# file. late-quit-report: healthy, and it "crashes while it quits": a report of this process lands 4 s after it
# was stopped. sync-crash,
# no-sync, empty-sync (the sync saves a baseline of no site) and seeded-no-home are healthy in an empty home. own-report: healthy, and in the seeded home a crash report that names
# this process appears while it is up. quit-report: healthy, and the empty home's process "crashes while it quits":
# a crash report that names it appears once the seeded home's launch is up, as ReportCrash writes one seconds later.
# helper-report: the same, but the report is of the empty home's HELPER, which died when its app went away: its
# parent is pid 1 by then and its path is in the app copy, so only the time it died says whose it is.
# first-report, other-report, home-report, blank-report: healthy, and while the EMPTY home's launch is up a crash
# report appears that names this process, a process of another build's app copy (as another tagged build that
# crashes on the same host does), a detached process whose program is in this run's HOME (a daemon that the app
# put there), or no process at all (blank-report: in each home's launch). blank-crash: a report of no process, then
# the app aborts. torn-report: healthy, and when it is stopped a report of this process is there with its head
# only, as one that is read while macOS writes it; its body comes a second later.
# MODE@DAEMON: what the app's snapshot says of its daemon (topology.daemon_state, daemon_failure). The smoke's
# reads while it waits for Home have the request id 1, its read when the watch ends 2, its read again 3. No
# DAEMON: connected in each read. none: the snapshot has no such field (a build from before it). down: not
# connected from the read 2 on. seeded-down: the same, in the seeded home only. reconnects: "disconnected" in
# the read 2 alone. failed: the state "failed" with a failure text from the read 2 on. The stub starts a daemon
# of its own as the real app does (its program in the bundle, cmux-tui's arguments, the session of
# Resources/session); a DAEMON that ends in "other" (other, down-other) starts none, as an app that got the daemon
# of another launch of its session.
STUB = r'''#!PYTHON
import json, os, signal, socket, subprocess, sys, time
here = os.path.dirname(os.path.abspath(__file__))
mode, _, daemon = open(os.path.join(here, "..", "Resources", "mode")).read().strip().partition("@")
home = os.environ["HOME"]
report = {"home_entries": sorted(os.listdir(home)), "cffixed": os.environ.get("CFFIXED_USER_HOME"),
          "leaked": sorted(k for k in os.environ if k in ("GH_TOKEN", "FRESH_SMOKE_SECRET", "RUNNER_TEMP"))}
open(os.path.join(home, "stub-report.json"), "w").write(json.dumps(report))
# A detached helper, as the real app's daemons are: cleanup must stop it by the run's root.
helper = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(600)", os.path.abspath(__file__)],
                          start_new_session=True)
open(os.path.join(home, "helper.pid"), "w").write(str(helper.pid))
resources = os.path.join(os.path.dirname(here), "Resources")
if daemon.endswith("other"):
    daemon = daemon[:-len("other")].rstrip("-")
else:
    subprocess.Popen([os.path.join(resources, "bin", "cmux-tui"), "-c", "import time; time.sleep(600)", "--headless",
                      "--session", open(os.path.join(resources, "session")).read(), "--socket", "s"],
                     start_new_session=True)
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
# Chromium's code-sign clone, when the test asks for one (Resources/clone: the account's clone folder, the bundle
# id, and what the cleanup helper does). As CEF: at each launch a clone folder of this launch alone, outside the
# run's root; and when the app is stopped (SIGTERM), a helper of the app that removes that folder after the app's
# end. So the helper is no process while the app is up, and an app that dies by itself starts none. HELPER ends:
# it removes the clone about 1 s after the app's end and says so (done-<suffix>); leaves: it ends 2 s after the
# app's end and removes nothing; stays: it never ends; no-suffix: it never ends and its command line does not
# name the clone; seeded-stays: ends in the empty home's launch, stays in the seeded home's.
start_clone_helper = None
clone_path = os.path.join(resources, "clone")
if os.path.exists(clone_path):
    asked = json.load(open(clone_path))
    suffix = "S%d" % os.getpid()
    clone = os.path.join(asked["dir"], asked["bundle"] + ".code_sign_clone", "code_sign_clone." + suffix)
    os.makedirs(os.path.join(clone, "Stub.app"))
    open(os.path.join(clone, "Stub.app", "binary"), "w").write("a copy of the app")
    cleanup = ("import os, shutil, sys, time\n"
               "app, clone, done, kind = int(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[5]\n"
               "while os.getppid() == app:\n"
               "    time.sleep(0.05)\n"
               "if kind == 'leaves':\n"
               "    time.sleep(2.0)\n"
               "    sys.exit(0)\n"
               "if kind != 'ends':\n"
               "    time.sleep(600)\n"
               "time.sleep(1.0)\n"
               "shutil.rmtree(clone)\n"
               "open(done, 'w').write('removed')\n")
    named = [] if asked["helper"] == "no-suffix" else ["--unique-temp-dir-suffix=" + suffix]
    def start_clone_helper():
        kind = asked["helper"]
        if kind == "seeded-stays":
            kind = "stays" if globals().get("seeded") else "ends"
        subprocess.Popen([sys.executable, "-c", cleanup, os.path.abspath(__file__), str(os.getpid()), clone,
                          os.path.join(asked["dir"], "done-" + suffix), kind,
                          "--type=code-sign-clone-cleanup", *named, "--wait-for-parent-exit"],
                         start_new_session=True)
    def stopped_then_cleanup(*_):
        start_clone_helper()
        os._exit(0)
    signal.signal(signal.SIGTERM, stopped_then_cleanup)
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
        open(os.path.join(state, "seed-0123456789abcdef.fingerprint"), "w").write(json.dumps(saved))
if mode in ("sync-crash", "no-sync", "empty-sync"):
    mode = "healthy"
if mode == "seeded-no-home":
    mode = "no-home" if seeded else "healthy"
if mode in ("own-report", "quit-report", "helper-report", "first-report", "other-report", "home-report",
            "blank-report", "blank-crash", "torn-report", "again-report", "other-hidden-report", "late-report",
            "late-seeded-report", "late-quit-report"):
    folder = open(os.path.join(here, "..", "Resources", "diagnostics_path")).read().strip()
    os.makedirs(folder, exist_ok=True)
    name = os.path.join(folder, "stub-2026-11-11-000000.ips")
    kind = mode
    def stamp(when):
        return time.strftime("%Y-%m-%d %H:%M:%S", time.gmtime(when)) + ".%04d +0000" % int(when % 1 * 10000)
    def ips(pid, parent, died=None, path=os.path.abspath(__file__), born=None):
        # As an .ips: a header line, then the report's JSON with the crashed process's pid, parent and path, and
        # (DIED given) the time it died and (BORN given) the time it was started, as macOS writes them.
        body = {"pid": pid, "parentPid": parent, "procPath": path, "procName": "stub"}
        if born is not None:
            body["procLaunch"] = stamp(born)
        if died is not None:
            body["captureTime"] = stamp(died)
        return json.dumps({"app_name": "stub", "bug_type": "309"}) + "\n" + json.dumps(body, indent=2) + "\n"
    if mode == "own-report" and seeded:
        open(name, "w").write(ips(os.getpid(), os.getppid(), time.time()))
    if mode == "first-report" and not seeded:
        open(name, "w").write(ips(os.getpid(), os.getppid(), time.time()))
    if mode == "other-report" and not seeded:
        # Another tagged build's launch on this host: its own pid, its own copy of the app.
        open(name, "w").write(ips(4190001, 1, time.time(),
                                  "/private/tmp/cmux-fresh-other00/app/Stub capfeedface00.app/Contents/MacOS/stub"))
    if mode == "home-report" and not seeded:
        # Not this process and not a child of it by the time it died, and not in the app copy: in the run's HOME.
        open(name, "w").write(ips(4190002, 1, time.time(), os.path.join(home, ".cmux", "bin", "stub-daemon")))
    # As macOS writes the path of a program under /tmp: the folders above the app copy are one `*`.
    hidden = "/tmp/*/%s/Contents/MacOS/stub"
    if mode == "again-report" and not seeded:
        # The app started itself again, not as its child (its parent is launchd), and that process crashed.
        open(name, "w").write(ips(4190003, 1, time.time(), hidden % os.path.basename(os.path.dirname(os.path.dirname(here))),
                                  born=time.time()))
    if mode == "other-hidden-report" and not seeded:
        # Another tagged build's launch from /tmp on this host, in these seconds: another name of the app copy.
        open(name, "w").write(ips(4190004, 1, time.time(), hidden % "Stub capfeedface00.app", born=time.time()))
    if mode == "late-report" or (mode == "late-seeded-report" and seeded):
        # The app crashes; macOS writes its report only after the verdict looked for it (the test's caller makes
        # a file then, named by this launch's pid), and its header line some seconds before the rest.
        writer = ("import os, time\n"
                  "deadline = time.time() + 60\n"
                  "while time.time() < deadline and not os.path.exists(os.environ['STUB_WAIT_FOR']):\n"
                  "    time.sleep(0.05)\n"
                  "whole = os.environ['STUB_REPORT_TEXT']\n"
                  "open(os.environ['STUB_REPORT'], 'w').write(whole.partition('\\n')[0] + '\\n')\n"
                  "time.sleep(2.5)\n"
                  "open(os.environ['STUB_REPORT'], 'w').write(whole)\n")
        subprocess.Popen([sys.executable, "-c", writer], cwd="/", start_new_session=True, env={
            "STUB_WAIT_FOR": os.path.join(os.path.dirname(folder), "verdict-looked-%d" % os.getpid()),
            "STUB_REPORT": name, "STUB_REPORT_TEXT": ips(os.getpid(), os.getppid(), time.time())})
        time.sleep(0.5)
        os.abort()
    if mode in ("blank-report", "blank-crash"):
        open(name, "w").write(json.dumps({"app_name": "stub", "bug_type": "309"}) + "\n")
    if mode == "blank-crash":
        time.sleep(0.5)
        os.abort()
    if mode == "torn-report":
        def torn_then_whole(*_):
            whole = ips(os.getpid(), os.getppid(), time.time())
            open(name, "w").write(whole.partition("\n")[0] + "\n")
            subprocess.Popen([sys.executable, "-c", "import os, time\ntime.sleep(1)\n"
                              "open(os.environ['STUB_REPORT'], 'w').write(os.environ['STUB_REPORT_TEXT'])\n"],
                             cwd="/", start_new_session=True, env={"STUB_REPORT": name, "STUB_REPORT_TEXT": whole})
            os._exit(0)
        signal.signal(signal.SIGTERM, torn_then_whole)
    if mode == "late-quit-report":
        def quit_then_late_report(*_):
            if start_clone_helper:
                start_clone_helper()
            # Detached, its command line never names the root: it outlives this launch as ReportCrash does.
            subprocess.Popen([sys.executable, "-c", "import os, time\ntime.sleep(4)\n"
                              "open(os.environ['STUB_REPORT'] + '.part', 'w').write(os.environ['STUB_REPORT_TEXT'])\n"
                              "os.replace(os.environ['STUB_REPORT'] + '.part', os.environ['STUB_REPORT'])\n"],
                             cwd="/", start_new_session=True,
                             env={"STUB_REPORT": name, "STUB_REPORT_TEXT": ips(os.getpid(), os.getppid())})
            os._exit(0)
        signal.signal(signal.SIGTERM, quit_then_late_report)
    if mode in ("quit-report", "helper-report") and not seeded:
        # Detached, its command line never names the root: it outlives this launch as ReportCrash does.
        writer = ("import os, time\n"
                  "deadline = time.time() + 20\n"
                  "while time.time() < deadline and not os.path.exists(os.environ['STUB_WAIT_FOR']):\n"
                  "    time.sleep(0.05)\n"
                  "open(os.environ['STUB_REPORT'] + '.part', 'w').write(os.environ['STUB_REPORT_TEXT'])\n"
                  "os.replace(os.environ['STUB_REPORT'] + '.part', os.environ['STUB_REPORT'])\n")
        def quit_then_report(*_):
            # quit-report: this process, and the report says no time. helper-report: this launch's helper (an
            # orphan once this process is gone), with the time it died, which is now.
            text = ips(helper.pid, 1, time.time()) if kind == "helper-report" else ips(os.getpid(), os.getppid())
            subprocess.Popen([sys.executable, "-c", writer], cwd="/", start_new_session=True, env={
                "STUB_WAIT_FOR": os.path.join(os.path.dirname(home), "seeded", "h", "stub-report.json"),
                "STUB_REPORT": name, "STUB_REPORT_TEXT": text})
            os._exit(0)
        signal.signal(signal.SIGTERM, quit_then_report)
    if mode in ("quit-report", "helper-report") and seeded:
        # The first launch's report lands while this launch is up: Home (below) comes only after the report. The wait
        # is shorter than the tool's wait for Home, so a report that never comes shows in the test as that report.
        deadline = time.time() + 8
        while time.time() < deadline and not os.path.exists(name):
            time.sleep(0.05)
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
def daemon_facts(read):
    kind = ("down" if seeded else "") if daemon == "seeded-down" else daemon
    if kind == "none":
        return {}
    if read >= 2 and kind == "failed":
        return {"daemon_state": "failed", "daemon_failure": "cmux-tui did not start"}
    if (read >= 2 and kind == "down") or (read == 2 and kind == "reconnects"):
        return {"daemon_state": "disconnected", "daemon_failure": None}
    return {"daemon_state": "connected", "daemon_failure": None}
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
        said = {**topology, **daemon_facts(request["id"])}
        conn.sendall((json.dumps({"id": request["id"], "ok": True, "result": {"topology": said}}) + "\n").encode())
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
    # The stub's daemon: a program file in the bundle (Python by another name) and a session of this test alone.
    (app / "Contents" / "Resources" / "bin").mkdir()
    os.symlink(sys.executable, app / "Contents" / "Resources" / "bin" / "cmux-tui")
    (app / "Contents" / "Resources" / "session").write_text(f"cmux-app-stub-{parent.parent.name}")
    # Where the stub puts a crash report of its own (the test's diagnostics folder), outside the run's root.
    (app / "Contents" / "Resources" / "diagnostics_path").write_text(str(parent.parent / "diagnostics"))
    write_executable(app / "Contents" / "MacOS" / "stub", STUB)
    return app


def gate_verdicts():
    """The publish gate's verdict helper (scripts/ci/nightly_next_launch_smoke.py)."""
    # Imported by name, never loaded by path: one module object per file (tests/test_script_module_loads.py).
    if str(ROOT / "scripts" / "ci") not in sys.path:
        sys.path.insert(0, str(ROOT / "scripts" / "ci"))
    return importlib.import_module("nightly_next_launch_smoke")


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
            "CMUX_FRESH_SMOKE_CRASH_EVIDENCE_WAIT_SECONDS": "0",
            "CMUX_FRESH_SMOKE_SEEDED_SCAN_WAIT_SECONDS": "4",
            "CMUX_FRESH_SMOKE_DAEMON_REREAD_SECONDS": "0.2",
            "FAKE_DEFAULTS_DIR": str(self.defaults_dir),
            "FRESH_SMOKE_SECRET": "must-not-reach-the-app",
            "GH_TOKEN": "must-not-reach-the-app",
        }
        # The account's code-sign clone folder (X) of this test alone, outside the run's root.
        self.clones = self.dir / "X"
        self.clones.mkdir()
        self.env["CMUX_FRESH_SMOKE_CLONE_DIR"] = str(self.clones)
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
        if getattr(self, "clone_helper", None):
            (app / "Contents" / "Resources" / "clone").write_text(json.dumps(
                {"dir": str(self.clones), "bundle": BUNDLE, "helper": self.clone_helper}))
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
        status, output, report = self.run_smoke("healthy", "--seconds", "0", "--startup-timeout", "10")
        self.assertEqual(status, smoke.PASS, output)
        self.assertEqual(domain.read_bytes(), b"account defaults")
        self.assertFalse(aside.exists())

    def test_a_domain_that_did_not_exist_is_removed_again(self):
        domain = self.defaults_dir / f"{BUNDLE}.plist"
        status, output, report = self.run_smoke("healthy", "--seconds", "0", "--startup-timeout", "10")
        self.assertEqual(status, smoke.PASS, output)
        self.assertFalse(domain.exists())
        self.assertFalse((self.dir / f"cmux-fresh-smoke-{BUNDLE}.aside.plist").exists())

    def test_an_export_that_fails_is_cannot_run_and_touches_nothing(self):
        domain = self.defaults_dir / f"{BUNDLE}.plist"
        domain.write_bytes(b"account defaults")
        status, output, report = self.run_smoke("healthy", "--seconds", "0",
                                                env={**self.env, "FAKE_DEFAULTS_FAIL": "export"})
        self.assertEqual(status, smoke.CANNOT_RUN, output)
        self.assertNotIn("pid", report)
        self.assertEqual(domain.read_bytes(), b"account defaults")

    def test_a_delete_that_fails_keeps_the_copy_and_does_not_launch(self):
        domain = self.defaults_dir / f"{BUNDLE}.plist"
        domain.write_bytes(b"account defaults")
        status, output, report = self.run_smoke("healthy", "--seconds", "0",
                                                env={**self.env, "FAKE_DEFAULTS_FAIL": "delete"})
        self.assertEqual(status, smoke.CANNOT_RUN, output)
        self.assertNotIn("pid", report)
        aside = self.dir / f"cmux-fresh-smoke-{BUNDLE}.aside.plist"
        self.assertEqual(plistlib.loads(aside.read_bytes()), {"stored": b"account defaults"})

    def test_defaults_that_cannot_be_put_back_fail_closed_and_stay_aside(self):
        domain = self.defaults_dir / f"{BUNDLE}.plist"
        domain.write_bytes(b"account defaults")
        status, output, report = self.run_smoke("healthy", "--seconds", "0", "--startup-timeout", "10",
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
        status, output, report = self.run_smoke(mode, "--seconds", "0", "--startup-timeout", "10",
                                                "--arms", "empty,seeded", "--seeded-seconds", "0", *extra)
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
        self.assertEqual(seed["source"], f"{smoke.SEED_BROWSER}/Default")
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
        (state / "x.fingerprint").write_text(json.dumps({"version": 1, "source": seed["source"], "hosts": {"a": "1"}}))
        self.assertEqual(smoke.cookie_sync_scanned(seed), {"hosts": 1})

    def test_the_seeds_browser_has_no_keychain_item_name_in_the_app(self):
        # The app asks the Keychain for a browser's cookie key by the item name that its table gives that browser
        # (browser-sources.json `safeStorage`, ImportBrowser.safeStorageService). The seed's browser is in no row of
        # it, so the app has no name to ask for, also if a later build imports the seeded cookies at launch.
        table = json.loads((ROOT / "Packages" / "macOS" / "CmuxNext" / "Sources" / "CmuxNextBrowserImport" / "Resources"
                            / "browser-sources.json").read_text())
        rows = table["browsers"] if isinstance(table, dict) else table
        self.assertGreater(len(rows), 50)
        self.assertIn("Chrome Safe Storage", [(row.get("safeStorage") or {}).get("service") for row in rows])
        self.assertNotIn(smoke.SEED_BROWSER, [row["id"] for row in rows])
        self.assertFalse(smoke.SEED_BROWSER.startswith("found."))  # the app's own prefix for a browser it found on disk
        home = self.dir / "named-home"
        smoke.seed_cookie_sync_home(home, BUNDLE)
        (record,) = json.loads((home / "Library" / "Application Support" / BUNDLE / "BrowserImport" / "sources.json").read_text())
        self.assertEqual(record["browser"], smoke.SEED_BROWSER)

    def test_a_caller_can_read_that_crash_reports_are_matched_by_process(self):
        # cmux-ci fresh-home gives a validator the account's real crash folder only when it has this.
        self.assertEqual(smoke.CRASH_FILTER, "pid")

    def test_the_seeded_arm_passes_when_the_app_reads_the_seeded_store(self):
        (self.defaults_dir / f"{BUNDLE}.plist").write_bytes(b"account defaults")
        self.host_pid_path = self.dir / "host.pid"
        status, output, report, out = self.seeded("healthy", "--seeded-seconds", "2")
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
        # Counted: the launch itself, a child of it, another process of this run's copy.
        self.assertIsNone(why(ips("own", pid=200, parentPid=1, procPath=binary)))
        self.assertIsNone(why(ips("own-moved", pid=200, parentPid=1, procPath=elsewhere)))
        self.assertIsNone(why(ips("child", pid=300, parentPid=200, procPath=elsewhere)))
        self.assertIsNone(why(ips("copy", pid=300, parentPid=1, procPath=binary)))
        # A report that names no process is no crash alone: it counts only for a launch whose app ended.
        unreadable = self.dir / "unreadable.ips"
        unreadable.write_text("{}")
        self.assertIsNone(smoke.crash_report_process(unreadable))
        for found in (ips("no-pid", exception={"type": "EXC_BAD_ACCESS"}), unreadable, self.dir / "gone.ips"):
            self.assertIn("names no process", why(found))
            self.assertIsNone(smoke.not_of_launch(found, 200, app, frozenset({100}), ended=True))
        # Not counted: the earlier launch (also a child of it, also from this run's copy), another copy of the app,
        # another process that names no path.
        self.assertIn("this run's earlier launch", why(ips("earlier", pid=100, parentPid=1, procPath=binary)))
        self.assertIn("this run's earlier launch", why(ips("earlier-child", pid=300, parentPid=100, procPath=binary)))
        self.assertIn("not this run's copy of the app", why(ips("other", pid=300, parentPid=1, procPath=elsewhere)))
        self.assertIn("names no path", why(ips("pathless", pid=300, parentPid=1)))
        # A launch's own folder (its HOME is there): a detached process whose program is in it is of that launch.
        home = self.dir / "root" / "seeded"
        daemon = str(home / "h" / ".cmux" / "bin" / "cmux-tui")
        first_home = str(self.dir / "root" / "h" / ".cmux" / "bin" / "cmux-tui")
        self.assertIsNone(smoke.not_of_launch(ips("daemon", pid=300, parentPid=1, procPath=daemon), 200, app,
                                              frozenset({100}), None, home))
        self.assertIn("not this run's copy of the app and not this launch's files",
                      smoke.not_of_launch(ips("first-daemon", pid=300, parentPid=1, procPath=first_home), 200, app,
                                          frozenset({100}), None, home))
        self.assertIn("not this run's copy of the app", why(ips("daemon", pid=300, parentPid=1, procPath=daemon)))
        # The older text format says the same in its head.
        text = self.dir / "old.crash"
        text.write_text(f"Process:               cmux NEXT [200]\nPath:                  {binary}\n"
                        "Identifier:            com.cmuxterm.app\nParent Process:        launchd [1]\n\nThread 0 Crashed:\n")
        self.assertEqual(smoke.crash_report_process(text), {"pid": 200, "parent": 1, "path": binary})
        text.write_text(f"Process:               cmux NEXT [100]\nPath:                  {binary}\n"
                        "Parent Process:        launchd [1]\n")
        self.assertIn("this run's earlier launch", why(text))

    def test_a_daemons_report_is_found_by_a_release_apps_name_and_counts_only_from_this_run(self):
        # A Release or NIGHTLY app's executable is `cmux`, so the name match (`cmux-*.ips`) also finds a report of
        # its daemon, `cmux-tui`. The daemon is detached (its parent is pid 1): only its path and its start time
        # say whose it is. The same daemon of another copy (the installed app, another build's copy under /tmp,
        # another run's home) crashes on the same host: that report must never fail this launch.
        root = self.dir / "root"
        app = root / "app" / "cmux NIGHTLY.app"
        bundled = app / "Contents" / "Resources" / "bin" / "cmux-tui"
        bundled.parent.mkdir(parents=True)
        bundled.write_text("")
        reports = self.dir / "reports"
        reports.mkdir()
        found = reports / "cmux-tui-2026-11-11-090004.ips"
        started = datetime(2026, 11, 11, 9, 0, 0, tzinfo=timezone.utc).timestamp()
        after, before = "2026-11-11 09:00:01.0000 +0000", "2026-11-11 08:59:20.5000 +0000"

        def look(where: str, born: str = after) -> tuple[list[str], str]:
            body = {"pid": 300, "parentPid": 1, "procPath": where, "procName": "cmux-tui", "procLaunch": born,
                    "captureTime": "2026-11-11 09:00:04.0000 +0000"}
            found.write_text(json.dumps({"app_name": "cmux-tui", "bug_type": "309"}) + "\n" + json.dumps(body) + "\n")
            crashes, others = smoke.launch_crash_reports(reports, "cmux", 0, False, 200, app, frozenset({100}),
                                                         started, root)
            return [path.name for path in crashes], " ".join(others.values())

        # The name: `cmux-` takes the daemon's report; a Debug executable's name (`cmux DEV`) does not.
        look(str(bundled))
        self.assertEqual([path.name for path in smoke.crash_reports(reports, "cmux", 0)], [found.name])
        self.assertEqual(smoke.crash_reports(reports, "cmux DEV", 0), [])
        # Counted: the daemon of this run's copy (the full path, and the path as macOS writes it under /tmp), and
        # one that the app put in this launch's home.
        for where in (str(bundled), "/tmp/*/cmux NIGHTLY.app/Contents/Resources/bin/cmux-tui",
                      str(root / "h" / ".cmux" / "bin" / "cmux-tui")):
            self.assertEqual(look(where), ([found.name], ""), where)
        # Not counted: the daemon of each other copy.
        for where in ("/Applications/cmux NIGHTLY.app/Contents/Resources/bin/cmux-tui",
                      "/Applications/cmux.app/Contents/Resources/bin/cmux-tui",
                      "/tmp/*/cmux DEV capfeedface00.app/Contents/Resources/bin/cmux-tui",
                      "/private/tmp/cmux-fresh-other00/h/.cmux/bin/cmux-tui",
                      str(self.dir / "other-root" / "h" / ".cmux" / "bin" / "cmux-tui")):
            crashes, why = look(where)
            self.assertEqual(crashes, [], where)
            self.assertIn("not this run's copy of the app and not this launch's files", why, where)
        # Nor one of a copy with this copy's NAME that was started before this launch (another run's, or an
        # earlier launch's). Started after it, the path cannot tell such a copy from this run's: the limit of the rule.
        crashes, why = look("/tmp/*/cmux NIGHTLY.app/Contents/Resources/bin/cmux-tui", before)
        self.assertEqual(crashes, [])
        self.assertRegex(why, r"its process was started at 08:59:20Z, 39\.5s before this launch started")

    def real_app_copy(self, name: str = "cmux DEV cap2616865988.app", whole: bool = True) -> Path:
        app = self.dir / name.replace(" ", "-") / "app" / name
        (app / "Contents" / "MacOS").mkdir(parents=True)
        if whole:
            (app / "Contents" / "MacOS" / "cmux DEV").write_text("")
        return app

    def test_a_real_crash_report_is_read_and_is_of_its_launch(self):
        self.assertEqual(smoke.crash_report_process(REAL_REPORT),
                         {"pid": 79502, "parent": 78738, "path": "/tmp/*/cmux DEV cap2616865988.app/Contents/MacOS/cmux DEV"})
        died, born = smoke.crash_report_time(REAL_REPORT), smoke.crash_report_launch_time(REAL_REPORT)
        self.assertEqual((round(died[0] - born, 4), died[1]), (3.1366, 0.0))
        app = self.real_app_copy()
        for pid in (79502, 78738):  # the launch itself, and a child of the launch
            self.assertIsNone(smoke.not_of_launch(REAL_REPORT, pid, app, frozenset(), born - 1, app.parent.parent))

    def test_a_real_report_of_this_runs_app_copy_counts_by_the_path_that_macos_wrote(self):
        # macOS writes the path of a program under /tmp with the folders above the app copy hidden
        # (`/tmp/*/NAME.app/...`), so the full path of this run's copy never matches a real report. A process that is
        # not the launch and not its child (the app started again through launchd) is still this launch's when the
        # rest of the path is a file of this run's copy and the process was started after this launch.
        app = self.real_app_copy()
        born = smoke.crash_report_launch_time(REAL_REPORT)

        def why(copy: Path, started: float | None, earlier: frozenset = frozenset(), found: Path = REAL_REPORT):
            return smoke.not_of_launch(found, 4242, copy, earlier, started, copy.parent.parent)

        self.assertIsNone(why(app, born - 1))
        # Started before this launch: of an earlier launch of the same copy (the first arm's, for the seeded arm).
        self.assertIn("before this launch started", why(app, born + 1))
        self.assertIn("this run's earlier launch", why(app, born - 1, frozenset({79502})))
        # Another tag's copy, and a copy that has no such file: a crash of another launch on this host.
        for other in (self.real_app_copy("cmux DEV capfeedface00.app"), self.real_app_copy("other/cmux DEV.app"),
                      self.real_app_copy("hollow/cmux DEV cap2616865988.app", whole=False)):
            self.assertIn("not this run's copy of the app", why(other, born - 1), other)
        # macOS hides the folders of a program under /tmp, where each run's root is. A `*` in another place, two of
        # them, or a `..` after it is not the path of this run's copy.
        head, _, body = REAL_REPORT.read_text().partition("\n")
        inner = "cmux DEV cap2616865988.app/Contents/MacOS/cmux DEV"
        moved = self.dir / "moved.ips"
        for where, counts in ((f"/private/tmp/*/{inner}", True), (f"/Users/cmux/*/{inner}", False),
                              (f"*/{inner}", False), (f"/tmp/*/*/{inner}", False), (f"/var/tmp/*/{inner}", False),
                              ("/tmp/*/cmux DEV cap2616865988.app/Contents/../Contents/MacOS/cmux DEV", False),
                              (f"/tmp/*/{inner[:-8]}{'x' * 300}/../cmux DEV", False),
                              (f"/tmp/*/{inner[:-8]}{'x' * 300}", False), (f"/tmp/*/{inner}\0", False)):
            moved.write_text(head + "\n" + json.dumps({**json.loads(body), "procPath": where}))
            said = why(app, born - 1, found=moved)
            self.assertEqual(said is None, counts, (where, said))
            if not counts:
                self.assertRegex(said, "not this run's copy of the app|its path cannot be read", where)
        # The hidden path says less than a full one: without the time of the process's start it is not enough.
        self.assertIn("no start time of this launch was given", why(app, None))
        timeless = self.dir / "timeless.ips"
        timeless.write_text("".join(line for line in REAL_REPORT.read_text().splitlines(keepends=True)
                                    if '"procLaunch"' not in line))
        self.assertEqual(smoke.crash_report_process(timeless)["pid"], 79502)
        self.assertIn("does not say when its process was started", why(app, born - 1, found=timeless))

    def test_a_crash_of_the_app_that_was_started_again_fails_the_launch_by_its_hidden_path(self):
        status, output, report = self.run_smoke("again-report", "--seconds", "0", "--startup-timeout", "20")
        self.assertEqual(status, smoke.FAIL, output)
        self.assertEqual((report["verdict"], report["exit"]), ("fail", None))
        self.assertEqual([Path(found).name for found in report["crash_reports"]], ["stub-2026-11-11-000000.ips"])
        self.assertEqual(report["crash_reports_not_counted"], [])
        verdicts = gate_verdicts()
        self.assertEqual(verdicts.attempt_result(status, report), verdicts.CRASH)
        self.assert_cleaned_up(report)

    def test_a_hidden_path_of_another_builds_app_copy_never_fails_a_healthy_launch(self):
        status, output, report = self.run_smoke("other-hidden-report", "--seconds", "0", "--startup-timeout", "20")
        self.assertEqual(status, smoke.PASS, output)
        self.assertEqual((report["verdict"], report["crash_reports"]), ("pass", []))
        self.assertEqual([Path(found).name for found in report["crash_reports_not_counted"]], ["stub-2026-11-11-000000.ips"])
        self.assertIn("it is of pid 4190004 at /tmp/*/Stub capfeedface00.app/Contents/MacOS/stub, "
                      "not this run's copy of the app", output)
        self.assert_cleaned_up(report)

    def test_a_report_that_comes_after_the_verdicts_wait_is_kept_as_evidence_of_a_failed_launch(self):
        # macOS can take longer than the verdict waits to write a build's first report. The verdict is the app's
        # end and does not wait for it; after a FAIL the evidence does, and never changes the verdict's fields.
        late = {**self.env, "CMUX_FRESH_SMOKE_CRASH_EVIDENCE_WAIT_SECONDS": "20"}
        looked = ("verdict_look = smoke.launch_crash_reports\n"
                  "def look_and_say(*args):\n"
                  "    found = verdict_look(*args)\n"
                  f"    open({str(self.dir)!r} + '/verdict-looked-%d' % args[4], 'w').close()\n"
                  "    return found\n"
                  "smoke.launch_crash_reports = look_and_say")
        for mode, arms in (("late-report", ()), ("late-seeded-report", ("--arms", "empty,seeded", "--seeded-seconds", "0"))):
            with self.subTest(mode=mode):
                status, output, report = self.run_smoke(mode, "--seconds", "0", "--startup-timeout", "10", *arms,
                                                        env=late, setup=looked)
                self.assertEqual(status, smoke.FAIL, output)
                self.assertEqual((report["verdict"], report["exit"], report["crash_reports"]), ("fail", -6, []))
                self.assertEqual(len(report["failures"]), 1, report["failures"])
                self.assertRegex(report["failures"][0], r"the app exited \(signal 6\)")
                self.assertEqual([Path(found).name for found in report["crash_reports_late"]],
                                 ["stub-2026-11-11-000000.ips"])
                self.assertIn("--- stub-2026-11-11-000000.ips (first 6000 bytes)", output)
                # The report was half written when the look first saw it: it is kept when it names this launch.
                kept = smoke.crash_report_process(self.dir / f"out-{mode}-{self.runs}" / "stub-2026-11-11-000000.ips")
                self.assertEqual(kept and kept["pid"], report["pid"])
                # The failure is told before the report is waited for.
                self.assertLess(output.index("FAIL: "), output.index("--- stub-2026-11-11-000000.ips"))
                self.assert_cleaned_up(report)
                (self.dir / "diagnostics" / "stub-2026-11-11-000000.ips").unlink()

    def test_a_run_that_is_cut_while_it_waits_for_a_late_report_has_told_the_failure(self):
        # The gate's watchdog cuts an attempt that takes too long. The wait for a late report is the last thing a
        # failed launch does: the report on disk and the log have the failure before it, in each arm.
        # The late look says when it begins (a caller script, then the real look), and the run is cut there: the
        # look then waits far longer than this test, so the run cannot end by itself.
        late = {**self.env, "CMUX_FRESH_SMOKE_CRASH_EVIDENCE_WAIT_SECONDS": "600"}
        begins = "the late look begins"
        caller = ("import importlib.util, sys\n"
                  f"spec = importlib.util.spec_from_file_location('smoke', {str(SCRIPT)!r})\n"
                  "smoke = importlib.util.module_from_spec(spec); spec.loader.exec_module(smoke)\n"
                  "real_look = smoke.late_crash_reports\n"
                  f"smoke.late_crash_reports = lambda *a, **k: smoke.log({begins!r}) or real_look(*a, **k)\n"
                  "sys.exit(smoke.main(sys.argv[1:]))\n")
        for mode, arms, arm, told in (("crash", (), None, "FAIL: the app exited"),
                                      ("sync-crash", ("--arms", "empty,seeded", "--seeded-seconds", "0"), "seeded",
                                       "FAIL: seeded home: the app exited")):
            with self.subTest(mode=mode):
                app, out = make_app(self.dir / f"cut-{mode}", mode), self.dir / f"out-cut-{mode}"
                harness = subprocess.Popen([sys.executable, "-c", caller, "--app", str(app), "--out", str(out),
                                            "--seconds", "0", "--startup-timeout", "10", *arms],
                                           env=late, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
                lines, before_the_look = [], None
                try:
                    for line in harness.stdout:
                        if line.startswith(begins) and before_the_look is None:
                            before_the_look = list(lines)
                            harness.terminate()
                        lines.append(line)
                    status = harness.wait(timeout=60)
                finally:
                    if harness.poll() is None:
                        harness.kill()
                    harness.stdout.close()
                output = "".join(lines)
                self.assertIsNotNone(before_the_look, f"the late look did not begin:\n{output}")
                self.assertTrue(any(line.startswith(told) for line in before_the_look),
                                f"the failure was not told before the late look began:\n{output}")
                self.assertEqual(status, 128 + signal.SIGTERM, output)
                report = json.loads((out / "report.json").read_text())
                self.assertEqual((report["verdict"], report["exit"], report.get("arm"), report["crash_reports_late"]),
                                 ("fail", -6, arm, []), output)
                self.assertRegex(report["failures"][0], r"the app exited \(signal 6\)")
                self.assert_cleaned_up(report)
                # The gate gives a cut attempt the status 124 and reads this report: it is that attempt's crash.
                gate = gate_verdicts()
                self.assertEqual(gate.attempt_result(124, report), gate.CRASH, report)

    def test_a_crash_stays_a_crash_when_its_crash_reports_cannot_be_read(self):
        # The verdict of an app that ended is its end. A report folder or a report that cannot be read must not make
        # that launch a cannot-run, in either arm (LOOKS: how many looks at the folder still work).
        refuse = ("looks = []\n"
                  "def refuse(*_a, **_k):\n"
                  "    looks.append(1)\n"
                  "    if len(looks) > LOOKS:\n"
                  "        raise OSError('no reports today')\n"
                  "    return []\n"
                  "smoke.crash_reports = refuse")
        for mode, arms, arm, looks in (("crash", (), None, 0),
                                       ("sync-crash", ("--arms", "empty,seeded", "--seeded-seconds", "0"), "seeded", 1)):
            with self.subTest(mode=mode):
                status, output, report = self.run_smoke(mode, "--seconds", "0", "--startup-timeout", "10", *arms,
                                                        setup=refuse.replace("LOOKS", str(looks)))
                self.assertEqual(status, smoke.FAIL, output)
                self.assertEqual((report["verdict"], report["exit"], report.get("arm"), report["crash_reports"]),
                                 ("fail", -6, arm, []), output)
                self.assertIn("crash reports could not be read: OSError: no reports today", output)
                self.assertRegex(output, r"FAIL: (seeded home: )?the app exited \(signal 6\)")
                verdicts = gate_verdicts()
                self.assertEqual(verdicts.attempt_result(status, report), verdicts.CRASH)
                self.assert_cleaned_up(report)

    def test_a_crash_of_another_runs_copy_between_the_two_arms_never_fails_the_seeded_arm(self):
        # The first arm gives the defaults lock back before the seeded arm takes it. Another run of a copy with the
        # same name can launch and crash in between, and macOS writes that report while the seeded launch is up: its
        # process was started after the first arm ended, but before the seeded launch was.
        report_path = self.dir / "diagnostics" / "stub-2026-11-11-000000.ips"
        between = ("seed = smoke.seed_cookie_sync_home\n"
                   "def seed_after_another_run(home, bundle_id):\n"
                   "    import json, subprocess, sys, time\n"
                   "    at = time.time()\n"
                   "    now = time.strftime('%Y-%m-%d %H:%M:%S', time.gmtime(at)) + ('%.4f' % (at % 1))[1:] + ' +0000'\n"
                   "    body = {'pid': 4190005, 'parentPid': 1, 'procLaunch': now, 'captureTime': now,\n"
                   "            'procPath': '/tmp/*/Stub healthy.app/Contents/MacOS/stub'}\n"
                   "    writer = ('import os, sys, time\\n'\n"
                   "              'deadline = time.time() + 60\\n'\n"
                   "              'while time.time() < deadline and not os.path.exists(sys.argv[1]):\\n'\n"
                   "              '    time.sleep(0.05)\\n'\n"
                   "              'os.makedirs(os.path.dirname(sys.argv[2]), exist_ok=True)\\n'\n"
                   "              'open(sys.argv[2] + \".part\", \"w\").write(sys.argv[3])\\n'\n"
                   "              'os.replace(sys.argv[2] + \".part\", sys.argv[2])\\n')\n"
                   "    subprocess.Popen([sys.executable, '-c', writer, str(home / 'stub-report.json'),\n"
                   f"                      {str(report_path)!r}, json.dumps({{'app_name': 'stub'}}) + '\\n' + json.dumps(body)],\n"
                   "                     cwd='/', start_new_session=True)\n"
                   "    time.sleep(2.2)\n"
                   "    return seed(home, bundle_id)\n"
                   "smoke.seed_cookie_sync_home = seed_after_another_run\n"
                   # The seeded launch stays up until that report is there (the watch's end is else its Home).
                   "watch = smoke.watch\n"
                   "def watch_until_the_report(*args, **kwargs):\n"
                   "    import os, time\n"
                   "    seen = watch(*args, **kwargs)\n"
                   "    deadline = time.time() + 60\n"
                   "    while kwargs.get('seed') is not None and time.time() < deadline \\\n"
                   f"            and not os.path.exists({str(report_path)!r}):\n"
                   "        time.sleep(0.05)\n"
                   "    return seen\n"
                   "smoke.watch = watch_until_the_report")
        status, output, report = self.run_smoke("healthy", "--seconds", "0", "--startup-timeout", "10",
                                                "--arms", "empty,seeded", "--seeded-seconds", "0", setup=between)
        self.assertEqual(status, smoke.PASS, output)
        arm = report["arms"]["seeded"]
        self.assertEqual((arm["verdict"], arm["crash_reports"]), ("pass", []), output)
        self.assertEqual([Path(found).name for found in arm["crash_reports_not_counted"]], [report_path.name])
        self.assertRegex(output, r"is not counted for the seeded launch: its process died at [0-9:]+Z, "
                                 r"[0-9.]+s before this launch started")
        self.assert_cleaned_up(report)

    def test_only_a_launch_whose_app_ended_waits_for_a_late_report(self):
        # A pass, and a failure of an app that stayed up (no Home), must not get slower: no crash, no report to come.
        # The late look itself says when it runs (no clock): it does for an app that ended, and only for that.
        # The evidence wait is far longer than run_smoke's bound: a wait for a report in ANY other place stops there.
        told = "smoke.late_crash_reports = lambda *a, **k: smoke.log('the late look ran') or []"
        long_wait = {**self.env, "CMUX_FRESH_SMOKE_CRASH_EVIDENCE_WAIT_SECONDS": "600"}
        for mode, verdict, looked in (("healthy", "pass", False), ("no-home", "fail", False), ("crash", "fail", True)):
            with self.subTest(mode=mode):
                status, output, report = self.run_smoke(mode, "--seconds", "0", "--startup-timeout", "3",
                                                        env=long_wait, setup=told)
                self.assertEqual(report["verdict"], verdict, output)
                self.assertEqual("the late look ran" in output, looked, output)
                self.assertEqual(report.get("crash_reports_late", []), [])

    def test_a_crash_report_of_another_builds_launch_never_fails_a_healthy_first_arm(self):
        # Fleet builds all have one executable name, so the name and the file's time also match a crash of another
        # tagged build on the same host. The report says whose it is: another pid, another copy of the app.
        status, output, report = self.run_smoke("other-report", "--seconds", "0", "--startup-timeout", "20")
        self.assertEqual(status, smoke.PASS, output)
        self.assertEqual((report["verdict"], report["crash_reports"]), ("pass", []))
        self.assertEqual([Path(found).name for found in report["crash_reports_not_counted"]], ["stub-2026-11-11-000000.ips"])
        # One read tells the owner whose crash it was: the report's name, its process and that process's app.
        self.assertIn("note: crash report stub-2026-11-11-000000.ips is not counted for this launch: it is of pid 4190001 "
                      "at /private/tmp/cmux-fresh-other00/app/Stub capfeedface00.app/Contents/MacOS/stub, "
                      "not this run's copy of the app", output)
        out = self.dir / f"out-other-report-{self.runs}"
        self.assertTrue((out / "not-counted" / "stub-2026-11-11-000000.ips").is_file())
        self.assertFalse((out / "stub-2026-11-11-000000.ips").exists())
        verdicts = gate_verdicts()
        self.assertEqual(verdicts.attempt_result(status, report), verdicts.PASS)
        self.assert_cleaned_up(report)

    def test_a_crash_report_that_names_no_process_is_no_crash_alone_in_either_arm(self):
        # Such a report says nothing of whose it is: any app with this executable name on the host can have written
        # it. Both homes' launches are healthy, so the run passes; the report is said and kept, never counted.
        status, output, report, out = self.seeded("blank-report")
        self.assertEqual(status, smoke.PASS, output)
        arm = report["arms"]["seeded"]
        self.assertEqual((report["verdict"], report["arm"], arm["verdict"]), ("pass", "empty", "pass"), output)
        for launch, said in ((report, "this launch"), (arm, "the seeded launch")):
            self.assertEqual(launch["crash_reports"], [])
            self.assertEqual([Path(found).name for found in launch["crash_reports_not_counted"]],
                             ["stub-2026-11-11-000000.ips"])
            self.assertIn(f"stub-2026-11-11-000000.ips is not counted for {said}: it names no process", output)
        self.assertTrue((out / "not-counted" / "stub-2026-11-11-000000.ips").is_file())
        self.assertFalse((out / "stub-2026-11-11-000000.ips").exists())
        verdicts = gate_verdicts()
        self.assertEqual(verdicts.attempt_result(status, report), verdicts.PASS)
        self.assert_cleaned_up(report)

    def test_a_report_of_no_process_is_evidence_of_a_launch_whose_app_ended(self):
        # The end of the app is the crash verdict; the report beside it is kept as its evidence.
        status, output, report = self.run_smoke("blank-crash", "--seconds", "3", "--startup-timeout", "5")
        self.assertEqual(status, smoke.FAIL, output)
        self.assertEqual((report["verdict"], report["exit"]), ("fail", -6))
        self.assertEqual([Path(found).name for found in report["crash_reports"]], ["stub-2026-11-11-000000.ips"])
        self.assertEqual(report["crash_reports_not_counted"], [])
        self.assertTrue((self.dir / f"out-blank-crash-{self.runs}" / "stub-2026-11-11-000000.ips").is_file())
        self.assert_cleaned_up(report)

    def test_a_report_that_is_read_while_it_is_written_is_read_again(self):
        # Its head alone names no process. A second later its body does: this launch's. It still fails the launch.
        status, output, report = self.run_smoke("torn-report", "--seconds", "0", "--startup-timeout", "20")
        self.assertEqual(status, smoke.FAIL, output)
        self.assertEqual((report["verdict"], report["exit"]), ("fail", None))
        self.assertEqual([Path(found).name for found in report["crash_reports"]], ["stub-2026-11-11-000000.ips"])
        self.assertEqual(report["crash_reports_not_counted"], [])
        self.assert_cleaned_up(report)

    def test_a_crash_report_of_the_first_arms_own_launch_fails_it_as_before(self):
        # home-report: a detached process whose program is under the run's HOME, not in the app copy. It is of this
        # run (nothing else writes under the run's private root), so it counts, as it did before the filter.
        for mode in ("first-report", "home-report"):
            with self.subTest(mode=mode):
                status, output, report = self.run_smoke(mode, "--seconds", "0", "--startup-timeout", "20")
                self.assertEqual(status, smoke.FAIL, output)
                self.assertEqual((report["verdict"], report["exit"]), ("fail", None))
                self.assertEqual([Path(found).name for found in report["crash_reports"]], ["stub-2026-11-11-000000.ips"])
                self.assertEqual(report["crash_reports_not_counted"], [])
                self.assertEqual(report["failures"], ["crash report: stub-2026-11-11-000000.ips"])
                self.assertTrue((self.dir / f"out-{mode}-{self.runs}" / "stub-2026-11-11-000000.ips").is_file())
                verdicts = gate_verdicts()
                self.assertEqual(verdicts.attempt_result(status, report), verdicts.CRASH)
                self.assert_cleaned_up(report)
                (self.dir / "diagnostics" / "stub-2026-11-11-000000.ips").unlink()

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

    def test_a_report_of_a_process_that_was_started_before_the_launch_is_not_of_it(self):
        # A process of an earlier launch that died AFTER this launch started (the run did not find it, or macOS
        # took the time of death late): the time it was started says whose it is.
        app = self.dir / "root" / "app" / "cmux NEXT.app"
        (app / "Contents" / "MacOS").mkdir(parents=True)
        helper = str(app / "Contents" / "Resources" / "bin" / "cmux-tui")
        started = 1794387600.0  # 2026-11-11 09:00:00 UTC

        def ips(name: str, **body) -> Path:
            found = self.dir / f"{name}.ips"
            found.write_text(json.dumps({"app_name": "cmux"}) + "\n" + json.dumps(body, indent=2) + "\n")
            return found

        def why(found: Path) -> str | None:
            return smoke.not_of_launch(found, 200, app, frozenset({100}), started)

        late = {"pid": 300, "parentPid": 1, "procPath": helper, "captureTime": "2026-11-11 09:00:04.0000 +0000"}
        self.assertEqual(smoke.crash_report_launch_time(ips("born", procLaunch="2026-11-11 08:59:20.5000 +0000", **late)),
                         started - 39.5)
        self.assertIsNone(smoke.crash_report_launch_time(ips("unborn", **late)))
        self.assertIsNone(smoke.crash_report_launch_time(ips("bad", procLaunch=12, **late)))
        self.assertRegex(why(ips("earlier", procLaunch="2026-11-11 08:59:20.5000 +0000", **late)),
                         r"its process was started at 08:59:20Z, 39\.5s before this launch started")
        # Counted, as before: started after the launch did, or the report does not say when.
        self.assertIsNone(why(ips("ours", procLaunch="2026-11-11 09:00:01.0000 +0000", **late)))
        self.assertIsNone(why(ips("silent", **late)))
        self.assertIsNone(smoke.not_of_launch(ips("no-start", procLaunch="2026-11-11 08:00:00.0000 +0000", **late),
                                              200, app, frozenset({100})))
        text = self.dir / "old.crash"
        text.write_text(f"Process:               cmux-tui [300]\nPath:                  {helper}\n"
                        "Date/Time:             2026-11-11 09:00:04.000 +0000\n"
                        "Launch Time:           2026-11-11 08:59:20.500 +0000\nParent Process:        launchd [1]\n")
        self.assertEqual(smoke.crash_report_launch_time(text), started - 39.5)
        self.assertIn("was started at 08:59:20Z", why(text))

    def test_a_seed_that_cannot_be_made_leaves_the_arm_cannot_run(self):
        (self.defaults_dir / f"{BUNDLE}.plist").write_bytes(b"account defaults")
        refuse = "def refuse(*_a, **_k):\n    raise RuntimeError('no seed today')\nsmoke.seed_cookie_sync_home = refuse"
        status, output, report = self.run_smoke("healthy", "--seconds", "0", "--startup-timeout", "10",
                                                "--arms", "empty,seeded", "--seeded-seconds", "0", setup=refuse)
        self.assertEqual(status, smoke.PASS, output)
        self.assertEqual((report["verdict"], report["arm"]), ("pass", "empty"))
        arm = report["arms"]["seeded"]
        self.assertEqual((arm["verdict"], arm["reason"]), ("cannot-run", "RuntimeError: no seed today"))
        self.assertNotIn("pid", arm)
        self.assertIn("seeded-home arm CANNOT RUN: RuntimeError: no seed today; the first arm's verdict stands", output)
        self.assertEqual((self.defaults_dir / f"{BUNDLE}.plist").read_bytes(), b"account defaults")
        self.assert_cleaned_up(report)

    def test_a_fault_of_the_seeded_arm_itself_is_never_a_crash_on_both_attempts_too(self):
        # The post-publish smoke takes a build back from the feed when it crashed on both attempts. A fault of this
        # tool in the seeded arm (the seed cannot be made, its folder cannot be written, the app cannot be started,
        # the watch breaks) is not a crash of the app: each attempt passes on its first arm, says that the seeded
        # arm could not run, and two such attempts are a pass, so nothing is rolled back.
        wrap = "make = smoke.seed_cookie_sync_home\ndef seed(home, *a, **k):\n{body}\nsmoke.seed_cookie_sync_home = seed"
        faults = {
            "the seed tool refuses": (
                "def refuse(*_a, **_k):\n    raise RuntimeError('no seed today')\nsmoke.seed_cookie_sync_home = refuse",
                r"^RuntimeError: no seed today$", False),
            "a file is where the seed's folder must be": (
                wrap.format(body="    (home / '.config').write_text('not a folder')\n    return make(home, *a, **k)"),
                r"^(NotADirectoryError|FileExistsError): .*\.config", False),
            "the app cannot be started": (
                "import subprocess\nreal, launches = subprocess.Popen, []\n"
                "def popen(*a, **k):\n"
                "    argv = a[0] if a else k.get('args')\n"
                "    if isinstance(argv, list) and '/Contents/MacOS/' in str(argv[0]):\n"
                "        launches.append(argv)\n"
                "        if len(launches) == 2:\n"
                "            raise OSError(8, 'Exec format error')\n"
                "    return real(*a, **k)\n"
                "subprocess.Popen = popen",
                r"^OSError: \[Errno 8\] Exec format error$", False),
            "the watch of the seeded launch breaks": (
                "real = smoke.watch\n"
                "def watch(*a, **k):\n"
                "    if k.get('seed') is not None:\n"
                "        raise RuntimeError('the watch broke')\n"
                "    return real(*a, **k)\n"
                "smoke.watch = watch",
                r"^RuntimeError: the watch broke$", True),
        }
        if os.geteuid() != 0:  # root writes a folder of any mode
            faults["the seeded home is not writable"] = (
                wrap.format(body="    os.chmod(home, 0o500)\n    try:\n        return make(home, *a, **k)\n"
                                 "    finally:\n        os.chmod(home, 0o700)").replace("make =", "import os\nmake =", 1),
                r"^PermissionError: \[Errno 13\] .*\.config", False)
        verdicts = gate_verdicts()
        (self.defaults_dir / f"{BUNDLE}.plist").write_bytes(b"account defaults")
        for name, (setup, reason, started) in faults.items():
            with self.subTest(fault=name):
                attempts = []
                for _attempt in (1, 2):
                    status, output, report = self.run_smoke("healthy", "--seconds", "0", "--startup-timeout", "10",
                                                            "--arms", "empty,seeded", "--seeded-seconds", "0",
                                                            setup=setup)
                    self.assertEqual(status, smoke.PASS, output)
                    self.assertEqual((report["verdict"], report["arm"]), ("pass", "empty"), output)
                    arm = report["arms"]["seeded"]
                    self.assertEqual(arm["verdict"], "cannot-run", output)
                    self.assertRegex(arm["reason"], reason)
                    self.assertIn("==> seeded-home arm CANNOT RUN: ", output)
                    self.assertNotIn("FAIL", output)
                    # The seeded app, when the fault came after its start, is stopped as the first arm's is.
                    self.assertEqual("pid" in arm, started, arm)
                    if started:
                        self.assertFalse(smoke.alive(arm["pid"]), "the seeded app outlived the run")
                    self.assertEqual((self.defaults_dir / f"{BUNDLE}.plist").read_bytes(), b"account defaults")
                    self.assert_cleaned_up(report)
                    self.assertEqual(verdicts.attempt_result(status, report), verdicts.PASS)
                    attempts.append((status, report))
                self.assertEqual(verdicts.verdict(attempts), verdicts.PASS)

    def test_a_seeded_crash_stays_a_crash_when_its_evidence_cannot_be_kept(self):
        refuse = "def refuse(*_a, **_k):\n    raise RuntimeError('no evidence today')\nsmoke.explain = refuse"
        status, output, report = self.run_smoke("sync-crash", "--seconds", "0", "--startup-timeout", "10",
                                                "--arms", "empty,seeded", "--seeded-seconds", "0", setup=refuse)
        self.assertEqual(status, smoke.FAIL, output)
        self.assertEqual((report["verdict"], report["arm"], report["exit"]), ("fail", "seeded", -6))
        self.assertIn("the seeded launch's evidence is not complete: RuntimeError: no evidence today", output)
        self.assertIn("FAIL: seeded home: the app exited", output)
        verdicts = gate_verdicts()
        self.assertEqual(verdicts.attempt_result(status, report), verdicts.CRASH)
        self.assert_cleaned_up(report)

    def test_a_seeded_crash_stays_a_crash_when_the_evidence_and_its_warning_both_fail(self):
        # As a log that went away while the evidence was told: the arm's verdict was a failure before that.
        refuse = ("def refuse(*_a, **_k):\n    raise RuntimeError('no evidence today')\nsmoke.explain = refuse\n"
                  "say = smoke.log\n"
                  "def log(message):\n"
                  "    if message.startswith('warning: the seeded launch'):\n"
                  "        raise BrokenPipeError('the log went away')\n"
                  "    say(message)\n"
                  "smoke.log = log")
        status, output, report = self.run_smoke("sync-crash", "--seconds", "0", "--startup-timeout", "10",
                                                "--arms", "empty,seeded", "--seeded-seconds", "0", setup=refuse)
        self.assertEqual(status, smoke.FAIL, output)
        self.assertEqual((report["verdict"], report["arm"], report["exit"]), ("fail", "seeded", -6))
        self.assertEqual(report["arms"]["seeded"]["verdict"], "fail")
        verdicts = gate_verdicts()
        self.assertEqual(verdicts.attempt_result(status, report), verdicts.CRASH)
        self.assert_cleaned_up(report)

    def test_a_first_arm_crash_stays_a_crash_when_its_evidence_cannot_be_kept(self):
        refuse = "def refuse(*_a, **_k):\n    raise OSError('no evidence today')\nsmoke.explain = refuse"
        status, output, report = self.run_smoke("crash", "--seconds", "0", "--startup-timeout", "10", setup=refuse)
        self.assertEqual(status, smoke.FAIL, output)
        self.assertEqual((report["verdict"], report["exit"]), ("fail", -6))
        self.assertIn("this launch's evidence is not complete: OSError: no evidence today", output)
        self.assertIn("FAIL: the app exited", output)
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
        harness = subprocess.Popen([sys.executable, str(SCRIPT), "--app", str(app), "--out", str(out), "--seconds", "0",
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

    def test_a_healthy_launch_that_the_gate_cuts_is_never_a_crash_for_the_gate(self):
        # The gate reads a cut attempt (status 124) by its report. A healthy app that the harness itself stops at
        # the cut must leave no evidence of an end: `exit` and the crash reports are only what the watch saw while
        # the app ran, and the stop at the cut writes nothing of the app into the report. In each phase of each arm.
        verdicts = gate_verdicts()
        cuts = (("==> fresh-home launch of", ("--seconds", "60")),
                ("ok: Home rendered in a visible window", ("--seconds", "60")),
                ("==> seeded-home launch of", ("--seconds", "0", "--seeded-seconds", "60")),
                ("ok: the cookie sync read the seeded store", ("--seconds", "0", "--seeded-seconds", "60")))
        for name, (cut_at, extra) in enumerate(cuts):
            with self.subTest(cut_at=cut_at):
                app, out = make_app(self.dir / f"cut-healthy-{name}", "healthy"), self.dir / f"out-cut-healthy-{name}"
                harness = subprocess.Popen([sys.executable, str(SCRIPT), "--app", str(app), "--out", str(out),
                                            "--startup-timeout", "10", "--arms", "empty,seeded", *extra],
                                           env=self.env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
                lines = []
                try:
                    for line in harness.stdout:
                        lines.append(line)
                        if line.startswith(cut_at):
                            harness.terminate()
                    status = harness.wait(timeout=60)
                finally:
                    if harness.poll() is None:
                        harness.kill()
                    harness.stdout.close()
                output = "".join(lines)
                self.assertEqual(status, 128 + signal.SIGTERM, output)
                report = json.loads((out / "report.json").read_text())
                self.assertIsNone(report.get("exit"), output)
                self.assertFalse(report.get("crash_reports") or report.get("run_exceptions"), output)
                self.assertNotEqual(report.get("verdict"), "fail", output)
                self.assertEqual(verdicts.attempt_result(124, report), verdicts.CANNOT_RUN, report)
                self.assertEqual(verdicts.verdict([(124, report), (124, report)]), verdicts.CANNOT_RUN, report)
                for pid in (report.get("pid"), ((report.get("arms") or {}).get("seeded") or {}).get("pid")):
                    self.assertFalse(pid and smoke.alive(pid), "an app outlived the stopped run")
                self.assert_cleaned_up(report)

    # The daemon check (--daemon: the publish gate asks for it, the post-publish smoke does not). A NEXT build whose
    # daemon (cmux-tui) is dead shows Home and takes no key: the app stays up, so the watch of the app's process
    # alone said PASS for it.
    CONNECTED = {"state": "connected", "failure": None}
    DISCONNECTED = {"state": "disconnected", "failure": None}

    def test_a_daemon_that_is_not_connected_when_the_watch_ends_fails_the_launch(self):
        verdicts = gate_verdicts()
        status, output, report = self.run_smoke("healthy@down", "--seconds", "0", "--startup-timeout", "10", "--daemon")
        self.assertEqual(status, smoke.FAIL, output)
        self.assertEqual(report["verdict"], "fail")
        self.assertIsNone(report["exit"])  # the app is up: only its word on the daemon fails the launch
        self.assertIsNotNone(report["rendered_at"])
        self.assertEqual(report["daemon"], [self.DISCONNECTED, self.DISCONNECTED])
        self.assertRegex(report["failures"][0],
                         r"daemon .* not connected .*\(disconnected\) and at the next read \(disconnected\)")
        self.assertEqual(report["daemon_down"], report["failures"][0])
        self.assertIn("FAIL: the app's daemon", output)
        self.assertEqual(output.count("daemon: disconnected\n"), 2, output)
        self.assert_cleaned_up(report)
        # For the publish gate it is evidence as the app's end is: one attempt holds nothing, both hold the build.
        self.assertEqual(verdicts.attempt_result(1, report, True), verdicts.CRASH)
        self.assertEqual(verdicts.attempt_result(124, report, True), verdicts.CRASH)
        self.assertEqual(verdicts.verdict([(1, report)], daemon=True), verdicts.CANNOT_RUN)
        self.assertEqual(verdicts.verdict([(1, report), (1, report)], daemon=True), verdicts.CRASH)
        # And for a caller that does not ask (the post-publish smoke's verdict) it is no crash.
        self.assertEqual(verdicts.verdict([(1, report), (1, report)]), verdicts.CANNOT_RUN)

    def daemon_of_another_launch(self, session: str) -> subprocess.Popen:
        """A live app daemon of SESSION whose program is not in the run's app copy: another launch's."""
        program = self.dir / f"other-{session}" / "cmux-tui"
        program.parent.mkdir()
        os.symlink(sys.executable, program)
        other = subprocess.Popen([str(program), "-c", "import time; time.sleep(600)", "--headless", "--session",
                                  session, "--socket", "s"])
        self.addCleanup(other.wait)
        self.addCleanup(other.kill)
        # How a daemon failure names it. The program is all before the first option: for this stand-in, Python's
        # own -c and its text too (the real daemon's first argument is --headless).
        other.said = f"pid {other.pid} {program} -c import time; time.sleep(600) ({session})"
        return other

    def test_a_connected_daemon_that_is_not_of_this_launch_is_not_judged_and_is_no_pass_for_the_gate(self):
        # The daemon's socket is the account's, by session, not the home's (FOUND 5): with an installed build of the
        # same channel live, the launched app gets THAT daemon, and "connected" says nothing of this build's.
        verdicts = gate_verdicts()
        self.daemon_of_another_launch(f"cmux-app-stub-{self.dir.name}")
        status, output, report = self.run_smoke("healthy@other", "--seconds", "0", "--startup-timeout", "10", "--daemon")
        self.assertEqual(status, smoke.PASS, output)  # the launch itself passed; what a caller makes of the mark is its
        self.assertEqual(report["daemon"], [{**self.CONNECTED, "of_launch": False}])
        self.assertIsNone(report["daemon_down"])
        self.assertIn("\ndaemon: not judged (not of this launch)\n", output)
        self.assertNotIn("daemon: connected", output)
        self.assert_cleaned_up(report)
        self.assertEqual(verdicts.attempt_result(0, report, True), verdicts.CANNOT_RUN)
        self.assertEqual(verdicts.attempt_result(0, report), verdicts.PASS)  # the post-publish smoke: as before
        # The seeded home's launch has the same rule, and the report says which home.
        status, output, report = self.run_smoke("healthy@other", "--seconds", "0", "--startup-timeout", "10", "--arms",
                                                "empty,seeded", "--seeded-seconds", "0", "--daemon")
        self.assertEqual(status, smoke.PASS, output)
        self.assertEqual(report["arms"]["seeded"]["daemon"], [{**self.CONNECTED, "of_launch": False}])
        self.assertEqual(output.count("daemon: not judged (not of this launch)\n"), 2, output)
        self.assertEqual(verdicts.attempt_result(0, report, True), verdicts.CANNOT_RUN)

    def test_a_daemon_failure_names_the_daemons_of_its_session_that_are_not_of_this_launch_or_none(self):
        # A reader of a held build must know at once whether another launch's daemon can be the cause.
        session = f"cmux-app-stub-{self.dir.name}"
        status, output, report = self.run_smoke("healthy@down", "--seconds", "0", "--startup-timeout", "10", "--daemon")
        self.assertEqual(status, smoke.FAIL, output)
        self.assertTrue(report["daemon_down"].endswith(
            f"at the next read (disconnected); daemons of {session} that are not of this launch: none"), output)
        other = self.daemon_of_another_launch(session)
        stranger = self.daemon_of_another_launch(session + "-2")  # another session: not the launch's socket
        status, output, report = self.run_smoke("healthy@failed", "--seconds", "0", "--startup-timeout", "10", "--daemon")
        self.assertEqual(status, smoke.FAIL, output)
        self.assertTrue(report["daemon_down"].endswith(
            f"did not start; daemons of {session} that are not of this launch: {other.said}"), output)
        self.assertEqual(report["daemon_down"], report["failures"][0])
        self.assertIn(f"FAIL: {report['daemon_down']}", output)
        # A launch with no daemon of its own (a dead daemon has no process) does not know its session: each app
        # session's daemons are named, with their session.
        status, output, report = self.run_smoke("healthy@down-other", "--seconds", "0", "--startup-timeout", "10", "--daemon")
        self.assertEqual(status, smoke.FAIL, output)
        said = report["daemon_down"].partition("; daemons of an app session that are not of this launch: ")[2]
        self.assertTrue(said, report["daemon_down"])
        # 3 at most are named, and a developer's Mac can have app daemons of its own.
        self.assertTrue({other.said, stranger.said} & set(said.split(", ")) or len(said.split(", ")) == 3, said)
        self.assert_cleaned_up(report)

    def test_a_daemon_that_is_connected_again_at_the_second_read_is_no_failure(self):
        # A reconnect in work when the watch ends: the app says "not connected" one time and "connected" the next.
        status, output, report = self.run_smoke("healthy@reconnects", "--seconds", "0", "--startup-timeout", "10",
                                                "--daemon")
        self.assertEqual(status, smoke.PASS, output)
        self.assertEqual(report.get("daemon"), [self.DISCONNECTED, self.CONNECTED], output)
        self.assertIsNone(report["daemon_down"])
        self.assertIn("\ndaemon: disconnected\ndaemon: connected\n", output)
        self.assert_cleaned_up(report)

    def test_a_connected_daemon_is_read_one_time_and_adds_no_wait(self):
        env = {**self.env, "CMUX_FRESH_SMOKE_DAEMON_REREAD_SECONDS": "600"}  # a second read would end the run's bound
        status, output, report = self.run_smoke("healthy", "--seconds", "0", "--startup-timeout", "10", "--arms",
                                                "empty,seeded", "--seeded-seconds", "0", "--daemon", env=env)
        self.assertEqual(status, smoke.PASS, output)
        self.assertEqual(report.get("daemon"), [self.CONNECTED], output)
        self.assertEqual(report["arms"]["seeded"]["daemon"], [self.CONNECTED])
        self.assertNotIn("the app's daemon", output)
        self.assertEqual(output.count("daemon: connected\n"), 2, output)  # each arm says what it read
        self.assert_cleaned_up(report)

    def test_a_daemon_failure_that_the_app_tells_fails_the_launch(self):
        status, output, report = self.run_smoke("healthy@failed", "--seconds", "0", "--startup-timeout", "10", "--daemon")
        self.assertEqual(status, smoke.FAIL, output)
        self.assertEqual(report["daemon"][-1], {"state": "failed", "failure": "cmux-tui did not start"})
        self.assertIn("cmux-tui did not start", report["daemon_down"])
        self.assertEqual(gate_verdicts().attempt_result(1, report, True), gate_verdicts().CRASH)
        self.assert_cleaned_up(report)

    def test_a_daemon_that_is_down_in_the_seeded_home_fails_the_run_as_that_arms_failure(self):
        verdicts = gate_verdicts()
        status, output, report = self.run_smoke("healthy@seeded-down", "--seconds", "0", "--startup-timeout", "10",
                                                "--arms", "empty,seeded", "--seeded-seconds", "0", "--daemon")
        self.assertEqual(status, smoke.FAIL, output)
        self.assertEqual(report["arm"], smoke.SEEDED)
        self.assertEqual(report["arms"]["empty"]["verdict"], "pass")
        self.assertEqual(report["arms"]["seeded"]["verdict"], "fail")
        self.assertEqual(report["pid"], report["arms"]["seeded"]["pid"])
        self.assertIsNone(report["exit"])
        self.assertEqual(report["daemon"], [self.DISCONNECTED, self.DISCONNECTED])
        self.assertRegex(report["daemon_down"], r"^the app's daemon .* not connected")
        self.assertEqual(report["failures"], [f"seeded home: {report['daemon_down']}"])
        self.assertEqual(report["arms"]["seeded"]["daemon_down"], report["daemon_down"])
        self.assertIn("FAIL: seeded home: the app's daemon", output)
        self.assertEqual(verdicts.attempt_result(1, report, True), verdicts.CRASH)
        self.assertEqual(verdicts.verdict([(1, report), (124, report)], daemon=True), verdicts.CRASH)
        self.assert_cleaned_up(report)

    def test_what_the_daemon_check_does_not_judge(self):
        verdicts = gate_verdicts()
        # A build whose snapshot has no word on the daemon (one from before the field): not judged.
        status, output, report = self.run_smoke("healthy@none", "--seconds", "0", "--startup-timeout", "10", "--daemon")
        self.assertEqual(status, smoke.PASS, output)
        self.assertEqual(report.get("daemon"), [{"state": None, "failure": None}], output)
        self.assertIn("\ndaemon: not judged (no field)\n", output)  # said: a silence is not read as a pass
        # A launch that never showed Home fails as before and is no crash for the gate: the daemon is not read
        # (Home's render is the proof that it was connected one time).
        status, output, report = self.run_smoke("no-home@down", "--seconds", "0", "--startup-timeout", "3", "--daemon")
        self.assertEqual(status, smoke.FAIL, output)
        self.assertIn("Home did not render", report["failures"][0])
        self.assertEqual(len(report["failures"]), 1)
        self.assertFalse(report.get("daemon") or report.get("daemon_down"), report)
        self.assertEqual(verdicts.attempt_result(1, report, True), verdicts.CANNOT_RUN)
        # A caller with its own ready state (scripts/cmux-next/idle_cpu.py: any visible window) has no such proof.
        visible = "lambda snap: smoke.visible_windows(snap) > 0"
        status, output, report = self.run_smoke("new-tab@down", "--seconds", "0", "--startup-timeout", "10", "--daemon",
                                                ready=visible)
        self.assertEqual(status, smoke.PASS, output)
        self.assertFalse(report.get("daemon") or report.get("daemon_down"), report)
        self.assert_cleaned_up(report)

    def test_without_daemon_the_app_is_not_asked_so_the_post_publish_smoke_says_what_it_said_before(self):
        # The post-publish smoke (nightly-next-launch-smoke.yml) and each other caller run the harness with no
        # --daemon. A rollback of a published build is not this check's to start: for them a build with a dead
        # daemon is what it was before the check, a pass, and the app gets no read more.
        verdicts = gate_verdicts()
        env = {**self.env, "CMUX_FRESH_SMOKE_DAEMON_REREAD_SECONDS": "600"}  # a second read would end the run's bound
        for mode in ("healthy@down", "healthy@failed"):
            with self.subTest(mode=mode):
                status, output, report = self.run_smoke(mode, "--seconds", "0", "--startup-timeout", "10", "--arms",
                                                        "empty,seeded", "--seeded-seconds", "0", env=env)
                self.assertEqual(status, smoke.PASS, output)
                self.assertEqual(report["verdict"], "pass")
                self.assertFalse(report.get("daemon") or report.get("daemon_down"), report)
                self.assertFalse(report["arms"]["seeded"].get("daemon") or report["arms"]["seeded"].get("daemon_down"))
                self.assertNotIn("daemon", output)
                self.assertEqual(verdicts.verdict([(status, report)]), verdicts.PASS)
                self.assert_cleaned_up(report)

    def test_a_launch_that_the_gate_cuts_while_the_daemon_is_read_again_is_never_a_crash_for_the_gate(self):
        # The app said "not connected" one time and the second read is still to come: that is no verdict. A cut
        # there (the gate's watchdog) leaves a report with no failure and no word that the daemon is down.
        verdicts = gate_verdicts()
        env = {**self.env, "CMUX_FRESH_SMOKE_DAEMON_REREAD_SECONDS": "600"}
        for name, mode in enumerate(("healthy@down", "healthy@seeded-down")):
            with self.subTest(mode=mode):
                app, out = make_app(self.dir / f"cut-daemon-{name}", mode), self.dir / f"out-cut-daemon-{name}"
                harness = subprocess.Popen([sys.executable, str(SCRIPT), "--app", str(app), "--out", str(out),
                                            "--startup-timeout", "10", "--arms", "empty,seeded", "--seconds", "0",
                                            "--seeded-seconds", "0", "--daemon"],
                                           env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
                lines = []
                try:
                    for line in harness.stdout:
                        lines.append(line)
                        if line.startswith("daemon: disconnected"):
                            harness.terminate()
                    status = harness.wait(timeout=60)
                finally:
                    if harness.poll() is None:
                        harness.kill()
                    harness.stdout.close()
                output = "".join(lines)
                self.assertEqual(status, 128 + signal.SIGTERM, output)
                report = json.loads((out / "report.json").read_text())
                self.assertNotEqual(report.get("verdict"), "fail", output)
                self.assertFalse(report.get("daemon_down"), report)
                self.assertFalse(((report.get("arms") or {}).get("seeded") or {}).get("daemon_down"), report)
                self.assertEqual(verdicts.attempt_result(124, report, True), verdicts.CANNOT_RUN, report)
                self.assertEqual(verdicts.verdict([(124, report), (124, report)], daemon=True), verdicts.CANNOT_RUN, report)
                for pid in (report.get("pid"), ((report.get("arms") or {}).get("seeded") or {}).get("pid")):
                    self.assertFalse(pid and smoke.alive(pid), "an app outlived the stopped run")
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
        status, output, report = self.run_smoke("no-home", "--seconds", "0", "--startup-timeout", "3")
        self.assertEqual(status, smoke.FAIL, output)
        self.assertIn("Home did not render", report["failures"][0])
        self.assert_cleaned_up(report)

    def test_a_caller_ready_check_replaces_only_the_home_check(self):
        # scripts/cmux-next/idle_cpu.py: a fresh launch of feat opens a New Tab tab, not Home (cmux-ad m9, job
        # 857451d6: "Home did not render"). A caller's READY decides the window part; the nightly smoke keeps Home.
        status, output, report = self.run_smoke("new-tab", "--seconds", "0", "--startup-timeout", "3")
        self.assertEqual(status, smoke.FAIL, output)
        self.assertIn("Home did not render", report["failures"][0])
        visible = "lambda snap: smoke.visible_windows(snap) > 0"
        status, output, report = self.run_smoke("new-tab", "--seconds", "0", "--startup-timeout", "10", ready=visible)
        self.assertEqual(status, smoke.PASS, output)
        self.assert_cleaned_up(report)
        # The frame mark still counts: a visible window with no first frame is not ready.
        status, output, report = self.run_smoke("no-home", "--seconds", "0", "--startup-timeout", "3", ready=visible)
        self.assertEqual(status, smoke.FAIL, output)
        self.assert_cleaned_up(report)

    def test_a_fresh_launch_with_the_first_run_page_over_home_passes(self):
        # Every NEXT Nightly since #33215 failed here as "Home did not render ... Home tab not selected" (cannot-run in
        # nightly_next_launch_smoke.py, so the job stayed green): the page covers Home and Home's pane has no selection.
        status, output, report = self.run_smoke("first-run", "--seconds", "0", "--startup-timeout", "10")
        self.assertEqual(status, smoke.PASS, output)
        self.assertEqual(report["verdict"], "pass")
        self.assert_cleaned_up(report)
        # Without the app's mark the same parked pane is not a healthy launch.
        status, output, report = self.run_smoke("first-run-unmarked", "--seconds", "0", "--startup-timeout", "3")
        self.assertEqual(status, smoke.FAIL, output)
        self.assertIn("Home did not render", report["failures"][0])
        self.assertIn("first_run.history_import_shown missing", report["failures"][0])
        self.assert_cleaned_up(report)

    def clones_left(self) -> list[str]:
        """The clone folders in this test's X folder, as PARENT/NAME."""
        return sorted(f"{path.parent.name}/{path.name}" for path in self.clones.glob("*.code_sign_clone/*"))

    def test_the_clone_cleanup_helper_ends_by_itself_before_the_run_stops_what_is_left(self):
        # Chromium's helper removes the launch's code-sign clone (about 1 GB) about 1 s after the app's end. The
        # run stopped it with the app's other processes at once, so each launch left its clone until reboot.
        self.clone_helper = "ends"
        status, output, report = self.run_smoke("healthy", "--seconds", "0", "--startup-timeout", "10")
        self.assertEqual(status, smoke.PASS, output)
        done = sorted(path.name for path in self.clones.glob("done-*"))
        self.assertEqual(len(done), 1, f"the cleanup helper was stopped before it removed the clone\n{output}")
        self.assertEqual(self.clones_left(), [])
        told = report["clone_cleanup"]
        self.assertEqual((told["helpers"], told["helper_ended"]), (1, True), told)
        self.assertEqual(told["clones"], {done[0].removeprefix("done-"): "gone"})
        self.assert_cleaned_up(report)

    def test_each_arms_cleanup_helper_ends_by_itself(self):
        self.clone_helper = "ends"
        status, output, report, _ = self.seeded("healthy")
        self.assertEqual(status, smoke.PASS, output)
        self.assertEqual(len(list(self.clones.glob("done-*"))), 2, output)
        self.assertEqual(self.clones_left(), [])
        self.assertTrue(report["clone_cleanup"]["helper_ended"], report["clone_cleanup"])
        self.assertTrue(report["arms"]["seeded"]["clone_cleanup"]["helper_ended"], report["arms"]["seeded"])
        self.assert_cleaned_up(report)

    def test_a_helper_that_does_not_end_is_stopped_and_only_its_launchs_clone_is_removed(self):
        # The parent folder holds one clone for each live launch of the bundle id (two runs of one build on one
        # host), and X holds the clones of each other app: only the folder that this launch's helper names goes.
        self.clone_helper = "stays"
        other_launch = self.clones / f"{BUNDLE}.code_sign_clone" / "code_sign_clone.Other1"
        other_app = self.clones / "com.example.other.code_sign_clone" / "code_sign_clone.Other2"
        for folder in (other_launch, other_app):
            folder.mkdir(parents=True)
            (folder / "binary").write_text("of another launch")
        env = {**self.env, "CMUX_FRESH_SMOKE_CLONE_HELPER_WAIT_SECONDS": "0.5"}
        status, output, report = self.run_smoke("healthy", "--seconds", "0", "--startup-timeout", "10", env=env)
        self.assertEqual(status, smoke.PASS, output)
        self.assertEqual(list(self.clones.glob("done-*")), [])
        self.assertEqual(self.clones_left(), ["com.example.fresh-smoke-stub.code_sign_clone/code_sign_clone.Other1",
                                              "com.example.other.code_sign_clone/code_sign_clone.Other2"])
        told = report["clone_cleanup"]
        self.assertEqual((told["helpers"], told["helper_ended"]), (1, False), told)
        self.assertEqual(list(told["clones"].values()), ["removed by this tool"])
        self.assertIn("note: code-sign clone cleanup:", output)
        time.sleep(0.2)
        self.assertEqual(smoke.pids_under(Path(report["root"])), [])
        self.assert_cleaned_up(report)

    def test_the_clone_parent_stays_as_chromiums_helper_leaves_it(self):
        # The parent is where each launch of this bundle id makes its clone, and this removal holds no lock that
        # such a launch waits for: a parent that goes in the moment that another launch makes its clone there
        # breaks that launch. Chromium's own helper leaves the (empty) parent too.
        self.clone_helper = "stays"
        env = {**self.env, "CMUX_FRESH_SMOKE_CLONE_HELPER_WAIT_SECONDS": "0.5"}
        status, output, report = self.run_smoke("healthy", "--seconds", "0", "--startup-timeout", "10", env=env)
        self.assertEqual(status, smoke.PASS, output)
        self.assertEqual(list(report["clone_cleanup"]["clones"].values()), ["removed by this tool"])
        self.assertEqual(self.clones_left(), [], output)
        self.assertEqual(sorted(path.name for path in self.clones.iterdir()), [f"{BUNDLE}.code_sign_clone"], output)

    def test_a_clone_that_no_helper_names_is_never_removed(self):
        # The suffix is a read of the launch's own helper. Without it the tool cannot know which folder is this
        # launch's: it removes none (never the newest, never the whole parent) and says so.
        self.clone_helper = "no-suffix"
        env = {**self.env, "CMUX_FRESH_SMOKE_CLONE_HELPER_WAIT_SECONDS": "0.5"}
        status, output, report = self.run_smoke("healthy", "--seconds", "0", "--startup-timeout", "10", env=env)
        self.assertEqual(status, smoke.PASS, output)
        self.assertEqual(len(self.clones_left()), 1, output)
        told = report["clone_cleanup"]
        self.assertEqual((told["helpers"], told["helper_ended"], told["clones"]), (1, False, {}), told)
        self.assertIn("no clone is removed here", told["clones_not_known"])
        time.sleep(0.2)
        self.assertEqual(smoke.pids_under(Path(report["root"])), [])

    def cut_at(self, mode: str, helper: str, line: str, *args: str, count: int = 1,
               within: float = 60.0) -> tuple[str, dict]:
        """A run on a stub of MODE, with a helper bound of 600 s, that gets SIGTERM when its log has COUNT lines
        that start with LINE, as the gate's watchdog cuts a run that takes too long. The line must show in WITHIN
        seconds, and the run must end in 60 s after the cut."""
        app, out = make_app(self.dir / "run-1", mode), self.dir / "out-cut"
        (app / "Contents" / "Resources" / "clone").write_text(json.dumps(
            {"dir": str(self.clones), "bundle": BUNDLE, "helper": helper}))
        env = {**self.env, "CMUX_FRESH_SMOKE_CLONE_HELPER_WAIT_SECONDS": "600"}
        harness = subprocess.Popen([sys.executable, str(SCRIPT), "--app", str(app), "--out", str(out),
                                    "--startup-timeout", "10", *args],
                                   env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        read: queue.Queue = queue.Queue()

        def reader() -> None:
            for text in harness.stdout:
                read.put(text)
            read.put(None)

        thread = threading.Thread(target=reader, daemon=True)
        thread.start()
        lines, cut, deadline = [], False, time.monotonic() + within
        try:
            while True:
                try:
                    text = read.get(timeout=max(0.0, deadline - time.monotonic()))
                except queue.Empty:
                    # The line did not show, or the run did not end after the cut: SIGTERM, so that the run
                    # stops its own processes and removes its root, then the assertions below say which it was.
                    harness.terminate()
                    break
                if text is None:
                    break
                lines.append(text)
                if not cut and sum(seen.startswith(line) for seen in lines) == count:
                    harness.terminate()
                    cut, deadline = True, time.monotonic() + 60
            status = harness.wait(timeout=60)
        finally:
            if harness.poll() is None:
                harness.kill()
            thread.join(timeout=10)
            harness.stdout.close()
        while not read.empty():
            lines.append(read.get() or "")
        output = "".join(lines)
        self.assertTrue(cut, f"the run's log had no {count} line(s) {line!r} in {within:.0f} s\n{output}")
        self.assertEqual(status, 128 + signal.SIGTERM, output)
        report = json.loads((out / "report.json").read_text())
        time.sleep(0.2)
        self.assertEqual(smoke.pids_under(Path(report["root"])), [], output)
        self.assert_cleaned_up(report)
        return output, report

    def cut_at_home(self, helper: str, *args: str, homes: int = 1) -> tuple[str, dict]:
        """cut_at for a healthy stub, when its launch number HOMES shows Home."""
        return self.cut_at("healthy", helper, "ok: Home rendered", *args, count=homes)

    def assert_cut_in_the_helpers_wait(self, report: dict, output: str) -> None:
        """The run was cut before a launch's clone cleanup ended: the report has the cleanup of the run's end,
        which did not wait, stopped the helper and removed the launch's clone."""
        self.assertEqual(self.clones_left(), [], output)
        self.assertNotIn("clone_cleanup", report)
        told = report["clone_cleanup_at_end"]
        self.assertEqual((told["helpers"], told["helper_ended"], told["wait"]), (1, False, 0.0), told)
        self.assertEqual(list(told["clones"].values()), ["removed by this tool"])

    def test_a_failed_launch_that_is_cut_while_its_helper_is_awaited_keeps_its_verdict(self):
        # The verdict is in the report and in the log BEFORE the helper gets its time: the gate's watchdog that
        # cuts a run in that wait must read "fail" (a crash holds the nightly), never a run with no verdict
        # (cannot-run, which holds nothing).
        output, report = self.cut_at("first-report", "stays", "FAIL:", "--seconds", "0", within=20)
        self.assertEqual((report["verdict"], report["failures"]),
                         ("fail", ["crash report: stub-2026-11-11-000000.ips"]), output)
        self.assert_cut_in_the_helpers_wait(report, output)

    def test_a_passed_launch_that_is_cut_while_its_helper_is_awaited_keeps_its_verdict(self):
        output, report = self.cut_at("healthy", "stays", "==> fresh-home launch smoke OK", "--seconds", "0",
                                     within=20)
        self.assertEqual(report["verdict"], "pass", output)
        self.assert_cut_in_the_helpers_wait(report, output)

    def test_a_failed_seeded_launch_that_is_cut_while_its_helper_is_awaited_keeps_its_verdict(self):
        # The first launch's helper ends by itself; the seeded launch's never does.
        output, report = self.cut_at("own-report", "seeded-stays", "FAIL:", "--seconds", "0",
                                     "--arms", "empty,seeded", "--seeded-seconds", "0", within=30)
        self.assertEqual((report["verdict"], report["arm"]), ("fail", "seeded"), output)
        self.assertEqual(report["failures"], ["seeded home: crash report: stub-2026-11-11-000000.ips"], output)
        self.assertEqual(report["arms"]["seeded"]["verdict"], "fail")
        self.assertTrue(report["arms"]["empty"]["clone_cleanup"]["helper_ended"], report["arms"]["empty"])
        self.assertNotIn("clone_cleanup", report["arms"]["seeded"])
        self.assert_cut_in_the_helpers_wait(report, output)

    def test_a_run_that_is_cut_does_not_wait_for_the_helper_and_removes_its_launchs_clone(self):
        # The gate's watchdog sends SIGTERM to a run that takes too long: its end must not take the helper's bound.
        output, report = self.cut_at_home("stays", "--seconds", "60")
        self.assertEqual(self.clones_left(), [], output)
        # No launch of this run ended, so the report has the cleanup of the run's end and no launch's.
        self.assertNotIn("clone_cleanup", report)
        told = report["clone_cleanup_at_end"]
        self.assertEqual((told["helpers"], told["helper_ended"], told["wait"]), (1, False, 0.0), told)
        self.assertEqual(list(told["clones"].values()), ["removed by this tool"])

    def test_a_run_that_is_cut_in_its_seeded_launch_does_not_wait_for_the_helper(self):
        # The first launch's helper ends by itself; the seeded launch's never does, and the bound is 600 s.
        output, report = self.cut_at_home("seeded-stays", "--seconds", "0", "--arms", "empty,seeded",
                                          "--seeded-seconds", "60", homes=2)
        self.assertEqual(len(list(self.clones.glob("done-*"))), 1, output)
        self.assertEqual(self.clones_left(), [], output)
        self.assertTrue(report["clone_cleanup"]["helper_ended"], report["clone_cleanup"])
        told = report["clone_cleanup_at_end"]
        self.assertEqual((told["helpers"], told["helper_ended"], told["wait"]), (1, False, 0.0), told)
        self.assertEqual(list(told["clones"].values()), ["removed by this tool"])

    def test_a_report_that_lands_while_the_helper_is_awaited_changes_no_verdict(self):
        # The app "crashes while it quits", and its report lands 4 s after its end. A launch that stayed up gets
        # one look for its crash reports, at once after its processes were stopped: this launch passes. The wait
        # for the helper comes after that look, never before it: a later look would make this pass a fail, and
        # two failed attempts hold a nightly.
        self.clone_helper = "stays"
        env = {**self.env, "CMUX_FRESH_SMOKE_CLONE_HELPER_WAIT_SECONDS": "6"}
        status, output, report = self.run_smoke("late-quit-report", "--seconds", "0", "--startup-timeout", "10",
                                                env=env)
        self.assertEqual(status, smoke.PASS, output)
        self.assertEqual(report["crash_reports"], [])
        told = report["clone_cleanup"]
        self.assertEqual((told["helpers"], told["helper_ended"]), (1, False), told)
        # The report did land while the run waited for the helper.
        self.assertGreaterEqual(told["helper_seconds"], 6.0, told)
        self.assertTrue((self.dir / "diagnostics" / "stub-2026-11-11-000000.ips").exists(), output)
        self.assert_cleaned_up(report)

    def test_a_report_that_lands_while_the_seeded_launchs_helper_is_awaited_changes_no_verdict(self):
        # The same in the seeded home: the first launch's helper ends by itself, the seeded launch's stays for
        # its bound of 6 s, and the seeded app's quit report lands 4 s after its end.
        self.clone_helper = "seeded-stays"
        env = {**self.env, "CMUX_FRESH_SMOKE_CLONE_HELPER_WAIT_SECONDS": "6"}
        status, output, report = self.run_smoke("late-quit-report", "--seconds", "0", "--startup-timeout", "10",
                                                "--arms", "empty,seeded", "--seeded-seconds", "0", env=env)
        self.assertEqual(status, smoke.PASS, output)
        seeded = report["arms"]["seeded"]
        self.assertEqual((seeded["verdict"], seeded["crash_reports"]), ("pass", []), output)
        told = seeded["clone_cleanup"]
        self.assertEqual((told["helpers"], told["helper_ended"]), (1, False), told)
        self.assertGreaterEqual(told["helper_seconds"], 6.0, told)
        self.assert_cleaned_up(report)

    def test_a_clone_that_its_helper_left_is_removed_and_the_log_says_so(self):
        self.clone_helper = "leaves"
        status, output, report = self.run_smoke("healthy", "--seconds", "0", "--startup-timeout", "10")
        self.assertEqual(status, smoke.PASS, output)
        self.assertEqual(self.clones_left(), [], output)
        told = report["clone_cleanup"]
        self.assertEqual((told["helpers"], told["helper_ended"]), (1, True), told)
        self.assertEqual(list(told["clones"].values()), ["removed by this tool"])
        self.assertIn("note: code-sign clone cleanup:", output)
        self.assert_cleaned_up(report)

    def test_a_failed_seeded_launch_has_its_own_clone_cleanup_at_the_reports_top(self):
        self.clone_helper = "ends"
        status, output, report, _ = self.seeded("sync-crash")
        self.assertEqual(status, smoke.FAIL, output)
        self.assertEqual(report["arm"], "seeded")
        self.assertEqual(report["arms"]["empty"]["clone_cleanup"]["helpers"], 1, report["arms"]["empty"])
        # The app aborted in the seeded home: an app that dies by itself starts no cleanup helper.
        self.assertEqual(report["arms"]["seeded"]["clone_cleanup"], {"helpers": 0})
        self.assertEqual(report["clone_cleanup"], {"helpers": 0})

    def test_only_a_plain_folder_of_this_launch_under_the_clone_parent_is_removed(self):
        with tempfile.TemporaryDirectory() as d, mock.patch.dict(os.environ, {"CMUX_FRESH_SMOKE_CLONE_DIR": d}):
            parent = Path(d) / f"{BUNDLE}.code_sign_clone"
            kept = Path(d) / "kept"
            kept.mkdir()
            (kept / "file").write_text("not a clone")
            parent.mkdir()
            # A link in the place of the clone is never followed.
            os.symlink(kept, parent / "code_sign_clone.Link1")
            self.assertTrue(smoke.remove_own_clone(BUNDLE, "Link1").startswith("not removed"))
            self.assertTrue((kept / "file").exists())
            # A suffix or a bundle id that is not a plain name is no path.
            for bundle, suffix in ((BUNDLE, "../kept"), (BUNDLE, ""), (BUNDLE, "a/b"), ("../x", "Ab12"), ("", "Ab12")):
                self.assertTrue(smoke.remove_own_clone(bundle, suffix).startswith("not removed"), (bundle, suffix))
            self.assertTrue((kept / "file").exists())
            self.assertEqual(smoke.remove_own_clone(BUNDLE, "Gone1"), "gone")
            (parent / "code_sign_clone.Ab12" / "Stub.app").mkdir(parents=True)
            self.assertEqual(smoke.remove_own_clone(BUNDLE, "Ab12"), "removed by this tool")
            self.assertEqual(sorted(path.name for path in parent.iterdir()), ["code_sign_clone.Link1"])
            # A link in the place of the clone PARENT is never followed: what it names is outside the clone folder.
            (kept / "code_sign_clone.Ab12").mkdir()
            os.symlink(kept, Path(d) / "com.example.linked.code_sign_clone")
            self.assertTrue(smoke.remove_own_clone("com.example.linked", "Ab12").startswith("not removed"))
            self.assertTrue((kept / "code_sign_clone.Ab12").is_dir())

    def test_the_helpers_suffix_is_read_from_its_own_command_line(self):
        root = self.dir / "run"
        table = [(11, f"{root}/Stub.app/Contents/MacOS/stub -ApplePersistenceIgnoreState YES"),
                 (12, f"{root}/Stub.app/Contents/MacOS/stub --type=code-sign-clone-cleanup "
                      "--unique-temp-dir-suffix=Ab12Cd --wait-for-parent-exit"),
                 (13, f"{root}/Stub.app/Contents/MacOS/stub --type=code-sign-clone-cleanup --wait-for-parent-exit"),
                 (14, f"{self.dir}/other/Stub.app/Contents/MacOS/stub --type=code-sign-clone-cleanup "
                      "--unique-temp-dir-suffix=Zz99"),
                 (15, f"{root}/Stub.app/Contents/MacOS/stub --type=code-sign-clone-cleanup "
                      "--unique-temp-dir-suffix=../../etc"),
                 # Another process type whose name only starts as the helper's.
                 (16, f"{root}/Stub.app/Contents/MacOS/stub --type=code-sign-clone-cleanup-x "
                      "--unique-temp-dir-suffix=Qq11")]
        with mock.patch.object(smoke, "user_processes", return_value=table):
            self.assertEqual(smoke.clone_helpers(root), {12: "Ab12Cd", 13: None, 15: None})

    def test_a_launch_with_no_cleanup_helper_reads_the_process_list_one_time(self):
        # A read is a `ps` of each process of the account (0.27 s on a VM with 470 of them). The run's end had one
        # read before the clone cleanup; a launch with no helper, as each launch of a build without CEF, pays no more.
        with tempfile.TemporaryDirectory() as d, mock.patch.object(smoke, "user_processes", return_value=[]) as read:
            self.assertEqual(smoke.stop_own(Path(d), BUNDLE), {"helpers": 0})
        self.assertEqual(read.call_count, 1)

    def test_a_launch_with_a_cleanup_helper_looks_again_for_what_is_left_after_the_wait(self):
        root = self.dir / "run"
        helper = (12, f"{root}/Stub.app/Contents/MacOS/stub --type=code-sign-clone-cleanup "
                      "--unique-temp-dir-suffix=Ab12Cd --wait-for-parent-exit")
        stopped: list[list[int]] = []
        with tempfile.TemporaryDirectory() as d, mock.patch.dict(os.environ, {"CMUX_FRESH_SMOKE_CLONE_DIR": d}), \
                mock.patch.object(smoke, "user_processes", return_value=[(11, f"{root}/x"), helper]) as read, \
                mock.patch.object(smoke, "stop", side_effect=lambda pids, grace=5.0: stopped.append(list(pids))), \
                mock.patch.object(smoke, "alive", return_value=True):
            told = smoke.stop_own(root, BUNDLE, wait=0.0)
        # The helper is not in the first stop; the second stop, from a new read, takes what is left with it.
        self.assertEqual(stopped, [[11], [11, 12]])
        self.assertEqual(read.call_count, 2)
        self.assertEqual((told["helpers"], told["helper_ended"], told["clones"]), (1, False, {"Ab12Cd": "gone"}))

    def faulty_end(self, environment: dict, reads: list | None = None, helper: bool = True,
                   **patches) -> tuple[dict, list[list[int]]]:
        """stop_own for a run with one process (11) and, when HELPER, one cleanup helper (12, it does not end)
        whose clone is there, with PATCHES of the tool; what it told and what it stopped. READS: the errors that
        the first reads of the process list raise, one each."""
        root = self.dir / "run"
        table = [(11, f"{root}/x")]
        if helper:
            table.append((12, f"{root}/Stub.app/Contents/MacOS/stub --type=code-sign-clone-cleanup "
                              "--unique-temp-dir-suffix=Ab12Cd --wait-for-parent-exit"))
        turns = list(reads or [])

        def read() -> list:
            if turns:
                raise turns.pop(0)
            return table

        stopped: list[list[int]] = []
        with tempfile.TemporaryDirectory() as d, \
                mock.patch.dict(os.environ, {"CMUX_FRESH_SMOKE_CLONE_DIR": d, **environment}), \
                mock.patch.object(smoke, "user_processes", read), \
                mock.patch.object(smoke, "stop", side_effect=lambda pids, grace=5.0: stopped.append(list(pids))), \
                mock.patch.object(smoke, "alive", return_value=True), \
                (mock.patch.multiple(smoke, **patches) if patches else contextlib.nullcontext()):
            if helper:
                (Path(d) / f"{BUNDLE}.code_sign_clone" / "code_sign_clone.Ab12Cd").mkdir(parents=True)
            told = smoke.stop_own(root, BUNDLE)
            self.assertEqual(list(Path(d).glob("*/*")), [], told)
        return told, stopped

    def test_a_fault_that_loses_the_helper_list_still_stops_the_helper_and_removes_its_clone(self):
        # The first read of the process list fails: no helper is known, and the run's other processes may still
        # run. The end reads again, does not wait (the bound here is 5 s) and removes the clone that the helper
        # names.
        told, stopped = self.faulty_end({"CMUX_FRESH_SMOKE_CLONE_HELPER_WAIT_SECONDS": "5"},
                                        reads=[RuntimeError("no list")])
        self.assertIn("RuntimeError", told["error"])
        self.assertEqual(stopped, [[11, 12]])
        self.assertEqual((told["helpers"], told["wait"], told["clones"]),
                         (1, 0.0, {"Ab12Cd": "removed by this tool"}), told)

    def test_a_fault_in_the_first_stop_of_a_launch_with_no_helper_still_stops_what_is_left(self):
        told, stopped = self.faulty_end({}, reads=[RuntimeError("no list")], helper=False)
        self.assertIn("RuntimeError", told["error"])
        self.assertEqual(stopped, [[11]])
        self.assertEqual(told["helpers"], 0)

    def test_a_fault_in_the_last_stop_is_told_and_never_raised(self):
        # The end of a launch runs after the verdict: a fault in it must never be the run's result.
        told, stopped = self.faulty_end({"CMUX_FRESH_SMOKE_CLONE_HELPER_WAIT_SECONDS": "0"},
                                        own_pids=mock.Mock(side_effect=[[11], RuntimeError("no list")]))
        self.assertIn("RuntimeError", told["error"])
        self.assertEqual(stopped, [[11]])
        self.assertEqual((told["helpers"], told["clones"]), (1, {"Ab12Cd": "removed by this tool"}))

    def test_the_helpers_bound_counts_from_the_stop_of_the_launch(self):
        # The look for crash reports and the verdict's evidence come between the stop and this wait: their time
        # is the helper's time too. 100 s after the stop, a bound of 50 s is over.
        root = self.dir / "run"
        state = {"helpers": {12: "Ab12Cd"}, "asked": time.monotonic() - 100}
        with tempfile.TemporaryDirectory() as d, mock.patch.dict(os.environ, {"CMUX_FRESH_SMOKE_CLONE_DIR": d}), \
                mock.patch.object(smoke, "user_processes", return_value=[]), mock.patch.object(smoke, "stop"), \
                mock.patch.object(smoke, "alive", return_value=True), \
                mock.patch.object(smoke.time, "sleep", side_effect=AssertionError("it waited")):
            told = smoke.end_clones(root, BUNDLE, state, wait=50)
        self.assertNotIn("error", told)
        self.assertEqual((told["helper_ended"], told["wait"]), (False, 50))
        self.assertGreaterEqual(told["helper_seconds"], 100)

    def test_a_bound_that_is_no_number_of_seconds_is_no_wait_and_a_valid_report(self):
        root = self.dir / "run"
        for given, used in (("nan", 0.0), ("-5", 0.0), ("inf", 600.0), ("2", 2.0)):
            with self.subTest(given=given), tempfile.TemporaryDirectory() as d, \
                    mock.patch.dict(os.environ, {"CMUX_FRESH_SMOKE_CLONE_DIR": d,
                                                 "CMUX_FRESH_SMOKE_CLONE_HELPER_WAIT_SECONDS": given}), \
                    mock.patch.object(smoke, "user_processes", return_value=[]), mock.patch.object(smoke, "stop"), \
                    mock.patch.object(smoke, "alive", return_value=False):
                told = smoke.end_clones(root, BUNDLE, {"helpers": {12: "Ab12Cd"}, "asked": time.monotonic()})
                self.assertEqual(told["wait"], used, told)
                self.assertNotIn("error", told)
                json.dumps(told, allow_nan=False)

    def test_a_fault_while_the_helper_is_awaited_still_stops_it_and_removes_its_clone(self):
        told, stopped = self.faulty_end({"CMUX_FRESH_SMOKE_CLONE_HELPER_WAIT_SECONDS": "soon"})
        self.assertIn("ValueError", told["error"])
        self.assertEqual(stopped, [[11], [11, 12]])
        self.assertEqual((told["helpers"], told["clones"]), (1, {"Ab12Cd": "removed by this tool"}))

    def test_a_fault_in_the_first_stop_still_stops_each_process_of_the_run(self):
        told, stopped = self.faulty_end({"CMUX_FRESH_SMOKE_CLONE_HELPER_WAIT_SECONDS": "0"},
                                        own_pids=mock.Mock(side_effect=[RuntimeError("no list"), [11, 12]]))
        self.assertIn("RuntimeError", told["error"])
        self.assertEqual(stopped, [[11, 12]])
        self.assertEqual((told["helpers"], told["clones"]), (1, {"Ab12Cd": "removed by this tool"}))

    def test_the_detached_helper_is_stopped_by_the_runs_root(self):
        status, output, report = self.run_smoke("healthy", "--seconds", "0", "--startup-timeout", "10")
        self.assertEqual(status, smoke.PASS, output)
        time.sleep(0.2)
        self.assertEqual(smoke.pids_under(Path(report["root"])), [])

    def test_the_apps_terminal_host_is_stopped_by_its_record(self):
        # cmux#36625: a host's command line never names the run's root, so only its record ties it to the run
        self.host_pid_path = self.dir / "host.pid"
        status, output, report = self.run_smoke("healthy", "--seconds", "0", "--startup-timeout", "10")
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
        status, output, report = self.run_smoke("healthy", "--seconds", "0",
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
