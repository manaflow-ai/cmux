#!/usr/bin/env python3
"""The Chief thread's structure on the real app: launch it, open Chief and Home, read the accessibility
tree, check it against tests/ui-structure/chief-thread.json.

Leo, 2026-11-10, on a nightly whose Chief panel was a column of avatar tiles beside wide grey cards:
"latest nightly chief UI got completely cooked we have massive regression what happened" ... "Where's
the spec for that? Where's the iMessage". Every static check passed that build. This one launches the
exact app (scripts/ci/fresh_home_launch_smoke.py: a fresh home, no defaults, Home must render), then
through the release control socket opens the Chief (`home.openChief`) and Home (`home.show`), dumps the
app's accessibility tree with tests/ui-structure/ax_dump.swift after each, and runs
tests/ui-structure/thread_structure.py on it. It reads geometry from the tree any accessibility client
reads, so it holds whichever renderer draws the thread.

    chief_thread_smoke.py (--dmg DMG | --app APP) --out DIR [--ax-dump BIN]

Exit 0: every shown thread met the spec. 1: a thread broke it (the violations are in DIR/report.json
"chief_thread" and the job summary), or the app crashed or never rendered Home. 3: it could not run (no
GUI session, no accessibility trust for the dumper, no thread container on any surface: a fresh home's
first-run panel instead of a transcript). A publish gate blocks on 1 only.
"""
from __future__ import annotations

import importlib.util
import json

import socket
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
_spec = importlib.util.spec_from_file_location("fresh_home_launch_smoke", HERE / "fresh_home_launch_smoke.py")
smoke = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(smoke)
_tspec = importlib.util.spec_from_file_location("thread_structure", ROOT / "tests" / "ui-structure" / "thread_structure.py")
structure = importlib.util.module_from_spec(_tspec)
_tspec.loader.exec_module(structure)

SURFACES = [("chief-panel", "home.openChief"), ("home", "home.show")]
SETTLE_SECONDS = 3.0
# A web page's tree fills in after its first paint: each surface is read again until a thread shows.
READS = 6
# The compiled tests/ui-structure/ax_dump.swift (--ax-dump; console-session.sh passes no environment).
AX_DUMP = ""


def call(socket_path: Path, method: str, params: dict | None = None, timeout: float = 30.0) -> dict:
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
            sock.settimeout(timeout)
            sock.connect(str(socket_path))
            sock.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
            buffer = b""
            while b"\n" not in buffer:
                chunk = sock.recv(1 << 20)
                if not chunk:
                    break
                buffer += chunk
        reply = json.loads(buffer.split(b"\n", 1)[0])
    except (OSError, ValueError) as error:
        return {"error": str(error)}
    if reply.get("error"):
        return {"error": reply.get("error")}
    result = reply.get("result")
    return result if isinstance(result, dict) else {"value": result}


def ax_dump(binary: Path, pid: int) -> tuple[int, dict | None, str]:
    try:
        done = subprocess.run([str(binary), str(pid)], capture_output=True, text=True, timeout=90)
    except (OSError, subprocess.SubprocessError) as error:
        return 127, None, str(error)
    if done.returncode != 0:
        return done.returncode, None, done.stderr.strip()[:500]
    try:
        return 0, json.loads(done.stdout), ""
    except ValueError as error:
        return 1, None, f"unreadable dump: {error}"


def journey(process, socket_path, env, app, out, report) -> list[str]:
    binary = Path(AX_DUMP) if AX_DUMP else Path("/nonexistent")
    result: dict = {"surfaces": {}, "verdict": "cannot-run"}
    report["chief_thread"] = result
    if not binary.is_file():
        result["why"] = f"no accessibility dumper at {binary} (swiftc tests/ui-structure/ax_dump.swift)"
        return []
    failures: list[str] = []
    checked = 0
    for surface, action in SURFACES:
        reply = call(Path(socket_path), "action.run", {"action": action, "focus": True})
        entry: dict = {"action": action, "reply": reply}
        result["surfaces"][surface] = entry
        tree, snap = None, None
        for _ in range(READS):
            time.sleep(SETTLE_SECONDS)
            status, tree, why = ax_dump(binary, int(report.get("pid") or process.pid))
            if status == 3:
                result["why"] = "the dumper is not trusted for accessibility"
                return []
            if tree is None:
                continue
            snap = structure.normalize(tree, surface, source=f"{app.name} {surface} (ax_dump)")
            if snap["thread_frame"]:
                break
        if tree is None:
            entry["why"] = why
            continue
        if out:
            (Path(out) / f"ax-{surface}.json").write_text(json.dumps(tree))
            # Evidence only, never the verdict (screencapture may lack the Screen Recording grant).
            subprocess.run(["screencapture", "-x", str(Path(out) / f"shot-{surface}.png")], capture_output=True, timeout=30)
        entry["snapshot"] = snap
        if out:
            (Path(out) / f"thread-{surface}.json").write_text(json.dumps(snap, indent=1))
        if not snap["thread_frame"]:
            entry["why"] = "no Messages container on this surface (a first-run panel or nothing shown)"
            continue
        checked += 1
        violations = structure.check(snap, surface=surface)
        entry["violations"] = violations
        failures += [f"chief thread structure ({surface}): {v['rule']}: {v['detail']}" for v in violations]
    if checked:
        result["verdict"] = "fail" if failures else "pass"
    else:
        result["why"] = "no surface showed a thread container"
    return failures


def login_keychain(env: dict) -> None:
    """A login keychain in the fresh home, as a real install has: without one the first Chromium
    Safe Storage read puts up "Keychain Not Found" over the window (as stable_next_ui_journey.py)."""
    home = Path(env["HOME"])
    keychain = home / "Library" / "Keychains" / "login.keychain-db"
    keychain.parent.mkdir(parents=True, exist_ok=True)
    scoped = {"HOME": env["HOME"], "CFFIXED_USER_HOME": env["CFFIXED_USER_HOME"], "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
              "USER": env.get("USER", "")}
    for args in (["create-keychain", "-p", "", str(keychain)],
                 ["list-keychains", "-d", "user", "-s", str(keychain)],
                 ["default-keychain", "-d", "user", "-s", str(keychain)],
                 ["set-keychain-settings", str(keychain)]):
        done = subprocess.run(["security", *args], env=scoped, capture_output=True, text=True, timeout=30)
        if done.returncode != 0:
            raise smoke.CannotRun(f"security {args[0]} in the fresh home failed: {done.stderr.strip()[:300]}")


def main(argv: list[str] | None = None) -> int:
    global AX_DUMP
    args = list(argv if argv is not None else sys.argv[1:])
    if "--ax-dump" in args:
        i = args.index("--ax-dump")
        AX_DUMP = args[i + 1]
        del args[i:i + 2]
    smoke.AFTER_RENDER = journey
    smoke.PREPARE_HOME = login_keychain
    status = smoke.main(args)
    out = None
    if "--out" in args:
        out = Path(args[args.index("--out") + 1])
    verdict = None
    if out and (out / "report.json").exists():
        verdict = (json.loads((out / "report.json").read_text()).get("chief_thread") or {}).get("verdict")
    if status == smoke.PASS and verdict != "pass":
        # Launched and rendered, but no thread to check: never a pass, never a block.
        return smoke.CANNOT_RUN
    return status


if __name__ == "__main__":
    sys.exit(main())
