#!/usr/bin/env python3
"""Drive a tagged DEV app to each visual-gate state and take its light and dark stills.

    capture_states.py --app "<path>/cmux DEV <tag>.app" --out DIR STATE.json...

The CI-runner twin of HQ's pr-capture driver (build-fleet/pr_capture/driver.py):
same state files, same output shape, so visual_gate.py reads either. It runs on
the Mac that built the app (the nightly's visual-gate job on an owned session
runner) and reuses tour.py's launch and session handling: a private control
socket, its own settings file, no activation, and the app's own drawing of its
main window (debug.window_snapshot), so nothing else on the Mac shows up.

A state is {"settings": {...} | null, "launch_args": [...], "steps": [...]}.
A step has a `title`, at most one of a `cmux` argv or an `rpc` {"method",
"params"} (neither: it only waits), a `wait` (seconds, default 1.5),
`optional` (true or a reason: an optional step that fails is `unavailable`, any
other is `failed`) and `cite` (where its handler lives; not read). `--showcase` in
launch_args also sets CMUX_NEXT_SHOWCASE=1.

The app always launches with its own settings file (the state's settings, or
none), never the Mac's ~/.config/cmux/cmux-next.json: a theme pinned there (a
dark-only one makes every light still dark) is the host's, not the build's.

Writes DIR/<state>/light.png, dark.png and result.json:
{"state", "host", "runner", "settings_source": "own",
"steps": [{"title", "status", "detail"}], "errors": [...],
"window_points": [w, h] (the main window in points, from debug.layers),
"appearance": {"light": reply, "dark": reply} (debug.appearance read back once
the switch settled: effective appearance, terminal background, themes folder),
"snapshots": {"light": reply, "dark": reply} (debug.window_snapshot's reply:
pixel size and method, composited or appkit)}. Exit 0 when every state
captured both stills with no failed step, 1 otherwise, 2 on a bad state file.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import sys
import tempfile
import time
from typing import Any

MEDIA = Path(__file__).resolve().parents[1] / "media"
sys.path.insert(0, str(MEDIA))
import tour  # noqa: E402  (scripts/cmux-next/media/tour.py)

DEFAULT_WAIT = 1.5
STEP_TIMEOUT = 60.0
SNAPSHOT_TIMEOUT = 30.0
APPEARANCE_SETTLE = 2.0
STATE_KEYS = {"title", "settings", "launch_args", "steps"}
# `cite` is documentation (the handler's file:line); a step with neither `cmux` nor `rpc` only waits.
STEP_KEYS = {"title", "cmux", "rpc", "wait", "optional", "cite"}


class StateError(Exception):
    pass


def load_state(path: Path) -> dict[str, Any]:
    """The state in `path`, checked; StateError says what is wrong with it."""
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise StateError(f"{path}: {error}") from error
    if not isinstance(data, dict) or set(data) - STATE_KEYS:
        raise StateError(f"{path}: a state is an object with only {sorted(STATE_KEYS)}")
    if data.get("settings") is not None and not isinstance(data["settings"], dict):
        raise StateError(f"{path}: `settings` must be an object or null")
    args = data.get("launch_args", [])
    if not isinstance(args, list) or not all(isinstance(a, str) for a in args):
        raise StateError(f"{path}: `launch_args` must be a list of strings")
    steps = data.get("steps")
    if not isinstance(steps, list) or not steps:
        raise StateError(f"{path}: `steps` must be a non-empty list")
    for number, step in enumerate(steps, 1):
        where = f"{path}: step {number}"
        if not isinstance(step, dict) or set(step) - STEP_KEYS:
            raise StateError(f"{where} must be an object with only {sorted(STEP_KEYS)}")
        if not isinstance(step.get("title"), str) or not step["title"].strip():
            raise StateError(f"{where} needs a `title`")
        command, rpc = step.get("cmux"), step.get("rpc")
        if command is not None and rpc is not None:
            raise StateError(f"{where} has both `cmux` and `rpc`; use one per step")
        if command is not None and (not isinstance(command, list) or not command
                                    or not all(isinstance(word, str) for word in command)):
            raise StateError(f"{where}: `cmux` must be a non-empty list of strings")
        if rpc is not None and (not isinstance(rpc, dict) or set(rpc) - {"method", "params"}
                                or not isinstance(rpc.get("method"), str)
                                or not isinstance(rpc.get("params", {}), dict)):
            raise StateError(f"{where}: `rpc` must be {{\"method\": name, \"params\": object}}")
        wait = step.get("wait", DEFAULT_WAIT)
        if isinstance(wait, bool) or not isinstance(wait, (int, float)) or not 0 <= wait <= 30:
            raise StateError(f"{where}: `wait` must be 0 to 30 seconds")
        if "optional" in step and not (step["optional"] is True or
                                       (isinstance(step["optional"], str) and step["optional"].strip())):
            raise StateError(f"{where}: `optional` is true or the reason the step may fail")
    return {"name": path.stem, "settings": data.get("settings"), "launch_args": args, "steps": steps}


def run_step(app: Any, step: dict[str, Any]) -> dict[str, Any]:
    record: dict[str, Any] = {"title": step["title"], "status": "ok"}
    try:
        if step.get("cmux") is not None:
            done = app.cli(step["cmux"], timeout=STEP_TIMEOUT)
            if done.returncode != 0:
                raise tour.TourError((done.stderr or done.stdout).strip()[-400:] or f"exit {done.returncode}")
        elif step.get("rpc") is not None:
            record["rpc"] = step["rpc"]["method"]
            answer = app.request(step["rpc"]["method"], step["rpc"].get("params") or {}, timeout=STEP_TIMEOUT)
            if isinstance(answer, dict) and answer.get("error"):
                raise tour.TourError(f"{record['rpc']}: {answer['error']}")
    except (OSError, ValueError, tour.TourError) as error:
        record["status"] = "unavailable" if step.get("optional") else "failed"
        record["detail"] = str(error)[-400:]
    time.sleep(float(step.get("wait", DEFAULT_WAIT)))
    return record


def window_points(app: Any) -> list[float] | None:
    frame = app.main_window_frame()
    return [float(frame[2]), float(frame[3])] if frame else None


def take_still(app: Any, mode: str, path: Path) -> tuple[dict[str, Any], dict[str, Any]]:
    """(debug.appearance read back after the switch settled, debug.window_snapshot's reply)."""
    app.request("debug.appearance", {"mode": mode})
    time.sleep(APPEARANCE_SETTLE)
    # No mode: only reports. The gate reads it to tell a build that did not switch from a host
    # whose configuration pins a dark theme.
    appearance = app.request("debug.appearance", {})
    path.unlink(missing_ok=True)
    reply = app.request("debug.window_snapshot", {"kind": "main", "path": str(path)}, timeout=SNAPSHOT_TIMEOUT)
    if not path.is_file() or path.stat().st_size == 0:
        raise tour.TourError("debug.window_snapshot wrote no image")
    return (appearance if isinstance(appearance, dict) else {}), (reply if isinstance(reply, dict) else {})


def capture_state(app_path: Path, state: dict[str, Any], out: Path, session: Any) -> dict[str, Any]:
    directory = out / state["name"]
    if directory.exists():
        shutil.rmtree(directory)
    session.shareable(directory)
    workdir = Path(tempfile.mkdtemp(prefix="cmux-visual-gate.", dir="/tmp"))
    env = {"CMUX_NEXT_SHOWCASE": "1"} if "--showcase" in state["launch_args"] else {}
    result: dict[str, Any] = {"state": state["name"], "host": socket.gethostname(),
                              "runner": os.environ.get("RUNNER_NAME", ""), "settings_source": "own",
                              "steps": [], "errors": [], "appearance": {}, "snapshots": {}}
    app = None
    try:
        try:
            # Its own settings file always (`{}` without settings): never the Mac's. A bundle
            # that cannot be read (no Info.plist) is this state's error, and the next state runs.
            app = tour.App(app_path, session, workdir, fresh_state=True, settings=state["settings"] or {},
                           launch_env=env, launch_args=state["launch_args"])
            app.launch()
        except (tour.TourError, OSError, ValueError, KeyError) as error:
            result["errors"].append(f"launch: {type(error).__name__}: {error}")
            return result
        result["app"] = {key: app.identity.get(key) for key in ("version", "build", "bundle_id", "tag")}
        for step in state["steps"]:
            record = run_step(app, step)
            result["steps"].append(record)
            print(f"[{state['name']}] {record['status']:<11} {step['title']}"
                  + (f": {record['detail']}" if record.get("detail") else ""), flush=True)
            if not app.alive():
                result["errors"].append("the app exited during the state: " + app.log_tail())
                return result
        result["window_points"] = window_points(app)
        for mode in ("light", "dark"):
            try:
                result["appearance"][mode], result["snapshots"][mode] = take_still(app, mode, directory / f"{mode}.png")
            except (OSError, ValueError, tour.TourError) as error:
                result["errors"].append(f"{mode} still: {error}")
    finally:
        signal.signal(signal.SIGINT, signal.SIG_IGN)
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        if app is not None:
            app.stop()
            if app.log_path.exists():
                shutil.copy(app.log_path, directory / "app.log")
        shutil.rmtree(workdir, ignore_errors=True)
        (directory / "result.json").write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    return result


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0],
                                     formatter_class=argparse.RawDescriptionHelpFormatter, epilog=__doc__)
    parser.add_argument("states", nargs="+", type=Path, help="state JSON files or directories of them")
    parser.add_argument("--app", type=Path, help="the tagged DEV app bundle")
    parser.add_argument("--out", type=Path, help="one folder per state goes here")
    parser.add_argument("--check", action="store_true", help="only validate the state files")
    args = parser.parse_args(argv)
    files: list[Path] = []
    for path in args.states:
        files.extend(sorted(path.glob("*.json")) if path.is_dir() else [path])
    try:
        states = [load_state(path) for path in files]
    except StateError as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    if args.check:
        print(f"ok: {len(states)} state(s)")
        return 0
    if not args.app or not args.out:
        parser.error("--app and --out are required unless --check")
    signal.signal(signal.SIGTERM, tour.terminated)
    session = tour.Session()
    args.out.mkdir(parents=True, exist_ok=True)
    ok = True
    for state in states:
        signal.signal(signal.SIGINT, signal.default_int_handler)
        signal.signal(signal.SIGTERM, tour.terminated)
        result = capture_state(args.app, state, args.out, session)
        good = not result["errors"] and all(s["status"] != "failed" for s in result["steps"])
        print(f"[{state['name']}] {'captured' if good else 'capture had failures'}", flush=True)
        ok = ok and good
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
