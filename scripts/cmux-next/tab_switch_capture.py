"""The capture half of the tab switch harness (tab_switch_frames.py): the screen recorded by CuaDriver, synced to the
harness's actions by a marker window, decoded into frames tab_switch_judge.py reads.

Why CuaDriver: a recorder compiled on the step is a new binary to TCC every run, so it never holds the Screen Recording
grant (the NIGHTLY run of 2026-11-16 got SCStream -3801 "The user declined TCCs"), and without it macOS leaves other
processes' layers (the chat's and the Chromium page's) out of a capture. CuaDriver (/Applications/CuaDriver.app) is the
one signed app the fleet grants it (cmuxterm-hq build-fleet/mini-ops/cua-driver.sh grant; pr-capture's displayRecord
records the same way). Its start_recording keeps its stream for the life of the `cua-driver mcp` session that started
it, and writes an mp4 of the main display.

The sync: tools.swift's `marker` shows a small black or white window in the display's top-left corner, flipped right
before each action. A flip makes a frame (the display changed); its presentation time in the video is the action's
mark. A block is one recording: the flips are matched to the marker's luma transitions in order, so a block whose
counts disagree is reported, never guessed.

Everything here is drive-then-judge: the frames exist only once the block's recording stops and decodes.
"""
from __future__ import annotations

import json
import os
import select
import shutil
import signal
import subprocess
import sys
import threading
import time

import tab_switch_judge as judge

sys.path.append(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "ci"))
from ci_process_tree import kill_group  # noqa: E402  (a refused killpg still kills the leader)

CUA_DRIVER = "/Applications/CuaDriver.app/Contents/MacOS/cua-driver"
ANSWER_SECONDS = 30.0


class CaptureError(Exception):
    """The capture could not record or sync (the run cannot measure)."""


