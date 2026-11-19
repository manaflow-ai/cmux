#!/usr/bin/env python3
"""The mobile bench's competitor capture on a Mac: one app, a list of flows, one clip each.

    capture.py --app BUNDLE_ID --flows id,id --out DIR --tools DIR [--hz 120] [--display 1600x1200]

Run by scripts/measure/mobile-bench-mac-capture.sh in the console user's GUI session of a fleet Mac (never a
person's Mac). It holds a virtual display at --hz as the main display (scripts/ci/frame-pacing/vdisplay.m), opens
the app there (an iPhone app "Designed for iPhone" runs on Apple Silicon as a wrapped bundle), puts its window at a
phone's size, and for each flow: records the window with ScreenCaptureKit at --hz (mbcap record, every frame's own
presentation time), sends the flow's stimulus (hid_inject: CGEvents at mach-time deadlines, each event's time
logged on the recorder's clock), waits for it to settle and stops. Each flow writes DIR/<app>/<flow>/clip.mp4 and
meta.json (the mobile bench's clip contract: app, flow, source, device, os, app_version, recorded_at, stimulus_t,
fps_nominal), plus recorder.json and input.json. A flow the app profile cannot drive here gets meta.json with
"unsupported" and its reason. Stdout carries `MOBILEBENCH ...` marker lines as well (cut.py's format).

The flows and how to drive them come from the app's profile: apps/<BUNDLE_ID>.json beside this file, or one passed
in as base64url JSON (--profile-b64; profiles of other companies' apps are kept outside this repo). Window-relative
points (fractions of the window, title bar included) for clicks and scrolls, keys, text. No grant falls back silently:
without Screen Recording for this process the recording goes through CuaDriver (the fleet's granted recorder; the
stimulus is found by a marker window's flip, tab-switch-frames/tools.swift), and without PostEvent the input goes
through `cua-driver call` (its call takes about 270 ms, so stimulus_uncertainty_s says so). Every route taken is in
meta.json and run.json.

Only what this run started is stopped: the app by the pids that appeared after its own launch (an app that was
already running is left alone and reported), the display holder, the recorder, the marker.
"""
from __future__ import annotations

import argparse
import base64
import datetime as dt
import json
import os
import platform
import pwd
import select
import signal
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
CUA = "/Applications/CuaDriver.app/Contents/MacOS/cua-driver"

# US ANSI virtual key codes (Carbon kVK_*), for typing through hid_inject; shifted characters below.
KEYS = {c: k for k, c in enumerate("asdfhgzxcv")}
KEYS.update({"b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21,
             "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32,
             "[": 33, "i": 34, "p": 35, "\n": 36, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43,
             "/": 44, "n": 45, "m": 46, ".": 47, "\t": 48, " ": 49, "`": 50})
NAMED = {"return": 36, "tab": 48, "space": 49, "delete": 51, "escape": 53, "left": 123, "right": 124, "down": 125,
         "up": 126, "home": 115, "end": 119, "pageup": 116, "pagedown": 121}
SHIFTED = {"?": "/", "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9",
           ")": "0", "_": "-", "+": "=", ":": ";", '"': "'", "<": ",", ">": "."}
STIMULUS_EVENTS = {"down", "key_down", "scroll", "drag"}


def log(*words):
    print("MBC", *words, flush=True)


def uptime_ns() -> int:
    return time.clock_gettime_ns(time.CLOCK_UPTIME_RAW)


def account_env():
    """The account's real HOME for cua-driver (a fleet step's HOME is a scratch folder: tab_switch_capture.driver_env)."""
    env = dict(os.environ)
    try:
        env["HOME"] = pwd.getpwuid(os.getuid()).pw_dir
    except KeyError:
        pass
    env.pop("CFFIXED_USER_HOME", None)
    return env


def run_json(argv, timeout=60, check=False):
    done = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
    lines = [line for line in done.stdout.splitlines() if line.strip().startswith("{")]
    try:
        value = json.loads(lines[-1]) if lines else {}
    except ValueError:
        value = {}
    if check and done.returncode != 0:
        raise RuntimeError(f"{os.path.basename(argv[0])} {argv[1] if len(argv) > 1 else ''}: exit {done.returncode} "
                           f"{(done.stderr or done.stdout).strip()[-300:]}")
    value.setdefault("_exit", done.returncode)
    if done.stderr.strip():
        value.setdefault("_stderr", done.stderr.strip()[-300:])
    return value


