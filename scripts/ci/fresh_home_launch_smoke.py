#!/usr/bin/env python3
"""Fresh-home launch smoke of a signed cmux NEXT app, the nightly-next publish gate.

A NEXT nightly shipped an app that crashed on a first launch (Home's first-run
panel, 4b5c86ed, fixed by 1daea603) while every static check passed. This
launches the exact app the feed would offer as a first install would: an empty
HOME (CFFIXED_USER_HOME too, so Application Support, caches and logs start
empty), no defaults, an empty TMPDIR and none of the runner's environment. It
passes when

  1. the app stays up SECONDS (default 30) after launch, with no crash report
     and no recorded uncaught exception (run.exception), and
  2. the app rendered Home's first-run view: the release control socket's
     snapshot.get shows a visible window with Home's page tab (`home-dock`,
     HomeDock.page: the Chief conversation, whose empty state is the first-run
     panel) selected, and the launch marks the app streams to
     CMUX_NEXT_LAUNCH_MARKS_FD (LaunchMarkSink) include
     first_window_frame_committed. While the first-run Bring your history page
     covers Home, the tab has no selection: the mark
     first_run.history_import_shown stands in, so this path proves the frame
     and that the page opened, not Home's first-run view behind it.

The app keeps its defaults in the account's preferences whatever HOME says
(cfprefsd), so the run holds a per-bundle lock, sets the domain aside
(defaults export, then delete) and puts it back afterwards: the app starts with
no defaults and the account's are as before once the run ends.

A NEXT nightly (2616865988e1, build 4294166855401) also crashed at launch only
for a person whose imported cookies were kept in sync: no check launched with
such a home. `--arms empty,seeded` adds a second launch of the same app copy
from a home this tool makes (seed_cookie_sync_home: made-up data, no person's):
`browser.import.cookieSync` on, the import store's sources.json naming one
Chromium profile whose cookies are kept in sync, and that profile's `Cookies`
database with rows. It passes when the app stays up SEEDED-SECONDS (default 10)
with Home rendered and no crash, and the app's cookie sync saved its baseline
of the seeded store with at least one site (the proof that it opened and read
it). A build whose sync never reads the store (it has none, or its format
moved on) is "not-run" for this arm, and a seed that could not be made is
"cannot-run", said in the log and in report.json's `arms`: never a pass of it,
never a failure, and the first arm's exit code stands. A crash of the seeded
arm fails the run as a crash of the first does. In each arm a crash report
counts only when it is of that launch (not_of_launch); another is kept under
--out's not-counted/. Without --arms only the empty home is launched.

--daemon (the publish gate only): a build with a dead daemon (cmux-tui) shows Home and takes no key. So each
arm asks the app when its watch ends: a daemon failure, or a daemon that is not connected then and
DAEMON_REREAD_SECONDS later, fails the launch (report.json's `daemon_down`). The daemon's socket is the account's,
by session, not the home's (DaemonLauncher.swift runtimeBase): "connected" counts only with a daemon of this
launch's app copy (app_daemons), else the read is not judged and is no pass.

--dmg copies the app out of the DMG (mounted read-only, detached at once);
--app copies it too. Every process the run starts runs from its private root
(/tmp/cmux-fresh-*): cleanup stops the app, then each process of this user
whose command line names that root, and each terminal host whose record under
it names its pid (a host's command line never names the root), by exact PID,
and deletes the root. --out
keeps the evidence: report.json (verdict, launch marks, snapshot), the app's
output, its crash files (run.exception, the .ips) and a screenshot when the
runner may take one (evidence only, never the verdict).

Exit 0: passed. 1: the app crashed, exited or never rendered Home (in either
arm; report.json's `arm` names the one the report describes). 2: usage.
3: the smoke could not run (no app, no GUI session, a signing keychain still
present). A publish gate treats anything but 0 as a failure: a build that was
never launched is never published.
"""
from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import plistlib
import re
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
from collections.abc import Callable
from datetime import datetime, timezone
from pathlib import Path

PASS, FAIL, USAGE, CANNOT_RUN = 0, 1, 2, 3
# A caller that drives the rendered app further (scripts/ci/stable_next_ui_journey.py) sets this to
# journey(process, socket_path, env, app, out, report) -> list of failures. It runs once Home has
# rendered and the app is still up, before the app is stopped; it may quit the app itself.
AFTER_RENDER = None
# A caller's preparation of the fresh home before the app starts: prepare(env) (None for the nightly smoke).
PREPARE_HOME = None
# A caller whose ready state is not Home (scripts/cmux-next/idle_cpu.py: any visible window) sets this to
# ready(snapshot) -> bool; it replaces only the Home-tab check, never the first_window_frame_committed mark.
# None (the nightly smoke): home_rendered, Home's tab selected or covered by the first-run page.
READY = None
RENDER_MARK = "first_window_frame_committed"
HOME_PAGE = "home-dock"
# The app marks this when it opens the first-run Bring your history page over Home. That page is not
# in the topology, so Home's tab has no selection while it shows.
FIRST_RUN_MARK = "first_run.history_import_shown"


# The arms: EMPTY is a first install (the module doc's launch). SEEDED is a home where a person imported a
# Chromium profile's cookies and keeps them in sync (seed_cookie_sync_home), launched from ROOT/SEEDED.
EMPTY, SEEDED = "empty", "seeded"
ARMS = (EMPTY, SEEDED)
# Both arms match a crash report to their launch by the process that it names (not_of_launch), so a caller can
# give the account's real DiagnosticReports folder, which has the reports of every launch on the host.
CRASH_FILTER = "pid"
# The seeded arm's verdict when it launched nothing or the app never read the seeded store.
NOT_RUN = "not-run"
# Where --out keeps the crash reports that an arm found and did not count (the log says why).
NOT_COUNTED = "not-counted"
# The seeded arm's bounds, so both arms fit in one attempt of the publish gate (launch-smoke-gate.sh, 240 s):
# how long Home may take to render in it, and how long after launch the sync may take to read the store. (A
# clone cleanup helper that hangs adds up to CLONE_HELPER_WAIT + 5 s to each arm; these bounds do not count it.)
SEEDED_STARTUP_LIMIT = 45.0
DAEMON_REREAD_SECONDS = 5.0
SEEDED_SCAN_WAIT = 30.0
# Chromium's code-sign clone. At each launch CEF clones the app to
# <the account's X folder>/<bundle id>.code_sign_clone/code_sign_clone.<SUFFIX>/ (about 1 GB), and a helper of the
# app (the program of its Helper app, with `--type=code-sign-clone-cleanup --unique-temp-dir-suffix=<SUFFIX>`)
# removes it about 1 s after the app ends. The X folder is beside the account's temp folder, not under the launch's TMPDIR,
# so the removal of the run's root never takes it. A helper that is stopped with the app leaves the clone until
# reboot (29 GB on cmux18, 2026-11-02; scripts/perf-bench/procs.py has the same wait). CLONE_HELPER_WAIT: how
# long the helper gets after the app's end; it is a bound, the wait ends when the helper does. The helper shows
# only when the app is stopped: an app that crashed or was killed starts none, and its clone stays.
CLONE_CLEANUP = "--type=code-sign-clone-cleanup"
CLONE_SUFFIX = re.compile(r"(?:^|\s)--unique-temp-dir-suffix=([A-Za-z0-9]{1,32})(?=\s|$)")
CLONE_HELPER_WAIT = 15.0
# The seeded source (ImportSourceRecord.sourceKey is BROWSER/PROFILE). The browser is made up, in no row of the
# app's browser table (browser-sources.json): the app has a Keychain item name ("Chrome Safe Storage") only for a
# browser of that table, so it has none to ask for here, whatever a build does with the seeded cookies.
SEED_BROWSER, SEED_PROFILE = "cmuxLaunchSmoke", "Default"
# Made-up sites (RFC 2606 names) and how many cookies each has.
SEED_HOSTS = tuple(f"{sub}example.{tld}" for tld in ("com", "org", "net") for sub in (".", "www.", "app.", "login."))
SEED_COOKIES_PER_HOST = 20
# Seconds from 1601 to 1970: Chromium's cookie times are microseconds since 1601.
CHROMIUM_EPOCH_OFFSET = 11_644_473_600
# Chromium's `Cookies` schema (version 24), the one the app's cookie sync and importer read.
SEED_SCHEMA = """
CREATE TABLE meta(key LONGVARCHAR NOT NULL UNIQUE PRIMARY KEY, value LONGVARCHAR);
INSERT INTO meta VALUES('version', '24');
INSERT INTO meta VALUES('last_compatible_version', '24');
CREATE TABLE cookies(creation_utc INTEGER NOT NULL, host_key TEXT NOT NULL, top_frame_site_key TEXT NOT NULL,
  name TEXT NOT NULL, value TEXT NOT NULL, encrypted_value BLOB NOT NULL, path TEXT NOT NULL,
  expires_utc INTEGER NOT NULL, is_secure INTEGER NOT NULL, is_httponly INTEGER NOT NULL,
  last_access_utc INTEGER NOT NULL, has_expires INTEGER NOT NULL, is_persistent INTEGER NOT NULL,
  priority INTEGER NOT NULL, samesite INTEGER NOT NULL, source_scheme INTEGER NOT NULL,
  source_port INTEGER NOT NULL, last_update_utc INTEGER NOT NULL, source_type INTEGER NOT NULL,
  has_cross_site_ancestor INTEGER NOT NULL);
CREATE UNIQUE INDEX cookies_unique_index ON cookies(host_key, top_frame_site_key, has_cross_site_ancestor,
  name, path, source_scheme, source_port);
"""


