#!/usr/bin/env python3
"""Whether this process may read the screen, and who macOS asks about it.

A capture of a window that shows content drawn by another process (a Chromium page's GPU layers, a
WebKit page) comes back without that content unless the capturing process's responsible process holds
the Screen Recording grant (TCC kTCCServiceScreenCapture): the window server leaves out what it may not
show. A bench that launches the app as its child makes that app answer to the bench's own responsible
process, so this check, run from the bench's process, says what the app's frame strip will see.

    screen_capture_check.py [--json FILE] [--png-dir DIR]

Prints one JSON object (and writes it to FILE): the preflight answer, the responsible process (pid and
executable), this process's ancestors, csrutil's answer, what `screencapture -x` did, and what the
CuaDriver daemon (which holds its own grant on the fleet minis) reports and captures. With --png-dir the
two whole-display captures are kept there, to compare a granted capture with this process's.
"""
from __future__ import annotations

import argparse
import base64
import ctypes
import ctypes.util
import json
import os
import subprocess
import sys
from pathlib import Path

CUA_DRIVER = "/Applications/CuaDriver.app/Contents/MacOS/cua-driver"


def run(argv: list[str], timeout: float = 30) -> dict:
    try:
        done = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired) as error:
        return {"error": f"{type(error).__name__}: {error}"}
    return {"rc": done.returncode, "out": done.stdout.strip()[-2000:], "err": done.stderr.strip()[-2000:]}


def pid_path(pid: int) -> str | None:
    libproc = ctypes.CDLL(ctypes.util.find_library("proc") or "/usr/lib/libproc.dylib")
    buf = ctypes.create_string_buffer(4096)
    n = libproc.proc_pidpath(ctypes.c_int(pid), buf, ctypes.c_uint32(len(buf)))
    return buf.value.decode(errors="replace") if n > 0 else None


def responsible_pid(pid: int) -> int | None:
    libsystem = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
    try:
        fn = libsystem.responsibility_get_pid_responsible_for_pid
    except AttributeError:
        return None
    fn.restype = ctypes.c_int
    fn.argtypes = [ctypes.c_int]
    answer = fn(pid)
    return answer if answer > 0 else None


def preflight() -> bool | None:
    try:
        cg = ctypes.CDLL("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
        fn = cg.CGPreflightScreenCaptureAccess
    except (OSError, AttributeError):
        return None
    fn.restype = ctypes.c_bool
    return bool(fn())


def ancestors(pid: int) -> list[dict]:
    chain = []
    seen = set()
    while pid > 1 and pid not in seen and len(chain) < 20:
        seen.add(pid)
        ps = run(["ps", "-o", "ppid=,user=,command=", "-p", str(pid)])
        line = ps.get("out", "").strip()
        if not line:
            break
        ppid, user, command = (line.split(None, 2) + ["", ""])[:3]
        chain.append({"pid": pid, "user": user, "exe": pid_path(pid), "command": command[:300]})
        pid = int(ppid)
    return chain


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--json")
    parser.add_argument("--png-dir")
    parser.add_argument("--embed-png", action="store_true",
                        help="put the two captures in the JSON (base64, at most 1600 px wide): a fleet step returns one file")
    args = parser.parse_args()
    png_dir = Path(args.png_dir) if args.png_dir else Path(os.environ.get("TMPDIR", "/tmp"))
    png_dir.mkdir(parents=True, exist_ok=True)
    me = os.getpid()
    rpid = responsible_pid(me)
    report: dict = {
        "pid": me,
        "uid": os.getuid(),
        "console_user": run(["stat", "-f", "%Su", "/dev/console"]).get("out"),
        "screen_recording_preflight": preflight(),
        "responsible_pid": rpid,
        "responsible_exe": pid_path(rpid) if rpid else None,
        "ancestors": ancestors(me),
        "csrutil": run(["csrutil", "status"]).get("out"),
        "macos": run(["sw_vers", "-productVersion"]).get("out"),
    }
    if rpid:
        report["responsible_codesign"] = run(["codesign", "-dv", "--verbose=2", report["responsible_exe"] or ""])
    shot = png_dir / "capture-check-screencapture.png"
    shot.unlink(missing_ok=True)
    sc = run(["screencapture", "-x", "-t", "png", str(shot)])
    sc["file_bytes"] = shot.stat().st_size if shot.exists() else None
    report["screencapture"] = sc
    if os.path.exists(CUA_DRIVER):
        report["cua_permissions"] = run([CUA_DRIVER, "permissions", "status"])
        cua_png = png_dir / "capture-check-cua.png"
        cua_png.unlink(missing_ok=True)
        answer = run([CUA_DRIVER, "call", "get_desktop_state", json.dumps({"screenshot_out_file": str(cua_png.resolve())})], timeout=60)
        answer["out"] = answer.get("out", "")[:500]
        answer["file_bytes"] = cua_png.stat().st_size if cua_png.exists() else None
        report["cua_desktop_shot"] = answer
    else:
        report["cua_permissions"] = "CuaDriver not installed"
    # CuaDriver's daemon runs in the console user's own home (a step gets a home of its own).
    if os.path.exists(CUA_DRIVER) and report.get("console_user"):
        env = dict(os.environ, HOME=f"/Users/{report['console_user']}")
        cua_png = png_dir / "capture-check-cua-home.png"
        try:
            done = subprocess.run([CUA_DRIVER, "call", "get_desktop_state", json.dumps({"screenshot_out_file": str(cua_png.resolve())})],
                                  capture_output=True, text=True, timeout=60, env=env)
            report["cua_desktop_shot_home"] = {"rc": done.returncode, "out": done.stdout[:300], "err": done.stderr[-600:],
                                               "file_bytes": cua_png.stat().st_size if cua_png.exists() else None}
        except (OSError, subprocess.TimeoutExpired) as error:
            report["cua_desktop_shot_home"] = {"error": str(error)}
    if args.embed_png:
        home_shot = report.get("cua_desktop_shot_home")
        if isinstance(home_shot, dict):
            png = png_dir / "capture-check-cua-home.png"
            if png.exists():
                small = png.with_suffix(".small.png")
                run(["sips", "-Z", "1600", str(png), "--out", str(small)])
                home_shot["png_base64"] = base64.b64encode((small if small.exists() else png).read_bytes()).decode()
        for key, png in (("screencapture", shot), ("cua_desktop_shot", png_dir / "capture-check-cua.png")):
            if png.exists() and isinstance(report.get(key), dict):
                small = png.with_suffix(".small.png")
                run(["sips", "-Z", "1600", str(png), "--out", str(small)])
                source = small if small.exists() else png
                report[key]["png_base64"] = base64.b64encode(source.read_bytes()).decode()
    tcc_user = Path.home() / "Library/Application Support/com.apple.TCC/TCC.db"
    query = "select client, client_type, auth_value, auth_reason from access where service='kTCCServiceScreenCapture'"
    report["tcc_user_db"] = run(["sqlite3", str(tcc_user), query])
    report["tcc_system_db"] = run(["sqlite3", "/Library/Application Support/com.apple.TCC/TCC.db", query])
    text = json.dumps(report, indent=2)
    print(text)
    if args.json:
        Path(args.json).parent.mkdir(parents=True, exist_ok=True)
        Path(args.json).write_text(text + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
