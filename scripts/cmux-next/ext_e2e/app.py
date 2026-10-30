"""Launch and drive one tagged cmux-next build (AGENT-BRIEF launch rules).

The app runs with a clean environment, never activates (unless
`CMUX_EXT_E2E_ACTIVATE=1`, for a leased host nobody works on), and puts its
window on the last screen. Only the PID this module started is ever killed.
"""
import glob
import json
import os
import plistlib
import shutil
import signal
import socket
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from bench_cli_storm import Client  # noqa: E402


def app_path(tag):
    matches = glob.glob(os.path.expanduser(
        f"~/Library/Developer/Xcode/DerivedData/cmux-{tag}/Build/Products/Debug/cmux DEV {tag}.app"))
    if not matches:
        raise SystemExit(f"no tagged build for {tag}; run ./scripts/reload.sh --tag {tag}")
    return matches[0]


class OpenedApp:
    """The app started through LaunchServices (`open -g -n`), for hosts reached over ssh
    (fleet capture minis): a process started from an ssh shell is outside the GUI
    session, so its windows never show and its Chromium tabs never get a browser.
    `CMUX_EXT_E2E_OPEN=1` picks it. Quacks like the Popen the rest of the module uses;
    the PID is the one process running exactly this build's executable."""

    def __init__(self, pid, binary):
        self.pid = pid
        self.binary = binary
        self.returncode = None

    @classmethod
    def launch(cls, app, binary, env, log_dir, activate=False, timeout=20):
        before = set(cls.pids(binary))
        command = ["/usr/bin/open"] + ([] if activate else ["-g"]) + ["-n", "-a", app]
        for key, value in env.items():
            if key not in ("HOME", "USER", "TMPDIR", "PATH"):
                command += ["--env", f"{key}={value}"]
        if log_dir:
            log = os.path.join(log_dir, "app.log")
            command += ["--stdout", log, "--stderr", log]
        subprocess.run(command, check=True)
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            started = [pid for pid in cls.pids(binary) if pid not in before]
            if started:
                return cls(started[0], binary)
            time.sleep(0.2)
        raise SystemExit("open started no app process")

    @staticmethod
    def pids(binary):
        listing = subprocess.run(["/bin/ps", "-axo", "pid=,command="], capture_output=True, text=True).stdout
        return [int(pid) for pid, _, command in (line.strip().partition(" ") for line in listing.splitlines())
                if command == binary]

    def poll(self):
        # Not our child: once it exits its PID may be reused, so alive means the PID
        # still runs this build's executable (quit signals only then).
        if self.returncode is None and self.pid not in self.pids(self.binary):
            self.returncode = 0
        return self.returncode

    def wait(self, timeout=None):
        deadline = time.monotonic() + (timeout or 1e9)
        while self.poll() is None:
            if time.monotonic() > deadline:
                raise subprocess.TimeoutExpired("cmux", timeout)
            time.sleep(0.1)
        return self.returncode


def free_port():
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


