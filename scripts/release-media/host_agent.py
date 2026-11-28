#!/usr/bin/env python3
"""Release-media host agent: runs on the capture Mac, driven by release_media.py.

release_media.py pipes this file to `ssh <host> python3 - <payload>`, where the
payload is base64 JSON holding the scene, the options, and the window probe
source. The agent:

1. checks the host: console user, display scale, a capture backend, and that
   no other `cmux NIGHTLY` is running (a second copy of the same bundle would
   terminate it);
2. downloads the latest nightly DMG on this host into ~/release-media/nightly
   (never relayed through the operator's Mac) and copies the app out of it;
3. launches that copy on a private socket with a clean zsh, applies the scene's
   cmux.json settings (restored afterwards), and runs the scene's cmux steps
   in a fresh window sized to the scene;
4. captures the window: a PNG, or a clip as PNG frames with timestamps (helper
   backend) or a .mov (native backend);
5. prints `RESULT <json>` naming the raw files; release_media.py copies them
   back and encodes them.

It targets the system python3 (3.9) and uses only the standard library.
Progress goes to stderr; stdout carries only the RESULT line.
"""
import base64
import fcntl
import hashlib
import json
import os
import plistlib
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time

ROOT = os.path.expanduser("~/release-media")
NIGHTLY_URL = "https://github.com/manaflow-ai/cmux/releases/download/nightly/cmux-nightly-macos-{arch}.dmg"
APP_NAME = "cmux NIGHTLY.app"
HELPER_CANDIDATES = [
    os.path.expanduser("~/Applications/CuaSshScreenCapture.app"),
    "/Applications/CuaSshScreenCapture.app",
]
CMUX_JSON = os.path.expanduser("~/.config/cmux/cmux.json")


class AgentError(Exception):
    """A failure with a stable code release_media.py maps to operator guidance."""

    def __init__(self, code, message, details=None):
        super().__init__(message)
        self.code = code
        self.details = details or {}


STARTED = time.monotonic()


def log(message):
    sys.stderr.write("[host +{:.0f}s] {}\n".format(time.monotonic() - STARTED, message))
    sys.stderr.flush()


def run(args, check=True, env=None, timeout=120):
    result = subprocess.run(
        args,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        universal_newlines=True,
        env=env,
        timeout=timeout,
    )
    if check and result.returncode != 0:
        raise AgentError(
            "command-failed",
            "{} exited {}: {}".format(" ".join(args), result.returncode, result.stderr.strip() or result.stdout.strip()),
        )
    return result


# Host facts -----------------------------------------------------------------


def build_probe(source):
    """Compile window_probe.swift once per source hash and return its path."""
    digest = hashlib.sha256(source.encode()).hexdigest()[:16]
    binary = os.path.join(ROOT, "bin", "window_probe-" + digest)
    if not os.access(binary, os.X_OK):
        os.makedirs(os.path.dirname(binary), exist_ok=True)
        src = os.path.join(ROOT, "bin", "window_probe-" + digest + ".swift")
        with open(src, "w") as handle:
            handle.write(source)
        log("compiling window probe")
        run(["xcrun", "swiftc", "-O", src, "-o", binary], timeout=300)
    return binary


def probe(binary, *args):
    return json.loads(run([binary] + [str(a) for a in args]).stdout)


def check_console_user():
    console = run(["stat", "-f", "%Su", "/dev/console"]).stdout.strip()
    me = run(["id", "-un"]).stdout.strip()
    if console != me:
        raise AgentError(
            "no-gui-session",
            "the console user is {!r}, not {!r}; log {} in at the Mac first".format(console, me, me),
        )


def processes():
    """(pid, executable path) for every process, from `ps` (comm is the full path)."""
    rows = []
    for line in run(["ps", "-Axo", "pid=,comm="]).stdout.splitlines():
        pid, _, comm = line.strip().partition(" ")
        if pid.isdigit():
            rows.append((int(pid), comm.strip()))
    return rows


def pgrep_lines(pattern):
    """`pgrep -fl` matches, minus this agent (its payload argument is arbitrary text)."""
    lines = run(["pgrep", "-fl", pattern], check=False).stdout.splitlines()
    return [line.strip() for line in lines if line.split(" ", 1)[0] != str(os.getpid())]


