#!/usr/bin/env python3
"""Launch journey: does a launch of cmux NEXT show the blocking "Connecting to cmux-tui" screen?

Lawrence 2026-10-15: "i'm seeing 'connect to cmux tui' loading screen when app launches" (cx-r650e).
This drives one fleet-built tagged app (`nx-remote --needs gui --app-from-fleet cmux --tag T --ref SHA`)
through the launches a person makes and reads every launch mark as an event (the app writes one
`<name> <ms since process start>` line per mark to CMUX_NEXT_LAUNCH_MARKS_FD,
Control/LaunchMarkSink.swift):

  first    a new tag: no daemon, no saved state (each dogfood build is one)
  warm     the app quit keeping its sessions; the daemon runs on (the daemon is adopted)
  restart  the daemon stopped too (an update or a reboot): the app starts it on the big registry

Between `first` and `warm` it grows the tag's registry with real work: workspaces whose terminals
print --seed-mb MiB of output in total (terminal output is journaled in the registry), so the
daemon opens a large registry on `restart`.

Per launch it prints the marks that matter, how long the window showed the connecting screen
(`connecting_view_shown` .. `connecting_view_left`) and whether its "Connecting to cmux-tui" line
became visible (`connecting_status_shown`), and saves a window still 1.5 s after the first frame
(`debug.window_snapshot`). Checks (exit 1 when one fails):
  - first: the "Connecting to cmux-tui" line never becomes visible;
  - warm, restart: the launch window draws the last layout (`launch_snapshot_shown`) and the
    connecting screen never shows;
  - first: the first frame shows the sidebar beside the empty main pane, never glass alone;
  - warm, restart: the first frame draws the last layout whole: the sidebar, the tab strip and
    the pane each show in it (`reveal.<region>`, or the pane's launch frame), none after it;
  - every launch: the app shows workspace content within --usable-ms of process start.

It stops only what it started: the app process it launched (its own pid, quit through the app's
`action.run quitKeepSessions`), the tag's daemon through the bundled `cmux-tui server stop`, and
at the end `$NX_APP_STOP`. It never scans or signals other processes.
"""
import argparse
import base64
import json
import os
import select
import socket
import subprocess
import sys
import tempfile
import time

MARKS = [
    "main_start", "did_finish_launching_start", "launch_snapshot_applied", "launch_snapshot_shown",
    "connecting_view_shown", "first_window_frame_committed", "daemon.status_start", "daemon.status_end",
    "daemon.remembered_socket", "daemon.ensure_start", "daemon.ensure_end", "daemon.socket_connected",
    "daemon.identify_end", "daemon.handshake_end", "daemon.snapshot_start", "daemon.snapshot_end",
    "daemon.first_tree_applied", "daemon_snapshot_loaded", "connecting_status_shown", "connecting_view_left",
    "workspace_content_shown", "first_terminal_frame", "agent_pane.handshake_end",
    "sidebar_rows_shown", "reveal.sidebar", "reveal.tabs", "reveal.pane", "terminal.launch_frame_shown",
    "launch.visible_terminals_drawn", "agent_pane.launch_image_shown",
]
# Launch regions held clear until their data lands (LaunchReveal); `reveal.<region>` marks when one shows.
# A region that shows after the first frame was clear in it. The pane also shows in the first frame
# when every visible terminal's last frame (the last of them, `launch.visible_terminals_drawn`; never the first,
# `terminal.launch_frame_shown`, which hid REOPEN-F1) or its agent page's last image drew there.
REGIONS = {"sidebar": [], "tabs": [], "pane": ["launch.visible_terminals_drawn", "agent_pane.launch_image_shown"]}
# A fresh profile's launch window opens on the empty main pane beside the sidebar (cx-r650e) while
# cmux-tui starts; its tab strip comes with the first workspace.
FIRST_REGIONS = {"sidebar": [], "pane": ["connecting_view_shown", "workspace_content_shown"]}
USABLE = ["workspace_content_shown"]


class Client:
    """One JSON Lines connection to the app's control socket or the daemon socket."""

    def __init__(self, path, timeout=15):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(timeout)
        self.sock.connect(path)
        self.buffer = b""
        self.next_id = 1

    def call(self, method, params=None, daemon=False):
        request_id = self.next_id
        self.next_id += 1
        body = {"id": request_id}
        if daemon:
            body.update({"cmd": method, **(params or {})})
        else:
            body.update({"method": method, "params": params or {}})
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


def connect(path, timeout):
    """The socket once it accepts: the app makes it during launch (an event the marks cannot name)."""
    deadline = time.monotonic() + timeout
    while True:
        try:
            return Client(path)
        except OSError:
            if time.monotonic() > deadline:
                raise
            time.sleep(0.2)


