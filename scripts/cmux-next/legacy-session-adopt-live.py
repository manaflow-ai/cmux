#!/usr/bin/env python3
"""Behavior test: an untagged channel build adopts the old shared `cmux-app` session once (cx-r650e).

Before cx-6so.41 an untagged NIGHTLY, RC or staging build ran daemon session `cmux-app` in
cmux-tui's default state root. Since then it runs `cmux-app-<channel>` in
`cmux/tags/<channel>/tui`, so its first launch after the update opened an empty session. The app
now adopts `cmux-app` in place when the old session has workspaces and its own is untouched
(DaemonLauncher.appNames, LegacyChannelSession).

Run inside `nx-remote --needs gui --app-from-fleet cmux --tag T --ref SHA` on cmux-lawrence-2
(never on a person's Mac). It stages a copy of `$NX_APP` as the staging channel build
(`com.cmuxterm.app.staging`, the same code path as NIGHTLY and a bundle no person runs there),
signed ad hoc, and runs it with a scratch HOME, so the old layout lives only under the job:

  adopt  an old-layout state: a running `cmux-app` daemon in the default root with workspaces
         legacy-1..3 and its launch snapshot, and no `cmux-app-staging` state. Launch: the app
         must show legacy-1..3 (its daemon is the old one) and record the adopt marker. Relaunch:
         still the old session, and the last layout is drawn at once from its snapshot.
  keep   the same old layout, but the channel's own session was used (a workspace own-1).
         Launch: the app must show own-1 and not the legacy workspaces; no marker.
  late   a person who already opened a post-split build once (no remembered old snapshot, so
         that launch starts the own session with its New Tab page). Next launch with the
         remembered snapshot: the old session is adopted.

Every daemon it starts it stops with the bundled `cmux-tui server stop --end-terminals`; the app
quits through its control socket (`action.run quitKeepSessions`); only processes it started are
waited on. Exit 0 when every check passes.
"""
import glob
import json
import os
import plistlib
import select
import shutil
import socket
import subprocess
import sys
import tempfile
import time

BUNDLE_ID = "com.cmuxterm.app.staging"
CHANNEL = "staging"
CONTROL_SOCKET = "/tmp/cmux-staging.sock"
LEGACY = ["legacy-1", "legacy-2", "legacy-3"]


class Client:
    def __init__(self, path, timeout=20):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(timeout)
        self.sock.connect(path)
        self.buffer = b""
        self.next_id = 1

    def call(self, method, params=None, daemon=False):
        request_id = self.next_id
        self.next_id += 1
        body = {"id": request_id, **({"cmd": method, **(params or {})} if daemon else {"method": method, "params": params or {}})}
        self.sock.sendall((json.dumps(body) + "\n").encode())
        while True:
            while b"\n" not in self.buffer:
                chunk = self.sock.recv(1 << 20)
                if not chunk:
                    raise ConnectionError("socket closed")
                self.buffer += chunk
            line, self.buffer = self.buffer.split(b"\n", 1)
            message = json.loads(line)
            if message.get("id") == request_id:
                return message

    def close(self):
        self.sock.close()


def bounded(check, timeout, what):
    """Waits for a file or socket state the app or daemon makes (no event names it)."""
    deadline = time.monotonic() + timeout
    while True:
        value = check()
        if value:
            return value
        if time.monotonic() > deadline:
            raise SystemExit(f"timed out after {timeout:.0f} s: {what}")
        time.sleep(0.25)


class Stage:
    def __init__(self, root):
        source = os.environ["NX_APP"]
        self.app = os.path.join(root, "cmux STAGING.app")
        # The copy is made inside the source bundle: skip that stage folder itself.
        shutil.copytree(source, self.app, symlinks=True,
                        ignore=lambda folder, names: [n for n in names if n.startswith("legacy-adopt-")])
        info = os.path.join(self.app, "Contents/Info.plist")
        with open(info, "rb") as handle:
            plist = plistlib.load(handle)
        plist["CFBundleIdentifier"] = BUNDLE_ID
        plist.get("LSEnvironment", {}).pop("CMUX_TAG", None)
        with open(info, "wb") as handle:
            plistlib.dump(plist, handle)
        subprocess.run(["codesign", "--force", "--deep", "--sign", "-", self.app], check=True, capture_output=True)
        self.binary = os.path.join(self.app, "Contents/MacOS/cmux DEV")
        self.tui = os.path.join(self.app, "Contents/Resources/bin/cmux-tui")
        self.temp = subprocess.run(["getconf", "DARWIN_USER_TEMP_DIR"], capture_output=True, text=True).stdout.strip()