class CannotRun(Exception):
    pass


def seed_cookie_sync_home(home: Path, bundle_id: str, now: float | None = None) -> dict:
    """Makes HOME the home of a person who imported a Chromium profile's cookies into the app BUNDLE_ID and keeps
    them in sync, from nothing: every value is made up here, and no browser, profile or keychain is read.

    What the app reads at launch (Packages/macOS/CmuxNext: BrowserImportGate.follow, ImportCookieSync.reconcile,
    then the Rust sync's thread `cmux-cookie-sync`, which copies the database and opens the copy with its SQLite):

      .config/cmux/cmux-next.json                                browser.import.enabled and .cookieSync, both true
      Library/Application Support/BUNDLE_ID/BrowserImport/sources.json
                                                                 one ImportSourceRecord with syncedCookieFile
      Library/Application Support/cmux-launch-smoke/Chromium/Default/Network/Cookies
                                                                 that file: a Chromium cookie store with rows

    The store is not in a browser's own folder, so the app's browser detection finds no browser in this home. No
    baseline is written (BrowserImport/cookie-sync/ stays empty): the sync's first scan then saves its own and
    reports nothing changed, so the app imports nothing and never asks the Keychain for a browser's key. That is
    the app's code of today. SEED_BROWSER holds it for a build that imports at its first scan: with no Keychain
    item name and no cookie reader (CookieImporter.read) it reads no key and saves no baseline, so the arm is
    not-run, never a Keychain dialog on the host. Returns what the run checks afterwards: the source's key, the
    baseline folder, and the hosts and rows written.
    """
    import sqlite3  # here, so a Python without it is this arm's cannot-run only

    settings = home / ".config" / "cmux" / "cmux-next.json"
    settings.parent.mkdir(parents=True, exist_ok=True)
    settings.write_text(json.dumps({"browser": {"import": {"enabled": True, "cookieSync": True}}}, indent=2) + "\n")
    database = (home / "Library" / "Application Support" / "cmux-launch-smoke" / "Chromium" / SEED_PROFILE
                / "Network" / "Cookies")
    database.parent.mkdir(parents=True, exist_ok=True)
    stamp = int(((time.time() if now is None else now) + CHROMIUM_EPOCH_OFFSET) * 1_000_000)
    rows = []
    for host in SEED_HOSTS:
        for index in range(SEED_COOKIES_PER_HOST):
            # As Chrome stores a cookie on macOS: an empty value and a "v10" blob. These bytes are a digest of a
            # made-up label, not a cookie encrypted with any key.
            blob = b"v10" + hashlib.sha256(f"cmux launch smoke {host} {index}".encode()).digest()
            rows.append((stamp + len(rows), host, "", f"smoke_{index}", "", blob, "/", stamp + 30 * 86400 * 1_000_000,
                         1, index % 2, stamp, 1, 1, 1, index % 3 - 1, 2, 443, stamp, 0, 0))
    conn = sqlite3.connect(str(database))
    try:
        conn.executescript(SEED_SCHEMA)
        conn.executemany("INSERT INTO cookies VALUES(" + ",".join("?" * 20) + ")", rows)
        conn.commit()
    finally:
        conn.close()
    store = home / "Library" / "Application Support" / bundle_id / "BrowserImport"
    store.mkdir(parents=True, exist_ok=True)
    profile_id = "5eed0000-0000-4000-8000-00000c00c1e5"  # made up: the cmux browser profile the cookies went to
    record = {"browser": SEED_BROWSER, "profileDirectory": SEED_PROFILE, "displayName": "Launch smoke profile",
              "profileName": "Launch smoke", "proposedProfileID": profile_id, "targetProfileID": profile_id,
              "syncedCookieFile": database.as_uri()}
    (store / "sources.json").write_text(json.dumps([record], sort_keys=True))
    return {"source": f"{SEED_BROWSER}/{SEED_PROFILE}", "state_dir": str(store / "cookie-sync"),
            "hosts": len(SEED_HOSTS), "rows": len(rows)}


def cookie_sync_scanned(seed: dict) -> dict | None:
    """The baseline the app's cookie sync saved of the seeded store (cmux-cookie-sync baseline.rs: one
    `*.fingerprint` JSON per source, written after its first read), as {"hosts": N}; None until it is there.
    It exists only after the sync's thread opened the store's copy with its SQLite and read every row."""
    try:
        files = sorted(Path(seed["state_dir"]).glob("*.fingerprint"))
    except OSError:
        return None
    for path in files:
        try:
            saved = json.loads(path.read_text())
        except (OSError, ValueError):
            continue
        if isinstance(saved, dict) and saved.get("source") == seed["source"] and isinstance(saved.get("hosts"), dict):
            return {"hosts": len(saved["hosts"])}
    return None


def log(message: str) -> None:
    print(message, flush=True)


def signing_keychains_present() -> list[str]:
    """scripts/ci/lib/signing-runtime-guard.sh: bundle code never runs while this job holds a signing keychain."""
    state = os.environ.get("CMUX_SIGNING_KEYCHAIN_STATE_DIR") or (
        os.path.join(os.environ["RUNNER_TEMP"], "cmux-signing-keychain") if os.environ.get("RUNNER_TEMP") else "")
    if not state or not os.path.isdir(state):
        return []
    return sorted(name[:-len(".password")] for name in os.listdir(state) if name.endswith(".password"))


def gui_session_problem() -> str | None:
    """A Mac process outside an Aqua session gets no working window server (CEF hangs the main thread)."""
    if sys.platform != "darwin" or os.environ.get("CMUX_FRESH_SMOKE_SKIP_SESSION_CHECK") == "1":
        return None
    try:
        name = subprocess.run(["launchctl", "managername"], capture_output=True, text=True, timeout=10).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return "launchctl managername did not answer"
    return None if name == "Aqua" else f"this process is in a {name or 'unknown'} session, not Aqua (no GUI)"


def bundle_info(app: Path) -> tuple[str, str]:
    with open(app / "Contents" / "Info.plist", "rb") as handle:
        info = plistlib.load(handle)
    return info["CFBundleIdentifier"], info["CFBundleExecutable"]


def copy_app(source: Path, root: Path) -> Path:
    dest = root / "app" / source.name
    dest.parent.mkdir(exist_ok=True)
    if shutil.which("ditto"):
        subprocess.run(["ditto", str(source), str(dest)], check=True, timeout=600)
    else:
        shutil.copytree(source, dest, symlinks=True)
    return dest


def copy_app_from_dmg(dmg: Path, root: Path) -> Path:
    mount = root / "mnt"
    mount.mkdir()
    try:
        subprocess.run(["hdiutil", "attach", str(dmg), "-nobrowse", "-readonly", "-mountpoint", str(mount)],
                       check=True, stdout=subprocess.DEVNULL, timeout=300)
        apps = sorted(mount.glob("*.app"))
        if not apps:
            raise CannotRun(f"no app in {dmg}")
        return copy_app(apps[0], root)
    finally:
        detach(mount)


def detach(mount: Path) -> None:
    """Detach the image if it is attached (a timed-out attach may still finish), forcing it if needed; never raises."""
    if not os.path.ismount(mount):
        return
    for args in (["hdiutil", "detach", str(mount)], ["hdiutil", "detach", "-force", str(mount)]):
        try:
            if subprocess.run(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=120).returncode == 0:
                return
        except (OSError, subprocess.SubprocessError):
            pass
    log(f"warning: could not detach {mount}")


def fresh_env(root: Path, socket_path: Path, marks_fd: int) -> dict[str, str]:
    """No runner variable reaches the app (no token, no key, no CMUX_* routing): only these."""
    home = root / "h"
    for sub in ("Library/Preferences", "Library/Application Support", "Library/Caches", "Library/Logs"):
        (home / sub).mkdir(parents=True, exist_ok=True)
    (root / "t").mkdir(exist_ok=True)
    user = os.environ.get("USER") or os.environ.get("LOGNAME") or ""
    return {
        "HOME": str(home),
        "CFFIXED_USER_HOME": str(home),
        "TMPDIR": str(root / "t") + "/",
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "USER": user,
        "LOGNAME": user,
        "LANG": "en_US.UTF-8",
        "SHELL": "/bin/zsh",
        "CMUX_NEXT_SOCKET_PATH": str(socket_path),
        "CMUX_NEXT_SOCKET_MODE": "allowAll",
        "CMUX_NEXT_NO_ACTIVATE": "1",
        "CMUX_NEXT_LAUNCH_MARKS_FD": str(marks_fd),
    }