class Tag:
    def __init__(self, args):
        self.app = os.environ["NX_APP"]
        self.tag = os.environ["NX_APP_TAG"]
        self.socket = os.environ["NX_APP_SOCKET"]
        self.out = args.out
        self.session = "cmux-app-" + self.tag
        self.binary = os.path.join(self.app, "Contents/MacOS/cmux DEV")
        self.tui = os.path.join(self.app, "Contents/Resources/bin/cmux-tui")
        self.state = os.path.expanduser(f"~/Library/Application Support/cmux/tags/{self.tag}/tui")
        self.scratch = tempfile.mkdtemp(prefix="launch-connect-")
        with open(os.path.join(self.scratch, "cmux.json"), "w") as config:
            config.write("{}\n")

    def daemon_env(self):
        temp = subprocess.run(["getconf", "DARWIN_USER_TEMP_DIR"], capture_output=True, text=True).stdout.strip()
        env = dict(os.environ)
        env.update({"CMUX_TUI_STATE_DIR": self.state, "TMPDIR": temp})
        env.pop("XDG_RUNTIME_DIR", None)
        return env

    def tui_json(self, *args):
        out = subprocess.run([self.tui, "--session", self.session, "--json", *args], env=self.daemon_env(),
                             capture_output=True, text=True, timeout=60)
        lines = [line for line in out.stdout.splitlines() if line.startswith("{")]
        return out.returncode, (json.loads(lines[-1]) if lines else {}), out.stderr.strip()

    def registry_bytes(self):
        total = 0
        for root, _, files in os.walk(self.state):
            total += sum(os.path.getsize(os.path.join(root, name)) for name in files
                         if name.startswith("workspace-registry.sqlite3"))
        return total


class Launch:
    """One app process this script started; its launch marks arrive on a pipe."""

    def __init__(self, tag, extra_env=None):
        read_fd, write_fd = os.pipe()
        env = dict(os.environ)
        env.update({
            "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
            "CMUX_NEXT_TEST_WINDOW_SCREEN": "last",
            "CMUX_NEXT_CONFIG_FILE": os.path.join(tag.scratch, "cmux.json"),
            "CMUX_NEXT_LAUNCH_MARKS_FD": str(write_fd),
            **(extra_env or {}),
        })
        self.started = time.monotonic()
        self.process = subprocess.Popen([tag.binary], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                        start_new_session=True, pass_fds=(write_fd,))
        os.close(write_fd)
        self.tag = tag
        self.read_fd = read_fd
        self.buffer = b""
        self.marks = {}

    def wait_for(self, wanted, timeout, any_of=True):
        wanted = [wanted] if isinstance(wanted, str) else list(wanted)
        landed = any if any_of else all
        deadline = time.monotonic() + timeout
        while not landed(name in self.marks for name in wanted):
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return False
            ready, _, _ = select.select([self.read_fd], [], [], remaining)
            if not ready:
                return False
            chunk = os.read(self.read_fd, 65536)
            if not chunk:
                return False
            self.buffer += chunk
            *lines, self.buffer = self.buffer.split(b"\n")
            for line in lines:
                name, _, ms = line.decode().partition(" ")
                if name and ms:
                    self.marks.setdefault(name, float(ms))
        return True

    def drain(self, seconds):
        """Marks that arrive in the next `seconds` (the end of the launch)."""
        self.wait_for("__never__", seconds)

    def snapshot(self, path):
        try:
            client = connect(self.tag.socket, 20)
            reply = client.call("debug.window_snapshot", {"kind": "main", "path": path})
            client.close()
            return reply.get("ok", False)
        except (OSError, ConnectionError, ValueError):
            return False

    def quit_keep_sessions(self):
        """The app's own quit that keeps the daemon and its terminals; waits for this pid only."""
        try:
            client = connect(self.tag.socket, 20)
            client.call("action.run", {"id": "quitKeepSessions"})
            client.close()
        except (OSError, ConnectionError, ValueError):
            pass
        try:
            self.process.wait(timeout=45)
        except subprocess.TimeoutExpired:
            raise SystemExit(f"the app (pid {self.process.pid}) did not quit within 45 s of quitKeepSessions")
        os.close(self.read_fd)