class Cua:
    """`cua-driver call TOOL JSON` with the account's HOME (its daemon holds the fleet's grants)."""

    def __init__(self):
        self.ok = os.access(CUA, os.X_OK)

    def call(self, tool, args, timeout=30):
        if not self.ok:
            raise RuntimeError("no CuaDriver on this Mac")
        done = subprocess.run([CUA, "call", tool, json.dumps(args)], capture_output=True, text=True, timeout=timeout,
                              env=account_env())
        try:
            result = json.loads(done.stdout) if done.stdout.strip() else {}
        except ValueError:
            result = {"raw": done.stdout[-300:]}
        if done.returncode != 0 or (isinstance(result, dict) and result.get("error")):
            raise RuntimeError(f"cua-driver {tool}: exit {done.returncode} {done.stdout[-300:]} {done.stderr[-300:]}")
        return result


class CuaRecorder:
    """A display recording by CuaDriver's own MCP session (tab_switch_capture.CuaSession), for a Mac where this
    process holds no Screen Recording grant."""

    def __init__(self):
        sys.path.insert(0, os.path.join(HERE, "..", "..", "cmux-next"))
        import tab_switch_capture  # noqa: E402  (scripts/cmux-next: the same session the tab switch bench records with)
        self.session = tab_switch_capture.CuaSession(CUA)
        self.granted = self.session.open()

    def start(self, folder):
        self.session.start(folder)

    def stop(self, folder):
        return self.session.stop(folder)

    def close(self):
        self.session.close()