def check_not_busy(app_path):
    """Refuse when another nightly or a soak is running on this host."""
    others = [line for line in pgrep_lines("cmux NIGHTLY.app/Contents/MacOS/cmux") if app_path not in line]
    if others:
        raise AgentError(
            "host-busy",
            "another cmux NIGHTLY is running; launching a second copy would terminate it",
            {"processes": others},
        )
    soaks = pgrep_lines("[-_]soak|soak[-_]")
    if soaks:
        raise AgentError("host-busy", "a soak is running on this host", {"processes": soaks})


def screencapture_works(workdir):
    """True when this SSH session itself may record the screen."""
    out = os.path.join(workdir, "native-probe.png")
    result = run(["/usr/sbin/screencapture", "-x", "-t", "png", out], check=False, timeout=30)
    return result.returncode == 0 and os.path.exists(out) and os.path.getsize(out) > 0


def approved_helper(workdir):
    """Return an approved CuaSshScreenCapture.app that can capture, or None."""
    for app in HELPER_CANDIDATES:
        if not os.path.isdir(app):
            continue
        out = os.path.join(workdir, "helper-probe.png")
        run(["/usr/bin/open", "-g", "-n", "-W", app, "--args", "desktop", out], check=False, timeout=60)
        if os.path.exists(out) and os.path.getsize(out) > 0:
            return app
    return None


def pick_backend(binary, workdir):
    if probe(binary, "preflight").get("screenRecording") and screencapture_works(workdir):
        return {"name": "native"}
    helper = approved_helper(workdir)
    if helper:
        return {"name": "helper", "app": helper}
    raise AgentError(
        "no-screen-recording",
        "this SSH session has no Screen Recording permission and no approved CuaSshScreenCapture.app",
    )


# Nightly install and launch -------------------------------------------------


def install_nightly():
    arch = "arm64" if os.uname().machine == "arm64" else "x86_64"
    base = os.path.join(ROOT, "nightly", arch)
    os.makedirs(base, exist_ok=True)
    dmg = os.path.join(base, "cmux-nightly.dmg")
    log("downloading the latest nightly DMG on this host")
    # -z skips the download unless the upload is newer than our copy; -R keeps
    # the upload's time on the file. Writing to .partial first means a failed
    # download never leaves a truncated DMG that -z would then trust.
    partial = dmg + ".partial"
    if os.path.exists(partial):
        os.unlink(partial)
    args = ["curl", "-fsSLR", "--retry", "3", "-o", partial, NIGHTLY_URL.format(arch=arch)]
    if os.path.exists(dmg):
        args[1:1] = ["-z", dmg]
    run(args, timeout=900)
    if os.path.exists(partial):
        if os.path.getsize(partial) > 0:
            os.replace(partial, dmg)
        else:
            os.unlink(partial)
    mount = tempfile.mkdtemp(prefix="rm-dmg-")
    run(["hdiutil", "attach", "-nobrowse", "-readonly", "-mountpoint", mount, dmg], timeout=300)
    try:
        with open(os.path.join(mount, APP_NAME, "Contents", "Info.plist"), "rb") as handle:
            info = plistlib.load(handle)
        build = str(info["CFBundleVersion"])
        app = os.path.join(base, build, APP_NAME)
        if not os.path.isdir(app):
            staging = app + ".partial"
            shutil.rmtree(staging, ignore_errors=True)
            run(["ditto", os.path.join(mount, APP_NAME), staging], timeout=600)
            os.rename(staging, app)
    finally:
        run(["hdiutil", "detach", mount], check=False)
        shutil.rmtree(mount, ignore_errors=True)
    # Keep one build: older copies are reproducible from their DMGs and each
    # is several hundred MB. A copy that is still running stays.
    running = [path for _, path in processes()]
    for entry in os.listdir(base):
        old = os.path.join(base, entry)
        if entry != build and os.path.isdir(old) and not any(path.startswith(old + "/") for path in running):
            shutil.rmtree(old)
    return {
        "app": app,
        "version": info.get("CFBundleShortVersionString", ""),
        "build": build,
        "bundleId": info.get("CFBundleIdentifier", ""),
    }


