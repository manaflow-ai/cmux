#!/usr/bin/env python3
"""Run cmux-next UI tours against a built app and capture each step.

    tour.py --app "<path>/cmux DEV ci-media.app" --out "$RUNNER_TEMP/media" tours/core.json [...]
    tour.py --stop "<path>/cmux DEV ci-media.app" [--stop ...]

Each tour launches the app fresh on a private control socket (the knobs
scripts/smoke-signed-app-cli.sh uses), drives it only through the bundled
`cmux` CLI (plans/cmux-next/cli.md), and writes <out>/<tour>/:

    manifest.json   steps with their command, status, output and screenshot
    shots/NN-*.png  one screenshot per step (a failed step is captured too)
    capture.mov    continuous window-only video at up to 60 fps
    frames/*.jpg    fastest available stills when no native video route works

A tour is a JSON file with a `title` and `steps`, and optionally `settings`:
the cmux-next.json the app launches with (`CMUX_NEXT_CONFIG_FILE`), a private
file in the tour's work directory, so a tour can show a setting (background
art, a theme) and `cmux settings set` writes there, never to the runner's own
settings. A step has a `title` and optionally:

    cmux      argv after `cmux`; app scopes get --app-socket, see `daemon`
    rpc       {"method": ..., "params": {...}}: one app control-socket request
              with no CLI verb (a DEBUG fixture such as debug.home.sidebar_fixture),
              after `cmux`; an error answer, an `error` field or `ok` false fails the step
    daemon    true for a daemon verb (notify, terminal ...): it gets
              --session cmux-app-<tag> instead of the app socket
    wait      seconds to let the UI settle before the screenshot (default 1.5)
    shot      false to skip the screenshot
    optional  why the step may fail (a feature not ported yet); its failure is
              reported as unavailable and makes the tour degraded, rather than
              letting an incomplete tour look fully verified
    expect    app debug RPC postcondition: {"method": "debug.layers",
              "fields": {"field": expected_value}}; mismatches fail required
              steps and make optional steps unavailable

Screenshots are the DEV app's own drawing of its main window
(`debug.window_snapshot`, which needs no grant), child windows it owns
included, so nothing covering the window (permission prompts, other jobs'
windows) is in them. A build that cannot snapshot falls back to that window
alone by its window server id (`screencapture -l`, run in the console user's
session as the E2E recorder on main does), never the display, so tours on one
Mac never capture each other. The app is never activated: the tour drives it
through its socket, so concurrent tours do not trade focus or the key window.

`--stop` ends what a built app left running and exits: its tagged daemon
through its own socket, then every process whose executable is in the bundle
(the app, the chief host and its acpmux daemon and router), SIGKILL after
STOP_GRACE seconds. The tour job runs it whatever happened before, since a
cancel can land while the app starts and outlive this process's own cleanup.

The manifest records `result` as `pass`, `degraded`, or `failed`. Optional
failures keep the process exit status green for compatibility, but result in a
degraded manifest that publishers and reviewers can distinguish from a full
pass. The media is written either way.
"""

from __future__ import annotations

import argparse
import getpass
import json
import os
from pathlib import Path
import plistlib
import re
import selectors
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
from typing import Any

MAX_SECONDS = 300

STEP_KEYS = {"title", "cmux", "rpc", "daemon", "wait", "shot", "display", "optional", "expect", "windows"}
# Other windows a step shoots beside the main one (floating panels, popovers,
# sheets), at most this many, each at least this big in points.
MAX_OTHER_WINDOWS = 4
MIN_OTHER_WINDOW = (40, 24)
# All of a step's other-window shots share this many seconds.
OTHER_WINDOWS_BUDGET = 20.0
TOUR_KEYS = {"title", "steps", "settings"}
# A directional focus right after a pane close (focus_after_close).
DIRECTIONAL_FOCUS = {"focusLeft", "focusRight", "focusUp", "focusDown"}
# Focus moves that open no pane, so they never undo a close (ActionCatalog+Focus.swift).
FOCUS_MOVES = DIRECTIONAL_FOCUS | {
    "focusPreviousPane", "focusNextPane", "focusPaneByNumber", "pane.focus", "column.focusLeft",
    "column.focusRight", "focusHistoryBack", "focusHistoryForward", "focusHistoryLast"}
PANE_CLOSES = {"closePane", "pane.closeOthers"}
DEFAULT_WAIT = 1.5
STEP_TIMEOUT = 20.0
POSTCONDITION_TIMEOUT = 2.0
SOCKET_TIMEOUT = 60.0
# --stop: seconds a bundle's processes get after SIGTERM before SIGKILL.
STOP_GRACE = 10.0
FRAME_INTERVAL = 1 / 60
# Five minutes of frames; a tour that runs longer keeps its screenshots but its
# video stops here, so a stuck step cannot fill the runner's disk.
MAX_FRAMES = 60 * MAX_SECONDS
WINDOW_TIMEOUT = 20.0
# A window snapshot paints each shown page too, so it can take a few seconds.
SNAPSHOT_TIMEOUT = 20.0
APP_WINDOW_MODE = "app window (debug.window_snapshot)"
# Still-only routes run sequentially, limited by their capture latency (at most 60 Hz).
APP_WINDOW_FRAME_INTERVAL = FRAME_INTERVAL
# scripts/release-media/host_agent.py on main looks in the same places.
HELPER_CANDIDATES = (Path.home() / "Applications/CuaSshScreenCapture.app",
                     Path("/Applications/CuaSshScreenCapture.app"))