class TaggedApp:
    def __init__(self, tag, extensions=(), fresh_profile=True, extra_switches=(), log_dir=None):
        self.tag = tag
        self.path = app_path(tag)
        with open(os.path.join(self.path, "Contents/Info.plist"), "rb") as plist:
            self.bundle_id = plistlib.load(plist)["CFBundleIdentifier"]
        self.socket_path = f"/tmp/cmux-debug-{tag}.sock"
        self.cdp_port = free_port()
        self.extensions = list(extensions)
        self.extra_switches = list(extra_switches)
        self.fresh_profile = fresh_profile
        self.log_dir = log_dir
        self.process = None
        self.client = None

    @property
    def chromium_root(self):
        return os.path.expanduser(f"~/Library/Application Support/{self.bundle_id}/Chromium")

    def launch(self, timeout=40):
        if os.path.exists(self.socket_path):
            try:
                Client(self.socket_path, timeout=2).call("debug.cef")
                raise SystemExit(f"{self.socket_path} is live: another {self.tag} instance runs; quit it first")
            except (OSError, ConnectionError):
                pass
        stopped = self.stop_tagged_daemon()
        if self.fresh_profile:
            # Fresh Chromium profile and fresh daemon state (no restored tabs).
            for pid in stopped:
                for _ in range(50):
                    try:
                        os.kill(pid, 0)
                    except OSError:
                        break
                    time.sleep(0.1)
            state = os.path.expanduser(f"~/Library/Application Support/cmux/tags/{self.tag}/tui")
            for path in (self.chromium_root, state):
                if os.path.isdir(path):
                    shutil.rmtree(path)
        switches = [f"remote-debugging-port={self.cdp_port}", "remote-allow-origins=*"] + self.extra_switches
        env = {
            "HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""),
            "TMPDIR": os.environ.get("TMPDIR", "/tmp"), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
            "CMUX_NEXT_CEF_EXTRA_SWITCHES": ":".join(switches),
        }
        # A key window lets the checks that need one run (action.openPopup, typing in
        # the omnibar); only on a host no person is using.
        activate = os.environ.get("CMUX_EXT_E2E_ACTIVATE") == "1"
        if activate:
            del env["CMUX_NEXT_NO_ACTIVATE"]
        # The last screen keeps the window off a person's main display; `CMUX_EXT_E2E_SCREEN=`
        # (empty) leaves the app's own placement (a fleet mini's last screen is not drawn).
        if screen := os.environ.get("CMUX_EXT_E2E_SCREEN", "last"):
            env["CMUX_NEXT_TEST_WINDOW_SCREEN"] = screen
        if self.extensions:
            env["CMUX_NEXT_CEF_LOAD_EXTENSIONS"] = ":".join(self.extensions)
        binary = os.path.join(self.path, "Contents/MacOS/cmux DEV")
        if os.environ.get("CMUX_EXT_E2E_OPEN") == "1":
            self.process = OpenedApp.launch(self.path, binary, env, self.log_dir, activate)
        else:
            log = open(os.path.join(self.log_dir, "app.log"), "w") if self.log_dir else subprocess.DEVNULL
            self.process = subprocess.Popen([binary], env=env, stdout=log, stderr=subprocess.STDOUT,
                                            start_new_session=True)
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if self.process.poll() is not None:
                raise SystemExit(f"app exited with {self.process.returncode}")
            try:
                self.client = Client(self.socket_path, timeout=30)
                if self.client.call("debug.cef").get("ok"):
                    self.wait_focused_pane()
                    return self
            except (OSError, ConnectionError, ValueError):
                time.sleep(0.25)
        raise SystemExit("socket never answered")

    def stop_tagged_daemon(self):
        """Stops the headless cmux-tui daemon of this tag's app bundle, which
        outlives the app and would restore the last run's tabs. Only processes
        whose executable is inside this tagged build are touched."""
        inside = os.path.join(self.path, "Contents/Resources/bin/cmux-tui")
        listing = subprocess.run(["/bin/ps", "-axo", "pid=,command="], capture_output=True, text=True).stdout
        stopped = []
        for line in listing.splitlines():
            pid, _, command = line.strip().partition(" ")
            if command.startswith(inside):
                os.kill(int(pid), signal.SIGTERM)
                stopped.append(int(pid))
        return stopped

    def call(self, method, params=None):
        try:
            return self.client.call(method, params or {})
        except (OSError, ConnectionError, ValueError):
            self.client = Client(self.socket_path, timeout=30)
            return self.client.call(method, params or {})

    def open_chromium(self, url):
        """Opens a Chromium tab and selects it. A tab a script opens stays in the background
        (the window keeps its New Tab page), and an unshown Chromium tab has no browser yet,
        so no extension would see its page."""
        return self.open_selected("tab new-chromium", {"url": url})

    def open_selected(self, name, args=None):
        """Runs an action that opens a tab, then selects the tab it created."""
        opened = self.action(name, args)
        for tab in ((opened.get("result") or {}).get("created") or [])[:1]:
            self.call("tab.focus", {"tab": tab})
        return opened

    def action(self, name, args=None):
        params = {"action": name}
        if args:
            params["args"] = args
        return self.call("action.run", params)

    def snapshot(self):
        return self.call("snapshot.get").get("result") or {}

    def wait_focused_pane(self, timeout=20):
        """The socket answers before the first window has a focused pane."""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            focus = (self.snapshot().get("topology") or {}).get("focus") or {}
            if focus.get("pane"):
                return focus["pane"]
            time.sleep(0.2)
        raise SystemExit("no focused pane")

    def urls(self):
        """Every URL string in the control snapshot (tabs the daemon owns)."""
        found = []

        def walk(node):
            if isinstance(node, dict):
                for key, value in node.items():
                    if key in ("url", "current_url") and isinstance(value, str):
                        found.append(value)
                    else:
                        walk(value)
            elif isinstance(node, list):
                for item in node:
                    walk(item)
        walk(self.snapshot())
        return found

    def quit(self):
        if not self.process or self.process.poll() is not None:
            return
        try:
            self.call("action.run", {"action": "app quit"})
            self.process.wait(timeout=15)
        except Exception:  # noqa: BLE001 - fall back to a signal to our own PID
            pass
        try:
            if self.process.poll() is None:
                os.kill(self.process.pid, signal.SIGTERM)
                try:
                    self.process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    if self.process.poll() is None:
                        os.kill(self.process.pid, signal.SIGKILL)
        except ProcessLookupError:  # it exited between the check and the signal
            pass

    def dump(self, name, payload):
        if self.log_dir:
            with open(os.path.join(self.log_dir, name), "w") as out:
                json.dump(payload, out, indent=2)