class Home:
    """A scratch HOME holding one scenario's old and new layouts."""

    def __init__(self, stage, root, name):
        self.stage = stage
        self.home = os.path.join(root, name)
        self.support = os.path.join(self.home, "Library/Application Support")
        os.makedirs(self.support)
        self.started = []  # (session, state dir or None)

    def env(self, state_dir=None):
        env = dict(os.environ)
        # CFFIXED_USER_HOME: Foundation's home (Application Support, preferences) follows it, not HOME.
        env.update({"HOME": self.home, "CFFIXED_USER_HOME": self.home, "TMPDIR": self.stage.temp})
        env.pop("XDG_RUNTIME_DIR", None)
        env.pop("CMUX_TUI_STATE_DIR", None)
        if state_dir:
            env["CMUX_TUI_STATE_DIR"] = state_dir
        return env

    def tui(self, session, state_dir, *args):
        out = subprocess.run([self.stage.tui, "--session", session, "--json", *args], env=self.env(state_dir),
                             capture_output=True, text=True, timeout=90)
        lines = [line for line in out.stdout.splitlines() if line.startswith("{")]
        return out.returncode, (json.loads(lines[-1]) if lines else {}), out.stderr.strip()

    def daemon(self, session, state_dir, names):
        """Starts `session` with workspaces `names` and waits for its launch snapshot to list them."""
        code, result, error = self.tui(session, state_dir, "server", "ensure")
        if code != 0 or not result.get("socket"):
            raise SystemExit(f"server ensure {session} failed (exit {code}): {error[-400:]}")
        self.started.append((session, state_dir))
        client = Client(result["socket"])
        for name in names:
            created = client.call("new-workspace", {"name": name}, daemon=True)
            if not created.get("ok"):
                raise SystemExit(f"new-workspace {name}: {created}")
        client.close()
        root = state_dir or os.path.join(self.support, "cmux-tui/sessions")

        def snapshot_lists_all():
            for path in glob.glob(os.path.join(root, f"{session}-*", "launch-snapshot.json")):
                try:
                    with open(path) as handle:
                        listed = {w.get("name") for w in json.load(handle)["tree"]["workspaces"]}
                except (OSError, ValueError, KeyError):
                    continue
                if set(names) <= listed:
                    return path
            return None
        return bounded(snapshot_lists_all, 60, f"{session} launch snapshot with {names}")

    def stop_all(self):
        """Stops every daemon of this HOME, the app's own channel session included."""
        own = (f"cmux-app-{CHANNEL}", os.path.join(self.support, f"cmux/tags/{CHANNEL}/tui"))
        failed = []
        for session, state_dir in reversed(self.started + ([] if own in self.started else [own])):
            code, result, error = self.tui(session, state_dir, "server", "stop", "--end-terminals")
            print(f"  stop {session}: exit {code} {result.get('status')} {error[-200:]}")
            if code != 0 and "not running" not in (error + json.dumps(result)).lower() and "no server" not in error.lower():
                failed.append(session)
        self.started = []
        acpmux = os.path.join(self.stage.app, "Contents/Resources/bin/acpmux")
        for acpmux_home in glob.glob(os.path.join(self.home, ".acpmux/builds/*")) + glob.glob(os.path.join(self.home, ".acpmux")):
            env = self.env()
            env["ACPMUX_HOME"] = acpmux_home
            out = subprocess.run([acpmux, "daemon", "shutdown"], env=env, capture_output=True, text=True, timeout=20)
            print(f"  acpmux daemon shutdown {acpmux_home}: exit {out.returncode}")
        if failed:
            raise SystemExit(f"could not stop {failed}; refusing to run the next scenario on a live daemon")

    def marker(self):
        return os.path.join(self.support, f"cmux/tags/{CHANNEL}/legacy-session-adopted")