class Cmux:
    """The scratch nightly: its process, private socket, and CLI."""

    def __init__(self, app, rundir, zshrc):
        self.app = app
        self.executable = os.path.join(app, "Contents", "MacOS", "cmux")
        self.cli = os.path.join(app, "Contents", "Resources", "bin", "cmux")
        # Unix socket paths are limited to 104 bytes; keep this one short.
        self.socket = "/tmp/rm-{}.sock".format(os.getpid())
        self.zdotdir = os.path.join(rundir, "zdot")
        os.makedirs(self.zdotdir, exist_ok=True)
        with open(os.path.join(self.zdotdir, ".zshrc"), "w") as handle:
            handle.write(zshrc)
        open(os.path.join(self.zdotdir, ".zshenv"), "w").close()
        self.env = dict(os.environ, CMUX_SOCKET_PATH=self.socket, CMUX_QUIET="1")

    def pids(self):
        """Processes running exactly this copy's main executable."""
        return [pid for pid, path in processes() if path == self.executable]

    def signal_all(self, signum):
        for pid in self.pids():
            try:
                os.kill(pid, signum)
            except ProcessLookupError:
                pass

    def stop(self):
        self.signal_all(signal.SIGTERM)
        deadline = time.time() + 15
        while self.pids() and time.time() < deadline:
            time.sleep(0.25)
        self.signal_all(signal.SIGKILL)
        for path in (self.socket, self.socket + ".lock"):
            if os.path.exists(path):
                os.unlink(path)

    def launch(self):
        self.stop()
        log("launching " + self.app)
        run([
            # Foreground launch: the scene window must render as the key window.
            "/usr/bin/open", "-n",
            "--env", "CMUX_ALLOW_SOCKET_OVERRIDE=1",
            "--env", "CMUX_SOCKET_MODE=allowAll",
            "--env", "CMUX_SOCKET_PATH=" + self.socket,
            "--env", "ZDOTDIR=" + self.zdotdir,
            self.app,
        ])
        deadline = time.time() + 60
        while time.time() < deadline:
            if run([self.cli, "ping"], check=False, env=self.env).stdout.strip() == "PONG":
                pids = self.pids()
                if len(pids) == 1:
                    return pids[0]
            time.sleep(0.5)
        raise AgentError("launch-failed", "the nightly did not answer ping on " + self.socket)

    def __call__(self, *args):
        result = run([self.cli] + list(args), check=False, env=self.env)
        if result.returncode != 0 or result.stdout.startswith("ERROR"):
            raise AgentError(
                "scene-step-failed",
                "cmux {} failed: {}".format(" ".join(args), (result.stderr or result.stdout).strip()),
            )
        return result.stdout.strip()


# Settings -------------------------------------------------------------------


def scan_jsonc(text, keep):
    """Rebuild text outside strings with keep(text, i) -> (kept, next_i); strings pass through."""
    out, i, n = [], 0, len(text)
    while i < n:
        if text[i] == '"':
            j = i + 1
            while j < n and text[j] != '"':
                j += 2 if text[j] == "\\" else 1
            out.append(text[i:j + 1])
            i = j + 1
        else:
            kept, i = keep(text, i)
            out.append(kept)
    return "".join(out)


def drop_comment(text, i):
    if text.startswith("//", i):
        end = text.find("\n", i)
        return "", len(text) if end < 0 else end
    if text.startswith("/*", i):
        end = text.find("*/", i + 2)
        return "", len(text) if end < 0 else end + 2
    return text[i], i + 1


def drop_trailing_comma(text, i):
    if text[i] == "," and re.match(r"\s*[}\]]", text[i + 1:]):
        return "", i + 1
    return text[i], i + 1


def parse_jsonc(text):
    """Parse cmux.json the way cmux's JSONCParser does: a BOM, comments, then
    trailing commas (so a comma before a commented-out last entry goes too)."""
    text = text.lstrip("\ufeff")
    stripped = scan_jsonc(scan_jsonc(text, drop_comment), drop_trailing_comma)
    try:
        return json.loads(stripped) if stripped.strip() else {}
    except ValueError as error:
        raise AgentError("bad-settings", "cannot parse {}: {}".format(CMUX_JSON, error))


def deep_merge(base, overlay):
    merged = dict(base)
    for key, value in overlay.items():
        if isinstance(value, dict) and isinstance(merged.get(key), dict):
            merged[key] = deep_merge(merged[key], value)
        else:
            merged[key] = value
    return merged


def write_atomically(path, data):
    """Replace path in one rename, so an interrupted write never leaves it truncated."""
    temp = path + ".release-media"
    with open(temp, "wb") as handle:
        handle.write(data)
    if os.path.exists(path):
        shutil.copymode(path, temp)
    os.replace(temp, path)