# A long tour would make a GIF past the inline limit; split it instead.
MAX_STEPS = 30
READ_ONLY_POSTCONDITION_METHODS = {
    "debug.layers", "debug.surfaces", "debug.focus", "debug.window_list", "debug.windows",
    "debug.pane_chrome", "debug.notifications", "debug.themes", "debug.dialog",
}
# The tour's shells read these rc files, never the runner account's, whose `%n@%m` prompt names the CI
# Mac. A DEBUG app launched with CMUX_CAPTURE_SHELL_HOME (as a PR capture slot is) starts its terminals'
# zsh there (ZDOTDIR; Ghostty's wrapper hands it back before `.zshrc` runs) and names the showcase Mac
# ("Studio Mac") on its panes and its machine picker, so pr-media's privacy check
# (scripts/ci/pr_media_privacy.py) passes the tour's shots.
FIXTURE_ZSHRC = "PROMPT='tour@studio-mac %1~ %# '\nRPROMPT=''\n"
# Inherited caller context a cmux terminal exports. Left in place, a local run
# inside cmux would route the tour's commands at the caller's own workspace, and
# any of LaunchIdentity.otherCmuxMarkers makes the app drop the tour's
# CMUX_NEXT_SOCKET_PATH and CMUX_CAPTURE_SHELL_HOME as another cmux's.
SCRUBBED_ENV = ("CMUX_WORKSPACE_ID", "CMUX_SURFACE_ID", "CMUX_TAB_ID", "CMUX_PANEL_ID",
                "CMUX_SOCKET_PATH", "CMUX_SOCKET_PASSWORD", "CMUX_TUI_SOCKET", "CMUX_TAG",
                "CMUX_BUNDLE_ID", "CMUX_SOCKET", "MUX_AGENT_TOKEN_FILE")


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
    if "settings" in data and not isinstance(data["settings"], dict):
        raise TourError(f"{path}: `settings` must be an object (the cmux-next.json the app launches with)")
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
        if "windows" in step and not isinstance(step["windows"], bool):
            raise TourError(f"{where}: `windows` must be true or false")
        rpc = step.get("rpc")
        if rpc is not None and (not isinstance(rpc, dict) or set(rpc) - {"method", "params"}
                                or not isinstance(rpc.get("method"), str) or not rpc["method"].strip()
                                or not isinstance(rpc.get("params", {}), dict)):
            raise TourError(f"{where}: `rpc` must be {{\"method\": name, \"params\": object}}")
        if step.get("daemon") and command is None:
            raise TourError(f"{where}: `daemon` needs a `cmux` command")
        wait = step.get("wait", DEFAULT_WAIT)
        if isinstance(wait, bool) or not isinstance(wait, (int, float)) or not 0 <= wait <= 30:
            raise TourError(f"{where}: `wait` must be 0 to 30 seconds")
        for key in ("daemon", "shot", "display"):
            if key in step and not isinstance(step[key], bool):
                raise TourError(f"{where}: `{key}` must be true or false")
        if "optional" in step and (not isinstance(step["optional"], str) or not step["optional"].strip()):
            raise TourError(f"{where}: `optional` is the reason the step may fail")
        expect = step.get("expect")
        if expect is not None:
            if not isinstance(expect, dict) or set(expect) - {"method", "fields"}:
                raise TourError(f"{where}: `expect` must contain only `method` and `fields`")
            if not isinstance(expect.get("method"), str) or not expect["method"].strip():
                raise TourError(f"{where}: `expect.method` must be a non-empty string")
            if (not isinstance(expect.get("fields"), dict) or not expect["fields"]
                    or not all(isinstance(field, str) and field for field in expect["fields"])):
                raise TourError(f"{where}: `expect.fields` must be a non-empty object of field names")
    focus_after_close(path, steps)
    return {"name": slug(path.stem), "title": data["title"].strip(), "steps": steps, "settings": data.get("settings")}


def _action(step: dict[str, Any]) -> str | None:
    """The action id a `cmux action run ID ...` step runs, else None."""
    command = step.get("cmux") or []
    return command[2] if len(command) >= 3 and command[:2] == ["action", "run"] else None


def _keeps_panes(step: dict[str, Any]) -> bool:
    """A step that opens no pane: a wait, a setting, a tunable, or a focus move."""
    command, rpc = step.get("cmux"), step.get("rpc")
    if command is None and rpc is None:
        return True
    if rpc is not None:
        return command is None and rpc["method"] == "debug.tunables"
    action = _action(step)
    return command[0] == "settings" or action in FOCUS_MOVES


def focus_after_close(path: Path, steps: list[dict[str, Any]]) -> None:
    """A directional focus is refused when the last step that changed the panes closed one: the close
    leaves the focus on a neighbour, and when it left one pane the move fails with "no pane left of
    the focused pane", which fails the whole capture (#27839's main-pane tour)."""
    for number, step in enumerate(steps, 1):
        if _action(step) not in DIRECTIONAL_FOCUS:
            continue
        for earlier in reversed(steps[:number - 1]):
            if _action(earlier) in PANE_CLOSES:
                raise TourError(
                    f"{path}: step {number} runs {_action(step)} after {_action(earlier)} with no pane opened "
                    "between: the close already focused a neighbour, and with one pane left the move fails. "
                    "Drop the step, or focus a pane by number (focusPaneByNumber)")
            if not _keeps_panes(earlier):
                break