class App:
    def __init__(self, home, legacy_snapshot=None):
        read_fd, write_fd = os.pipe()
        env = home.env()
        env.update({"CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation", "CMUX_NEXT_TEST_WINDOW_SCREEN": "last",
                    "CMUX_NEXT_CONFIG_FILE": os.path.join(home.home, "cmux.json"), "CMUX_NEXT_LAUNCH_MARKS_FD": str(write_fd)})
        with open(env["CMUX_NEXT_CONFIG_FILE"], "w") as config:
            config.write("{}\n")
        # The old NIGHTLY's own defaults named its snapshot; an argument-domain value stands in (no write).
        arguments = ["-cmuxNext.launchSnapshotPath.cmux-app", legacy_snapshot] if legacy_snapshot else []
        self.process = subprocess.Popen([home.stage.binary, *arguments], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                        start_new_session=True, pass_fds=(write_fd,))
        os.close(write_fd)
        self.read_fd, self.buffer, self.marks, self.home = read_fd, b"", {}, home

    def wait_mark(self, name, timeout):
        deadline = time.monotonic() + timeout
        while name not in self.marks:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([self.read_fd], [], [], remaining)[0]:
                return False
            chunk = os.read(self.read_fd, 65536)
            if not chunk:
                return False
            self.buffer += chunk
            *lines, self.buffer = self.buffer.split(b"\n")
            for line in lines:
                mark, _, ms = line.decode().partition(" ")
                if mark and ms:
                    self.marks.setdefault(mark, float(ms))
        return True

    def workspace_names(self):
        # The kept name (/tmp/cmux-staging.sock), or the same name under the scratch HOME's state dir.
        candidates = [CONTROL_SOCKET, os.path.join(self.home.home, ".local/state/cmux/cmux-staging.sock")]
        client = bounded(lambda: next(filter(None, map(_try_client, candidates)), None), 30,
                         f"the app's control socket ({candidates}; app alive: {self.process.poll() is None}; marks: {sorted(self.marks)[:12]})")
        try:
            topology = (client.call("snapshot.get").get("result") or {}).get("topology") or {}
        finally:
            client.close()
        return {w.get("name") for w in topology.get("workspaces", [])}

    def quit(self):
        try:
            client = next(filter(None, map(_try_client, [CONTROL_SOCKET, os.path.join(self.home.home, ".local/state/cmux/cmux-staging.sock")])), None)
            if client:
                client.call("action.run", {"id": "quitKeepSessions"})
                client.close()
            self.process.wait(timeout=45)
        except subprocess.TimeoutExpired:
            self.process.kill()  # the pid this script started, only
            self.process.wait(timeout=15)
        finally:
            os.close(self.read_fd)


def _try_client(path):
    try:
        return Client(path)
    except OSError:
        return None


def adopt(stage, root, failures):
    home = Home(stage, root, "adopt")
    try:
        legacy = home.daemon("cmux-app", None, LEGACY)
        app = App(home, legacy)
        try:
            if not app.wait_mark("daemon_snapshot_loaded", 60):
                failures.append("adopt: the app never loaded a live tree")
            names = app.workspace_names()
        finally:
            app.quit()
        print(f"  adopt launch 1: workspaces {sorted(n for n in names if n)}")
        if not set(LEGACY) <= names:
            failures.append(f"adopt: the old session's workspaces are not shown ({sorted(n for n in names if n)})")
        if not os.path.exists(home.marker()):
            failures.append("adopt: no adopt marker recorded")
        if glob.glob(os.path.join(home.support, f"cmux/tags/{CHANNEL}/tui/cmux-app-{CHANNEL}-*")):
            failures.append(f"adopt: a cmux-app-{CHANNEL} session was started anyway")
        app = App(home, legacy)
        try:
            snapshot_drawn = app.wait_mark("launch_snapshot_shown", 30)
            app.wait_mark("daemon_snapshot_loaded", 60)
            names = app.workspace_names()
        finally:
            app.quit()
        print(f"  adopt launch 2: workspaces {sorted(n for n in names if n)}, last layout drawn at once: {snapshot_drawn}")
        if not set(LEGACY) <= names:
            failures.append("adopt: the relaunch left the old session")
        if not snapshot_drawn:
            failures.append("adopt: the relaunch did not draw the last layout at once")
    finally:
        home.stop_all()