def seed(tag, args):
    """Workspaces whose terminals print seed-mb MiB of output in total, through the daemon socket."""
    code, status, error = tag.tui_json("server", "status")
    if not status.get("socket"):
        raise SystemExit(f"server status gave no socket (exit {code}): {error[-300:]}")
    daemon = Client(status["socket"], timeout=30)
    per = max(1, args.seed_mb // args.seed_workspaces)
    for index in range(args.seed_workspaces):
        created = daemon.call("new-workspace", {"name": f"journey-{index + 1:02d}"}, daemon=True)
        surface = (created.get("data") or {}).get("surface")
        if not created.get("ok") or surface is None:
            raise SystemExit(f"new-workspace failed: {created}")
        text = f"head -c {per * 3 // 4 * 1048576} /dev/urandom | base64; echo journey-done-{index}\r"
        daemon.call("send", {"surface": surface, "text": text}, daemon=True)
    daemon.close()
    # The output is written by the terminals while this waits; the size says when it is in.
    deadline = time.monotonic() + args.seed_seconds
    target = args.seed_mb * 1048576 * 0.8
    while tag.registry_bytes() < target and time.monotonic() < deadline:
        time.sleep(2)
    return tag.registry_bytes()


def report(name, launch, still):
    marks = launch.marks
    shown = marks.get("connecting_view_shown")
    left = marks.get("connecting_view_left")
    connecting_ms = None if shown is None or left is None else left - shown
    usable = next((marks[m] for m in USABLE if m in marks), None)
    first_frame = marks.get("first_window_frame_committed")
    regions = FIRST_REGIONS if name == "first" else REGIONS
    late = [region for region, stand_ins in regions.items() if first_frame is None
            or min([marks[m] for m in [f"reveal.{region}", *stand_ins] if m in marks] or [float("inf")]) > first_frame]
    row = {"launch": name, "marks": {m: round(marks[m], 1) for m in MARKS if m in marks},
           "connecting_screen_ms": None if connecting_ms is None else round(connecting_ms, 1),
           "connecting_screen_never_left": shown is not None and left is None,
           "connecting_status_shown": "connecting_status_shown" in marks,
           "launch_snapshot_shown": "launch_snapshot_shown" in marks,
           "usable_ms": None if usable is None else round(usable, 1), "still": still,
           "regions_after_first_frame": late}
    print(f"\n== {name}")
    for mark in MARKS:
        if mark in marks:
            print(f"  {mark:<34} {marks[mark]:>9.1f} ms")
    print(f"  connecting screen: {row['connecting_screen_ms']} ms, status line shown: {row['connecting_status_shown']},"
          f" last layout drawn at once: {row['launch_snapshot_shown']}, usable at {row['usable_ms']} ms")
    print(f"  regions clear in the first frame: {', '.join(late) or 'none'}")
    return row


def one_launch(tag, name, args, extra_env=None):
    launch = Launch(tag, extra_env)
    launch.wait_for("first_window_frame_committed", args.timeout)
    # The still 1.5 s after the first frame: what a person sees once "Connecting" could have faded in.
    first = launch.marks.get("first_window_frame_committed")
    if first is not None:
        wait = max(0.0, (first + 1500) / 1000 - (time.monotonic() - launch.started))
        launch.wait_for("__never__", wait)
    still = os.path.join(tag.out, f"{name}-1500ms.png")
    still = still if launch.snapshot(still) else None
    launch.wait_for(USABLE, args.timeout)
    launch.drain(2.0)
    row = report(name, launch, still)
    launch.quit_keep_sessions()
    return row


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS", "."))
    parser.add_argument("--timeout", type=float, default=60.0)
    parser.add_argument("--usable-ms", type=float, default=4000.0)
    parser.add_argument("--seed-mb", type=int, default=400)
    parser.add_argument("--seed-workspaces", type=int, default=20)
    parser.add_argument("--seed-seconds", type=float, default=240.0)
    parser.add_argument("--launches", default="first,warm,restart")
    args = parser.parse_args()
    os.makedirs(args.out, exist_ok=True)
    tag = Tag(args)
    wanted = args.launches.split(",")
    rows = []
    failures = []
    try:
        if os.path.exists(tag.state):
            raise SystemExit(f"{tag.state} exists: use a new tag (the first launch must be a new tag's)")
        rows.append(one_launch(tag, "first", args))
        size = seed(tag, args)
        print(f"\nregistry after seeding: {size / 1048576:.0f} MiB")
        if "warm" in wanted:
            rows.append(one_launch(tag, "warm", args))
        if "restart" in wanted:
            code, result, error = tag.tui_json("server", "stop")
            print(f"\nserver stop: exit {code} {result} {error[-300:]}")
            rows.append(one_launch(tag, "restart", args))
    finally:
        with open(os.path.join(args.out, "launch-connect.json"), "w") as out:
            json.dump({"tag": tag.tag, "registry_bytes": tag.registry_bytes(), "launches": rows}, out, indent=2)
        stop = os.environ.get("NX_APP_STOP")
        if stop:
            subprocess.run([stop], timeout=180)
    for row in rows:
        if row["usable_ms"] is None or row["usable_ms"] > args.usable_ms:
            failures.append(f"{row['launch']}: workspace content at {row['usable_ms']} ms (limit {args.usable_ms:.0f})")
        if row["launch"] == "first" and row["connecting_status_shown"]:
            failures.append("first: the Connecting to cmux-tui line became visible")
        if row["launch"] == "first" and row["regions_after_first_frame"]:
            failures.append("first: the first frame drew no " + ", ".join(row["regions_after_first_frame"]))
        if row["launch"] != "first":
            if not row["launch_snapshot_shown"]:
                failures.append(f"{row['launch']}: the last layout was not drawn at launch")
            if row["regions_after_first_frame"]:
                failures.append(f"{row['launch']}: the first frame drew no " + ", ".join(row["regions_after_first_frame"]))
            if row["connecting_screen_never_left"]:
                failures.append(f"{row['launch']}: the connecting screen never went away")
            elif row["connecting_screen_ms"] is not None:
                failures.append(f"{row['launch']}: the connecting screen showed for {row['connecting_screen_ms']} ms")
    print("\nFAIL\n  " + "\n  ".join(failures) if failures else "\nPASS")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