def command_line(argv: list[str]) -> str:
    return " ".join(word if re.fullmatch(r"[\w@%+=:,./-]+", word) else json.dumps(word) for word in argv)


class Session:
    """Runs commands in the console user's GUI session.

    `prefix` reaches that session from another user (app launch, kill).
    The app's own window (debug.window_snapshot) needs no grant and shows
    nothing that covers it, such as permission prompts or another job's
    windows, so the screen is only the fallback for an app without it.
    Capture needs Screen Recording, which a job's process may not have, so
    three routes are probed once and the first that writes an image wins:
    screencapture from this process, screencapture through `launchctl
    asuser` (main's E2E recorder; needs passwordless sudo), and an approved
    CuaSshScreenCapture.app (main's scripts/release-media helper backend).
    With none of them, `app_window` is set: the app snapshots its own window.
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
        self.app_window = False

    def run(self, argv: list[str], timeout: float = 15) -> subprocess.CompletedProcess[str]:
        return subprocess.run(self.prefix + argv, capture_output=True, text=True, timeout=timeout)

    def capture(self, argv: list[str], timeout: float = 15) -> subprocess.CompletedProcess[str]:
        return subprocess.run(self.capture_prefix + argv, capture_output=True, text=True, timeout=timeout)

    def probe_once(self) -> None:
        """probe_capture on first use, in a scratch folder that never leaves the runner."""
        if self.capture_mode != "unprobed":
            return
        probe = Path(tempfile.mkdtemp(prefix="cmux-tour-probe.", dir="/tmp"))
        try:
            self.probe_capture(self.shareable(probe))
        finally:
            # The probe captured the whole display.
            shutil.rmtree(probe, ignore_errors=True)

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
        # The app's own window needs no grant; a build without the debug verb
        # reports its error on every shot instead.
        print("no screen capture route (" + "; ".join(notes) + ")", flush=True)
        self.app_window = True
        self.capture_mode = APP_WINDOW_MODE

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

    def window_id(self, pid: int, size: tuple[int, int] | None = None) -> int | None:
        """The window server id of `pid`'s on-screen normal window of this size (the main window's), else its
        largest on-screen one, from the window list (ids and bounds need no Screen Recording grant)."""
        width, height = size or (0, 0)
        script = ('ObjC.import("CoreGraphics");'
                  'var list = ObjC.deepUnwrap(ObjC.castRefToObject($.CGWindowListCopyWindowInfo('
                  '$.kCGWindowListOptionOnScreenOnly | $.kCGWindowListExcludeDesktopElements, 0))) || [];'
                  f'var mine = list.filter(function (w) {{ return w.kCGWindowOwnerPID === {int(pid)} && w.kCGWindowLayer === 0; }});'
                  'function area(w) { return w.kCGWindowBounds.Width * w.kCGWindowBounds.Height; }'
                  f'var sized = mine.filter(function (w) {{ return Math.abs(w.kCGWindowBounds.Width - {int(width)}) <= 1'
                  f' && Math.abs(w.kCGWindowBounds.Height - {int(height)}) <= 1; }});'
                  'var pick = (sized.length ? sized : mine).sort(function (a, b) { return area(b) - area(a); });'
                  'pick.length ? String(pick[0].kCGWindowNumber) : ""')
        try:
            done = self.capture(["osascript", "-l", "JavaScript", "-e", script])
        except (OSError, subprocess.SubprocessError):
            return None
        text = done.stdout.strip()
        return int(text) if text.isdigit() else None

    def shareable(self, path: Path) -> Path:
        """A directory the session's user can write when that user is someone else."""
        path.mkdir(parents=True, exist_ok=True)
        if self.prefix or self.capture_prefix:
            path.chmod(0o777)
        return path


