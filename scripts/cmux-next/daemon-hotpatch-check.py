#!/usr/bin/env python3
"""Patch a running cmux-tui daemon's Rust in place with Dioxus `subsecond`
and time it (HQ#7149 R4, cmux-tui-core/src/hotpatch.rs).

Builds the daemon with the `hotpatch` feature under `dx serve --hot-patch`,
opens a shell in it, then edits `identify` in cmux-tui-core (a library crate,
not the binary's own) to add a probe field. It passes when the running
daemon answers `identify` with the probe, from the same pid, with the shell
still alive and echoing, within `--budget` seconds (10) of the save. The
edit is always taken back.

dx comes from the Dioxus release (0.7.10, the version `subsecond` is pinned
to), checked against its published sha256, into `--cache`. The first build
is a full debug build of cmux-tui; the patch itself is the measured part.
Linux only for now (the published dx is for x86_64 Linux).

Prints one JSON report; exits 0 only when every check passed.
"""

from __future__ import annotations

import argparse
import json
import os
import shlex
import signal
import socket
import subprocess
import sys
import tarfile
import tempfile
import time
from pathlib import Path

DX_VERSION = "0.7.10"
DX_URL = f"https://github.com/DioxusLabs/dioxus/releases/download/v{DX_VERSION}/dx-x86_64-unknown-linux-gnu.tar.gz"
DX_SHA256 = "4363e4ed2a3f1eb7f4d38d2d59aed59ce43271c44c16b425e92c89a64761fbe7"
EDIT_FILE = "cmux-tui/crates/cmux-tui-core/src/server/cmd_server.rs"
EDIT_ANCHOR = '        "daemon_handoff": 1,\n'


def now() -> float:
    return time.monotonic()


