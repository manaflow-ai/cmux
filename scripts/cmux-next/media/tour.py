#!/usr/bin/env python3
"""Run cmux-next UI tours against a built app and capture each step.

    tour.py --app "<path>/cmux DEV ci-media.app" --out "$RUNNER_TEMP/media" tours/core.json [...]

Each tour launches the app fresh on a private control socket (the knobs
scripts/smoke-signed-app-cli.sh uses), drives it only through the bundled
`cmux` CLI (plans/cmux-next/cli.md), and writes <out>/<tour>/:

    manifest.json   steps with their command, status, output and screenshot
    shots/NN-*.png  one screenshot per step (a failed step is captured too)
    frames/*.jpg    the window about twice a second, for the video

A tour is a JSON file with a `title` and `steps`. A step has a `title` and
optionally:

    cmux      argv after `cmux`; app scopes get --app-socket, see `daemon`
    daemon    true for a daemon verb (notify, terminal ...): it gets
              --session cmux-app-<tag> instead of the app socket
    wait      seconds to let the UI settle before the screenshot (default 1.5)
    shot      false to skip the screenshot
    optional  why the step may fail (a feature not ported yet); its failure is
              reported as unavailable and does not fail the tour

Screenshots cover the main window's rectangle on screen, so child windows
(browser pages, overlays) are in them; with no window frame they cover the
main display. Capture runs in the console user's session, as the E2E
recorder on main does (scripts/ci/preflight-e2e-screen-capture.py), so it
works when the runner user is not the console user.

Exit status: 0 when every required step passed, 1 otherwise. The media is
written either way.
"""

from __future__ import annotations

import argparse
import getpass
import json
import os
from pathlib import Path
import re
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
from typing import Any

STEP_KEYS = {"title", "cmux", "daemon", "wait", "shot", "optional"}
TOUR_KEYS = {"title", "steps"}
DEFAULT_WAIT = 1.5
STEP_TIMEOUT = 20.0
SOCKET_TIMEOUT = 60.0
FRAME_INTERVAL = 0.5
# Five minutes of frames; a tour that runs longer keeps its screenshots but its
# video stops here, so a stuck step cannot fill the runner's disk.
MAX_FRAMES = 600
WINDOW_TIMEOUT = 20.0
# scripts/release-media/host_agent.py on main looks in the same places.
HELPER_CANDIDATES = (Path.home() / "Applications/CuaSshScreenCapture.app",
                     Path("/Applications/CuaSshScreenCapture.app"))
# A long tour would make a GIF past the inline limit; split it instead.
MAX_STEPS = 30
# Inherited caller context a cmux terminal exports. Left in place, a local run
# inside cmux would route the tour's commands at the caller's own workspace.
SCRUBBED_ENV = ("CMUX_WORKSPACE_ID", "CMUX_SURFACE_ID", "CMUX_TAB_ID", "CMUX_PANEL_ID",
                "CMUX_SOCKET_PATH", "CMUX_SOCKET_PASSWORD", "CMUX_TUI_SOCKET", "CMUX_TAG",
                "CMUX_BUNDLE_ID", "CMUX_SOCKET")


class TourError(Exception):
    pass