class Screen:
    """Screenshots of the app's main window through `app` (debug.window_snapshot),
    or, after use_display(), of that window alone by its window server id
    (`screencapture -l`), which shows the window even when another covers it."""

    def __init__(self, session: Session, scratch: Path | None = None, app: App | None = None) -> None:
        self.session = session
        self.scratch = scratch or Path(tempfile.gettempdir())
        self.app = app
        self.rect: tuple[int, int, int, int] | None = None
        self.pid: int | None = None
        self.window_id: int | None = None

    @property
    def mode(self) -> str:
        return APP_WINDOW_MODE if self.app else self.session.capture_mode

    def use_display(self, pid: Any) -> None:
        """Capture the app's window through the window server from now on; follow() again after."""
        self.app = None
        self.rect = None
        self.pid = pid if isinstance(pid, int) else None

    def follow(self, frame: list[float] | None) -> None:
        """Aim at a window frame (NSWindow coordinates: bottom-left origin on the primary screen)."""
        # Without a usable window frame (none, gone, too small) nothing is captured.
        self.rect = None
        if not frame or len(frame) != 4 or frame[2] < 50 or frame[3] < 50:
            return
        self.rect = tuple(int(value) for value in frame)
        if not self.app:
            # The on-screen window of the main window's size (main_window_frame); child windows (Chromium
            # pages, overlay panels) are separate windows this route leaves out, so it is the last resort
            # for builds that cannot snapshot themselves.
            self.window_id = self.session.window_id(self.pid, (self.rect[2], self.rect[3])) if self.pid else None

    def capture(self, path: Path, kind: str = "png") -> str | None:
        """Write a screenshot of the app's window; None on success, else what went wrong.

        Never the display: the runner's console is shared with other jobs'
        windows, and these images are published.
        """
        if not self.rect:
            return "no app window on screen to capture"
        if self.app:
            return self.app_window_capture(path, kind)
        if self.window_id is None:
            return "no window server id for the app's window"
        if self.session.helper:
            return self.helper_capture(path, kind)
        argv = ["/usr/sbin/screencapture", "-x", "-o", "-t", kind, f"-l{self.window_id}", str(path)]
        try:
            done = self.session.capture(argv)
        except subprocess.TimeoutExpired:
            return "screencapture timed out"
        if path.is_file() and path.stat().st_size > 0:
            return None
        return (done.stderr or done.stdout or f"screencapture exited {done.returncode}").strip()

    def helper_capture(self, path: Path, kind: str) -> str | None:
        """The app's window through the helper (`window <id>`), as PNG or JPEG."""
        raw = path if kind == "png" else self.scratch / f"helper-{threading.get_ident()}.png"
        problem = self.session.helper_capture(self.session.helper, ["window", str(self.window_id)], raw)
        if problem or raw == path:
            return problem
        done = subprocess.run(["sips", "-s", "format", "jpeg", str(raw), "--out", str(path)],
                              capture_output=True, text=True)
        raw.unlink(missing_ok=True)
        if path.is_file() and path.stat().st_size > 0:
            return None
        return (done.stderr or done.stdout).strip() or "sips wrote no image"

    def app_window_capture(self, path: Path, kind: str) -> str | None:
        """The app's main window as it draws it (debug.window_snapshot), as PNG or JPEG."""
        # The app writes PNG; a JPEG starts in scratch and sips converts it.
        raw = path if kind == "png" else self.scratch / f"window-{threading.get_ident()}.png"
        try:
            raw.unlink(missing_ok=True)
            result = self.app.request("debug.window_snapshot", {"kind": "main", "path": str(raw)},
                                      timeout=SNAPSHOT_TIMEOUT)
        except (OSError, ValueError, TourError) as error:
            return f"debug.window_snapshot: {error}"
        if not isinstance(result, dict) or result.get("error"):
            problem = result.get("error") if isinstance(result, dict) else "no result"
            raw.unlink(missing_ok=True)
            return f"debug.window_snapshot: {problem}"
        if not raw.is_file() or raw.stat().st_size == 0:
            return "debug.window_snapshot wrote no image"
        if raw == path:
            return None
        done = subprocess.run(["sips", "-s", "format", "jpeg", str(raw), "--out", str(path)],
                              capture_output=True, text=True)
        raw.unlink(missing_ok=True)
        if path.is_file() and path.stat().st_size > 0:
            return None
        return (done.stderr or done.stdout).strip() or "sips wrote no image"


def frame_interval(mode: str) -> float:
    """Seconds between video frames for the session's capture route."""
    return APP_WINDOW_FRAME_INTERVAL if mode == APP_WINDOW_MODE else FRAME_INTERVAL


class WindowVideo:
    def __init__(self, session, pid: int | None, directory: Path, scratch: Path):
        self.session, self.pid = session, pid
        self.path = directory / "capture.mov"
        self.scratch = scratch
        self.process = None
        self.log = None
        self.reason = ""
        self.log_path = self.scratch / "record-window.log"

    def start(self) -> bool:
        if sys.platform != "darwin" or self.pid is None:
            self.reason = "ScreenCaptureKit requires macOS and an app PID"
            return False
        binary = self.scratch / "record-window"
        source = Path(__file__).with_name("record-window.swift")
        try:
            built = subprocess.run(["xcrun", "swiftc", "-parse-as-library", str(source), "-o", str(binary)],
                                   capture_output=True, text=True, timeout=120)
            if built.returncode:
                self.reason = "ScreenCaptureKit helper unavailable: " + built.stderr[-500:]
                return False
            # Both existing console routes can have different Screen Recording grants.
            for mode, prefix in self.session.capture_routes:
                self.path.unlink(missing_ok=True)
                self.log = self.log_path.open("w+")
                self.process = subprocess.Popen(prefix + [str(binary), str(self.pid), str(self.path)],
                                                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.log,
                                                text=True)
                with selectors.DefaultSelector() as ready:
                    ready.register(self.process.stdout, selectors.EVENT_READ)
                    if ready.select(timeout=30) and self.process.stdout.readline().strip() == "READY":
                        return True
                self.stop()
                self.reason = f"ScreenCaptureKit unavailable through {mode}: " + self.log_path.read_text()[-500:].strip()
        except (OSError, subprocess.SubprocessError) as error:
            self.reason = str(error)
            self.stop()
        self.path.unlink(missing_ok=True)
        return False

    def stop(self) -> bool:
        if self.process is None:
            return False
        process, self.process = self.process, None
        try:
            process.communicate(input="\n", timeout=20)
        except (OSError, subprocess.TimeoutExpired):
            process.kill()
            process.communicate()
        finally:
            if self.log:
                self.log.close()
                self.log = None
        return process.returncode == 0 and self.path.is_file() and self.path.stat().st_size > 0


