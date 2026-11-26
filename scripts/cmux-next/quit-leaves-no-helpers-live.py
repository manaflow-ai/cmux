#!/usr/bin/env python3
"""Tagged-app proof that quitting a dev build leaves no process of it running (issue 55842).

Usage: quit-leaves-no-helpers-live.py TAG APP [--mode MODE ...] [--settle SECONDS]
  TAG   the tagged build's tag (scripts/reload.sh --tag TAG)
  APP   the tagged "cmux DEV TAG.app" (reload.sh's "App path:")
  MODE  how the app ends, each run on a fresh launch (default: every one):
          quit          `action.run quit` over the debug socket: Cmd-Q's own action, keep sessions
          end-sessions  `action.run quitEndSessions`
          sigterm       SIGTERM, as reload.sh replaces a build
          sigkill       SIGKILL, as a crash
Host: needs a GUI session. Run it on the build host through nx-remote, never on a laptop
someone works on:
  nx-remote --needs gui --ref <sha> -- bash -c './scripts/reload.sh --tag <tag> && \\
      python3 scripts/cmux-next/quit-leaves-no-helpers-live.py <tag> "<App path>"'

Each run launches the app (no activate, automation socket), waits until its helpers run (the
terminal owner `cmux-tui --headless`, and acpmux when it starts), ends the app, waits for the
app's exit, then waits up to SETTLE seconds (default 30) for every process of the tag to be gone:
every process naming `cmux DEV TAG.app/`, every terminal holder or host owned by its app, and
their descendants (scripts/dev-build.py `tree`). It prints what is left, ends it with
`dev-build.py stop --tag TAG`, and exits 1 when any run left a process.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import signal
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("dev_build", ROOT / "scripts/dev-build.py")
dev_build = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(dev_build)

MODES = ("quit", "end-sessions", "sigterm", "sigkill")


def rpc(sock: str, method: str, params: dict, timeout: float = 15):
    try:
        c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        c.settimeout(timeout)
        c.connect(sock)
        c.sendall((json.dumps({"id": 1, "method": method, "params": params}) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = c.recv(1 << 20)
            if not chunk:
                break
            buf += chunk
        c.close()
        return json.loads(buf)
    except (OSError, ValueError) as error:
        return {"error": str(error)}


def tag_processes(tag: str):
    own = {os.getpid(), os.getppid()}
    return dev_build.tree(tag, dev_build.snapshot(), own)


def wait_for(predicate, timeout: float) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(0.5)  # test harness: polls the process table
    return predicate()


def launch(app: str, tag: str, sock: str):
    scratch = tempfile.mkdtemp(prefix="quit-no-helpers-")
    Path(scratch, "cmux.json").write_text("{}")
    Path(scratch, "ghostty").write_text("")
    env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
           "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
           "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": str(Path(scratch, "cmux.json")),
           "CMUX_NEXT_GHOSTTY_CONFIG": str(Path(scratch, "ghostty")), "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1000,700"}
    if os.path.exists(sock):
        os.unlink(sock)
    log = open(Path(tempfile.gettempdir(), f"quit-no-helpers-{tag}.log"), "a")
    binary = str(Path(app, "Contents/MacOS/cmux DEV"))
    return subprocess.Popen([binary], env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL)


def run(tag: str, app: str, mode: str, settle: float) -> list:
    sock = f"/tmp/cmux-debug-{tag}.sock"
    proc = launch(app, tag, sock)
    print(f"[{mode}] launched pid {proc.pid}", flush=True)
    owner = lambda: any("--headless" in p.command for p in tag_processes(tag))  # noqa: E731
    if not wait_for(lambda: os.path.exists(sock) and owner(), 180):
        print(f"[{mode}] the terminal owner never started", flush=True)
    wait_for(lambda: any("acpmux daemon run" in p.command or "acp daemon run" in p.command
                         for p in tag_processes(tag)), 30)
    before = tag_processes(tag)
    print(f"[{mode}] {len(before)} process(es) of the tag before the quit", flush=True)
    if mode == "quit":
        print(f"[{mode}] {rpc(sock, 'action.run', {'id': 'quit'})}", flush=True)
    elif mode == "end-sessions":
        print(f"[{mode}] {rpc(sock, 'action.run', {'id': 'quitEndSessions'})}", flush=True)
    elif mode == "sigterm":
        proc.send_signal(signal.SIGTERM)
    else:
        proc.send_signal(signal.SIGKILL)
    try:
        proc.wait(timeout=60)
    except subprocess.TimeoutExpired:
        print(f"[{mode}] the app did not exit in 60s; SIGKILL", flush=True)
        proc.kill()
        proc.wait()
    wait_for(lambda: not tag_processes(tag), settle)
    left = tag_processes(tag)
    for p in left:
        print(f"[{mode}] LEFT {p.pid} {p.command[:200]}", flush=True)
    print(f"[{mode}] {'PASS' if not left else 'FAIL'}: {len(left)} process(es) left", flush=True)
    return left


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("tag")
    parser.add_argument("app")
    parser.add_argument("--mode", action="append", choices=MODES)
    parser.add_argument("--settle", type=float, default=30)
    args = parser.parse_args()
    if not dev_build.valid_tag(args.tag) or not args.app.rstrip("/").endswith(f"/cmux DEV {args.tag}.app"):
        print("the app must be the tag's own cmux DEV TAG.app", file=sys.stderr)
        return 2
    if dev_build.app_pids(args.tag, dev_build.snapshot()):
        print(f"cmux DEV {args.tag} is already running; quit it first", file=sys.stderr)
        return 2
    failed = []
    try:
        for mode in args.mode or MODES:
            if run(args.tag, args.app, mode, args.settle):
                failed.append(mode)
            dev_build.stop(args.tag, dev_build.System(), log=lambda line: print(f"cleanup: {line}", flush=True))
    finally:
        dev_build.stop(args.tag, dev_build.System(), log=lambda line: print(f"cleanup: {line}", flush=True))
    print(json.dumps({"tag": args.tag, "failed": failed}), flush=True)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
