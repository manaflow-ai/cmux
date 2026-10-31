#!/usr/bin/env python3
"""End-to-end check of one remote group host (remote-groups-DESIGN.md, part II, slice A).

Connects to an SSH host the way the app's "New Remote Group..." does (SSH bootstrap installs
or reuses the pinned cmux-tui on the host), headless, on a private local socket, then checks
each surface the host serves over the one daemon protocol:

  1. enumerate: workspace list / terminal list answer (before and after create)
  2. terminal: create a workspace in a folder, type a command, read the remote output back
  3. diff: git status and git diff --patch of a repository on the host

It changes nothing in the running app: the bridge is headless (--headless) with its own
state dir and socket. On the host it creates ~/cmux-remote-group-e2e (a scratch git repo).

Usage:
  scripts/cmux-next/remote-group-e2e.py HOST [--ssh-config FILE] [--cmux PATH] [--keep]

HOST is an SSH alias or user@host. Exit 0 when every check passes, 1 otherwise; one JSON
line per check on stdout.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time

SCRATCH = "cmux-remote-group-e2e"


def run(cmd: list[str], timeout: float = 60) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)


def report(check: str, ok: bool, **fields: object) -> bool:
    print(json.dumps({"check": check, "ok": ok, **fields}), flush=True)
    return ok


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("host")
    parser.add_argument("--ssh-config", help="ssh -F file (for hosts not in ~/.ssh/config)")
    parser.add_argument("--cmux", default=shutil.which("cmux") or "cmux")
    parser.add_argument("--keep", action="store_true", help="leave the bridge running")
    parser.add_argument("--connect-timeout", type=float, default=240)
    args = parser.parse_args()

    ssh = ["ssh", "-o", "BatchMode=yes"] + (["-F", args.ssh_config] if args.ssh_config else [])
    ssh_args: list[str] = []
    if args.ssh_config:
        ssh_args = ["--ssh-arg", "-F", "--ssh-arg", args.ssh_config]

    work = tempfile.mkdtemp(prefix="rg-e2e-")
    sock = os.path.join(work, "mux.sock")
    log = open(os.path.join(work, "connect.log"), "w")
    bridge = subprocess.Popen(
        [args.cmux, "remote", "connect", f"ssh://{args.host}", "--headless", "--json",
         *ssh_args, "--state-dir", os.path.join(work, "state"), "--local-socket", sock,
         "--session", "rg-e2e"],
        stdout=log, stderr=subprocess.STDOUT, text=True,
    )
    ok = True
    try:
        start = time.monotonic()
        connected = False
        while time.monotonic() - start < args.connect_timeout and bridge.poll() is None:
            text = open(log.name).read()
            if '"state":"connected"' in text and os.path.exists(sock):
                connected = True
                break
            time.sleep(0.5)
        elapsed = round(time.monotonic() - start, 1)
        if not report("connect", connected, seconds=elapsed, log=open(log.name).read()[-400:] if not connected else None):
            return 1

        def cli(*words: str) -> object:
            out = run([args.cmux, "--socket", sock, "--json", *words])
            if out.returncode != 0:
                raise RuntimeError(f"{' '.join(words)}: {out.stdout.strip()} {out.stderr.strip()}")
            return json.loads(out.stdout) if out.stdout.strip() else None

        before = cli("workspace", "list")
        ok &= report("enumerate", isinstance(before, list), workspaces=len(before or []))

        prep = run(ssh + [args.host,
                          f"command -v git >/dev/null || exit 3; rm -rf ~/{SCRATCH} && mkdir -p ~/{SCRATCH} && cd ~/{SCRATCH}"
                          " && git init -q && echo hello > a.txt && git add -A"
                          " && git -c user.email=e2e@cmux -c user.name=e2e commit -qm init && echo changed >> a.txt && pwd"])
        has_git = prep.returncode == 0
        folder = prep.stdout.strip().splitlines()[-1] if has_git else None
        if not has_git:
            home = run(ssh + [args.host, f"mkdir -p ~/{SCRATCH} && cd ~/{SCRATCH} && pwd"])
            folder = home.stdout.strip().splitlines()[-1]

        made = cli("workspace", "create", "--name", "remote-group-e2e", "--cwd", folder)
        value = made["value"]
        term, ws = value["terminal_id"], value["workspace_id"]
        after = cli("workspace", "list")
        ok &= report("enumerate_after_create", any(w["id"] == ws for w in after), workspaces=len(after))
        terms = cli("terminal", "list")
        ok &= report("terminal_list", any(t["id"] == term and t.get("cwd") == folder for t in terms), terminals=len(terms))

        marker = f"rg-e2e-{os.getpid()}"
        cli("terminal", term, "write", "--text", f"echo {marker}-$(uname -s)\n")
        seen = None
        for _ in range(40):
            screen = cli("terminal", term, "screen", "read")
            screen = screen.get("value", screen) if isinstance(screen, dict) else {}
            lines = screen.get("lines") or screen.get("text", "").splitlines()
            seen = next((line for line in lines if line.startswith(f"{marker}-")), None)
            if seen:
                break
            time.sleep(0.25)
        ok &= report("terminal_roundtrip", seen is not None, output=seen)

        if has_git:
            status = cli("git", "status", "--workspace", ws)
            ok &= report("git_status", status.get("root") == folder, branch=status.get("branch"))
            diff = cli("git", "diff", "--path", folder, "--patch")
            patch = (diff.get("files") or [{}])[0].get("patch", "")
            ok &= report("git_diff", "+changed" in patch, files=diff.get("total_files"))
        else:
            report("git_status", True, skipped="git is not installed on the host")

        cli("workspace", ws, "close")
        return 0 if ok else 1
    except Exception as error:  # noqa: BLE001 - one report line per failure
        report("error", False, message=str(error))
        return 1
    finally:
        if not args.keep:
            bridge.terminate()
            try:
                bridge.wait(timeout=10)
            except subprocess.TimeoutExpired:
                bridge.kill()
            shutil.rmtree(work, ignore_errors=True)
        else:
            print(json.dumps({"bridge_pid": bridge.pid, "socket": sock}))


if __name__ == "__main__":
    sys.exit(main())