class DefaultsAside:
    """The bundle's defaults domain, set aside for the run under a per-bundle lock and put back after it.

    `defaults export` of a domain that does not exist writes an empty dictionary, so the copy always
    exists and putting it back also removes whatever the app wrote. The copy lives beside the lock,
    outside the run's temp root, so a harness that is killed mid-run (a step timeout) leaves it for the
    next run to put back before it sets anything aside. Any export, delete or import that fails is
    CannotRun: the gate fails closed and the copy stays for the next run."""

    def __init__(self, bundle_id: str, root: Path):
        self.bundle_id = bundle_id
        self.tool = os.environ.get("CMUX_FRESH_SMOKE_DEFAULTS_TOOL") or shutil.which("defaults")
        lock_dir = os.environ.get("CMUX_FRESH_SMOKE_LOCK_DIR") or "/tmp"
        stem = os.path.join(lock_dir, f"cmux-fresh-smoke-{bundle_id}")
        self.lock_path = stem + ".lock"
        self.backup = Path(stem + ".aside.plist")
        self.lock = None

    def defaults(self, *args: str) -> int:
        return subprocess.run([self.tool, *args], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                              timeout=60).returncode

    def holds_keys(self) -> bool:
        """Whether the domain still has any key (cfprefsd answers an emptied domain as {}, exit 0)."""
        probe = self.backup.with_name(self.backup.name + ".probe")
        try:
            if self.defaults("export", self.bundle_id, str(probe)) != 0 or not probe.exists():
                return True  # cannot tell: treat it as not cleared
            try:
                with open(probe, "rb") as handle:
                    return bool(plistlib.load(handle))
            except Exception:
                return True
        finally:
            probe.unlink(missing_ok=True)

    def clear(self) -> None:
        """Delete the domain (it fails when there is nothing to delete) and confirm it holds no key."""
        self.defaults("delete", self.bundle_id)
        if self.holds_keys():
            raise CannotRun(f"could not delete the {self.bundle_id} defaults; the copy stays in {self.backup}")

    def put_back(self) -> None:
        """Restore the copy set aside (this run's, or one a killed run left), then forget it."""
        if not self.backup.exists():
            return
        self.clear()
        if self.defaults("import", self.bundle_id, str(self.backup)) != 0:
            raise CannotRun(f"could not put back the {self.bundle_id} defaults; they stay set aside in {self.backup}")
        self.backup.unlink()

    def __enter__(self):
        if not self.tool:
            log("note: no defaults tool here; the app's defaults are not set aside")
            return self
        self.lock = open(self.lock_path, "a")
        wait = float(os.environ.get("CMUX_FRESH_SMOKE_LOCK_WAIT_SECONDS", 900))
        deadline = time.monotonic() + wait
        while True:
            try:
                fcntl.flock(self.lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    self.lock.close()
                    raise CannotRun(f"another fresh-home smoke of {self.bundle_id} held {self.lock_path} for {wait:.0f}s")
                time.sleep(1)
        try:
            if self.backup.exists():
                log(f"note: putting back the {self.bundle_id} defaults an earlier smoke left set aside")
                self.put_back()
            partial = self.backup.with_name(self.backup.name + ".partial")
            partial.unlink(missing_ok=True)
            if self.defaults("export", self.bundle_id, str(partial)) != 0 or not partial.exists():
                partial.unlink(missing_ok=True)
                raise CannotRun(f"could not export the {self.bundle_id} defaults; nothing was set aside")
            os.replace(partial, self.backup)
            self.clear()  # on failure the copy stays: the delete may have half-run
        except BaseException:
            self.release()
            raise
        return self

    def release(self) -> None:
        if self.lock is not None:
            fcntl.flock(self.lock, fcntl.LOCK_UN)
            self.lock.close()
            self.lock = None

    def __exit__(self, *_exc):
        if not self.tool:
            return False
        try:
            self.put_back()
        finally:
            self.release()
        return False


def snapshot(socket_path: Path, timeout: float = 5.0, request: int = 1) -> dict | None:
    """snapshot.get over the release control socket (newline-delimited JSON), None while it does not answer."""
    if not socket_path.exists():
        return None
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
            sock.settimeout(timeout)
            sock.connect(str(socket_path))
            sock.sendall(b'{"id": %d, "method": "snapshot.get", "params": {}}\n' % request)
            buffer = b""
            while b"\n" not in buffer:
                chunk = sock.recv(1 << 20)
                if not chunk:
                    return None
                buffer += chunk
        reply = json.loads(buffer.split(b"\n", 1)[0])
    except (OSError, ValueError):
        return None
    result = reply.get("result")
    return result if isinstance(result, dict) else None


def app_daemons(app: Path) -> tuple[list[str], list[str]]:
    """This user's app daemons (cmux-tui --headless --session cmux-app...; a Chief's is cmux-chief-...): the
    sessions of those whose program is below APP (this launch's), and the others of such a session (of each app
    session when this launch has none) as "pid N PROGRAM (SESSION)"."""
    own, others = [], []
    for pid, args in user_processes():
        session = re.search(r" --session (cmux-app\S*)", args)
        if session and " --headless" in args:
            if args.startswith((f"{app}/", f"{os.path.realpath(app)}/")):
                own.append(session[1])
            else:
                others.append((session[1], f"pid {pid} {args.partition(' --')[0]} ({session[1]})"))
    return own, [text for session, text in others if not own or session in own]


def daemon_at_end(socket_path: Path, app: Path) -> list[dict]:
    """The app's daemon_state and daemon_failure (snapshot.get topology): one read, and when it is not clean one
    more DAEMON_REREAD_SECONDS later (a reconnect in work). None (no answer, no field) is not judged, as is
    "connected" with no daemon of this launch (`of_launch` False: no pass). Each read is said in the log."""
    reads: list[dict] = []
    for request in (2, 3):
        snap = snapshot(socket_path, request=request)
        topology = (snap or {}).get("topology") or {}
        state = topology.get("daemon_state")
        reads.append({"state": state if isinstance(state, str) else None,
                      "failure": str(topology.get("daemon_failure") or "")[:300] or None})
        if state == "connected" and not app_daemons(app)[0]:
            reads[-1]["of_launch"] = False
        log("daemon: " + ("not judged (not of this launch)" if "of_launch" in reads[-1] else reads[-1]["state"]
                          or f"not judged ({'no field' if snap else 'no answer'})"))
        if request == 3 or (reads[0]["state"] in (None, "connected") and not reads[0]["failure"]):
            break
        time.sleep(float(os.environ.get("CMUX_FRESH_SMOKE_DAEMON_REREAD_SECONDS", DAEMON_REREAD_SECONDS)))
    return reads


def daemon_down(reads: list[dict] | None, app: Path) -> str | None:
    """Why READS fail the launch: the last tells a daemon failure, or both are not connected; with the live app
    daemons of other launches, a possible cause."""
    if reads and reads[-1]["failure"]:
        why = f"the app's daemon (cmux-tui) failed: {reads[-1]['failure']}"
    elif reads and len(reads) == 2 and all(read["state"] not in (None, "connected") for read in reads):
        why = (f"the app's daemon (cmux-tui) was not connected when the watch ended ({reads[0]['state']}) "
               f"and at the next read ({reads[1]['state']})")
    else:
        return None
    own, others = app_daemons(app)
    return (f"{why}; daemons of {' or '.join(sorted(set(own))) or 'an app session'} that are not of this launch: "
            f"{', '.join(others[:3]) or 'none'}")


def visible_windows(snap: dict | None) -> int:
    windows = ((snap or {}).get("topology") or {}).get("windows") or []
    return sum(1 for window in windows if isinstance(window, dict) and window.get("visible"))


def home_tab(snap: dict | None) -> dict | None:
    """Home's page tab, selected in a pane of a workspace a visible window shows; None otherwise."""
    topology = (snap or {}).get("topology") or {}
    shown = {window.get("workspace") for window in topology.get("windows") or []
             if isinstance(window, dict) and window.get("visible")}
    for workspace in topology.get("workspaces") or []:
        if not isinstance(workspace, dict) or workspace.get("id") not in shown:
            continue
        for screen in workspace.get("screens") or []:
            for pane in (screen or {}).get("panes") or []:
                for tab in (pane or {}).get("tabs") or []:
                    if isinstance(tab, dict) and tab.get("page") == HOME_PAGE and tab.get("id") == pane.get("selected_tab"):
                        return tab
    return None


def first_run_home_tab(snap: dict | None) -> dict | None:
    """Home's page tab with nothing selected in its pane, in a workspace a visible window shows; None otherwise.

    This alone does not prove a healthy launch. It counts only with FIRST_RUN_MARK, the app's word that
    its first-run page is what covers Home.
    """
    topology = (snap or {}).get("topology") or {}
    shown = {window.get("workspace") for window in topology.get("windows") or []
             if isinstance(window, dict) and window.get("visible")}
    for workspace in topology.get("workspaces") or []:
        if not isinstance(workspace, dict) or workspace.get("id") not in shown:
            continue
        for screen in workspace.get("screens") or []:
            for pane in (screen or {}).get("panes") or []:
                if (pane or {}).get("selected_tab") is not None:
                    continue
                for tab in (pane or {}).get("tabs") or []:
                    if isinstance(tab, dict) and tab.get("page") == HOME_PAGE:
                        return tab
    return None


def home_rendered(snap: dict | None, marks: dict[str, float]) -> bool:
    """A visible window committed a frame showing Home, or the first-run page the app opened over Home."""
    if RENDER_MARK not in marks:
        return False
    return bool(home_tab(snap)) or (FIRST_RUN_MARK in marks and bool(first_run_home_tab(snap)))


def read_marks(path: Path) -> dict[str, float]:
    marks: dict[str, float] = {}
    try:
        text = path.read_text(errors="replace")
    except OSError:
        return marks
    for line in text.splitlines():
        name, _, ms = line.rpartition(" ")
        try:
            marks.setdefault(name, float(ms))
        except ValueError:
            continue
    return marks


def crash_reports(directory: Path, executable: str, since: float) -> list[Path]:
    if not directory.is_dir():
        return []
    found = []
    for path in directory.iterdir():
        if path.suffix not in (".ips", ".crash") or not path.name.startswith(f"{executable}-"):
            continue
        try:
            if path.stat().st_mtime >= since:
                found.append(path)
        except OSError:
            continue
    return sorted(found)


def crash_report_process(path: Path) -> dict | None:
    """The process a crash report is about: its pid, its parent's pid and its executable's path (each None when
    the report does not say). None when the report names no pid. An .ips is a header line, then a JSON body with
    `pid`, `parentPid` and `procPath`; a .crash has `Process: NAME [PID]`, `Parent Process:` and `Path:` lines."""
    try:
        text = path.read_text(errors="replace")
    except OSError:
        return None
    try:
        body = json.loads(text.partition("\n")[2])
    except ValueError:
        body = None
    if isinstance(body, dict) and isinstance(body.get("pid"), int):
        parent, where = body.get("parentPid"), body.get("procPath")
        return {"pid": body["pid"], "parent": parent if isinstance(parent, int) else None,
                "path": where if isinstance(where, str) and where else None}
    head = text[:8000]
    process = re.search(r"^Process:.*\[(\d+)\]\s*$", head, re.MULTILINE)
    if process is None:
        return None
    parent = re.search(r"^Parent Process:.*\[(\d+)\]\s*$", head, re.MULTILINE)
    where = re.search(r"^Path:\s+(\S.*?)\s*$", head, re.MULTILINE)
    return {"pid": int(process.group(1)), "parent": int(parent.group(1)) if parent else None,
            "path": where.group(1) if where else None}


REPORT_TIME = re.compile(r"(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)(\.\d+)? ([+-]\d{4})")


def report_stamps(path: Path, body_key: str, header_key: str | None, line: str) -> tuple[float, float] | None:
    """A time a crash report gives, as (epoch seconds, how many seconds later it can have been), or None when the
    report does not say: the .ips body's BODY_KEY, else its header's HEADER_KEY (macOS writes that one to the
    whole second, `12:34:56.00`, and it is all there is while the body is not written in full), else a .crash
    file's LINE."""
    try:
        text = path.read_text(errors="replace")
    except OSError:
        return None
    head, _, rest = text.partition("\n")
    stamps: list[tuple[object, float]] = []
    try:
        stamps.append((json.loads(rest).get(body_key), 0.0))
    except (ValueError, AttributeError):
        pass
    if header_key is not None:
        try:
            stamps.append((json.loads(head).get(header_key), 1.0))
        except (ValueError, AttributeError):
            pass
    found = re.search(rf"^{re.escape(line)}\s+(\S.*?)\s*$", text[:8000], re.MULTILINE)
    if found:
        stamps.append((found.group(1), 0.0))
    for stamp, slack in stamps:
        found = REPORT_TIME.fullmatch(stamp) if isinstance(stamp, str) else None
        if found is None:
            continue
        try:
            when = datetime.strptime(f"{found.group(1)} {found.group(3)}", "%Y-%m-%d %H:%M:%S %z").timestamp()
        except ValueError:
            continue
        return when + float(found.group(2) or 0), slack
    return None


def crash_report_time(path: Path) -> tuple[float, float] | None:
    """When the process of a crash report died (report_stamps' form): the .ips body's `captureTime`, else its
    header's `timestamp`, else a .crash file's `Date/Time:` line."""
    return report_stamps(path, "captureTime", "timestamp", "Date/Time:")


def crash_report_launch_time(path: Path) -> float | None:
    """When the process of a crash report was started (epoch seconds), or None when the report does not say: the
    .ips body's `procLaunch`, else a .crash file's `Launch Time:` line."""
    stamp = report_stamps(path, "procLaunch", None, "Launch Time:")
    return None if stamp is None else stamp[0]


NO_PROCESS = "it names no process"
NO_PROCESS_REREAD_SECONDS = 3.0
# How long after a launch's app ENDED its crash report is looked for as evidence, the verdict's wait included. A
# build's first report took macOS more than the verdict's 10 s in 4 of 5 crashes on fleet hosts (2026-11-11).
EVIDENCE_REPORT_WAIT = 30.0


def hidden_path_in(where: str, app: Path) -> bool:
    """WHERE is a path as macOS writes it in a crash report for a program under /tmp (where each run's root is),
    with the folders above the app copy as one `*` (`/tmp/*/NAME.app/Contents/MacOS/NAME`: the real report in
    tests/fixtures/launch-smoke), and what follows the `*` is a file of the app copy APP: the copy's own name,
    then a path inside it. The hidden folders can be those of another run's copy with the same name."""
    for head in ("/tmp/*/", "/private/tmp/*/"):
        if where.startswith(head):
            rest = where[len(head):].split("/")
            return len(rest) > 1 and rest[0] == app.name and ".." not in rest and app.joinpath(*rest[1:]).is_file()
    return False


def not_of_launch(path: Path, pid: int, app: Path, earlier: frozenset[int], started: float | None = None,
                  own: Path | None = None, *, ended: bool = False) -> str | None:
    """Why the crash report at PATH is not of the launch with PID of the app copy APP, or None when it is or can
    be. crash_reports matches by the executable's name and the file's time alone, and ReportCrash writes a report
    some seconds after its process died: so a report of an EARLIER launch of this run (its app crashed while it
    quit, or a helper of it did when its app went away), or of another copy of the app on this host, can land
    while this launch is watched. STARTED is the wall time by which every earlier launch of this run was stopped,
    and before which this launch had no process: a report of a process that died before it is never this
    launch's. That time is the only thing that tells an earlier launch's orphaned helper (its parent is pid 1,
    its path is in the same app copy) from this launch's. After it, a report counts when it names this launch or
    a child of it, or another process of this run's app copy that is not of an earlier launch. macOS hides the
    folders of a path under /tmp (hidden_path_in), so for such a process the full path never matches a real
    report: what is left of the path must be a file of this run's copy, and the report must say that its process
    was started after STARTED (the same name of another run's copy on this host is then the one thing that this
    cannot tell apart; a copy of another build has another name). One that names no
    process (a format this tool does not know, or a report read while macOS writes it) says nothing of whose it
    is: it counts only when this launch's app ENDED in the watched time, as evidence beside that end, and is no
    crash alone. OWN is a folder that only this launch writes
    (its part of the run's private root, with its HOME): a process whose program is there is of this launch too,
    as a detached daemon that the app put in its home is."""
    died = crash_report_time(path) if started is not None else None
    if died is not None and died[0] + died[1] < started:
        return (f"its process died at {datetime.fromtimestamp(died[0], timezone.utc):%H:%M:%S}Z, "
                f"{started - died[0]:.1f}s before this launch started")
    # Nor is one of a process that was started before it: every process of this launch starts after STARTED. This
    # does not depend on when macOS takes the time of death, and it also covers a process of an earlier launch
    # that the run did not find and stop.
    born = crash_report_launch_time(path) if started is not None else None
    if born is not None and born < started:
        return (f"its process was started at {datetime.fromtimestamp(born, timezone.utc):%H:%M:%S}Z, "
                f"{started - born:.1f}s before this launch started")
    who = crash_report_process(path)
    if who is None:
        return None if ended else f"{NO_PROCESS}, and this launch's app did not end"
    if pid in (who["pid"], who["parent"]):
        return None
    if who["pid"] in earlier or who["parent"] in earlier:
        return f"it is of pid {who['pid']}, this run's earlier launch"
    if who["path"] is None:
        return f"it is of pid {who['pid']}, not this launch (pid {pid}), and names no path"
    try:
        real = os.path.realpath(who["path"])
        if any(real.startswith(os.path.realpath(tree) + os.sep) for tree in (app, own) if tree is not None):
            return None
        hidden = hidden_path_in(who["path"], app)
    except (OSError, ValueError) as error:  # a name too long for a file, a NUL
        return f"it is of pid {who['pid']}, and its path cannot be read ({type(error).__name__})"
    if hidden:
        if born is not None:  # and not before STARTED: that report was refused above
            return None
        return (f"it is of pid {who['pid']} at {who['path']}: the folder of that path is hidden, and "
                + ("the report does not say when its process was started" if started is not None
                   else "no start time of this launch was given"))
    return (f"it is of pid {who['pid']} at {who['path']}, not this run's copy of the app"
            + ("" if own is None else " and not this launch's files"))


def user_processes() -> list[tuple[int, str]]:
    """(pid, command line) of this user's other processes."""
    try:
        out = subprocess.run(["ps", "-ww", "-o", "pid=", "-o", "args=", "-U", str(os.getuid())],
                             capture_output=True, text=True, timeout=30).stdout
    except (OSError, subprocess.SubprocessError):
        return []
    pairs = [line.strip().partition(" ") for line in out.splitlines()]
    return [(int(pid), args.strip()) for pid, _, args in pairs if pid.isdigit() and int(pid) != os.getpid()]


def pids_under(root: Path, processes: list[tuple[int, str]] | None = None) -> list[int]:
    """This user's processes whose command line names the run's private root, never by name. PROCESSES: a
    user_processes read that the caller made already."""
    real = os.path.realpath(root)
    listed = user_processes() if processes is None else processes
    return [pid for pid, args in listed if f"{root}/" in args or f"{real}/" in args]


# Where a cmux NEXT terminal host records itself under the run's HOME: <id>.json names its host_pid. A build from
# before NEXT's own folder (cmux-next/) kept its tag state under classic's cmux/tags/.
HOST_RECORDS = ("h/Library/Application Support/cmux-next/tags/*/tui/terminal-hosts-*/*.json",
                "h/Library/Application Support/cmux/tags/*/tui/terminal-hosts-*/*.json")


def terminal_host_pids(root: Path) -> list[int]:
    """The terminal hosts this run's app started, by the host_pid their records under ROOT name. A host's command
    line is `cmux-tui __terminal-host ...`, which never names the root, so pids_under misses it, and it outlives
    the app on purpose (cmux#36625: 17 of them ran for days on a CI Mac). A recorded pid counts only while it
    still runs as a __terminal-host of this user, so a reused pid is never stopped."""
    pids = []
    for record in sorted(r for pattern in HOST_RECORDS for r in root.glob(pattern)):
        try:
            pid = json.loads(record.read_text()).get("host_pid")
        except (OSError, ValueError, AttributeError):
            continue
        if not isinstance(pid, int) or pid <= 1 or pid == os.getpid() or pid in pids:
            continue
        try:
            # Only this pid: BSD ps adds selections together, so `-p PID -U UID` would list every process of the user.
            lines = subprocess.run(["ps", "-ww", "-o", "uid=,args=", "-p", str(pid)],
                                   capture_output=True, text=True, timeout=30).stdout.splitlines()
        except (OSError, subprocess.SubprocessError):
            continue
        fields = lines[0].split(None, 1) if len(lines) == 1 else []
        if (len(fields) == 2 and fields[0] == str(os.getuid())
                and re.search(r"(?:^|\s)__terminal-host(?:\s|$)", fields[1])):
            pids.append(pid)
    return pids


def own_pids(root: Path, processes: list[tuple[int, str]] | None = None) -> list[int]:
    """Everything this run started that may still run: processes naming its root, and its terminal hosts (those
    of the seeded arm too, whose home is under ROOT/SEEDED). PROCESSES as pids_under."""
    return sorted(set(pids_under(root, processes)) | set(terminal_host_pids(root))
                  | set(terminal_host_pids(root / SEEDED)))


def alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except OSError:
        return False
    return True


def stop_child(process: subprocess.Popen, grace: float = 5.0) -> None:
    """The app this run started: SIGTERM, reaped within GRACE, else SIGKILL."""
    if process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=grace)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=grace)