class CuaSession:
    """One `cua-driver mcp` session holding a display recording (pr-capture's display_record.py, minimal)."""

    def __init__(self, driver=CUA_DRIVER):
        if not os.access(driver, os.X_OK):
            raise CaptureError(f"no CuaDriver at {driver} (the display pool's granted recorder)")
        self.driver = driver
        self.process = None
        self.next_id = 0

    def _readline(self, seconds):
        got = []
        reader = threading.Thread(target=lambda: got.append(self.process.stdout.readline()), daemon=True)
        reader.start()
        reader.join(seconds)
        return got[0] if got else None

    def _send(self, method, params=None, notify=False):
        message = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            message["params"] = params
        if not notify:
            self.next_id += 1
            message["id"] = self.next_id
        self.process.stdin.write(json.dumps(message) + "\n")
        self.process.stdin.flush()
        if notify:
            return None
        end = time.monotonic() + ANSWER_SECONDS
        while time.monotonic() < end:
            line = self._readline(end - time.monotonic())
            if line is None:
                break
            if not line:
                raise CaptureError(f"cua-driver mcp closed during {method}")
            try:
                answer = json.loads(line)
            except ValueError:
                continue
            if answer.get("id") == self.next_id:
                if answer.get("error"):
                    raise CaptureError(f"cua-driver {method}: {json.dumps(answer['error'])[:300]}")
                return answer.get("result") or {}
        raise CaptureError(f"cua-driver {method}: no answer in {ANSWER_SECONDS:g} s")

    def tool(self, name, arguments):
        result = self._send("tools/call", {"name": name, "arguments": arguments})
        facts = result.get("structuredContent") if isinstance(result.get("structuredContent"), dict) else {}
        if result.get("isError") or facts.get("last_error"):
            words = " ".join(str(c.get("text", "")) for c in result.get("content") or [] if isinstance(c, dict))
            raise CaptureError(f"cua-driver {name}: {(facts.get('last_error') or words)[:300]}")
        return facts

    def open(self):
        self.process = subprocess.Popen([self.driver, "mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.DEVNULL, text=True, bufsize=1, start_new_session=True)
        self._send("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                  "clientInfo": {"name": "tab-switch", "version": "1"}})
        self._send("notifications/initialized", notify=True)
        granted = self.tool("check_permissions", {})
        if granted.get("screen_recording") is False:
            self.close()
            raise CaptureError("CuaDriver has no Screen Recording grant on this Mac (cmuxterm-hq build-fleet/mini-ops/"
                               "cua-driver.sh grant HOST)")
        return granted

    def start(self, folder):
        os.makedirs(folder, exist_ok=True)
        self.tool("start_recording", {"output_dir": os.path.realpath(folder), "record_video": True})

    def stop(self, folder):
        facts = self.tool("stop_recording", {})
        video = facts.get("last_video_path") or os.path.join(os.path.realpath(folder), "recording.mp4")
        if not os.path.isfile(video) or os.path.getsize(video) < 4096:
            raise CaptureError(f"CuaDriver wrote no video ({video})")
        return video

    def close(self):
        process, self.process = self.process, None
        if process is None:
            return
        try:
            process.stdin.close()
        except OSError:
            pass
        try:
            process.wait(timeout=ANSWER_SECONDS)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)  # our own child, by its own process group
            process.wait()


class Marker:
    """tools.swift's marker window: one flip per mark."""

    def __init__(self, tools, pid):
        self.process = subprocess.Popen([tools, "marker", str(pid)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.PIPE, text=True, bufsize=1, start_new_session=True)
        self.ready = self.reply(20)
        if not self.ready or not self.ready.get("ready"):
            raise CaptureError(f"marker: {self.ready or 'no answer'}")
        if not self.ready.get("window"):
            raise CaptureError(f"marker: the app (pid {pid}) has no on-screen window: {self.ready}")

    def reply(self, timeout):
        ready, _, _ = select.select([self.process.stdout], [], [], timeout)
        if not ready:
            return None
        line = self.process.stdout.readline()
        try:
            return json.loads(line)
        except ValueError:
            return {"error": line.strip()[:300]}

    def send(self, line):
        self.process.stdin.write(line + "\n")
        self.process.stdin.flush()

    def flip(self, name):
        self.send(f"flip {name}")
        answer = self.reply(5)
        if not answer or answer.get("flipped") != name:
            raise CaptureError(f"marker flip {name}: {answer}")
        time.sleep(0.05)  # test script: the flip's frame reaches the display before the action's change

    def window(self):
        self.send("window")
        return self.reply(5) or {}

    def quit(self):
        if self.process.poll() is None:
            try:
                self.send("quit")
                self.process.wait(timeout=5)
            except (OSError, subprocess.TimeoutExpired):
                pass
        # this run's own marker, by its own process group, whatever its leader's state: a child would outlive it
        kill_group(self.process, signal.SIGKILL)


def transitions(series, threshold=128.0):
    """The presentation times where the marker's mean gray crosses `threshold`, in order: each is one flip."""
    out = []
    state = None
    for t, mean in series:
        now = mean >= threshold
        if state is not None and now != state:
            out.append(t)
        state = now
    return out


class Capture:
    """Blocks of recording. `begin()`, then `flip(name)` before each action, then `end()` returns the block: its frames
    [(seconds, gray)] cropped to the app's window and each flip's time on the frames' clock."""

    def __init__(self, tools, pid, width, folder):
        self.tools, self.width, self.folder = tools, width, folder
        self.session = CuaSession()
        self.permissions = self.session.open()
        self.marker = Marker(tools, pid)
        ready = self.marker.ready
        self.window = ready["window"]
        self.display = ready["display"]
        self.hz = ready["display_hz"]
        self.frame_ms = 1000.0 / self.hz
        self.scale = width / self.window[2]  # recorded pixels per point
        self.w = width
        self.h = max(32, int(round(width * self.window[3] / self.window[2])))
        self.names = []
        self.blocks = 0
        self.video_fps = None

    def begin(self):
        self.names = []
        self.blocks += 1
        self.block_dir = os.path.join(self.folder, f"block-{self.blocks:02d}")
        self.session.start(self.block_dir)
        time.sleep(0.3)  # test script: the stream's first frame before the first flip

    def flip(self, name):
        self.names.append(name)
        self.marker.flip(name)

    def end(self):
        time.sleep(0.2)  # test script: the last change's frames reach the stream
        video = self.session.stop(self.block_dir)
        frames_path = os.path.join(self.block_dir, "frames.bin")
        decoded = self.decode(video, frames_path)
        self.video_fps = decoded.get("fps")
        frames = judge.read_segment(frames_path, decoded["w"], decoded["h"])
        flips = transitions(decoded.get("marker") or [])
        if len(flips) != len(self.names):
            raise CaptureError(f"block {self.blocks}: {len(self.names)} flips sent, {len(flips)} seen in the video "
                               f"({decoded.get('frames')} frames at {decoded.get('fps')} fps)")
        shutil.rmtree(self.block_dir, ignore_errors=True)
        return frames, dict(zip(self.names, flips))

    def decode(self, video, out):
        vw_points = self.display[2]
        probe = subprocess.run([self.tools, "decode", video, out, "0", "0", "1", "1", "8", "0", "0", "1", "1"],
                               capture_output=True, text=True, timeout=600)
        try:
            size = json.loads(probe.stdout.strip().splitlines()[-1])["video"]
        except (ValueError, KeyError, IndexError):
            raise CaptureError(f"decode probe: {(probe.stdout + probe.stderr)[-400:]}")
        px = size[0] / vw_points  # video pixels per point
        x, y, w, h = (v * px for v in self.window)
        mx, my, mw, mh = (v * px for v in [4, 4, 16, 16])  # the marker's middle (its 24 pt square at the corner)
        done = subprocess.run([self.tools, "decode", video, out, *(f"{v:.1f}" for v in (x, y, w, h)), str(self.w),
                               *(f"{v:.1f}" for v in (mx, my, mw, mh))], capture_output=True, text=True, timeout=1200)
        try:
            decoded = json.loads(done.stdout.strip().splitlines()[-1])
        except (ValueError, IndexError):
            raise CaptureError(f"decode: {(done.stdout + done.stderr)[-400:]}")
        if decoded.get("error") or not decoded.get("frames"):
            raise CaptureError(f"decode: {decoded}")
        if decoded["w"] != self.w or decoded["h"] != self.h:
            self.h = decoded["h"]
        return decoded

    def close(self):
        self.marker.quit()
        self.session.close()
