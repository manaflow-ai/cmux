#!/usr/bin/env python3
"""The newest NEXT NIGHTLY's viewer Decode + Present with no host (goal screen-share-viewer-present).

On one Mac, no sign-in, no peer: download the newest NIGHTLY from the arm64 feed (the same checks as
accounts-nightly-launch.py), launch a private copy in the background (its own state root and control socket,
no activation, a second instance beside any app already running), make a test movie, and play it through a
Screen Sharing tab's own decoder and presenter with `cmux app mac-screen-replay` (cmux#64138). The last line
is `MAC_SCREEN_REPLAY {json}`: the command's report plus the NIGHTLY's build and commit and the movie's
name, which cmuxterm-hq's `screen_share_fast_receipt.py extract --format replay` reads as one replay run.

The movie: `movie=PATH` replays that file (a recording the Screen Sharing toolbar's Record wrote); without
it ffmpeg encodes 10 s of moving test pattern (testsrc2) at 1920x1080, 60 fps, H.264 through VideoToolbox,
the codec and rate a share streams. Arguments are key=value: build=NUMBER, movie=PATH, frames=1-120.
Everything it makes lives in one mktemp folder it removes at exit.
"""
from __future__ import annotations

import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
FEED = "https://files-next.cmux.com/nightly-next/appcast-arm64.xml"
MARK = "MAC_SCREEN_REPLAY"
# The generated movie: a share's codec and rate, moving content so every frame decodes as new.
TEST_MOVIE = "testsrc2-1920x1080-60fps-h264-10s.mp4"
TEST_SIZE, TEST_FPS, TEST_SECONDS, TEST_BITRATE = "1920x1080", 60, 10, "20M"
FFMPEG = ("/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg")


def module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


def run(argv, **kwargs):
    return subprocess.run(argv, check=True, timeout=kwargs.pop("timeout", 120), **kwargs)


def parse_args(argv: list[str]) -> dict[str, str]:
    args = {}
    for arg in argv:
        key, sep, value = arg.partition("=")
        if key not in ("build", "movie", "frames") or not sep or not value:
            raise RuntimeError("arguments are build=NUMBER, movie=PATH, frames=1-120")
        args[key] = value
    frames = args.get("frames", "120")
    if not frames.isdigit() or not 1 <= int(frames) <= 120:
        raise RuntimeError("frames is 1 to 120 (the app keeps its last 120 frames' timings)")
    return args


def ffmpeg_argv(ffmpeg: str, out: Path, encoder: str = "h264_videotoolbox") -> list[str]:
    return [ffmpeg, "-v", "error", "-y", "-f", "lavfi", "-i", f"testsrc2=size={TEST_SIZE}:rate={TEST_FPS}",
            "-t", str(TEST_SECONDS), "-c:v", encoder, "-b:v", TEST_BITRATE, "-pix_fmt", "yuv420p",
            "-movflags", "+faststart", str(out)]


def make_movie(work: Path) -> Path:
    ffmpeg = shutil.which("ffmpeg") or next((p for p in FFMPEG if os.access(p, os.X_OK)), None)
    if not ffmpeg:
        raise RuntimeError("no ffmpeg on this Mac to encode the test movie (pass movie=PATH)")
    out = work / TEST_MOVIE
    for encoder in ("h264_videotoolbox", "libx264"):
        if subprocess.run(ffmpeg_argv(ffmpeg, out, encoder), capture_output=True, timeout=180).returncode == 0:
            return out
    raise RuntimeError("ffmpeg could not encode the test movie with h264_videotoolbox or libx264")


def result_line(report: dict, selected: dict, movie: str) -> str:
    """The one line the receipt reads: the replay's report with which NIGHTLY and which movie."""
    return f"{MARK} " + json.dumps({**report, "nightly_build": selected.get("build"),
                                    "nightly_commit": selected.get("commit"), "recording": movie},
                                   sort_keys=True)