def stop(pids: list[int], grace: float = 5.0) -> None:
    for pid in pids:
        try:
            os.kill(pid, signal.SIGTERM)
        except OSError:
            pass
    deadline = time.monotonic() + grace
    while time.monotonic() < deadline and any(alive(pid) for pid in pids):
        time.sleep(0.1)
    for pid in pids:
        if alive(pid):
            try:
                os.kill(pid, signal.SIGKILL)
            except OSError:
                pass


def clone_helpers(root: Path, processes: list[tuple[int, str]] | None = None) -> dict[int, str | None]:
    """This run's code-sign clone cleanup helpers that run now: pid -> the clone suffix that its command line
    names (None when it names none). A helper is found as every process of the run is: its command line names
    the run's private root (the app copy's path). PROCESSES as pids_under."""
    real = os.path.realpath(root)
    found: dict[int, str | None] = {}
    for pid, args in (user_processes() if processes is None else processes):
        if (f"{root}/" in args or f"{real}/" in args) and CLONE_CLEANUP in args.split():
            named = CLONE_SUFFIX.search(args)
            found[pid] = named.group(1) if named else None
    return found


def clone_folder() -> Path | None:
    """The account's X folder, where Chromium keeps each bundle id's code-sign clones: beside the account's temp
    folder (/var/folders/../../T -> ../X), whatever TMPDIR says. None when it cannot be read."""
    given = os.environ.get("CMUX_FRESH_SMOKE_CLONE_DIR")
    if given:
        return Path(given)
    try:
        temp = os.confstr(65537).rstrip("/")  # _CS_DARWIN_USER_TEMP_DIR, what `getconf DARWIN_USER_TEMP_DIR` says
    except (AttributeError, OSError, ValueError):
        return None
    if not temp.startswith("/") or not temp.endswith("/T"):
        return None
    return Path(temp[:-1] + "X")