def request(sock: Path, payload: dict, timeout: float = 10.0) -> dict:
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
        conn.settimeout(timeout)
        conn.connect(str(sock))
        conn.sendall((json.dumps(payload) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = conn.recv(65536)
            if not chunk:
                break
            buf += chunk
    response = json.loads(buf)
    if response.get("ok") is not True:
        raise RuntimeError(f"{payload.get('cmd')}: {response}")
    return response.get("data") or {}


def wait_until(what: str, deadline: float, probe):
    last = None
    while now() < deadline:
        try:
            value = probe()
        except (OSError, RuntimeError, ValueError) as error:
            last, value = error, None
        if value:
            return value
        time.sleep(0.05)
    raise TimeoutError(f"{what}: timed out (last: {last})")


def install_dx(cache: Path) -> Path:
    dx = cache / f"dx-{DX_VERSION}" / "dx"
    if dx.exists():
        return dx
    dx.parent.mkdir(parents=True, exist_ok=True)
    archive = dx.parent / "dx.tar.gz"
    subprocess.run(["curl", "-sfL", "-o", str(archive), DX_URL], check=True, timeout=600)
    digest = subprocess.run(["sha256sum", str(archive)], capture_output=True, text=True, check=True).stdout.split()[0]
    if digest != DX_SHA256:
        raise RuntimeError(f"dx archive sha256 {digest} is not the pinned {DX_SHA256}")
    with tarfile.open(archive) as tar:
        member = tar.getmember("dx")
        tar.extractall(dx.parent, members=[member], filter="data")
    dx.chmod(0o755)
    return dx


def screen_has(sock: Path, surface: int, text: str) -> bool:
    return text in (request(sock, {"cmd": "read-screen", "surface": surface}).get("text") or "")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--cache", type=Path, default=Path(tempfile.gettempdir()) / "cmux-hotpatch-tools")
    parser.add_argument("--budget", type=float, default=10.0)
    parser.add_argument("--build-timeout", type=float, default=3600)
    args = parser.parse_args()

    repo = args.repo.resolve()
    edit_path = repo / EDIT_FILE
    original = edit_path.read_text()
    if EDIT_ANCHOR not in original:
        print(json.dumps({"passed": False, "error": f"{EDIT_FILE} no longer has the edit anchor"}))
        return 1
    dx = install_dx(args.cache)
    work = Path(tempfile.mkdtemp(prefix="cmux-hotpatch-", dir="/tmp"))
    (work / "cmux-tui").mkdir(mode=0o700)
    sock = work / "mux.sock"
    env = {k: v for k, v in os.environ.items() if not k.startswith(("ACPMUX_", "CMUX_"))}
    env.update(
        CMUX_TUI_STATE_DIR=str(work / "cmux-tui" / "sessions"),
        CMUX_TUI_HOST_EXE_DIR=str(work / "host-exe"),
        CMUX_TUI_SHELL_INTEGRATION="none",
        SHELL="/bin/sh",
    )
    daemon_args = shlex.join(["--headless", "--session", "hotpatch-check", "--socket", str(sock),
                              "--state", str(work / "state")])
    log_path = work / "dx.log"
    report: dict = {"dx": DX_VERSION, "budget_secs": args.budget}
    proc = None
    try:
        with open(log_path, "wb") as log:
            proc = subprocess.Popen(
                [str(dx), "serve", "--hot-patch", "--interactive", "false", "--platform", "linux",
                 "-p", "cmux-tui", "--bin", "cmux-tui", "--features", "hotpatch", "--args", daemon_args],
                cwd=repo / "cmux-tui", env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True,
            )
        start = now()
        before = wait_until("daemon under dx", start + args.build_timeout,
                            lambda: request(sock, {"cmd": "identify"}))
        report["first_build_secs"] = round(now() - start, 1)
        created = request(sock, {"cmd": "run", "argv": ["/bin/sh"], "new_workspace": True})
        surface = created["surface"]
        request(sock, {"cmd": "send", "surface": surface, "text": "echo before-$((1+1))\n"})
        wait_until("shell before", now() + 15, lambda: screen_has(sock, surface, "before-2"))

        probe = f"probe-{os.getpid()}-{int(time.time())}"
        t0 = now()
        edit_path.write_text(original.replace(EDIT_ANCHOR, EDIT_ANCHOR + f'        "hotpatch_probe": "{probe}",\n', 1))
        try:
            after = wait_until("patched identify", t0 + max(args.budget * 6, 120),
                               lambda: (r := request(sock, {"cmd": "identify"})).get("hotpatch_probe") == probe and r)
            patch_secs = now() - t0
        finally:
            edit_path.write_text(original)
        request(sock, {"cmd": "send", "surface": surface, "text": "echo after-$((2+2))\n"})
        shell_ok = bool(wait_until("shell after", now() + 15, lambda: screen_has(sock, surface, "after-4")))
        report.update(
            pid_before=before.get("pid"), pid_after=after.get("pid"),
            same_pid=before.get("pid") == after.get("pid"), patch_secs=round(patch_secs, 3),
            shell_alive=shell_ok,
        )
        report["passed"] = report["same_pid"] and shell_ok and patch_secs < args.budget
        try:
            request(sock, {"cmd": "shutdown-daemon", "pid": after.get("pid"),
                           "generation": after.get("generation"), "end_terminals": True})
        except (OSError, RuntimeError, ValueError):
            pass
    except Exception as error:  # noqa: BLE001 - reported as a failed check
        report.update(passed=False, error=f"{type(error).__name__}: {error}")
        report["dx_log_tail"] = log_path.read_text(errors="replace")[-3000:] if log_path.exists() else ""
    finally:
        if edit_path.read_text() != original:
            edit_path.write_text(original)
        if proc is not None and proc.poll() is None:
            # dx and the daemon it started run in this process group only.
            os.killpg(proc.pid, signal.SIGTERM)
            try:
                proc.wait(timeout=20)
            except subprocess.TimeoutExpired:
                os.killpg(proc.pid, signal.SIGKILL)
        subprocess.run(["rm", "-rf", str(work)], check=False)
    print(json.dumps(report, indent=2))
    return 0 if report.get("passed") else 1


if __name__ == "__main__":
    sys.exit(main())
