"""Launch and drive one tagged cmux-next build (AGENT-BRIEF launch rules).

The app runs with a clean environment, never activates, and puts its window
on the last screen. Only the PID this module started is ever killed.
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
            "CMUX_NEXT_TEST_WINDOW_SCREEN": "last",
            "CMUX_NEXT_CEF_EXTRA_SWITCHES": ":".join(switches),
        }
        if self.extensions:
            env["CMUX_NEXT_CEF_LOAD_EXTENSIONS"] = ":".join(self.extensions)
        log = open(os.path.join(self.log_dir, "app.log"), "w") if self.log_dir else subprocess.DEVNULL
        binary = os.path.join(self.path, "Contents/MacOS/cmux DEV")
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
        if self.process.poll() is None:
            os.kill(self.process.pid, signal.SIGTERM)
            try:
                self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.kill(self.process.pid, signal.SIGKILL)

    def dump(self, name, payload):
        if self.log_dir:
            with open(os.path.join(self.log_dir, name), "w") as out:
                json.dump(payload, out, indent=2)