def slug(text: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")[:40] or "step"


def load_tour(path: Path) -> dict[str, Any]:
    """The tour in `path`, checked; TourError says what is wrong with it."""
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise TourError(f"{path}: {error}") from error
    if not isinstance(data, dict) or set(data) - TOUR_KEYS:
        raise TourError(f"{path}: a tour is an object with only {sorted(TOUR_KEYS)}")
    steps = data.get("steps")
    if not isinstance(data.get("title"), str) or not data["title"].strip():
        raise TourError(f"{path}: `title` must be a non-empty string")
    if not isinstance(steps, list) or not steps:
        raise TourError(f"{path}: `steps` must be a non-empty list")
    if len(steps) > MAX_STEPS:
        raise TourError(f"{path}: {len(steps)} steps; split tours past {MAX_STEPS}")
    for number, step in enumerate(steps, 1):
        where = f"{path}: step {number}"
        if not isinstance(step, dict):
            raise TourError(f"{where} is not an object")
        unknown = set(step) - STEP_KEYS
        if unknown:
            raise TourError(f"{where} has unknown keys {sorted(unknown)}")
        if not isinstance(step.get("title"), str) or not step["title"].strip():
            raise TourError(f"{where} needs a `title`")
        command = step.get("cmux")
        if command is not None and (not isinstance(command, list) or not command
                                    or not all(isinstance(word, str) for word in command)):
            raise TourError(f"{where}: `cmux` must be a non-empty list of strings")
        if step.get("daemon") and command is None:
            raise TourError(f"{where}: `daemon` needs a `cmux` command")
        wait = step.get("wait", DEFAULT_WAIT)
        if isinstance(wait, bool) or not isinstance(wait, (int, float)) or not 0 <= wait <= 30:
            raise TourError(f"{where}: `wait` must be 0 to 30 seconds")
        for key in ("daemon", "shot"):
            if key in step and not isinstance(step[key], bool):
                raise TourError(f"{where}: `{key}` must be true or false")
        if "optional" in step and (not isinstance(step["optional"], str) or not step["optional"].strip()):
            raise TourError(f"{where}: `optional` is the reason the step may fail")
    return {"name": slug(path.stem), "title": data["title"].strip(), "steps": steps}


def command_line(argv: list[str]) -> str:
    return " ".join(word if re.fullmatch(r"[\w@%+=:,./-]+", word) else json.dumps(word) for word in argv)


class Session:
    """Runs commands in the console user's GUI session.

    `prefix` reaches that session from another user (app launch, kill).
    Capture needs Screen Recording, which a job's process may not have, so
    three routes are probed once and the first that writes an image wins:
    screencapture from this process, screencapture through `launchctl
    asuser` (main's E2E recorder; needs passwordless sudo), and an approved
    CuaSshScreenCapture.app (main's scripts/release-media helper backend).
    """

    def __init__(self) -> None:
        self.prefix: list[str] = []
        self.user = getpass.getuser()
        console = subprocess.run(["stat", "-f", "%Su", "/dev/console"],
                                 capture_output=True, text=True).stdout.strip()
        asuser: list[str] = []
        if console and console not in ("root", "loginwindow"):
            uid = subprocess.run(["id", "-u", console], capture_output=True, text=True).stdout.strip()
            asuser = ["sudo", "-n", "launchctl", "asuser", uid, "sudo", "-n", "-H", "-u", console]
            if console != self.user:
                self.prefix = asuser
                self.user = console
        self.capture_prefix = self.prefix
        self.capture_mode = "unprobed"
        self.capture_routes = [("direct", self.prefix)] + ([("launchctl asuser", asuser)] if asuser and asuser != self.prefix else [])
        self.helper: Path | None = None

    def run(self, argv: list[str], timeout: float = 15) -> subprocess.CompletedProcess[str]:
        return subprocess.run(self.prefix + argv, capture_output=True, text=True, timeout=timeout)

    def capture(self, argv: list[str], timeout: float = 15) -> subprocess.CompletedProcess[str]:
        return subprocess.run(self.capture_prefix + argv, capture_output=True, text=True, timeout=timeout)

    def probe_capture(self, scratch: Path) -> None:
        """Pick the capture route that writes a display image; notes every attempt."""
        notes = []
        for mode, prefix in self.capture_routes:
            image = scratch / f"probe-{len(notes)}.jpg"
            try:
                done = subprocess.run(prefix + ["/usr/sbin/screencapture", "-x", "-t", "jpg", "-D", "1", str(image)],
                                      capture_output=True, text=True, timeout=15)
                said = (done.stderr or done.stdout).strip() or f"exit {done.returncode}"
            except (OSError, subprocess.SubprocessError) as error:
                said = str(error)
            if image.is_file() and image.stat().st_size > 0:
                self.capture_prefix, self.capture_mode = prefix, mode
                return
            notes.append(f"{mode}: {said}")
        for helper in HELPER_CANDIDATES:
            if not helper.is_dir():
                continue
            image = scratch / "probe-helper.png"
            if self.helper_capture(helper, ["desktop"], image) is None:
                self.helper, self.capture_mode = helper, "helper"
                return
            notes.append(f"{helper.name}: wrote no image (not approved for Screen Recording?)")
        if not any(helper.is_dir() for helper in HELPER_CANDIDATES):
            notes.append("no CuaSshScreenCapture.app")
        self.capture_mode = "none (" + "; ".join(notes) + ")"

    def helper_capture(self, helper: Path, what: list[str], path: Path) -> str | None:
        """One helper capture (`desktop` or `window <id>`) to a PNG; None on success."""
        try:
            path.unlink(missing_ok=True)
            done = subprocess.run(self.prefix + ["/usr/bin/open", "-g", "-n", "-W", str(helper), "--args", *what, str(path)],
                                  capture_output=True, text=True, timeout=60)
        except (OSError, subprocess.SubprocessError) as error:
            return str(error)
        if path.is_file() and path.stat().st_size > 0:
            return None
        return (done.stderr or done.stdout).strip() or "the helper wrote no image"

    def shareable(self, path: Path) -> Path:
        """A directory the session's user can write when that user is someone else."""
        path.mkdir(parents=True, exist_ok=True)
        if self.prefix or self.capture_prefix:
            path.chmod(0o777)
        return path


class Screen:
    """Screenshots of a rectangle in global top-left coordinates (screencapture -R)."""

    def __init__(self, session: Session, scratch: Path | None = None) -> None:
        self.session = session
        self.scratch = scratch or Path(tempfile.gettempdir())
        self.rect: tuple[int, int, int, int] | None = None
        self.primary_height: float | None = None
        self.primary_width: float | None = None
        script = ('ObjC.import("AppKit");'
                  'var f = $.NSScreen.screens.objectAtIndex(0).frame;'
                  'JSON.stringify([f.size.width, f.size.height])')
        try:
            done = session.capture(["osascript", "-l", "JavaScript", "-e", script])
            self.primary_width, self.primary_height = (float(value) for value in json.loads(done.stdout)[:2])
        except (subprocess.SubprocessError, ValueError, IndexError, TypeError):
            self.primary_width = self.primary_height = None

    def follow(self, frame: list[float] | None) -> None:
        """Aim at a window frame (NSWindow coordinates: bottom-left origin on the primary screen)."""
        # Without a usable window frame (none, gone, too small, off the
        # display) nothing is captured: the old rect would show what is behind.
        self.rect = None
        if not frame or self.primary_height is None or len(frame) != 4:
            return
        x, y, width, height = frame
        if width < 50 or height < 50:
            return
        top = self.primary_height - (y + height)
        left, right = max(0.0, x), x + width
        bottom = min(self.primary_height, top + height)
        if self.primary_width:
            right = min(self.primary_width, right)
        top = max(0.0, top)
        if right - left < 50 or bottom - top < 50:
            return
        self.rect = (int(left), int(top), int(right - left), int(bottom - top))

    def capture(self, path: Path, kind: str = "png") -> str | None:
        """Write a screenshot of the app window's rect; None on success, else what went wrong.

        Never the whole display: the runner's console is shared, and these
        images are published, so with no window rect there is no shot.
        """
        if not self.rect:
            return "no app window on screen to capture"
        if self.session.helper:
            return self.helper_capture(path, kind)
        argv = ["/usr/sbin/screencapture", "-x", "-t", kind, f"-R{','.join(map(str, self.rect))}", str(path)]
        try:
            done = self.session.capture(argv)
        except subprocess.TimeoutExpired:
            return "screencapture timed out"
        if path.is_file() and path.stat().st_size > 0:
            return None
        return (done.stderr or done.stdout or f"screencapture exited {done.returncode}").strip()


    def helper_capture(self, path: Path, kind: str) -> str | None:
        """The whole display through the helper, cropped to the rect with sips."""
        # The whole desktop lands outside shots/ and frames/, so a kill
        # mid-capture cannot publish it, in a directory the helper's user can write.
        raw = self.scratch / f"raw-{threading.get_ident()}.png"
        problem = self.session.helper_capture(self.session.helper, ["desktop"], raw)
        if problem:
            return problem
        if not self.primary_width:
            raw.unlink(missing_ok=True)
            return "unknown display size; cannot crop the helper's desktop image"
        # The rect is clamped to the primary display (follow()), which the
        # helper's desktop image starts with.
        pixels = subprocess.run(["sips", "-g", "pixelWidth", str(raw)], capture_output=True, text=True).stdout
        match = re.search(r"pixelWidth:\s*(\d+)", pixels)
        scale = int(match.group(1)) / self.primary_width if match else 1.0
        x, y, width, height = (round(value * scale) for value in self.rect)
        argv = ["sips", "-s", "format", "jpeg" if kind == "jpg" else "png",
                "--cropOffset", str(y), str(x), "-c", str(height), str(width)]
        done = subprocess.run(argv + [str(raw), "--out", str(path)], capture_output=True, text=True)
        raw.unlink(missing_ok=True)
        if path.is_file() and path.stat().st_size > 0:
            return None
        return (done.stderr or done.stdout).strip() or "sips wrote no image"


class Recorder(threading.Thread):
    """Frames of the screen rectangle about every FRAME_INTERVAL seconds, tagged with the step."""

    def __init__(self, screen: Screen, directory: Path) -> None:
        super().__init__(daemon=True)
        self.screen = screen
        self.directory = directory
        self.step = 0
        self.frames: list[dict[str, Any]] = []
        self.error: str | None = None
        self.stopping = threading.Event()
        self.lock = threading.Lock()

    def run(self) -> None:
        while not self.stopping.is_set():
            started = time.monotonic()
            with self.lock:
                if self.stopping.is_set():
                    break
                if len(self.frames) >= MAX_FRAMES:
                    self.error = f"the video stops at {MAX_FRAMES} frames"
                    break
                path = self.directory / f"frame-{len(self.frames):05d}.jpg"
            problem = self.screen.capture(path, "jpg")
            with self.lock:
                if self.stopping.is_set():
                    path.unlink(missing_ok=True)
                    break
                if problem:
                    self.error = problem
                else:
                    self.frames.append({"file": f"frames/{path.name}", "step": self.step})
            self.stopping.wait(max(0.0, FRAME_INTERVAL - (time.monotonic() - started)))

    def stop(self) -> list[dict[str, Any]]:
        """Stop recording; the frames kept, which nothing appends to afterwards."""
        with self.lock:
            self.stopping.set()
            frames = list(self.frames)
        if self.is_alive():
            # A capture in flight is bounded (60 s for the helper); its frame is dropped.
            self.join(timeout=65)
        return frames


def clean_tag(tag: Any) -> str:
    """The tag as DaemonLauncher.sessionName reduces it to one path component."""
    return re.sub(r"[^A-Za-z0-9_.-]", "-", str(tag or "")).strip("-.")


class App:
    """One launch of the app on a private socket, driven through its bundled CLI."""

    def __init__(self, app_path: Path, session: Session, workdir: Path, *, fresh_state: bool = False) -> None:
        self.app_path = app_path
        self.session = session
        self.fresh_state = fresh_state
        self.cli_path = app_path / "Contents/Resources/bin/cmux"
        plist = app_path / "Contents/Info.plist"
        executable = subprocess.run(["/usr/libexec/PlistBuddy", "-c", "Print :CFBundleExecutable", str(plist)],
                                    capture_output=True, text=True, check=True).stdout.strip()
        self.executable = app_path / "Contents/MacOS" / executable
        tag = subprocess.run(["/usr/libexec/PlistBuddy", "-c", "Print :LSEnvironment:CMUX_TAG", str(plist)],
                             capture_output=True, text=True).stdout.strip()
        self.bundle_tag = clean_tag(tag)
        # sun_path holds 104 bytes, so the socket lives in a short private directory.
        self.socket_path = session.shareable(workdir) / "s.sock"
        self.log_path = workdir / "app.log"
        self.process: subprocess.Popen[bytes] | None = None
        self.identity: dict[str, Any] = {}

    def environment(self) -> dict[str, str]:
        env = {key: value for key, value in os.environ.items() if key not in SCRUBBED_ENV}
        return env

    def clear_leftovers(self) -> None:
        """Stop a copy of this bundle and its daemon a cancelled run left behind."""
        for pattern in (f"{self.app_path}/Contents/Resources/bin/", str(self.executable)):
            self.session.run(["pkill", "-f", re.escape(pattern)])

    def state_directory(self) -> Path | None:
        """DaemonLauncher.tagStateDirectory: where a tagged build keeps its workspaces."""
        if not self.bundle_tag:
            return None
        home = Path(os.path.expanduser(f"~{self.session.user}"))
        return home / "Library/Application Support/cmux/tags" / self.bundle_tag / "tui"

    def stop_daemon(self) -> None:
        """End the tagged build's daemon and its terminals through its own socket.

        The daemon outlives the app and writes its workspaces back to the state
        directory, so deleting that directory under a live daemon changes nothing.
        An untagged build's session is the user's own, so it is never stopped.
        """
        if self.bundle_tag:
            self.cli(["server", "stop", "--end-terminals"], daemon=True, timeout=20)

    def clear_state(self) -> None:
        """Start from no workspaces, not the ones an earlier tour on this tag left."""
        directory = self.state_directory()
        if self.fresh_state and directory:
            self.session.run(["rm", "-rf", str(directory)])
            print(f"fresh state: cleared {directory}", flush=True)

    def launch(self) -> None:
        self.stop_daemon()
        self.clear_leftovers()
        self.clear_state()
        knobs = [f"CMUX_NEXT_SOCKET_PATH={self.socket_path}", "CMUX_NEXT_SOCKET_MODE=allowAll"]
        argv = self.session.prefix + ["env", *knobs, str(self.executable), "-ApplePersistenceIgnoreState", "YES"]
        with self.log_path.open("wb") as log:
            self.process = subprocess.Popen(argv, stdout=log, stderr=subprocess.STDOUT,
                                            env=self.environment(), start_new_session=True)
        deadline = time.monotonic() + SOCKET_TIMEOUT
        while True:
            if self.process.poll() is not None:
                raise TourError(f"the app exited ({self.process.returncode}) before answering: {self.log_tail()}")
            if self.socket_path.exists() and self.cli(["app", "ping"], timeout=5).returncode == 0:
                break
            if time.monotonic() > deadline:
                raise TourError(f"no answer on {self.socket_path} within {SOCKET_TIMEOUT:.0f}s: {self.log_tail()}")
            time.sleep(0.5)
        done = self.cli(["--json", "app", "identify"])
        try:
            self.identity = json.loads(done.stdout)
        except ValueError:
            self.identity = {}
        bundle = self.identity.get("bundle_id")
        if bundle:
            # Best effort: the tour reads better with the app in front.
            self.session.run(["osascript", "-e", f'tell application id "{bundle}" to activate'])

    def daemon_session(self) -> str:
        """DaemonLauncher.sessionName: cmux-app, or cmux-app-<cleaned tag>."""
        cleaned = clean_tag(self.identity.get("tag")) or getattr(self, "bundle_tag", "")
        return f"cmux-app-{cleaned}" if cleaned else "cmux-app"

    def cli(self, args: list[str], *, daemon: bool = False, timeout: float = STEP_TIMEOUT) -> subprocess.CompletedProcess[str]:
        scope = ["--session", self.daemon_session()] if daemon else ["--app-socket", str(self.socket_path)]
        # Global flags (--json) stay in front of the scope flags.
        leading = [word for word in args[:1] if word in ("--json", "--jsonl", "--quiet")]
        argv = [str(self.cli_path), *leading, *scope, *args[len(leading):]]
        try:
            return subprocess.run(argv, capture_output=True, text=True, timeout=timeout, env=self.environment())
        except subprocess.TimeoutExpired as expired:
            return subprocess.CompletedProcess(argv, 124, expired.stdout or "", f"timed out after {timeout:.0f}s")

    def request(self, method: str, params: dict[str, Any] | None = None) -> Any:
        """One control-socket request with no CLI verb (debug.layers has none)."""
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
            connection.settimeout(10)
            connection.connect(str(self.socket_path))
            connection.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
            reply = b""
            while not reply.endswith(b"\n"):
                chunk = connection.recv(65536)
                if not chunk:
                    break
                reply += chunk
        answer = json.loads(reply.decode() or "{}")
        if not answer.get("ok"):
            raise TourError(f"{method}: {answer.get('error')}")
        return answer.get("result")

    def main_window_frame(self) -> list[float] | None:
        try:
            windows = (self.request("debug.layers") or {}).get("windows") or []
        except (OSError, ValueError, TourError):
            return None
        frames = [window.get("frame") for window in windows if isinstance(window, dict)]
        frames = [frame for frame in frames if isinstance(frame, list) and len(frame) == 4]
        return max(frames, key=lambda frame: frame[2] * frame[3]) if frames else None

    def alive(self) -> bool:
        pid = self.identity.get("pid")
        if isinstance(pid, int):
            return self.session.run(["kill", "-0", str(pid)]).returncode == 0
        return self.process is not None and self.process.poll() is None

    def log_tail(self, lines: int = 30) -> str:
        try:
            return "\n".join(self.log_path.read_text(errors="replace").splitlines()[-lines:])
        except OSError:
            return ""

    def stop(self) -> None:
        pid = self.identity.get("pid")
        if isinstance(pid, int):
            self.session.run(["kill", str(pid)])
        if self.process and self.process.poll() is None:
            try:
                os.killpg(self.process.pid, signal.SIGTERM)
                self.process.wait(timeout=10)
            except (ProcessLookupError, PermissionError, subprocess.TimeoutExpired):
                pass
        if isinstance(pid, int):
            self.session.run(["kill", "-9", str(pid)])
        # The app leaves its daemon running by design; this tour started it.
        self.stop_daemon()
        self.clear_leftovers()
        self.clear_state()


def run_step(app: App, screen: Screen, step: dict[str, Any], index: int, shots: Path) -> dict[str, Any]:
    started = time.monotonic()
    result: dict[str, Any] = {"index": index, "title": step["title"], "status": "ok"}
    command = step.get("cmux")
    if command:
        result["command"] = "cmux " + command_line(command)
        done = app.cli(command, daemon=bool(step.get("daemon")))
        output = (done.stdout.strip() + "\n" + done.stderr.strip()).strip()
        result["output"] = output[-1500:]
        if done.returncode != 0:
            result["status"] = "unavailable" if step.get("optional") else "failed"
            result["detail"] = f"exited {done.returncode}"
            if step.get("optional"):
                result["detail"] += f" ({step['optional']})"
    time.sleep(step.get("wait", DEFAULT_WAIT))
    if not app.alive():
        result["status"] = "failed"
        result["detail"] = (result.get("detail", "") + " the app is no longer running").strip()
    screen.follow(app.main_window_frame())
    if step.get("shot", True) or result["status"] == "failed":
        suffix = "-failed" if result["status"] == "failed" else ""
        path = shots / f"{index:02d}-{slug(step['title'])}{suffix}.png"
        problem = screen.capture(path)
        if problem:
            result["shot_error"] = problem
        else:
            result["shot"] = f"shots/{path.name}"
    result["seconds"] = round(time.monotonic() - started, 2)
    return result


def run_tour(app_path: Path, tour: dict[str, Any], out: Path, session: Session, *,
             fresh_state: bool = False) -> dict[str, Any]:
    directory = out / tour["name"]
    if directory.exists():
        shutil.rmtree(directory)
    shots = session.shareable(directory / "shots")
    frames = session.shareable(directory / "frames")
    manifest: dict[str, Any] = {"name": tour["name"], "title": tour["title"], "steps": [], "frames": [],
                                "frame_interval": FRAME_INTERVAL, "console_user": session.user,
                                "capture_mode": session.capture_mode}
    workdir = Path(tempfile.mkdtemp(prefix="cmux-tour.", dir="/tmp"))
    app = App(app_path, session, workdir, fresh_state=fresh_state)
    screen = Screen(session, session.shareable(workdir / "raw"))
    recorder = Recorder(screen, frames)
    try:
        try:
            app.launch()
        except (TourError, OSError, subprocess.SubprocessError) as error:
            manifest["error"] = f"launch: {error}"
            manifest["steps"].append({"index": 0, "title": "Launch", "status": "failed", "detail": str(error)[:1500]})
            return manifest
        manifest["app"] = {key: app.identity.get(key) for key in ("app", "version", "build", "bundle_id", "tag")}
        # Frames and shots cover the window only, so the recording starts once it is on screen.
        deadline = time.monotonic() + WINDOW_TIMEOUT
        while screen.rect is None and time.monotonic() < deadline:
            screen.follow(app.main_window_frame())
            if screen.rect is None:
                time.sleep(0.5)
        if screen.rect is None:
            manifest["frames_error"] = f"no app window on screen within {WINDOW_TIMEOUT:.0f}s"
        else:
            recorder.start()
        for index, step in enumerate(tour["steps"], 1):
            recorder.step = index
            result = run_step(app, screen, step, index, shots)
            manifest["steps"].append(result)
            print(f"[{tour['name']}] {index:02d} {result['status']:<11} {step['title']}"
                  + (f": {result['detail']}" if result.get("detail") else ""), flush=True)
            if not app.alive():
                manifest["error"] = "the app exited during the tour: " + app.log_tail()
                break
    finally:
        # A second signal must not cut the cleanup short.
        signal.signal(signal.SIGINT, signal.SIG_IGN)
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        # No frame after this point: once the app is gone, the rect shows
        # whatever was behind it on the shared console.
        with recorder.lock:
            recorder.stopping.set()
        # Then the app: a leftover app or daemon would serve the next run on this Mac.
        app.stop()
        manifest["frames"] = recorder.stop() if recorder.ident else []
        if recorder.error and not manifest["frames"]:
            manifest.setdefault("frames_error", recorder.error)
        manifest["capture_rect"] = screen.rect
        if app.log_path.exists():
            shutil.copy(app.log_path, directory / "app.log")
        shutil.rmtree(workdir, ignore_errors=True)
        (directory / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    return manifest


def terminated(signum: int, frame: Any) -> None:
    raise SystemExit(128 + signum)


def passed(manifest: dict[str, Any]) -> bool:
    return "error" not in manifest and all(step["status"] != "failed" for step in manifest["steps"])


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("tours", nargs="+", type=Path, help="tour JSON files or directories of them")
    parser.add_argument("--app", type=Path, help="the built app bundle")
    parser.add_argument("--out", type=Path, help="where each tour's folder goes")
    parser.add_argument("--check", action="store_true", help="only validate the tour files")
    parser.add_argument("--fresh-state", action="store_true",
                        help="delete the tagged build's saved workspaces before and after each tour")
    args = parser.parse_args(argv)
    files: list[Path] = []
    for path in args.tours:
        files.extend(sorted(path.glob("*.json")) if path.is_dir() else [path])
    try:
        tours = [load_tour(path) for path in files]
    except TourError as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    names = [tour["name"] for tour in tours]
    if len(set(names)) != len(names):
        print(f"error: tour names collide: {names}", file=sys.stderr)
        return 2
    if args.check:
        print(f"ok: {len(tours)} tour(s), {sum(len(t['steps']) for t in tours)} steps")
        return 0
    if not args.app or not args.out:
        parser.error("--app and --out are required unless --check")
    # A cancelled job gets SIGINT, then SIGTERM; both unwind through
    # run_tour's cleanup, so the app and its daemon do not outlive the job.
    signal.signal(signal.SIGTERM, terminated)
    session = Session()
    args.out.mkdir(parents=True, exist_ok=True)
    probe = Path(tempfile.mkdtemp(prefix="cmux-tour-probe.", dir="/tmp"))
    try:
        session.probe_capture(session.shareable(probe))
    finally:
        # The probe captured the whole display; it never leaves the runner.
        shutil.rmtree(probe, ignore_errors=True)
    print(f"screen capture: {session.capture_mode}", flush=True)
    ok = True
    for tour in tours:
        signal.signal(signal.SIGINT, signal.default_int_handler)
        signal.signal(signal.SIGTERM, terminated)
        ok = passed(run_tour(args.app, tour, args.out, session, fresh_state=args.fresh_state)) and ok
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