def remove_own_clone(bundle_id: str, suffix: str) -> str:
    """Removes the clone of ONE launch, <X>/<bundle id>.code_sign_clone/code_sign_clone.<suffix>, and never its
    parent. SUFFIX is what the launch's own helper named: never a guess and never the newest folder, because the
    parent also holds the clone of each other live launch of this bundle id (two runs of one build on one
    host). Returns what was done, for the report."""
    folder = clone_folder()
    if folder is None:
        return "not removed: the account's clone folder is not known"
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", bundle_id or "") or not re.fullmatch(r"[A-Za-z0-9]{1,32}", suffix):
        return "not removed: the bundle id or the suffix is not a plain name"
    parent = folder / f"{bundle_id}.code_sign_clone"
    clone = parent / f"code_sign_clone.{suffix}"
    if not os.path.lexists(clone):
        return "gone"
    # One absolute path, of this launch alone: a real folder (no link) right under this bundle id's clone parent.
    if (not clone.is_absolute() or clone.is_symlink() or parent.is_symlink() or not clone.is_dir()
            or os.path.realpath(clone) != os.path.join(os.path.realpath(folder), parent.name, clone.name)):
        return "not removed: the clone's path is not a plain folder under the clone parent"
    shutil.rmtree(clone, ignore_errors=True)
    if os.path.lexists(clone):
        return "not removed: the removal failed"
    # The parent stays, as Chromium's helper leaves it: another launch of this bundle id can make its clone there
    # in this moment, and this removal holds no lock that such a launch waits for.
    return "removed by this tool"


def stop_but_helpers(root: Path) -> dict:
    """The first part of a launch's end, after the app's: stops every process of the run that still runs but
    its code-sign clone cleanup helpers (CLONE_CLEANUP), from one read of the process list. Returns what
    end_clones needs: the helpers (pid -> the suffix that it names), when this ended, and a fault if one came."""
    state: dict = {"helpers": {}}
    try:
        processes = user_processes()
        state["helpers"] = clone_helpers(root, processes)
        stop([pid for pid in own_pids(root, processes) if pid not in state["helpers"]])
    except Exception as error:  # noqa: BLE001 - end_clones then stops all, and the verdict is not of this
        state["error"] = f"{type(error).__name__}: {error}"[:300]
    state["asked"] = time.monotonic()
    return state


def end_clones(root: Path, bundle_id: str | None, state: dict, wait: float | None = None) -> dict:
    """The second part, the last thing of a launch: after the look for its crash reports (that look is no later
    than it was without a helper) and after its verdict is in the report and the log (a run that is cut in here
    keeps it). The helpers of STATE get until WAIT seconds (CLONE_HELPER_WAIT) after the first part to remove
    the launch's clone and end by themselves, then what is left of the run is stopped from a new read. A clone
    that its helper named and did not remove is removed here. Returns what was seen, for the report; a fault in
    here is told there and never raised."""
    helpers = state["helpers"]
    facts: dict = {"helpers": len(helpers), **({"error": state["error"]} if "error" in state else {})}

    def fault(error: Exception) -> None:
        facts["error"] = f"{type(error).__name__}: {error}"[:300]

    try:
        if "error" in state:
            # The first part did not end: other processes of the run may still run, and the helpers may not be
            # known. No wait, and the helpers from a new read.
            wait, helpers = 0.0, helpers or clone_helpers(root)
            facts["helpers"] = len(helpers)
        if helpers:
            if wait is None:
                wait = float(os.environ.get("CMUX_FRESH_SMOKE_CLONE_HELPER_WAIT_SECONDS", CLONE_HELPER_WAIT))
            wait = min(wait, 600.0) if wait > 0 else 0.0  # "nan" also: no wait, and a number that JSON has
            while time.monotonic() - state["asked"] < wait and any(alive(pid) for pid in helpers):
                time.sleep(0.1)
            facts.update(helper_ended=not any(alive(pid) for pid in helpers),
                         helper_seconds=round(time.monotonic() - state["asked"], 1), wait=wait)
    except Exception as error:  # noqa: BLE001 - the stop below must run
        fault(error)
    try:
        if helpers or "error" in facts:
            stop(own_pids(root))
    except Exception as error:  # noqa: BLE001 - the removal below must run
        fault(error)
    try:
        if helpers:
            suffixes = sorted({suffix for suffix in helpers.values() if suffix})
            facts["clones"] = {suffix: remove_own_clone(bundle_id or "", suffix) for suffix in suffixes}
            if not suffixes:
                facts["clones_not_known"] = "the helper's command line named no suffix; no clone is removed here"
            if not (facts.get("helper_ended") and suffixes and set(facts["clones"].values()) == {"gone"}):
                log(f"note: code-sign clone cleanup: {json.dumps(facts, sort_keys=True)}")
    except Exception as error:  # noqa: BLE001 - told, never raised
        fault(error)
    return facts


def stop_own(root: Path, bundle_id: str | None, wait: float | None = None) -> dict:
    """Both parts at once: the end of a run, where no look for crash reports follows."""
    return end_clones(root, bundle_id, stop_but_helpers(root), wait)


def end_launch(process: subprocess.Popen, root: Path) -> dict:
    """The end of one launch, first part: the app, then the run's other processes (stop_but_helpers)."""
    stop_child(process)
    return stop_but_helpers(root)