class SettingsGuard:
    """Merges scene settings into cmux.json and restores the original bytes.

    The merged file is plain JSON, so comments are gone until restore().
    """

    def __init__(self):
        self.original = None
        if os.path.exists(CMUX_JSON):
            with open(CMUX_JSON, "rb") as handle:
                self.original = handle.read()
        self.touched = False

    def apply(self, overlay):
        current = {}
        if os.path.exists(CMUX_JSON):
            with open(CMUX_JSON, encoding="utf-8") as handle:
                current = parse_jsonc(handle.read())
        os.makedirs(os.path.dirname(CMUX_JSON), exist_ok=True)
        merged = json.dumps(deep_merge(current, overlay), indent=2) + "\n"
        self.touched = True
        write_atomically(CMUX_JSON, merged.encode())

    def restore(self):
        if not self.touched:
            return
        if self.original is None:
            os.unlink(CMUX_JSON)
        else:
            write_atomically(CMUX_JSON, self.original)
        self.touched = False


# Scene steps ----------------------------------------------------------------


def substitute(value, names):
    for key, replacement in names.items():
        value = value.replace("{" + key + "}", replacement)
    return value


def run_step(step, cmux, settings, names):
    if "sleep" in step:
        time.sleep(float(step["sleep"]))
    elif "settings" in step:
        settings.apply(step["settings"])
        cmux("reload-config")
    elif "cmux" in step:
        output = cmux(*[substitute(str(arg), names) for arg in step["cmux"]])
        if "save" in step:
            # Creation commands answer "OK <handle> ...": keep the handle.
            parts = output.split()
            if len(parts) < 2 or parts[0] != "OK":
                raise AgentError("scene-step-failed", "cannot read a handle from {!r}".format(output))
            names[step["save"]] = parts[1]
    else:
        raise AgentError("bad-scene", "unknown step {!r}".format(step))


def find_window(binary, pid, width, height):
    """The CGWindowID of the scene window: the app's window with the scene size."""
    deadline = time.time() + 10
    while time.time() < deadline:
        for window in probe(binary, "windows", pid):
            if window["layer"] == 0 and abs(window["width"] - width) < 1 and abs(window["height"] - height) < 1:
                return window
        time.sleep(0.25)
    raise AgentError("window-not-found", "no {}x{} window for pid {}".format(width, height, pid))


# Capture --------------------------------------------------------------------


def capture_still(backend, window_id, out):
    if backend["name"] == "native":
        run(["/usr/sbin/screencapture", "-x", "-o", "-l", str(window_id), out], timeout=60)
    else:
        # -g: the helper must not take focus, or the cmux window renders inactive.
        run(["/usr/bin/open", "-g", "-n", "-W", backend["app"], "--args", "window", str(window_id), out], timeout=60)
    if not os.path.exists(out) or os.path.getsize(out) == 0:
        raise AgentError("capture-failed", "no image written to " + out)


def capture_clip(backend, window_id, seconds, during, run_timed_step, rundir):
    """Record `seconds` of the window while running `during` steps at their offsets."""
    errors = []
    stopped = threading.Event()

    def timeline(start):
        try:
            for step in sorted(during, key=lambda s: float(s["at"])):
                # Event.wait returns True once recording has stopped: never run
                # a step (it may rewrite cmux.json) after the caller cleaned up.
                if stopped.wait(max(0.0, start + float(step["at"]) - time.monotonic())):
                    return
                run_timed_step(step)
        except Exception as error:  # surfaced after the recording stops
            errors.append(error)

    thread = threading.Thread(target=timeline, args=(time.monotonic(),))
    thread.start()
    try:
        result = record(backend, window_id, seconds, rundir)
    finally:
        stopped.set()
        thread.join()
    if errors:
        raise errors[0]
    return result