def keep(stage, root, failures):
    home = Home(stage, root, "keep")
    try:
        legacy = home.daemon("cmux-app", None, LEGACY)
        own_state = os.path.join(home.support, f"cmux/tags/{CHANNEL}/tui")
        os.makedirs(own_state)
        own = home.daemon(f"cmux-app-{CHANNEL}", own_state, ["own-1"])
        with open(own) as handle:
            tree = json.load(handle)["tree"]
        print(f"  keep: own state {sorted(os.listdir(own_state))}; own snapshot workspaces "
              f"{[(w.get('name'), w.get('kind'), [t.get('kind') for s in w.get('screens', []) for p in s.get('panes', []) for t in p.get('tabs', [])]) for w in tree.get('workspaces', [])]}")
        app = App(home, legacy)
        try:
            app.wait_mark("daemon_snapshot_loaded", 60)
            names = app.workspace_names()
        finally:
            app.quit()
        print(f"  keep: workspaces {sorted(n for n in names if n)}")
        if "own-1" not in names or set(LEGACY) & names:
            failures.append(f"keep: a used channel session must stay ({sorted(n for n in names if n)})")
        if os.path.exists(home.marker()):
            with open(home.marker()) as handle:
                print(f"  keep: marker {handle.read()}")
            failures.append("keep: an adopt marker was recorded over a used session")
    finally:
        home.stop_all()


def late(stage, root, failures):
    """A person who already opened a post-split build once: its own session holds only the
    launch's unused New Tab page. The next launch adopts the old session."""
    home = Home(stage, root, "late")
    try:
        legacy = home.daemon("cmux-app", None, LEGACY)
        app = App(home)  # no remembered old snapshot: no adopt, the own session starts
        try:
            app.wait_mark("workspace_content_shown", 60)
            first = app.workspace_names()
        finally:
            app.quit()
        own_state = os.path.join(home.support, f"cmux/tags/{CHANNEL}/tui")
        bounded(lambda: glob.glob(os.path.join(own_state, f"cmux-app-{CHANNEL}-*", "launch-snapshot.json")), 60,
                "the own session's launch snapshot")
        print(f"  late launch 1 (own session): workspaces {sorted(n for n in first if n)}")
        app = App(home, legacy)
        try:
            app.wait_mark("daemon_snapshot_loaded", 60)
            names = app.workspace_names()
        finally:
            app.quit()
        print(f"  late launch 2: workspaces {sorted(n for n in names if n)}")
        if set(LEGACY) & first:
            failures.append("late: launch 1 had no remembered old snapshot and must not adopt")
        if not set(LEGACY) <= names or not os.path.exists(home.marker()):
            failures.append("late: an own session with only its unused New Tab page must be adopted over")
    finally:
        home.stop_all()


def main():
    for path in [CONTROL_SOCKET]:
        if os.path.exists(path):
            raise SystemExit(f"{path} exists: another staging app may run here; refusing")
    # The staged copy lives inside the installed $NX_APP, so `$NX_APP_STOP` owns every helper it
    # leaves (agent screen detection, hook clients) and ends them at the end; this script signals none.
    root = tempfile.mkdtemp(prefix="legacy-adopt-", dir=os.path.join(os.environ["NX_APP"], "Contents"))
    stage = Stage(root)
    for name in ("cmux-app.sock", f"cmux-app-{CHANNEL}.sock"):
        found = glob.glob(os.path.join(stage.temp, "cmux-tui-*", name))
        if found:
            raise SystemExit(f"{found[0]} exists: a daemon of that session may run for this user; refusing")
    failures = []
    # Scratch HOMEs stay short: socket paths under them (acpmux router, ~/.local/state/cmux) must fit
    # sun_path; the model router's client traps on a longer one (seen in a /Users/cmux/nx-jobs HOME).
    homes = tempfile.mkdtemp(prefix="lad-", dir="/tmp")
    try:
        for scenario in (adopt, keep, late):
            print(f"== {scenario.__name__}")
            scenario(stage, homes, failures)
    finally:
        shutil.rmtree(homes, ignore_errors=True)
        if os.environ.get("NX_APP_STOP"):
            subprocess.run([os.environ["NX_APP_STOP"]], timeout=180)
    print("\nFAIL\n  " + "\n  ".join(failures) if failures else "\nPASS")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