class Recorder(threading.Thread):
    """Frames of the app's window about every `interval` seconds, tagged with the step."""

    def __init__(self, screen: Screen, directory: Path) -> None:
        super().__init__(daemon=True)
        self.screen = screen
        self.directory = directory
        self.step = 0
        self.frames: list[dict[str, Any]] = []
        self.error: str | None = None
        self.stopping = threading.Event()
        self.lock = threading.Lock()
        self.interval = frame_interval(screen.mode)
        self.started = 0.0
        self.elapsed = 0.0

    def run(self) -> None:
        self.started = time.monotonic()
        while not self.stopping.is_set() and time.monotonic() - self.started < MAX_SECONDS:
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
                    self.frames.append({"file": f"frames/{path.name}", "step": self.step,
                                        "time": started - self.started})
            self.stopping.wait(max(0.0, self.interval - (time.monotonic() - started)))

    def stop(self) -> list[dict[str, Any]]:
        """Stop recording; the frames kept, which nothing appends to afterwards."""
        with self.lock:
            self.stopping.set()
            self.elapsed = min(MAX_SECONDS, time.monotonic() - self.started) if self.started else 0.0
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

    def __init__(self, app_path: Path, session: Session, workdir: Path, *, fresh_state: bool = False,
                 settings: dict[str, Any] | None = None, launch_env: dict[str, str] | None = None,
                 launch_args: list[str] | None = None) -> None:
        self.app_path = app_path
        # Extra environment knobs and app arguments for one launch (the nightly
        # visual gate's states launch with --showcase, for example).
        self.launch_env = dict(launch_env or {})
        self.launch_args = list(launch_args or [])
        self.session = session
        self.fresh_state = fresh_state
        self.cli_path = app_path / "Contents/Resources/bin/cmux"
        with (app_path / "Contents/Info.plist").open("rb") as plist:
            info = plistlib.load(plist)
        self.executable = app_path / "Contents/MacOS" / info["CFBundleExecutable"]
        self.bundle_tag = clean_tag((info.get("LSEnvironment") or {}).get("CMUX_TAG"))
        # sun_path holds 104 bytes, so the socket lives in a short private directory.
        self.workdir = workdir
        self.socket_path = session.shareable(workdir) / "s.sock"
        self.log_path = workdir / "app.log"
        # The tour's own settings file; None keeps the session user's.
        self.settings_path: Path | None = None
        if settings is not None:
            self.settings_path = session.shareable(workdir) / "cmux-next.json"
            self.settings_path.write_text(json.dumps(settings, indent=2) + "\n", encoding="utf-8")
            if session.prefix:
                self.settings_path.chmod(0o666)
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

    def write_shell_home(self) -> Path:
        """The tour's own zsh startup folder (FIXTURE_ZSHRC), readable by the session's user."""
        home = self.session.shareable(self.workdir / "shell-home")
        rc = home / ".zshrc"
        rc.write_text(FIXTURE_ZSHRC, encoding="utf-8")
        rc.chmod(0o644)
        return home

    def launch(self) -> None:
        self.stop_daemon()
        self.clear_leftovers()
        self.clear_state()
        # CMUX_NEXT_NO_ACTIVATE: the app refuses every activation, so tours side by side on one Mac never take
        # focus or the key window from each other; debug.key and the CLI work on a window that is never key.
        knobs = [f"CMUX_NEXT_SOCKET_PATH={self.socket_path}", "CMUX_NEXT_SOCKET_MODE=allowAll", "CMUX_NEXT_NO_ACTIVATE=1",
                 f"CMUX_CAPTURE_SHELL_HOME={self.write_shell_home()}"]
        if self.settings_path:
            knobs.append(f"CMUX_NEXT_CONFIG_FILE={self.settings_path}")
        knobs += [f"{key}={value}" for key, value in sorted(self.launch_env.items())]
        argv = self.session.prefix + ["env", *knobs, str(self.executable), "-ApplePersistenceIgnoreState", "YES",
                                      *self.launch_args]
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

    def pid(self) -> int | None:
        """The app's process id: from identify, else the newest process running this build's executable."""
        pid = self.identity.get("pid")
        if isinstance(pid, int):
            return pid
        if not self.session.prefix and self.process is not None:
            return self.process.pid  # `env` execs the app in place
        found = self.session.run(["pgrep", "-n", "-f", re.escape(str(self.executable))]).stdout.strip()
        return int(found) if found.isdigit() else None

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

    def request(self, method: str, params: dict[str, Any] | None = None, timeout: float = 10) -> Any:
        """One control-socket request with no CLI verb (debug.layers has none).

        Each request has its own connection, so the recorder thread and the
        steps never share one.
        """
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
            connection.settimeout(timeout)
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


def _postcondition_field(state: Any, field: str) -> tuple[bool, Any]:
    """Read a dotted field from a JSON object, allowing numeric list indexes."""
    current = state
    for part in field.split("."):
        if isinstance(current, dict) and part in current:
            current = current[part]
        elif isinstance(current, list) and part.isdigit() and int(part) < len(current):
            current = current[int(part)]
        else:
            return False, None
    return True, current