def system_log_errors(pid: int, since: float, limit: int = 40) -> list[str]:
    """The app's error and fault lines in the unified log (where AppKit reports an assertion), best effort."""
    if sys.platform != "darwin" or not os.path.exists("/usr/bin/log"):
        return []
    start = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(since))
    try:
        out = subprocess.run(["/usr/bin/log", "show", "--style", "compact", "--start", start, "--predicate",
                              f"processID == {int(pid)} AND (messageType == error OR messageType == fault)"],
                             capture_output=True, text=True, timeout=90).stdout
    except (OSError, subprocess.SubprocessError):
        return []
    lines = [line[:400] for line in out.splitlines() if f"[{pid}:" in line and "com.apple.network" not in line]
    keyed = [line for line in lines if "Assertion failure" in line or "xception" in line]
    return (keyed or lines)[:limit]


def screenshot(out: Path) -> str | None:
    if shutil.which("screencapture") is None:
        return None
    path = out / "fresh-home.png"
    try:
        ok = subprocess.run(["screencapture", "-x", str(path)], stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL, timeout=20).returncode == 0
    except (OSError, subprocess.SubprocessError):
        ok = False
    return str(path) if ok and path.exists() else None


def watch(process: subprocess.Popen, marks_fd: int, marks_path: Path, socket_path: Path,
          seconds: float, startup_timeout: float, seed: dict | None = None, scan_wait: float = 0.0,
          daemon: bool = False) -> dict:
    """Until SECONDS have passed with Home rendered (or STARTUP_TIMEOUT without it), or the app exits.

    SEED (the seeded arm): the callers' READY does not apply, and once Home rendered the watch also goes on until
    the app's cookie sync saved its baseline of the seeded store, at most SCAN_WAIT seconds after launch.

    DAEMON: with Home rendered and the app up, daemon_at_end; not with a caller's READY, which is not Home."""
    os.set_blocking(marks_fd, False)
    started = time.monotonic()
    snap, rendered_at, status, scan, scanned_at = None, None, None, None, None
    ready = READY if seed is None else None
    with open(marks_path, "ab") as marks:
        while True:
            try:
                chunk = os.read(marks_fd, 1 << 16)
                if chunk:
                    marks.write(chunk)
                    marks.flush()
            except (BlockingIOError, OSError):
                pass
            elapsed = time.monotonic() - started
            status = process.poll()
            if status is not None:
                break
            if rendered_at is None:
                snap = snapshot(socket_path) or snap
                seen = read_marks(marks_path)
                shown = ready(snap) and RENDER_MARK in seen if ready is not None else home_rendered(snap, seen)
                if shown:
                    rendered_at = elapsed
                    log(f"ok: Home rendered in a visible window {elapsed:.1f}s after launch")
            if seed is not None and scan is None:
                scan = cookie_sync_scanned(seed)
                if scan is not None:
                    scanned_at = elapsed
                    log(f"ok: the cookie sync read the seeded store ({scan['hosts']} sites) {elapsed:.1f}s after launch")
            if elapsed >= seconds and (rendered_at is not None or elapsed >= startup_timeout):
                # A seeded arm with Home up waits for the scan; without Home it ends as the first arm does.
                if seed is None or scan is not None or rendered_at is None or elapsed >= scan_wait:
                    break
            time.sleep(0.25)
    reads, app = None, Path(process.args[0]).parents[2]  # the launch's app copy
    if daemon and status is None and rendered_at is not None and ready is None:
        reads = daemon_at_end(socket_path, app)
        status = process.poll()
    seen = {"snapshot": snap, "rendered_at": rendered_at, "exit": status, "daemon": reads,
            "daemon_down": daemon_down(reads, app), "seconds_up": round(time.monotonic() - started, 1)}
    if seed is not None:
        seen["cookie_sync"] = {**seed, "scanned_at": scanned_at, "scanned_hosts": (scan or {}).get("hosts")}
    return seen


def explain(pid: int, launched_wall: float, app_log: Path, crashes: list[Path], exceptions: list[Path],
            failures: list[str], report: dict) -> None:
    """A failed launch's evidence in the log: the app's errors in the system log, its exception and crash reports,
    the end of its output, then each failure."""
    errors = system_log_errors(pid, launched_wall)
    if errors:
        report["system_log_errors"] = errors
        log("--- the app's errors in the system log (an uncaught exception or assertion names itself here)\n"
            + "\n".join(errors))
    for path in exceptions:
        log(f"--- {path.name}\n{path.read_text(errors='replace')[:4000]}")
    for path in crashes:
        log(f"--- {path.name} (first 6000 bytes)\n{path.read_text(errors='replace')[:6000]}")
    tail = [line for line in app_log.read_text(errors="replace").splitlines() if not line.startswith("objc[")]
    log("--- app output (last 60 lines)\n" + "\n".join(tail[-60:]))
    for failure in failures:
        log(f"FAIL: {failure}")


def awaited_crash_reports(diagnostics: Path, executable: str, since: float, exited: bool,
                          skip: Callable[[Path], str | None] | None = None) -> list[Path]:
    """The app's crash reports since SINCE. ReportCrash writes the .ips a few seconds after the process died, so
    an app that EXITED is given that long. SKIP, when given, says why a report does not count (None: it does)."""
    def look() -> list[Path]:
        found = crash_reports(diagnostics, executable, since)
        return found if skip is None else [path for path in found if skip(path) is None]

    wait = float(os.environ.get("CMUX_FRESH_SMOKE_CRASH_REPORT_WAIT_SECONDS", 10))
    deadline = time.monotonic() + (wait if exited else 0)
    crashes = look()
    while not crashes and time.monotonic() < deadline:
        time.sleep(1)
        crashes = look()
    return crashes


def launch_crash_reports(diagnostics: Path, executable: str, since: float, exited: bool, pid: int, app: Path,
                         earlier: frozenset[int], started: float, own: Path) -> tuple[list[Path], dict[Path, str]]:
    """The crash reports of the launch with PID of the app copy APP, whose own files are under OWN
    (awaited_crash_reports), and the reports that the name and the file's time matched but that are not its, each
    with why (not_of_launch)."""
    try:
        return reports_of_launch(diagnostics, executable, since, exited, pid, app, earlier, started, own)
    except Exception as error:  # noqa: BLE001
        if not exited:
            raise
        # The app ENDED: that is the verdict, with no report. A cannot-run here would let a crashed build pass.
        log(f"warning: this launch's crash reports could not be read: {type(error).__name__}: {error}")
        return [], {}


def reports_of_launch(diagnostics: Path, executable: str, since: float, exited: bool, pid: int, app: Path,
                      earlier: frozenset[int], started: float, own: Path) -> tuple[list[Path], dict[Path, str]]:
    not_counted: dict[Path, str] = {}

    def skip(found: Path) -> str | None:
        why = not_of_launch(found, pid, app, earlier, started, own, ended=exited)
        if why is None:
            not_counted.pop(found, None)
        else:
            not_counted[found] = why
        return why

    crashes = awaited_crash_reports(diagnostics, executable, since, exited, skip)
    # A report that was read while macOS wrote it names its process a moment later: read again until each
    # report names one (or counts), for NO_PROCESS_REREAD_SECONDS at most (one of a format without a pid never does).
    deadline = time.monotonic() + NO_PROCESS_REREAD_SECONDS
    while (not crashes and time.monotonic() < deadline
           and any(why.startswith(NO_PROCESS) for why in not_counted.values())):
        time.sleep(0.5)
        crashes = awaited_crash_reports(diagnostics, executable, since, False, skip)
    return crashes, {found: not_counted[found] for found in sorted(not_counted) if found not in crashes}


def late_crash_reports(diagnostics: Path, executable: str, since: float, pid: int, app: Path, earlier: frozenset[int],
                       started: float, own: Path, asked: float, out: Path | None) -> list[str]:
    """EVIDENCE ONLY, for a launch that failed because its app ENDED and that had no crash report in the verdict's
    wait: the reports that name this launch (not_of_launch; one that names no process yet is read again), looked
    for once, then until EVIDENCE_REPORT_WAIT seconds after ASKED (the monotonic time at which the verdict's wait
    began), kept in OUT and shown. A caller runs this LAST, after the verdict is in the report and the failure is
    in the log (a watchdog can cut the run here), so the time the log read took is not added. What is found is in
    no field that a caller reads for a verdict."""
    deadline = asked + float(os.environ.get("CMUX_FRESH_SMOKE_CRASH_EVIDENCE_WAIT_SECONDS", EVIDENCE_REPORT_WAIT))
    while True:
        found = [path for path in crash_reports(diagnostics, executable, since)
                 if not_of_launch(path, pid, app, earlier, started, own) is None]
        if found or time.monotonic() >= deadline:
            break
        time.sleep(1)
    for path in found:
        if out is not None:
            shutil.copyfile(path, out / path.name)
        log(f"--- {path.name} (first 6000 bytes)\n{path.read_text(errors='replace')[:6000]}")
    return [str(path) for path in found]


def keep_not_counted(out: Path, others: list[Path]) -> None:
    """Reports that were found and not counted, kept under OUT/not-counted: not beside the counted ones, where a
    caller shows each report as this run's crash. The folder gets OUT's mode, so the account that made OUT (a CI
    runner, when the launch runs as the console user) can remove it."""
    for found in others:
        folder = out / NOT_COUNTED
        if not folder.is_dir():
            folder.mkdir()
            folder.chmod(out.stat().st_mode & 0o777)
        shutil.copyfile(found, folder / found.name)


