#!/usr/bin/env python3
"""CMUX-570: bytes and speed of cmux-tui builds measured side by side in one job (cli-size.sh toolchain).

  cli-size-speed.py OUT VARIANT...

OUT/VARIANT/cmux is each stripped binary and OUT/VARIANT/cmux.unstripped the same build before strip. Samples
interleave the variants (each round starts from a different one), so no variant gets a cold or a warm machine
to itself. Per variant it reports:
  - cli_help_ms, cli_version_ms: `cmux --help` and `cmux --version`, process start to exit (#42910's harness);
  - daemon_ready_ms: a headless daemon on a scratch home, spawn until its socket answers `identify`;
  - identify_ms: one `identify` request's round trip on a ready daemon;
  - new_workspace_ms: one `new-workspace` (a terminal and its shell, through cmux-tui-core) round trip.
Every number is a median (p50) with its p95; the first round is a warm-up and is dropped. Writes OUT/report.json
and prints one `CLI-SIZE-SPEED` JSON line. Python 3 standard library only; Linux and macOS.
"""
from __future__ import annotations

import hashlib
import json
import os
import pathlib
import shutil
import socket
import statistics
import subprocess
import sys
import tempfile
import time

ROUNDS = 11
REQUESTS = 50
WORKSPACES = 3


class Tui:
    def __init__(self, path: str, timeout: float = 30) -> None:
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.settimeout(timeout)
        self.sock.connect(path)
        self.buf = b""
        self.next_id = 1

    def close(self) -> None:
        try:
            self.sock.close()
        except OSError:
            pass

    def call(self, cmd: str, **params) -> dict:
        rid = self.next_id
        self.next_id += 1
        self.sock.sendall((json.dumps({"id": rid, "cmd": cmd, **params}) + "\n").encode())
        while True:
            while b"\n" not in self.buf:
                chunk = self.sock.recv(1 << 20)
                if not chunk:
                    raise ConnectionError("socket closed")
                self.buf += chunk
            line, self.buf = self.buf.split(b"\n", 1)
            msg = json.loads(line)
            if msg.get("id") == rid and "ok" in msg:
                if not msg.get("ok"):
                    raise RuntimeError(f"{cmd}: {msg.get('error')!r}")
                return msg.get("data") or {}


def cli(binary: pathlib.Path, flag: str) -> float:
    start = time.perf_counter()
    subprocess.run([str(binary), flag], capture_output=True, check=True, timeout=30)
    return (time.perf_counter() - start) * 1000


def daemon(binary: pathlib.Path, label: str) -> dict[str, list[float]]:
    """One headless daemon: its ready time, REQUESTS identify round trips, WORKSPACES new-workspace round trips."""
    # A short root: a macOS unix socket path holds at most 104 bytes.
    root = tempfile.mkdtemp(prefix="cs-", dir="/tmp")
    home = os.path.join(root, "home")
    os.makedirs(home)
    sock = os.path.join(root, "t.sock")
    env = dict(os.environ, HOME=home, XDG_CONFIG_HOME=os.path.join(home, ".config"),
               XDG_STATE_HOME=os.path.join(home, ".local/state"), XDG_DATA_HOME=os.path.join(home, ".local/share"),
               XDG_CACHE_HOME=os.path.join(home, ".cache"), CMUX_TUI_CONFIG=os.path.join(root, "config.json"),
               ACPMUX_SOCKET=os.path.join(root, "no-acpmux.sock"), SHELL="/bin/sh")
    env.pop("CMUX_TUI_TERMINAL_HOST_MODEL", None)
    log_path = os.path.join(root, "tui.log")
    out: dict[str, list[float]] = {"daemon_ready_ms": [], "identify_ms": [], "new_workspace_ms": []}
    with open(log_path, "w") as log:
        start = time.perf_counter()
        proc = subprocess.Popen([str(binary), "--headless", "--session", f"cs{os.getpid()}{label}", "--socket", sock,
                                 "--state", os.path.join(root, "state")],
                                stdout=log, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, env=env,
                                start_new_session=True)
    try:
        deadline = time.monotonic() + 60
        while True:
            if proc.poll() is not None:
                raise RuntimeError(f"{label}: daemon exited {proc.returncode}: {open(log_path).read()[-2000:]}")
            if os.path.exists(sock):
                try:
                    c = Tui(sock, timeout=5)
                    c.call("identify")
                    c.close()
                    break
                except (OSError, RuntimeError, ValueError):
                    pass
            if time.monotonic() > deadline:
                raise RuntimeError(f"{label}: daemon socket not up within 60 s")
            time.sleep(0.005)  # bench: polling the daemon it started; 5 ms bounds the ready-time error
        out["daemon_ready_ms"].append((time.perf_counter() - start) * 1000)
        c = Tui(sock)
        for _ in range(REQUESTS):
            t = time.perf_counter()
            c.call("identify")
            out["identify_ms"].append((time.perf_counter() - t) * 1000)
        for i in range(WORKSPACES):
            t = time.perf_counter()
            c.call("new-workspace", name=f"w{i}", cols=80, rows=24)
            out["new_workspace_ms"].append((time.perf_counter() - t) * 1000)
        c.close()
    finally:
        try:
            c = Tui(sock, timeout=30)
            ident = c.call("identify")
            c.call("shutdown-daemon", pid=ident.get("pid"),
                   generation=ident.get("generation") or ident.get("boot_generation") or "", end_terminals=True)
            c.close()
        except (OSError, RuntimeError, ValueError):
            pass
        try:
            proc.wait(timeout=30)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, 9)  # bench: only the daemon this run started, after its own shutdown failed
            proc.wait(timeout=10)
        shutil.rmtree(root, ignore_errors=True)
    return out


def summary(values: list[float]) -> dict:
    ordered = sorted(values)
    return {"p50_ms": round(statistics.median(ordered), 3),
            "p95_ms": round(ordered[min(len(ordered) - 1, int(len(ordered) * 0.95))], 3), "n": len(ordered)}


def main() -> int:
    out = pathlib.Path(sys.argv[1])
    variants = sys.argv[2:]
    keys = ("cli_help_ms", "cli_version_ms", "daemon_ready_ms", "identify_ms", "new_workspace_ms")
    samples = {v: {k: [] for k in keys} for v in variants}
    for rnd in range(ROUNDS):
        order = variants[rnd % len(variants):] + variants[:rnd % len(variants)]
        for v in order:
            binary = out / v / "cmux"
            help_ms, version_ms = cli(binary, "--help"), cli(binary, "--version")
            run = daemon(binary, v)
            if rnd == 0:
                continue  # warm-up round
            samples[v]["cli_help_ms"].append(help_ms)
            samples[v]["cli_version_ms"].append(version_ms)
            for k, values in run.items():
                samples[v][k].extend(values)
    report = {"kind": "cmux-tui-toolchain-size-speed", "uname": " ".join(os.uname()[0:5:2]), "variants": {}}
    for v in variants:
        binary = out / v / "cmux"
        report["variants"][v] = {
            "stripped_bytes": binary.stat().st_size,
            "unstripped_bytes": (out / v / "cmux.unstripped").stat().st_size,
            "sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
            "rustc": (out / v / "rustc.txt").read_text().strip(),
            **{k: summary(values) for k, values in samples[v].items()},
        }
    (out / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print("CLI-SIZE-SPEED " + json.dumps(report), flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