def check_postcondition(app: App, step: dict[str, Any]) -> tuple[str, str]:
    """Run a declared app-owned debug RPC and compare its expected fields."""
    expect = step.get("expect")
    if expect is None:
        return "skipped", "not configured"
    method = expect["method"]
    if method not in READ_ONLY_POSTCONDITION_METHODS:
        status = "unavailable" if step.get("optional") else "failed"
        return status, f"{method}: not an allowed read-only debug method"
    deadline = time.monotonic() + POSTCONDITION_TIMEOUT
    last_detail = "no state observed"
    while time.monotonic() < deadline:
        if not app.alive():
            status = "unavailable" if step.get("optional") else "failed"
            return status, f"{method}: app exited before postcondition"
        try:
            remaining = max(0.1, min(2.0, deadline - time.monotonic()))
            state = app.request(method, {"after": "sync"}, timeout=remaining)
        except (OSError, ValueError, TourError, socket.timeout) as error:
            status = "unavailable" if step.get("optional") else "failed"
            return status, f"{method}: {error}"
        mismatches = []
        observed = {}
        for field, expected in expect["fields"].items():
            found, actual = _postcondition_field(state, field)
            if found:
                observed[field] = actual
            if not found:
                mismatches.append(f"{field} missing (expected {json.dumps(expected, sort_keys=True)})")
            elif not _json_equal(actual, expected):
                mismatches.append(
                    f"{field}={json.dumps(actual, sort_keys=True)} (expected {json.dumps(expected, sort_keys=True)})"
                )
        if not mismatches:
            fields = ", ".join(expect["fields"])
            return "passed", f"{method}: matched {fields}; observed={json.dumps(observed, sort_keys=True)}"
        last_detail = f"{method}: " + "; ".join(mismatches)
        time.sleep(0.05)
    return ("unavailable" if step.get("optional") else "failed"), last_detail


def _json_equal(actual: Any, expected: Any) -> bool:
    """Compare JSON values without Python's bool-is-an-int coercion."""
    if type(actual) is not type(expected):
        return False
    if isinstance(actual, dict):
        return actual.keys() == expected.keys() and all(_json_equal(actual[key], expected[key]) for key in actual)
    if isinstance(actual, list):
        return len(actual) == len(expected) and all(_json_equal(a, e) for a, e in zip(actual, expected))
    return actual == expected


def display_capture(app: App, screen: Screen, path: Path) -> str | None:
    """The window's rect from the screen, so the shot shows a menu or popover
    (its own window, which the main window's snapshot leaves out)."""
    app.session.probe_once()
    if app.session.app_window:
        return "no screen capture route for a display shot"
    display = Screen(app.session, screen.scratch)
    display.use_display(app.pid())
    display.follow(app.main_window_frame())
    return display.capture(path)


def shoot_other_windows(app: App, main_shot: Path) -> tuple[list[dict[str, Any]], str | None]:
    """Every other visible window of the app beside the main window's shot: a
    floating panel, popover or sheet is its own window, which the main window's
    snapshot leaves out unless it is a child window. `debug.window_list` names
    them and `debug.window_snapshot` takes any window's number. A child window
    of another window (a Chromium page, the overlay panel) is skipped: the
    main shot composites it. A sheet is shot. An app without the list (an
    older base build) gets no extra shots and no error. The shots share
    OTHER_WINDOWS_BUDGET seconds and stop at the first failure past it."""
    deadline = time.monotonic() + OTHER_WINDOWS_BUDGET
    try:
        listed = app.request("debug.window_list", timeout=min(SNAPSHOT_TIMEOUT, OTHER_WINDOWS_BUDGET))
    except TourError as error:
        text = str(error).lower()
        unknown = "unknown method" in text or "method_not_found" in text
        return [], None if unknown else f"debug.window_list: {error}"
    except (OSError, ValueError) as error:
        return [], f"debug.window_list: {error}"
    windows = listed.get("windows") if isinstance(listed, dict) else None
    shots: list[dict[str, Any]] = []
    problems: list[str] = []
    for window in windows if isinstance(windows, list) else []:
        if len(shots) >= MAX_OTHER_WINDOWS:
            break
        if not isinstance(window, dict) or window.get("kind") == "main" or window.get("visible") is not True:
            continue
        if window.get("parent") is not None and window.get("kind") != "sheet":
            continue
        number, frame, alpha = window.get("id"), window.get("frame") or {}, window.get("alpha", 1)
        if not isinstance(number, int) or isinstance(number, bool) or number <= 0 or not isinstance(frame, dict):
            continue
        if not isinstance(alpha, (int, float)) or alpha <= 0:
            continue
        width, height = frame.get("width", 0), frame.get("height", 0)
        if not all(isinstance(v, (int, float)) for v in (width, height)) \
                or width < MIN_OTHER_WINDOW[0] or height < MIN_OTHER_WINDOW[1]:
            continue
        left = deadline - time.monotonic()
        if left <= 1:
            problems.append("out of time for the other windows")
            break
        path = main_shot.with_name(f"{main_shot.stem}--w{number}.png")
        try:
            done = app.request("debug.window_snapshot", {"window": number, "path": str(path)},
                               timeout=min(SNAPSHOT_TIMEOUT, left))
        except (OSError, ValueError, TourError) as error:
            problems.append(f"window {number}: {error}")
            continue
        if not isinstance(done, dict) or done.get("error") or not path.is_file() or path.stat().st_size == 0:
            path.unlink(missing_ok=True)
            problems.append(f"window {number}: {done.get('error') if isinstance(done, dict) else 'no image'}")
            continue
        shots.append({"id": number, "kind": str(window.get("kind") or "window")[:40], "shot": f"shots/{path.name}"})
    return shots, "; ".join(problems)[:500] or None