def launch_seeded(args: argparse.Namespace, root: Path, launch: dict, arm: dict, seen: dict,
                  failed: Callable[[], None]) -> None:
    """Launches the app copy once more, from the home seed_cookie_sync_home makes under ROOT/SEEDED, and puts
    the arm's verdict in ARM (what report.json's `arms` keeps) and what the watch saw in SEEN. FAILED is called
    when the arm's verdict is a failure, before its evidence is waited for."""
    app, bundle_id, executable = launch["app"], launch["bundle_id"], launch["executable"]
    sub = root / SEEDED
    sub.mkdir()
    socket_path, marks_path = sub / "s.sock", sub / "marks"
    with DefaultsAside(bundle_id, sub):
        marks_read, marks_write = os.pipe()
        try:
            try:
                env = fresh_env(sub, socket_path, marks_write)
                seed = seed_cookie_sync_home(Path(env["HOME"]), bundle_id)
                log(f"==> seeded-home launch of {bundle_id}: cookie sync on, {seed['rows']} made-up cookies of "
                    f"{seed['hosts']} sites, HOME={env['HOME']}, {args.seeded_seconds:.0f}s")
                launched_wall = time.time() - 1
                with open(sub / "app.log", "wb") as app_log:
                    process = subprocess.Popen([str(app / "Contents" / "MacOS" / executable),
                                                "-ApplePersistenceIgnoreState", "YES"],
                                               env=env, cwd=env["HOME"], stdin=subprocess.DEVNULL, stdout=app_log,
                                               stderr=subprocess.STDOUT, pass_fds=(marks_write,),
                                               start_new_session=True)
            finally:
                os.close(marks_write)
            arm["pid"] = process.pid
            try:
                startup = min(max(args.seeded_seconds, args.startup_timeout), SEEDED_STARTUP_LIMIT)
                scan_wait = float(os.environ.get("CMUX_FRESH_SMOKE_SEEDED_SCAN_WAIT_SECONDS", SEEDED_SCAN_WAIT))
                seen.update(watch(process, marks_read, marks_path, socket_path, args.seeded_seconds, startup,
                                  seed=seed, scan_wait=max(args.seeded_seconds, scan_wait), daemon=args.daemon))
            finally:
                ended = end_launch(process, root)
        finally:
            os.close(marks_read)
    seen["marks"] = read_marks(marks_path)
    seen["home_tab"] = home_tab(seen["snapshot"])
    status, elapsed = seen["exit"], seen["seconds_up"]

    # Only this launch's crash reports count here: the first arm's processes were stopped a moment ago, and a
    # report of one (a crash while it quit) would otherwise make this arm a crash of a healthy app. The first arm
    # gave the defaults lock back, so another run of a copy with this name can have launched since: this launch
    # had no process before LAUNCHED_WALL either.
    asked, began = time.monotonic(), max(launch["earlier_stopped"], launched_wall)
    crashes, not_counted = launch_crash_reports(launch["diagnostics"], executable, launched_wall, status is not None,
                                                process.pid, app, launch["earlier"], began, sub)
    others = list(not_counted)
    for found in others:
        log(f"note: crash report {found.name} is not counted for the seeded launch: {not_counted[found]}")
    exceptions = sorted((sub / "h").rglob("run.exception"))
    seen["crash_reports"] = [str(path) for path in crashes]
    seen["run_exceptions"] = [str(path) for path in exceptions]
    arm["crash_reports_not_counted"] = [str(path) for path in others]
    failures = []
    if status is not None:
        how = f"signal {-status}" if status < 0 else f"status {status}"
        failures.append(f"the app exited ({how}) {elapsed:.1f}s after launch")
    if crashes:
        failures.append(f"crash report: {', '.join(found.name for found in crashes)}")
    if exceptions:
        failures.append("the app recorded an uncaught exception (run.exception)")
    if seen["rendered_at"] is None and status is None:
        failures.append(f"Home did not render within {elapsed:.0f}s (visible windows {visible_windows(seen['snapshot'])}, "
                        f"{RENDER_MARK} {'seen' if RENDER_MARK in seen['marks'] else 'missing'})")
    if seen["daemon_down"]:
        failures.append(seen["daemon_down"])
    arm.update({key: seen[key] for key in ("exit", "seconds_up", "rendered_at", "crash_reports", "run_exceptions",
                                           "cookie_sync", "daemon", "daemon_down")})
    arm["crash_reports_late"] = seen["crash_reports_late"] = []
    if failures:
        seen["failures"] = [f"seeded home: {failure}" for failure in failures]
        arm.update(verdict="fail", failures=seen["failures"])
        failed()
    elif seen["cookie_sync"]["scanned_at"] is None:
        arm.update(verdict=NOT_RUN, reason=f"the app stayed up {elapsed:.0f}s with Home rendered, but its cookie sync "
                   "did not read the seeded store (a build with no cookie sync, one whose import store this tool "
                   "does not make, or one that imports cookies at its first scan: the seed's browser cannot be "
                   "imported)")
    elif not seen["cookie_sync"]["scanned_hosts"]:
        # A baseline of no site: the sync opened the store and kept none of its rows, so this was not a launch
        # with "a cookie store with rows".
        arm.update(verdict=NOT_RUN, reason=f"the app stayed up {elapsed:.0f}s with Home rendered, but its cookie sync "
                   "did not read the seeded store's rows (it saved a baseline of no site: the seed's format moved on)")
    else:
        arm["verdict"] = "pass"
    # The verdict stands before the evidence is kept: a copy or a log read that fails must not undo a crash.
    try:
        if launch["out"] is not None:
            for found in [*crashes, *exceptions]:
                shutil.copyfile(found, launch["out"] / found.name)
            keep_not_counted(launch["out"], others)
        if failures:
            explain(process.pid, launched_wall, sub / "app.log", crashes, exceptions, seen["failures"], seen)
        if status is not None and not crashes:
            arm["crash_reports_late"] = seen["crash_reports_late"] = late_crash_reports(
                launch["diagnostics"], executable, launched_wall, process.pid, app, launch["earlier"], began, sub,
                asked, launch["out"])
    except Exception as error:  # noqa: BLE001 - evidence only
        log(f"warning: the seeded launch's evidence is not complete: {type(error).__name__}: {error}")
        for failure in seen.get("failures", []):
            log(f"FAIL: {failure}")
    # Last, with the verdict told: a run that is cut while the clone helper has its time keeps the verdict.
    seen["clone_cleanup"] = arm["clone_cleanup"] = end_clones(root, bundle_id, ended)


def run_seeded(args: argparse.Namespace, root: Path, report: dict, launch: dict, status: int) -> int:
    """The second arm, after the first ended with STATUS. Returns the run's exit code: 1 when the app crashed,
    exited or never rendered Home from the seeded home (the report then describes that launch, `arm` says so, and
    the first arm's stays in `arms`); otherwise STATUS, whatever this arm could or could not do."""
    arm: dict = {"verdict": NOT_RUN}
    first = {key: report[key] for key in ("verdict", "exit", "seconds_up", "rendered_at", "failures", "clone_cleanup")
             if key in report}
    report["arm"], report["arms"] = EMPTY, {EMPTY: first, SEEDED: arm}
    if status != PASS:
        arm["reason"] = "the first arm did not pass"
        log(f"==> seeded-home arm NOT RUN: {arm['reason']}")
        return status
    started, seen = time.monotonic(), {}
    # The first arm stopped its app and every process of its run before it returned, so none of them died later
    # than now, and the seeded launch has no process yet.
    launch["earlier"], launch["earlier_stopped"] = frozenset({report["pid"]}), time.time()

    def failed() -> None:
        """The report describes the seeded launch: at its verdict, so that a run cut in the evidence has it."""
        for key in ("exit", "seconds_up", "rendered_at", "snapshot", "marks", "home_tab", "crash_reports",
                    "crash_reports_late", "run_exceptions", "failures", "system_log_errors", "cookie_sync",
                    "daemon", "daemon_down", "clone_cleanup"):
            report.pop(key, None)
            if key in seen:
                report[key] = seen[key]
        report.update(pid=arm["pid"], verdict="fail", arm=SEEDED,
                      crash_reports_not_counted=arm.get("crash_reports_not_counted", []))

    try:
        launch_seeded(args, root, launch, arm, seen, failed)
    except Exception as error:  # noqa: BLE001 - whatever stops this arm short of a verdict never fails the run
        if arm["verdict"] != "fail":  # a failure that the arm found stands, whatever its evidence then did
            arm.update(verdict="cannot-run", reason=f"{type(error).__name__}: {error}"[:500])
    arm["wall_seconds"] = round(time.monotonic() - started, 1)
    if arm["verdict"] == "pass":
        log(f"==> seeded-home arm OK: up {arm['seconds_up']:.0f}s, Home at {arm['rendered_at']:.1f}s, the cookie sync "
            f"read the store at {arm['cookie_sync']['scanned_at']:.1f}s, no crash ({arm['wall_seconds']:.0f}s in all)")
        return status
    if arm["verdict"] != "fail":
        log(f"==> seeded-home arm {'NOT RUN' if arm['verdict'] == NOT_RUN else 'CANNOT RUN'}: {arm['reason']}; "
            "the first arm's verdict stands")
        return status
    failed()  # again: with what the evidence added
    return FAIL