def main() -> int:
    work = Path(tempfile.mkdtemp(prefix="mac-screen-replay-"))
    status, launcher, owned_pid, mounted, selected = 1, None, None, False, {}
    cli, cli_env = None, None
    try:
        args = parse_args(sys.argv[1:])
        launch = module("accounts_nightly_launch", ROOT / "scripts/measure/accounts-nightly-launch.py")
        run(["curl", "-fsSL", "--max-time", "60", "-o", str(work / "feed.xml"), FEED])
        selected = launch.pick_feed((work / "feed.xml").read_bytes(), args.get("build", ""))
        run(["curl", "-fsSL", "--max-time", "600", "-o", str(work / "nightly.dmg"), selected["url"]], timeout=620)
        artifact = module("nightly_artifact", ROOT / "scripts/ci/nightly_next_artifact_check.py")
        selected["sha256"] = artifact.check_dmg(work / "nightly.dmg", selected["length"], selected["signature"])
        mount = work / "mount"
        mount.mkdir()
        run(["hdiutil", "attach", str(work / "nightly.dmg"), "-nobrowse", "-readonly", "-mountpoint", str(mount)],
            stdout=subprocess.DEVNULL)
        mounted = True
        apps = list(mount.glob("*.app"))
        if len(apps) != 1:
            raise RuntimeError("expected exactly one app in the NIGHTLY DMG")
        app = (work / "cmux NIGHTLY.app").resolve()
        run(["ditto", str(apps[0]), str(app)], timeout=300)
        run(["hdiutil", "detach", str(mount)], stdout=subprocess.DEVNULL)
        mounted = False
        (work / "nightly.dmg").unlink()
        with (app / "Contents/Info.plist").open("rb") as handle:
            meta = plistlib.load(handle)
        if meta.get("CFBundleIdentifier") != "com.cmuxterm.app.nightly" or str(meta.get("CFBundleVersion")) != selected["build"]:
            raise RuntimeError("app identity/build does not match the feed")
        selected["commit"] = meta.get("CMUXCommit")
        run(["codesign", "--verify", "--deep", "--strict", str(app)])
        movie = Path(args["movie"]).expanduser().resolve() if args.get("movie") else make_movie(work)
        if not movie.is_file():
            raise RuntimeError("movie= names no file")
        state = work / "state"
        state.mkdir()
        socket = str(work / "control.sock")
        if len(os.fsencode(socket)) > 103:
            raise RuntimeError("private control socket path exceeds the macOS limit")
        config = work / "cmux-next.json"
        config.write_text("{}\n")
        env = module("app_launch_env", ROOT / "scripts/cmux-next/app_launch_env.py").launch_env(os.environ)
        env = {k: v for k, v in env.items() if not k.startswith(("CMUX_UITEST_", "CMUX_DOGFOOD_", "CMUX_GITHUB_TEST_", "CMUX_AUTH_"))}
        values = {"CMUX_NEXT_SOCKET_PATH": socket, "CMUX_NEXT_STATE_ROOT": str(state),
                  "CMUX_NEXT_CONFIG_FILE": str(config), "CMUX_NEXT_ALLOW_SECOND_INSTANCE": "1",
                  "CMUX_NEXT_NO_ACTIVATE": "1"}
        command = ["/usr/bin/open", "-W", "-g", "-n"]
        for key, value in values.items():
            command += ["--env", f"{key}={value}"]
        launcher = subprocess.Popen(command + [str(app)], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        cli = str(app / "Contents/Resources/bin/cmux")
        cli_env = {**env, **values, "CMUX_SOCKET_PATH": socket}
        deadline = time.monotonic() + 90
        while time.monotonic() < deadline and owned_pid is None:
            if launcher.poll() is not None:
                raise RuntimeError("NIGHTLY exited before its private socket was ready")
            reply = subprocess.run([cli, "app", "identify", "--json"], env=cli_env, capture_output=True, text=True, timeout=10)
            try:
                identity = json.loads(reply.stdout)
            except ValueError:
                identity = {}
            if identity.get("app_bundle_path") == str(app) and isinstance(identity.get("pid"), int):
                owned_pid = identity["pid"]
            else:
                time.sleep(1)
        if owned_pid is None:
            raise RuntimeError("NIGHTLY did not identify its exact private app path within 90 seconds")
        tab = subprocess.run([cli, "tab", "new-mac-screen", "--json"], env=cli_env, capture_output=True, text=True, timeout=30)
        try:
            tab_id = json.loads(tab.stdout).get("tab")
        except ValueError:
            tab_id = None
        if not tab_id:
            raise RuntimeError(f"tab new-mac-screen gave no tab (exit {tab.returncode})")
        replay = subprocess.run([cli, "app", "mac-screen-replay", "--tab", str(tab_id), "--path", str(movie),
                                 "--frames", args.get("frames", "120"), "--json"],
                                env=cli_env, capture_output=True, text=True, timeout=200)
        try:
            report = json.loads(replay.stdout)
        except ValueError:
            report = {"ok": False, "error": (replay.stderr or replay.stdout or "").strip()[-300:]}
        print(result_line(report if isinstance(report, dict) else {"ok": False}, selected, movie.name), flush=True)
        status = 0 if replay.returncode == 0 and isinstance(report, dict) and report.get("ok") is True else 1
    except Exception as error:
        reason = str(error) if type(error) is RuntimeError else f"{type(error).__name__}: {str(error)[:200]}"
        print(result_line({"ok": False, "error": reason}, selected, ""), flush=True)
    finally:
        cleanup_ok = True
        if owned_pid and cli and cli_env:
            try:
                check = subprocess.run([cli, "app", "identify", "--json"], env=cli_env, capture_output=True, text=True, timeout=10)
                identity = json.loads(check.stdout)
                if identity.get("pid") == owned_pid and identity.get("app_bundle_path") == cli.rsplit("/Contents/", 1)[0]:
                    os.kill(owned_pid, signal.SIGTERM)  # the private copy this run launched, nothing else
                else:
                    cleanup_ok = False
            except (OSError, subprocess.TimeoutExpired, ValueError):
                cleanup_ok = False
        if launcher:
            try:
                launcher.wait(timeout=30)
            except subprocess.TimeoutExpired:
                cleanup_ok = False
                launcher.terminate()  # only our open -W helper
        if mounted:
            try:
                cleanup_ok &= subprocess.run(["hdiutil", "detach", str(work / "mount")], capture_output=True, timeout=30).returncode == 0
            except (OSError, subprocess.TimeoutExpired):
                cleanup_ok = False
        if cleanup_ok:
            shutil.rmtree(work, ignore_errors=True)  # this run alone made this mktemp folder
        else:
            status = status or 1
    return status


if __name__ == "__main__":
    raise SystemExit(main())