def step_label(result: dict[str, Any]) -> str:
    """A step's status as reports show it: "unchecked" for an ok step whose shot no `expect` checked."""
    if result.get("status") == "ok" and result.get("shot") and result.get("checked") is False:
        return "unchecked"
    return str(result.get("status", ""))


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
    rpc = step.get("rpc")
    if rpc and result["status"] == "ok":
        result["rpc"] = rpc["method"]
        try:
            answer = app.request(rpc["method"], rpc.get("params") or {})
            error = answer.get("error") if isinstance(answer, dict) else None
            # A method that answers but could not do it says so in its own `ok` (a bool, or
            # "false" from a method whose answer is all strings, as debug.hover_cards {gallery}).
            if not error and isinstance(answer, dict) and answer.get("ok") in (False, "false"):
                error = "answered ok: false"
            result["output"] = json.dumps(answer)[-1500:]
        except (OSError, ValueError, TourError, socket.timeout) as problem:
            error = str(problem)
        if error:
            result["status"] = "unavailable" if step.get("optional") else "failed"
            result["detail"] = f"{rpc['method']}: {error}"
            if step.get("optional"):
                result["detail"] += f" ({step['optional']})"
    time.sleep(step.get("wait", DEFAULT_WAIT))
    postcondition_status, postcondition_detail = check_postcondition(app, step)
    result["postcondition"] = {
        "method": (step.get("expect") or {}).get("method"),
        "expected": (step.get("expect") or {}).get("fields"),
        "status": postcondition_status,
        "detail": postcondition_detail,
    }
    # Whether an `expect` read the app's state and matched it. A step without one reports "ok" once
    # it ran, whatever its shot shows, so its shot is unchecked (see `step_label`).
    result["checked"] = postcondition_status == "passed"
    if postcondition_status in ("failed", "unavailable"):
        result["status"] = postcondition_status
        result["detail"] = (result.get("detail", "") + " " + postcondition_detail).strip()
        if postcondition_status == "unavailable" and step.get("optional") and step["optional"] not in result["detail"]:
            result["detail"] += f" ({step['optional']})"
    if not app.alive():
        result["status"] = "failed"
        result["detail"] = (result.get("detail", "") + " the app is no longer running").strip()
    screen.follow(app.main_window_frame())
    if step.get("shot", True) or result["status"] == "failed":
        suffix = "-failed" if result["status"] == "failed" else ""
        path = shots / f"{index:02d}-{slug(step['title'])}{suffix}.png"
        problem = display_capture(app, screen, path) if step.get("display") else screen.capture(path)
        if problem:
            result["shot_error"] = problem
        else:
            result["shot"] = f"shots/{path.name}"
            if screen.app and step.get("windows", not step.get("display")):
                windows, problem = shoot_other_windows(app, path)
                if windows:
                    result["windows"] = windows
                if problem:
                    result["windows_error"] = problem
    result["seconds"] = round(time.monotonic() - started, 2)
    return result