class Marker:
    """tab-switch-frames/tools.swift's marker: a 24 pt square in the main display's top-left corner, flipped right
    before a stimulus so a recording on another clock (CuaDriver's) shows when the stimulus came."""

    def __init__(self, tools, pid):
        self.process = subprocess.Popen([tools, "marker", str(pid)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.DEVNULL, text=True, bufsize=1, start_new_session=True)
        self.ready = self.reply(20) or {}

    def reply(self, timeout):
        ready, _, _ = select.select([self.process.stdout], [], [], timeout)
        if not ready:
            return None
        try:
            return json.loads(self.process.stdout.readline())
        except ValueError:
            return None

    def flip(self, name):
        self.process.stdin.write(f"flip {name}\n")
        self.process.stdin.flush()
        answer = self.reply(5) or {}
        t = uptime_ns()
        time.sleep(0.05)
        return t, answer

    def quit(self):
        if self.process.poll() is None:
            try:
                self.process.stdin.write("quit\n")
                self.process.stdin.flush()
                self.process.wait(timeout=5)
            except (OSError, subprocess.TimeoutExpired):
                os.killpg(self.process.pid, signal.SIGKILL)  # our own marker, by its own process group


class Display:
    """vdisplay.m held for the run: the main display at HZ, gone when this process stops it."""

    def __init__(self, app, hz, size):
        self.process = subprocess.Popen([os.path.join(app, "Contents", "MacOS", "VDisplay"), str(hz), "3600", "main",
                                         size, "hidpi"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                        start_new_session=True)
        self.line = ""
        end = time.monotonic() + 30
        while time.monotonic() < end:
            ready, _, _ = select.select([self.process.stdout], [], [], end - time.monotonic())
            if not ready:
                break
            line = self.process.stdout.readline()
            if not line:
                break
            if line.startswith(("ready", "error")):
                self.line = line.strip()
                break
        parts = self.line.split()
        self.ok = len(parts) >= 3 and parts[0] == "ready"
        self.interval_ms = float(parts[2]) if self.ok else 0.0
        self.fields = dict(p.split("=", 1) for p in parts[3:] if "=" in p) if self.ok else {}

    def stop(self):
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(self.process.pid, signal.SIGKILL)  # our own display holder


class Run:
    def __init__(self, opts):
        self.opts = opts
        self.tools = opts.tools
        self.mbcap = os.path.join(opts.tools, "mbcap")
        self.hid = os.path.join(opts.tools, "hid_inject")
        self.cua = Cua()
        self.pids = []  # the app processes this run started
        self.window = None
        self.report = {"app": opts.app, "flows": {}, "routes": {}}
        self.profile = self.load_profile(opts.app, opts.profile_b64)
        self.name = opts.name or self.profile.get("name") or opts.app.split(".")[-1].lower()
        self.scratch = tempfile.mkdtemp(prefix="mbc-")

    @staticmethod
    def load_profile(bundle, b64=None):
        if b64:
            # A profile passed in the step's arguments (base64url JSON): an app whose profile lives outside this repo.
            return json.loads(base64.urlsafe_b64decode(b64 + "=" * (-len(b64) % 4)))
        path = os.path.join(HERE, "apps", f"{bundle}.json")
        if not os.path.isfile(path):
            return {"bundle": bundle, "flows": {}}
        with open(path) as f:
            return json.load(f)

    # -- the app --------------------------------------------------------------------------------------------

    def running(self):
        return run_json([self.mbcap, "pids", self.opts.app]).get("pids", [])

    def launch(self):
        """Opens the app through LaunchServices (as a Dock click does); returns the CLOCK_UPTIME_RAW ns of the open."""
        before = set(self.running())
        argv = ["/usr/bin/open", "-b", self.opts.app]
        document = self.profile.get("document")
        if document:
            argv += [self.document_path(document)]
        t = uptime_ns()
        subprocess.run(argv, capture_output=True, timeout=60)
        end = time.monotonic() + 30
        while time.monotonic() < end:
            new = [p for p in self.running() if p not in before]
            if new:
                self.pids = new
                break
            time.sleep(0.05)
        return t

    def document_path(self, document):
        """A scratch document for an app whose launch opens one (TextEdit): DOCUMENT is {"name", "lines"}."""
        path = os.path.join(self.scratch, document.get("name", "doc.txt"))
        if not os.path.exists(path):
            with open(path, "w") as f:
                for i in range(int(document.get("lines", 400))):
                    f.write(f"line {i + 1}: the quick brown fox jumps over the lazy dog, again and again.\n")
        return path

    def quit(self):
        for pid in self.pids:
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
        end = time.monotonic() + 10
        while time.monotonic() < end and any(self.alive(p) for p in self.pids):
            time.sleep(0.1)
        for pid in self.pids:
            if self.alive(pid):
                log("KILL", pid, "after 10 s")
                os.kill(pid, signal.SIGKILL)  # the app process this run launched, by its pid
        self.pids = []
        time.sleep(1.0)

    @staticmethod
    def alive(pid):
        try:
            os.kill(pid, 0)
            return True
        except ProcessLookupError:
            return False
        except PermissionError:
            return True

    def find_window(self, seconds=15):
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            for pid in self.pids:
                got = run_json([self.mbcap, "window", str(pid)])
                if got.get("window"):
                    return pid, got["window"], got.get("id")
            time.sleep(0.1)
        return None, None, None

    def place(self, display_w):
        """Puts the window at the profile's phone size, centred near the top; returns its rect as it ended up."""
        pid, rect, wid = self.find_window()
        if not rect:
            raise RuntimeError("the app showed no window")
        size = self.profile.get("window") or {}
        w, h = float(size.get("w", rect[2])), float(size.get("h", rect[3]))
        x, y = max(0.0, (display_w - w) / 2), 40.0
        route = "none"
        if size:
            got = run_json([self.mbcap, "setframe", str(pid), str(x), str(y), str(w), str(h)])
            if got.get("_exit") == 0:
                route = "ax"
            elif self.cua.ok:
                try:
                    self.cua.call("set_window_frame", {"pid": pid, "window_id": wid, "x": x, "y": y, "width": w, "height": h})
                    route = "cua-driver"
                except (RuntimeError, subprocess.TimeoutExpired) as error:
                    log("WARN window frame:", str(error)[:300])
            time.sleep(0.5)
        _, rect, wid = self.find_window(5)
        self.report["routes"]["window_frame"] = route
        log("WINDOW", json.dumps({"pid": pid, "rect": rect, "id": wid, "route": route}))
        self.window = (pid, rect, wid)
        return rect

    # -- input ----------------------------------------------------------------------------------------------

    def to_global(self, at):
        _, rect, _ = self.window
        return rect[0] + float(at[0]) * rect[2], rect[1] + float(at[1]) * rect[3]

    def hid_steps(self, steps):
        out = []
        for step in steps:
            kind = step.get("do")
            if kind in ("click", "move"):
                x, y = self.to_global(step["at"])
                out.append({"do": kind, "x": x, "y": y, "count": step.get("count", 1)})
            elif kind == "scroll":
                x, y = self.to_global(step["at"])
                out.append({"do": "scroll", "x": x, "y": y, "dy": step.get("dy", -10), "count": step.get("count", 20),
                            "hz": step.get("hz", 120), "phases": step.get("phases", True)})
            elif kind == "drag":
                (ax, ay), (bx, by) = self.to_global(step["from"]), self.to_global(step["to"])
                out.append({"do": "drag", "from": [ax, ay], "to": [bx, by], "duration_ms": step.get("duration_ms", 120),
                            "hz": 120})
            elif kind == "key":
                code = NAMED.get(step["key"], KEYS.get(step["key"]))
                if code is None:
                    raise ValueError(f"unknown key {step['key']!r}")
                out.append({"do": "key", "key_code": code, "modifiers": step.get("modifiers", [])})
            elif kind == "type":
                for ch in step["text"]:
                    mods = []
                    if ch in SHIFTED:
                        ch, mods = SHIFTED[ch], ["shift"]
                    elif ch.isupper():
                        ch, mods = ch.lower(), ["shift"]
                    if ch not in KEYS:
                        raise ValueError(f"cannot type {ch!r}")
                    out.append({"do": "key", "key_code": KEYS[ch], "modifiers": mods, "hold_ms": 25})
                    out.append({"do": "wait", "ms": step.get("gap_ms", 35)})
            elif kind == "wait":
                out.append({"do": "wait", "ms": step["ms"]})
            else:
                raise ValueError(f"unknown step {kind!r}")
        return out

    def send(self, steps, folder, name):
        """Posts STEPS; returns (CLOCK_UPTIME_RAW ns of the first stimulus event, route, uncertainty s, log)."""
        if not steps:
            return None, "none", 0.0, {}
        if self.report["routes"].get("input") != "cua-driver":
            script = os.path.join(folder, f"{name}.hid.json")
            out = os.path.join(folder, f"{name}.input.json")
            with open(script, "w") as f:
                json.dump({"start_delay_ms": 50, "rate_floor": 0, "steps": self.hid_steps(steps)}, f)
            done = subprocess.run([self.hid, "run", script, out], capture_output=True, text=True, timeout=300)
            if done.returncode in (0, 4) and os.path.isfile(out):
                with open(out) as f:
                    got = json.load(f)
                first = next((e[0] for e in got.get("events", []) if e[1] in STIMULUS_EVENTS), None)
                self.report["routes"]["input"] = "hid_inject"
                return first, "hid_inject", 0.0, got
            log("WARN hid_inject exit", done.returncode, done.stderr.strip()[-300:], "- input through cua-driver")
            self.report["routes"]["input"] = "cua-driver"
            self.report["routes"]["hid_inject_refusal"] = done.stderr.strip()[-300:]
        return self.send_cua(steps)

    def send_cua(self, steps):
        pid, rect, wid = self.window
        scale = self.report.get("scale", 2.0)
        first = None
        for step in steps:
            kind = step.get("do")
            t = uptime_ns()
            args = {"pid": pid, "window_id": wid, "delivery_mode": "foreground"}
            if kind in ("click", "scroll", "move"):
                args.update(x=float(step["at"][0]) * rect[2] * scale, y=float(step["at"][1]) * rect[3] * scale)
            if kind == "click":
                self.cua.call("click", args)
            elif kind == "scroll":
                args.update(direction="up" if step.get("dy", -10) > 0 else "down", amount=abs(step.get("count", 20)))
                self.cua.call("scroll", args)
            elif kind == "drag":
                (fx, fy), (tx, ty) = step["from"], step["to"]
                args.update(from_x=fx * rect[2] * scale, from_y=fy * rect[3] * scale, to_x=tx * rect[2] * scale,
                            to_y=ty * rect[3] * scale, duration_ms=step.get("duration_ms", 120), steps=6)
                self.cua.call("drag", args)
            elif kind == "key":
                mods = step.get("modifiers") or []
                if mods:
                    self.cua.call("hotkey", {**args, "keys": [*mods, step["key"]]})
                else:
                    self.cua.call("press_key", {**args, "key": step["key"]})
            elif kind == "type":
                self.cua.call("type_text", {**args, "text": step["text"], "delay_ms": step.get("gap_ms", 35)})
            elif kind == "wait":
                time.sleep(step["ms"] / 1000)
                continue
            if first is None:
                first = t
        return first, "cua-driver", 0.3, {}

    # -- recording ------------------------------------------------------------------------------------------

    def record_flow(self, flow_id, spec, display):
        folder = os.path.join(self.opts.out, self.name, flow_id)
        os.makedirs(folder, exist_ok=True)
        meta = self.base_meta(flow_id)
        if spec.get("unsupported"):
            meta["unsupported"] = spec["unsupported"]
            print(f"MOBILEBENCH flow={flow_id} unsupported reason=\"{spec['unsupported']}\"", flush=True)
            return self.write_meta(folder, meta)
        cold = spec.get("stimulus") == "launch"
        if cold:
            # A cold launch: the window's place is known from the launch before, and the app is gone now.
            self.quit()
        for step_list in (spec.get("prepare") or [],):
            if step_list and not cold:
                self.send(step_list, folder, "prepare")
                time.sleep(float(spec.get("prepare_settle_s", 1.0)))
        pid, rect, wid = self.window
        if not cold:
            _, now, _ = self.find_window(3)
            rect = now or rect
            self.window = (pid, rect, wid)
        clip = os.path.join(folder, "clip.mp4")
        lead, settle = float(spec.get("lead_s", 0.6)), float(spec.get("settle_s", 2.5))
        route = self.report["routes"]["recorder"]
        stim_ns, input_route, uncertainty, input_log = None, "none", 0.0, {}
        if route == "sck":
            rec = subprocess.Popen([self.mbcap, "record", *(f"{v:.1f}" for v in rect), str(self.opts.hz), clip],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                   start_new_session=True)
            ready = None
            end = time.monotonic() + 10
            while time.monotonic() < end and ready is None:
                r, _, _ = select.select([rec.stdout], [], [], end - time.monotonic())
                if not r:
                    break
                line = rec.stdout.readline()
                if not line:
                    break
                if '"ready"' in line:
                    ready = json.loads(line)
            if ready is None:
                rec.kill()
                out, err = rec.communicate(timeout=10)
                meta["error"] = f"the recorder never started: {(err or out).strip()[-300:]}"
                return self.write_meta(folder, meta)
            time.sleep(lead)
            if cold:
                stim_ns, input_route = self.launch(), "launchservices-open"
            else:
                stim_ns, input_route, uncertainty, input_log = self.send(spec.get("steps") or [], folder, "stimulus")
            time.sleep(settle)
            out, err = rec.communicate("stop\n", timeout=120)
            summary = next((json.loads(line) for line in reversed(out.splitlines()) if '"done"' in line), {})
            if not summary:
                meta["error"] = f"the recorder wrote no summary: {err.strip()[-300:]}"
                return self.write_meta(folder, meta)
            first = summary["first_pts_ns"]
            meta["stimulus_t"] = round((stim_ns - first) / 1e9, 6) if stim_ns else None
            meta["recorder"] = {"route": "screencapturekit", "frames": summary["frames"],
                                "p50_interval_ms": summary.get("p50_interval_ms"),
                                "peak_fps_250ms": summary.get("peak_fps_250ms"), "dropped": summary.get("dropped"),
                                "size": summary.get("size"), "scale": summary.get("scale")}
            with open(os.path.join(folder, "recorder.json"), "w") as f:
                json.dump(summary, f, indent=1)
            video_start = first
        else:
            stim_ns, input_route, uncertainty, video_start = self.record_cua(folder, clip, spec, cold, rect, lead, settle)
            meta["recorder"] = self.report.get("cua_last", {})
            if stim_ns is None or video_start is None:
                meta["error"] = self.report.get("cua_error", "the CuaDriver recording found no marker flip")
                return self.write_meta(folder, meta)
            meta["stimulus_t"] = round((stim_ns - video_start) / 1e9, 6)
        if input_log:
            with open(os.path.join(folder, "input.json"), "w") as f:
                json.dump(input_log, f)
        if cold:
            _, now, wid = self.find_window(5)
            if now:
                self.window = (self.pids[0] if self.pids else pid, now, wid)
        stats = run_json([self.mbcap, "stats", clip]) if os.path.isfile(clip) else {}
        meta["fps_measured"] = {"frames": stats.get("frames"), "duration_s": stats.get("duration_s"),
                                "p50_interval_ms": stats.get("p50_interval_ms"),
                                "peak_fps_250ms": stats.get("peak_fps_250ms")}
        meta["input"] = {"route": input_route, "stimulus_uncertainty_s": uncertainty}
        meta["window"] = rect
        if spec.get("note"):
            meta["note"] = spec["note"]
        if self.profile.get("unverified"):
            meta["profile_unverified"] = True
        epoch_start = time.time() - (uptime_ns() - video_start) / 1e9
        print(f"MOBILEBENCH video-start t={epoch_start:.6f} flow={flow_id}", flush=True)
        if meta.get("stimulus_t") is not None:
            print(f"MOBILEBENCH flow={flow_id} event=stimulus t_video={meta['stimulus_t']:.6f}", flush=True)
        print(f"MOBILEBENCH flow={flow_id} event=end t_video={stats.get('duration_s') or 0:.6f}", flush=True)
        for after in (spec.get("after") or [],):
            if after:
                self.send(after, folder, "after")
                time.sleep(0.8)
        return self.write_meta(folder, meta)

    def record_cua(self, folder, clip, spec, cold, rect, lead, settle):
        """CuaDriver records the main display; the marker's flip gives the stimulus's place in its timeline; the
        movie is cropped to the window. Returns (stimulus ns, input route, uncertainty, video start ns)."""
        raw_dir = os.path.join(self.scratch, f"cua-{os.path.basename(folder)}")
        marker = Marker(os.path.join(self.tools, "tab-switch-tools"), self.pids[0] if self.pids else 0)
        try:
            self.cua_rec.start(raw_dir)
            time.sleep(lead)
            flip_ns, _ = marker.flip("stimulus")
            if cold:
                stim_ns, route, unc = self.launch(), "launchservices-open", 0.0
            else:
                stim_ns, route, unc, _ = self.send(spec.get("steps") or [], folder, "stimulus")
            time.sleep(settle)
            raw = self.cua_rec.stop(raw_dir)
        finally:
            marker.quit()
        scale = self.report.get("scale", 2.0)
        frames = os.path.join(self.scratch, "frames.bin")
        decoded = run_json([os.path.join(self.tools, "tab-switch-tools"), "decode", raw, frames, "0", "0", "16", "16", "8",
                            "4", "4", "16", "16"], timeout=1200)
        try:
            os.remove(frames)
        except OSError:
            pass
        video_w = (decoded.get("video") or [0, 0])[0]
        px = video_w / float(self.report.get("display_points_w") or video_w or 1)
        marks = decoded.get("marker") or []
        flip_video = next((t for (t, g), (_, g0) in zip(marks[1:], marks) if abs(g - g0) > 100), None)
        self.report["cua_last"] = {"route": "cua-driver", "frames": decoded.get("frames"), "nominal_fps": decoded.get("fps"),
                                   "video": decoded.get("video")}
        if flip_video is None or not marks:
            self.report["cua_error"] = f"no marker flip in the CuaDriver movie ({decoded.get('frames')} frames)"
            return None, route, unc, None
        crop = run_json([self.mbcap, "crop", raw, clip, *(str(int(v * px)) for v in rect)], timeout=1200)
        log("CROP", json.dumps(crop))
        # The movie's own time 0 is its first frame; flip_video is seconds into it. Video start on our clock:
        first_t = marks[0][0]
        video_start = flip_ns - int((flip_video - first_t) * 1e9)
        _ = scale
        return stim_ns, route, unc, video_start

    def base_meta(self, flow_id):
        info = self.report.get("app_info", {})
        return {"app": self.name, "flow": flow_id,
                "source": "mac-iphone-app" if info.get("iphone_app") else "mac-app",
                "device": f"{self.report.get('model', 'Mac')} {self.opts.hz} Hz virtual display",
                "os": f"macOS {platform.mac_ver()[0]}", "app_version": info.get("version", ""),
                "app_build": info.get("build", ""), "bundle_id": self.opts.app,
                "recorded_at": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"),
                "stimulus_t": None, "fps_nominal": self.opts.hz}

    def write_meta(self, folder, meta):
        with open(os.path.join(folder, "meta.json"), "w") as f:
            json.dump(meta, f, indent=1)
        self.report["flows"][meta["flow"]] = meta
        log("FLOW", json.dumps(meta))
        return meta

    # -- the run --------------------------------------------------------------------------------------------

    def main(self):
        opts = self.opts
        os.makedirs(opts.out, exist_ok=True)
        self.report["model"] = subprocess.run(["sysctl", "-n", "hw.model"], capture_output=True, text=True).stdout.strip()
        probe = run_json([self.mbcap, "probe"])
        self.report["probe_before_display"] = probe
        info = run_json([self.mbcap, "app", opts.app])
        self.report["app_info"] = info
        log("APP", json.dumps(info))
        if not info.get("installed"):
            log("NOT INSTALLED", opts.app)
            return self.finish(3)
        flows = list(self.profile.get("flows", {})) if opts.flows == "all" else [f for f in opts.flows.split(",") if f]
        known = set(self.profile.get("flows", {}))
        display = Display(opts.vdisplay, opts.hz, opts.display)
        self.report["display"] = {"line": display.line, "interval_ms": display.interval_ms}
        log("DISPLAY", display.line)
        try:
            if not display.ok:
                log("WARN no virtual display: recording the main display as it is")
            probe = run_json([self.mbcap, "probe"])
            self.report["probe"] = probe
            log("PROBE", json.dumps(probe))
            main = next((d for d in probe.get("displays", []) if d.get("main")), {})
            self.report["scale"] = main.get("scale", 2.0)
            self.report["display_points_w"] = (main.get("bounds") or [0, 0, 1600])[2]
            self.report["main_display"] = main
            if probe.get("screen_recording"):
                self.report["routes"]["recorder"] = "sck"
            else:
                self.cua_rec = CuaRecorder()
                self.report["routes"]["recorder"] = "cua-driver"
                log("WARN no Screen Recording for this process: recording through CuaDriver", json.dumps(self.cua_rec.granted))
            if not probe.get("post_event"):
                self.report["routes"]["input"] = "cua-driver"
            already = self.running()
            if already:
                self.report["already_running"] = already
                log("WARN the app was already running (pids", already, "); a cold launch needs it quit: leaving it")
            self.launch()
            time.sleep(float(self.profile.get("launch_settle_s", 3)))
            self.place(self.report["display_points_w"])
            for setup in (self.profile.get("setup") or [],):
                if setup:
                    self.send(setup, opts.out, "setup")
                    time.sleep(1.0)
            for flow_id in flows:
                spec = self.profile.get("flows", {}).get(flow_id)
                if spec is None:
                    spec = {"unsupported": f"no stimulus for {flow_id} in apps/{opts.app}.json (known: {sorted(known)})"}
                if spec.get("stimulus") == "launch" and already:
                    spec = {"unsupported": "the app was already running when the run began: a cold launch would quit it"}
                try:
                    self.record_flow(flow_id, spec, display)
                except Exception as error:  # one flow's failure is that flow's result; the rest still run
                    log("FLOW-ERROR", flow_id, repr(error)[:400])
                    self.report["flows"][flow_id] = {"flow": flow_id, "error": repr(error)[:400]}
            return self.finish(0)
        finally:
            if getattr(self, "cua_rec", None):
                self.cua_rec.close()
            if self.pids:
                self.quit()
            display.stop()

    def finish(self, code):
        with open(os.path.join(self.opts.out, "run.json"), "w") as f:
            json.dump(self.report, f, indent=1)
        return code


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--app", required=True)
    ap.add_argument("--flows", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--tools", required=True)
    ap.add_argument("--vdisplay", required=True, help="VDisplay.app")
    ap.add_argument("--name", help="the app's short name in the output paths and meta.json (default: the profile's)")
    ap.add_argument("--profile-b64", help="the app profile as base64url JSON, instead of apps/BUNDLE_ID.json")
    ap.add_argument("--hz", type=int, default=120)
    ap.add_argument("--display", default="1600x1200", help="the virtual display's size in points (2x pixels)")
    return Run(ap.parse_args()).main()


if __name__ == "__main__":
    sys.exit(main())