def run(args: argparse.Namespace, root: Path, report: dict, launch: dict | None = None) -> int:
    """The first arm. LAUNCH, when given, receives what a second arm needs to launch the same app copy."""
    present = signing_keychains_present()
    if present:
        raise CannotRun(f"a CI signing keychain is still present ({' '.join(present)}); bundle code never runs beside it")
    problem = gui_session_problem()
    if problem:
        raise CannotRun(problem)
    source = Path(args.dmg or args.app)
    if not source.exists():
        raise CannotRun(f"{source} does not exist")
    app = copy_app_from_dmg(source, root) if args.dmg else copy_app(source, root)
    if not (app / "Contents" / "Info.plist").is_file():
        raise CannotRun(f"no app bundle at {app}")
    bundle_id, executable = bundle_info(app)
    report.update(bundle_id=bundle_id, executable=executable)
    out = Path(args.out) if args.out else None
    socket_path, marks_path = root / "s.sock", root / "marks"
    diagnostics = Path(os.environ.get("CMUX_FRESH_SMOKE_DIAGNOSTIC_DIR")
                       or os.path.expanduser("~/Library/Logs/DiagnosticReports"))
    if launch is not None:
        launch.update(app=app, bundle_id=bundle_id, executable=executable, diagnostics=diagnostics, out=out)
    with DefaultsAside(bundle_id, root):
        marks_read, marks_write = os.pipe()
        env = fresh_env(root, socket_path, marks_write)
        if PREPARE_HOME is not None:
            PREPARE_HOME(env)
        log(f"==> fresh-home launch of {bundle_id} ({app}), HOME={env['HOME']}, {args.seconds:.0f}s")
        launched_wall = time.time() - 1
        with open(root / "app.log", "wb") as app_log:
            process = subprocess.Popen([str(app / "Contents" / "MacOS" / executable), "-ApplePersistenceIgnoreState", "YES"],
                                       env=env, cwd=env["HOME"], stdin=subprocess.DEVNULL, stdout=app_log,
                                       stderr=subprocess.STDOUT, pass_fds=(marks_write,), start_new_session=True)
        report["pid"] = process.pid
        os.close(marks_write)
        try:
            seen = watch(process, marks_read, marks_path, socket_path, args.seconds,
                         max(args.seconds, args.startup_timeout), daemon=args.daemon)
        finally:
            os.close(marks_read)
        report.update(seen)
        report["marks"] = read_marks(marks_path)
        report["home_tab"] = home_tab(seen["snapshot"])
        if out is not None and seen["exit"] is None:
            report["screenshot"] = screenshot(out)
        journey_failures = []
        if AFTER_RENDER is not None and seen["exit"] is None and seen["rendered_at"] is not None:
            journey_failures = list(AFTER_RENDER(process, socket_path, env, app, out, report) or [])
        ended = end_launch(process, root)
    # Only this launch's crash reports count. The name and the file's time also match a crash of ANOTHER launch
    # on this host in the same seconds: every fleet build's executable has one name, so another tagged build that
    # crashed there made a healthy launch a crash. The report says whose it is (not_of_launch).
    # ROOT: while this arm runs, all that is under the run's private root is this launch's.
    asked = time.monotonic()
    crashes, not_counted = launch_crash_reports(diagnostics, executable, launched_wall, seen["exit"] is not None,
                                                process.pid, app, frozenset(), launched_wall, root)
    for found, why in not_counted.items():
        log(f"note: crash report {found.name} is not counted for this launch: {why}")
    exceptions = sorted((root / "h").rglob("run.exception"))
    report["crash_reports"] = [str(path) for path in crashes]
    report["crash_reports_not_counted"] = [str(path) for path in not_counted]
    report["run_exceptions"] = [str(path) for path in exceptions]
    if out is not None:
        for path in [*crashes, *exceptions]:
            shutil.copyfile(path, out / path.name)
        try:
            keep_not_counted(out, list(not_counted))
        except OSError as error:  # evidence only: never the verdict
            log(f"warning: a crash report that was not counted could not be kept: {error}")
    failures = list(journey_failures)
    status, elapsed = seen["exit"], seen["seconds_up"]
    if status is not None:
        how = f"signal {-status}" if status < 0 else f"status {status}"
        failures.append(f"the app exited ({how}) {elapsed:.1f}s after launch")
    if crashes:
        failures.append(f"crash report: {', '.join(path.name for path in crashes)}")
    if exceptions:
        failures.append("the app recorded an uncaught exception (run.exception)")
    if seen["rendered_at"] is None and status is None:
        failures.append(f"Home did not render within {elapsed:.0f}s (visible windows {visible_windows(seen['snapshot'])}, "
                        f"Home tab {'selected' if report['home_tab'] else 'not selected'}, "
                        f"{RENDER_MARK} {'seen' if RENDER_MARK in report['marks'] else 'missing'}, "
                        f"{FIRST_RUN_MARK} {'seen' if FIRST_RUN_MARK in report['marks'] else 'missing'})")
    if seen["daemon_down"]:
        failures.append(seen["daemon_down"])
    if not failures:
        report["verdict"] = "pass"
        log(f"==> fresh-home launch smoke OK: up {elapsed:.0f}s, Home at {seen['rendered_at']:.1f}s, no crash")
        # Last, with the verdict told: a run that is cut while the clone helper has its time keeps the verdict.
        report["clone_cleanup"] = end_clones(root, bundle_id, ended)
        return PASS
    # The verdict stands before the evidence is kept: a run that is cut in the log read or the wait below keeps it.
    report.update(verdict="fail", failures=failures, crash_reports_late=[])
    try:
        explain(report["pid"], launched_wall, root / "app.log", crashes, exceptions, failures, report)
        if status is not None and not crashes:
            report["crash_reports_late"] = late_crash_reports(diagnostics, executable, launched_wall, process.pid, app,
                                                              frozenset(), launched_wall, root, asked, out)
    except Exception as error:  # noqa: BLE001 - evidence only: never the verdict
        log(f"warning: this launch's evidence is not complete: {type(error).__name__}: {error}")
        for failure in failures:
            log(f"FAIL: {failure}")
    report["clone_cleanup"] = end_clones(root, bundle_id, ended)
    return FAIL


def arms_asked(value: str) -> tuple[str, ...]:
    names = tuple(name.strip() for name in value.split(",") if name.strip())
    if not names or names[0] != EMPTY or len(set(names)) != len(names) or any(name not in ARMS for name in names):
        raise argparse.ArgumentTypeError(f"--arms is {EMPTY} or {EMPTY},{SEEDED}")
    return names


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--app")
    source.add_argument("--dmg")
    parser.add_argument("--seconds", type=float, default=30.0, help="how long the app must stay up")
    parser.add_argument("--startup-timeout", type=float, default=90.0, help="how long Home may take to render")
    parser.add_argument("--out")
    parser.add_argument("--arms", type=arms_asked, default=(EMPTY,),
                        help=f"{EMPTY} (the default), or {EMPTY},{SEEDED}: then also a launch from a home whose "
                             "imported cookies are kept in sync")
    parser.add_argument("--seeded-seconds", type=float, default=10.0,
                        help="how long the app must stay up in the seeded arm")
    parser.add_argument("--daemon", action="store_true",
                        help="also fail a launch whose daemon is not connected when the watch ends")
    args = parser.parse_args(argv)
    # Evidence stays readable by the runner account when this runs as the console user (a sudo hop).
    os.umask(0o022)
    if args.out:
        os.makedirs(args.out, exist_ok=True)
    # A short root: the socket path must fit sun_path (104 bytes).
    root = Path(tempfile.mkdtemp(prefix="cmux-fresh-", dir="/tmp"))
    report: dict = {"root": str(root)}

    def interrupted(signum, _frame):
        raise SystemExit(128 + signum)

    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    status = CANNOT_RUN
    launch: dict = {}
    try:
        try:
            status = run(args, root, report, launch)
        except (CannotRun, OSError, subprocess.SubprocessError) as error:
            log(f"CANNOT RUN: {error}")
            report.update(verdict="cannot-run", failures=[str(error)])
            status = CANNOT_RUN
        if SEEDED in args.arms:
            status = run_seeded(args, root, report, launch, status)
    finally:
        seeded_pid = ((report.get("arms") or {}).get(SEEDED) or {}).get("pid")
        for pid in (report.get("pid"), seeded_pid):
            if pid:
                stop([pid])
        # Nothing runs here after a launch that ended (end_clones). After a cut or a fault between a launch's two
        # parts: no wait, and the launch's clone goes by its helper's suffix.
        at_end = stop_own(root, report.get("bundle_id"), wait=0.0)
        if at_end != {"helpers": 0}:
            report["clone_cleanup_at_end"] = at_end
        if args.out:
            # app.log is the launch the report describes; the other arm's is beside it under its arm's name.
            logs = {EMPTY: root / "app.log", SEEDED: root / SEEDED / "app.log"}
            told = report.get("arm", EMPTY)
            for name, app_log in logs.items():
                if app_log.exists():
                    shutil.copyfile(app_log, Path(args.out) / ("app.log" if name == told else f"app-{name}.log"))
            with open(Path(args.out) / "report.json", "w", encoding="utf-8") as handle:
                json.dump(report, handle, indent=2, sort_keys=True)
        left = own_pids(root)
        if left:
            log(f"warning: processes still under {root}: {left}")
        shutil.rmtree(root, ignore_errors=True)
    return status


if __name__ == "__main__":
    sys.exit(main())