def record(backend, window_id, seconds, rundir):
    if backend["name"] == "native":
        mov = os.path.join(rundir, "clip.mov")
        recorder = subprocess.Popen(
            ["/usr/sbin/screencapture", "-x", "-v", "-V", str(seconds), "-l", str(window_id), mov],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        try:
            recorder.wait(timeout=seconds + 60)
        except subprocess.TimeoutExpired:
            recorder.kill()
            raise AgentError("capture-failed", "screencapture -v did not finish")
        if recorder.returncode != 0 or not os.path.exists(mov):
            raise AgentError("capture-failed", "screencapture -v failed: " + recorder.stderr.read().decode().strip())
        return {"kind": "mov", "path": mov}

    # Helper backend: one window-only image per helper launch (about 6 fps).
    # Window capture skips any dialog or banner stacked over the window.
    frames_dir = os.path.join(rundir, "frames")
    os.makedirs(frames_dir, exist_ok=True)
    frames = []
    start = time.monotonic()
    while time.monotonic() - start < seconds:
        taken = time.monotonic() - start
        path = os.path.join(frames_dir, "frame-{:05d}.png".format(len(frames)))
        capture_still(backend, window_id, path)
        frames.append({"file": os.path.basename(path), "t": round(taken, 3)})
    return {"kind": "frames", "dir": frames_dir, "frames": frames, "seconds": seconds}


# Main -----------------------------------------------------------------------


def main(payload):
    """One capture at a time per host: a second run would kill the first's app
    and snapshot its modified cmux.json as the original."""
    os.makedirs(ROOT, exist_ok=True)
    with open(os.path.join(ROOT, "lock"), "w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            raise AgentError("host-busy", "another release-media capture is running on this host")
        return capture(payload)


def capture(payload):
    scene = payload["scene"]
    options = payload["options"]
    rundir = os.path.join(ROOT, "runs", time.strftime("%Y%m%dT%H%M%S") + "-" + scene["slug"])
    os.makedirs(rundir, exist_ok=True)
    result = {"rundir": rundir, "warnings": []}

    check_console_user()
    binary = build_probe(payload["probeSource"])
    display = probe(binary, "display")
    result["display"] = display
    if display["scale"] < 2:
        if not options.get("allow1x"):
            raise AgentError("not-hidpi", "the main display runs at {}x".format(display["scale"]), display)
        result["warnings"].append("captured at {}x: the display is not HiDPI".format(display["scale"]))
    backend = pick_backend(binary, rundir)
    result["backend"] = backend["name"]
    log("capture backend: " + backend["name"])

    nightly = install_nightly()
    log("nightly " + nightly["version"])
    result["nightly"] = nightly
    check_not_busy(nightly["app"])

    cmux = Cmux(nightly["app"], rundir, scene.get("zshrc", 'PROMPT="%F{blue}~/project%f %# "\n'))
    settings = SettingsGuard()
    try:
        if scene.get("settings"):
            settings.apply(scene["settings"])
        pid = cmux.launch()
        log("running the scene")
        width, height = scene["window"]["width"], scene["window"]["height"]
        names = {"window": cmux("new-window").split()[1]}
        cmux("resize-window", "--window", names["window"], "--width", str(width), "--height", str(height))
        for step in scene.get("setup", []):
            run_step(step, cmux, settings, names)
        cmux("focus-window", "--window", names["window"])
        window = find_window(binary, pid, width, height)
        log("capturing window {}".format(window["id"]))
        result["window"] = window
        capture = scene["capture"]
        if capture["type"] == "screenshot":
            still = os.path.join(rundir, "still.png")
            capture_still(backend, window["id"], still)
            result["capture"] = {"kind": "still", "path": still}
        else:
            result["capture"] = capture_clip(
                backend,
                window["id"],
                float(capture["seconds"]),
                capture.get("during", []),
                lambda step: run_step(step, cmux, settings, names),
                rundir,
            )
        cmux("close-window", "--window", names["window"])
    finally:
        settings.restore()
        if options.get("keepApp") and cmux.pids():
            try:
                cmux("reload-config")
            except AgentError:
                pass
        else:
            cmux.stop()
    return result


def exit_on_signal(signum, _frame):
    # Raise instead of dying so main's finally restores cmux.json and quits the app.
    raise SystemExit(128 + signum)


if __name__ == "__main__":
    signal.signal(signal.SIGHUP, exit_on_signal)
    signal.signal(signal.SIGTERM, exit_on_signal)
    payload = json.loads(base64.b64decode(sys.argv[1]))
    try:
        outcome = main(payload)
    except AgentError as error:
        outcome = {"error": error.code, "message": str(error), "details": error.details}
    except Exception as error:
        outcome = {"error": "internal", "message": "{}: {}".format(type(error).__name__, error), "details": {}}
    print("RESULT " + json.dumps(outcome))