def run_tour(app_path: Path, tour: dict[str, Any], out: Path, session: Session, *,
             fresh_state: bool = False) -> dict[str, Any]:
    directory = out / tour["name"]
    if directory.exists():
        shutil.rmtree(directory)
    shots = session.shareable(directory / "shots")
    frames = session.shareable(directory / "frames")
    workdir = Path(tempfile.mkdtemp(prefix="cmux-tour.", dir="/tmp"))
    app = App(app_path, session, workdir, fresh_state=fresh_state, settings=tour.get("settings"))
    screen = Screen(session, session.shareable(workdir / "raw"), app)
    recorder = Recorder(screen, frames)
    video = WindowVideo(session, None, session.shareable(directory), screen.scratch)
    video_started = False
    manifest: dict[str, Any] = {"name": tour["name"], "title": tour["title"], "steps": [], "frames": [],
                                "frame_interval": recorder.interval, "console_user": session.user,
                                "capture_mode": screen.mode}
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
        probe = screen.scratch / "probe-window.png"
        if screen.rect is not None and screen.capture(probe):
            # No window snapshot from this build: the display, if a route works.
            session.probe_once()
            if not session.app_window:
                screen.use_display(app.pid())
                screen.follow(app.main_window_frame())
        probe.unlink(missing_ok=True)
        recorder.interval = frame_interval(screen.mode)
        manifest["capture_mode"], manifest["frame_interval"] = screen.mode, recorder.interval
        print(f"[{tour['name']}] screen capture: {screen.mode}", flush=True)
        if screen.rect is None:
            manifest["frames_error"] = f"no app window on screen within {WINDOW_TIMEOUT:.0f}s"
        else:
            video.pid = app.pid()
            video_started = video.start()
            if video_started:
                manifest["video_mode"] = "ScreenCaptureKit window, requested 60 fps"
            else:
                manifest["video_fallback"] = video.reason
                print(f"[{tour['name']}] still-only video fallback: {video.reason}", flush=True)
                recorder.start()
        for index, step in enumerate(tour["steps"], 1):
            recorder.step = index
            result = run_step(app, screen, step, index, shots)
            manifest["steps"].append(result)
            print(f"[{tour['name']}] {index:02d} {step_label(result):<11} {step['title']}"
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
        # Finalize video while its window still exists. Never capture what is behind a closed app.
        video_ok = video.stop()
        if video_started:
            if video_ok:
                manifest["video"] = "capture.mov"
            else:
                manifest["frames_error"] = "window video could not be finalized"
        manifest["frames"] = recorder.stop() if recorder.ident else []
        if manifest["frames"] and recorder.elapsed:
            manifest["frame_interval"] = recorder.elapsed / len(manifest["frames"])
            manifest["capture_fps"] = len(manifest["frames"]) / recorder.elapsed
        # Then the app: a leftover app or daemon would serve the next run on this Mac.
        app.stop()
        if recorder.error and not manifest["frames"]:
            manifest.setdefault("frames_error", recorder.error)
        manifest["capture_rect"] = screen.rect
        if not screen.app:
            manifest["capture_window"] = screen.window_id
        if app.log_path.exists():
            shutil.copy(app.log_path, directory / "app.log")
        shutil.rmtree(workdir, ignore_errors=True)
        manifest["result"] = classify_result(manifest)
        (directory / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    return manifest


def running_from(session: Session, bundle: Path) -> list[int]:
    """Processes whose executable is in the bundle: the command starts with its path."""
    found = session.run(["pgrep", "-f", "^" + re.escape(f"{bundle}/Contents/")]).stdout.split()
    return [int(pid) for pid in found if pid.isdigit()]


def stop_apps(bundles: list[Path], session: Session) -> bool:
    """End what each built app left running; False when something outlived SIGKILL.

    A cancel can land while the app starts: run 39199091515's chief host started
    a minute after its capture step was cancelled, and with its parent gone it
    held cmux10s's DerivedData open for days. Only the command's start is
    matched, so a process that merely names the bundle in its arguments stays.
    """
    clean = True
    for bundle in bundles:
        if not (bundle / "Contents/Info.plist").is_file():
            print(f"{bundle}: no app here; nothing to stop", flush=True)
            continue
        workdir = Path(tempfile.mkdtemp(prefix="cmux-tour-stop.", dir="/tmp"))
        try:
            App(bundle, session, workdir).stop_daemon()
        except (OSError, ValueError, KeyError) as error:
            # A half-built bundle (no CLI, a bad Info.plist) still gets its processes ended.
            print(f"{bundle.name}: could not stop its daemon ({error})", flush=True)
        finally:
            shutil.rmtree(workdir, ignore_errors=True)
        pattern = "^" + re.escape(f"{bundle}/Contents/")
        left = running_from(session, bundle)
        if left:
            session.run(["pkill", "-f", pattern])
            deadline = time.monotonic() + STOP_GRACE
            while (left := running_from(session, bundle)) and time.monotonic() < deadline:
                time.sleep(0.5)
        if left:
            session.run(["pkill", "-9", "-f", pattern])
            time.sleep(1)
            left = running_from(session, bundle)
        print(f"{bundle.name}: " + (f"still running {left}" if left else "nothing left running"), flush=True)
        clean = clean and not left
    return clean


def terminated(signum: int, frame: Any) -> None:
    raise SystemExit(128 + signum)


def passed(manifest: dict[str, Any]) -> bool:
    return "error" not in manifest and all(step["status"] != "failed" for step in manifest["steps"])


def classify_result(manifest: dict[str, Any]) -> str:
    """Classify the evidence without treating optional gaps as full coverage."""
    if manifest.get("error") or any(step.get("status") == "failed" for step in manifest.get("steps", [])):
        return "failed"
    if manifest.get("frames_error") or any(
        step.get("status") == "unavailable" or step.get("shot_error")
        for step in manifest.get("steps", [])
    ):
        return "degraded"
    return "pass"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("tours", nargs="*", type=Path, help="tour JSON files or directories of them")
    parser.add_argument("--app", type=Path, help="the built app bundle")
    parser.add_argument("--out", type=Path, help="where each tour's folder goes")
    parser.add_argument("--check", action="store_true", help="only validate the tour files")
    parser.add_argument("--fresh-state", action="store_true",
                        help="delete the tagged build's saved workspaces before and after each tour")
    parser.add_argument("--stop", type=Path, action="append", default=[], metavar="APP",
                        help="end what this built app left running, then exit (repeatable)")
    args = parser.parse_args(argv)
    if args.stop:
        return 0 if stop_apps(args.stop, Session()) else 1
    if not args.tours:
        parser.error("give tour files, or --stop")
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
    ok = True
    for tour in tours:
        signal.signal(signal.SIGINT, signal.default_int_handler)
        signal.signal(signal.SIGTERM, terminated)
        manifest = run_tour(args.app, tour, args.out, session, fresh_state=args.fresh_state)
        manifest["result"] = classify_result(manifest)
        (args.out / tour["name"] / "manifest.json").write_text(
            json.dumps(manifest, indent=2) + "\n", encoding="utf-8"
        )
        print(f"[{tour['name']}] result={manifest['result']}", flush=True)
        ok = passed(manifest) and ok
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
