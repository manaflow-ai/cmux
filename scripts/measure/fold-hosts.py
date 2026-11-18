#!/usr/bin/env python3
"""Start time and idle memory of the programs bin/cmux runs by argv[0] (CMUX-570), base against head.

Leo (CMUX-570): "decreasing bundle size". A program folded into the multicall cmux binary runs from a bigger file;
this says what that costs each process, on Linux, from one harness on one runner. fold-hosts.sh builds the bin/
folders; this samples them in turns (base, head, head, base, ...) so neither side gets the warm cache.

For each --bin LABEL=DIR (a folder with cmux and its siblings, links or files):

  cmux-agent-screen-detection  start: wall time of `list` (exec, the manifests, one JSON answer, exit).
                               idle: the plugin under a headless daemon of the same folder's cmux (the daemon
                               starts it from beside its own executable, as in the app), SETTLE s after the
                               daemon's socket answers.
  cmux-cloud                   start: spawn to its first stdout line (the link-details request it sends before
                               it reads any op). idle: the same process SETTLE s later, stdin still open.
  cmux-tui-host                idle: the terminal host of one workspace's terminal under that daemon. Linux runs it
                               from bin/cmux-tui-host when that answers with the daemon's build, else re-execs the
                               daemon (/proc/self/exe): run once with the folder as it is and once with
                               cmux-tui-host hidden (`full-host`), which is what a host folded into bin/cmux costs.
                               start: wall time of `cmux-tui-host --version`, and of `cmux --version`.

Idle numbers are /proc/PID/smaps_rollup: Rss, Pss, Pss_Anon, Private_Dirty (kB). Prints one FOLD-SAMPLE line (JSON)
per sample and a FOLD-SUMMARY line per label and metric (median, p90, n). Measurement only: it signals only the
processes it started.

  fold-hosts.py --bin base=DIR --bin head=DIR [--rounds 15] [--idle-rounds 3] [--settle 8]
"""

import argparse
import importlib.util
import json
import os
import shutil
import statistics
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location("tui_idle_ram", HERE / "tui-idle-ram.py")
tui_idle = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(tui_idle)

DETECTOR = "cmux-agent-screen-detection"
CLOUD = "cmux-cloud"
HOST = "cmux-tui-host"
KEYS = ("Rss", "Pss", "Pss_Anon", "Private_Dirty")


SAMPLES = {}


def emit(label, program, metric, value, **extra):
    if not label.startswith("warm-"):
        SAMPLES.setdefault((label, program, metric), []).append(value)
    print("FOLD-SAMPLE " + json.dumps({"label": label, "program": program, "metric": metric, "value": value,
                                       **extra}), flush=True)


def wall_ms(argv, env=None):
    t0 = time.perf_counter()
    done = subprocess.run(argv, capture_output=True, timeout=60, env=env)
    elapsed = (time.perf_counter() - t0) * 1000
    if done.returncode != 0:
        raise RuntimeError(f"{argv} exited {done.returncode}: {done.stderr[-400:]!r}")
    return elapsed, done.stdout


def scratch_env(root):
    home = os.path.join(root, "home")
    os.makedirs(home, exist_ok=True)
    return dict(os.environ, HOME=home, XDG_CONFIG_HOME=os.path.join(home, ".config"),
                XDG_STATE_HOME=os.path.join(home, ".local/state"), XDG_DATA_HOME=os.path.join(home, ".local/share"),
                XDG_CACHE_HOME=os.path.join(home, ".cache"), CMUX_TUI_CONFIG=os.path.join(root, "config.json"),
                ACPMUX_SOCKET=os.path.join(root, "no-acpmux.sock"), SHELL="/bin/sh")


def starts(label, bin_dir, answers):
    """One start sample of each program in BIN_DIR. ANSWERS keeps the first stdout of each command: base and head
    must answer the same."""
    root = tempfile.mkdtemp(prefix="fold-start-")
    env = scratch_env(root)
    try:
        for program, argv in ((DETECTOR, [str(bin_dir / DETECTOR), "list"]),
                              (HOST, [str(bin_dir / HOST), "--version"]),
                              ("cmux", [str(bin_dir / "cmux"), "--version"])):
            if not (bin_dir / argv[0].rsplit("/", 1)[1]).exists():
                continue
            ms, out = wall_ms(argv, env)
            if program == DETECTOR:
                previous = answers.setdefault(program, out)
                if out != previous:
                    raise RuntimeError(f"{label}: `{DETECTOR} list` answered differently from the first run")
            emit(label, program, "start_ms", round(ms, 2))
        if (bin_dir / CLOUD).exists():
            ms, line, idle = cloud_once(bin_dir / CLOUD, env, settle=0)
            emit(label, CLOUD, "start_ms", round(ms, 2))
            previous = answers.setdefault(CLOUD, line)
            if line != previous:
                raise RuntimeError(f"{label}: {CLOUD}'s first line differs: {line!r} vs {previous!r}")
    finally:
        shutil.rmtree(root, ignore_errors=True)


def cloud_once(binary, env, settle):
    """Spawn the Cloud server with stdin open; the time to its first stdout line, that line, and its rollup SETTLE
    s later (None for settle 0). Ends it by closing stdin."""
    t0 = time.perf_counter()
    proc = subprocess.Popen([str(binary)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                            env={k: env[k] for k in ("HOME", "PATH") if k in env})
    try:
        line = proc.stdout.readline()
        ms = (time.perf_counter() - t0) * 1000
        if not line:
            raise RuntimeError(f"{binary} wrote no line (exit {proc.poll()})")
        idle = None
        if settle:
            time.sleep(settle)  # bench: the idle window
            idle = tui_idle.rollup(proc.pid)
        return ms, line, idle
    finally:
        proc.stdin.close()
        try:
            proc.wait(timeout=30)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()


def daemon_idle(label, bin_dir, settle, variant):
    """A headless daemon of BIN_DIR's cmux with one workspace: the rollups of its screen-detection plugin and its
    terminal host, SETTLE s after it answers. VARIANT `full-host` runs it from a copy of the folder without
    cmux-tui-host, so the terminal host is the daemon's own binary."""
    root = tempfile.mkdtemp(prefix="fold-idle-")
    env = scratch_env(root)
    run_dir = bin_dir
    if variant == "full-host":
        run_dir = Path(root) / "bin"
        shutil.copytree(bin_dir, run_dir, symlinks=True)
        (run_dir / HOST).unlink(missing_ok=True)
    sock = os.path.join(root, "t.sock")
    proc = subprocess.Popen([str(run_dir / "cmux"), "--headless", "--session", f"fold{os.getpid()}", "--socket", sock,
                             "--state", os.path.join(root, "state")],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, stdin=subprocess.DEVNULL, env=env,
                            start_new_session=True)
    try:
        deadline = time.monotonic() + 60
        while True:
            if proc.poll() is not None:
                raise RuntimeError(f"{label}: daemon exited {proc.returncode}")
            if os.path.exists(sock):
                try:
                    c = tui_idle.Tui(sock, timeout=5)
                    c.call("identify")
                    break
                except (OSError, RuntimeError, ValueError):
                    pass
            if time.monotonic() > deadline:
                raise RuntimeError(f"{label}: daemon socket not up within 60 s")
            time.sleep(0.1)  # bench: waiting for the daemon it started to listen
        c.call("new-workspace", name="w0", cols=80, rows=24)
        c.close()
        time.sleep(settle)  # bench: the idle window
        found = set()
        for pid in tui_idle.children(proc.pid)[1:]:
            try:
                with open(f"/proc/{pid}/cmdline", "rb") as f:
                    argv = f.read().split(b"\0")
                exe = os.readlink(f"/proc/{pid}/exe")
                roll = tui_idle.rollup(pid)
            except OSError:
                continue
            name = os.path.basename(argv[0].decode(errors="replace"))
            if name == DETECTOR:
                program = DETECTOR
            elif b"__terminal-host" in argv or name == HOST:
                program = HOST if variant == "as-built" else f"{HOST}@full"
            else:
                continue
            if program in found:
                continue
            found.add(program)
            for key in KEYS:
                emit(label, program, f"idle_{key.lower()}_kb", roll.get(key, 0), exe=os.path.basename(exe))
        for want in ((DETECTOR, HOST) if variant == "as-built" else (f"{HOST}@full",)):
            if want == DETECTOR and not (bin_dir / DETECTOR).exists():
                continue
            if want not in found:
                print(f"FOLD-MISSING {label} {variant} {want}", flush=True)
    finally:
        try:
            c = tui_idle.Tui(sock, timeout=30)
            ident = c.call("identify")
            c.call("shutdown-daemon", pid=ident.get("pid"),
                   generation=ident.get("generation") or ident.get("boot_generation") or "", end_terminals=True)
            c.close()
        except (OSError, RuntimeError, ValueError) as exc:
            print(f"FOLD-NOTE {label}: shutdown-daemon: {exc}", flush=True)
        try:
            proc.wait(timeout=60)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, 9)
            proc.wait()
        shutil.rmtree(root, ignore_errors=True)


def cloud_idle(label, bin_dir, settle):
    if not (bin_dir / CLOUD).exists():
        return
    root = tempfile.mkdtemp(prefix="fold-cloud-")
    try:
        _, _, roll = cloud_once(bin_dir / CLOUD, scratch_env(root), settle)
        for key in KEYS:
            emit(label, CLOUD, f"idle_{key.lower()}_kb", roll.get(key, 0))
    finally:
        shutil.rmtree(root, ignore_errors=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bin", action="append", required=True, help="LABEL=DIR")
    ap.add_argument("--rounds", type=int, default=15)
    ap.add_argument("--idle-rounds", type=int, default=3)
    ap.add_argument("--settle", type=float, default=8)
    args = ap.parse_args()
    bins = [(label, Path(path).resolve()) for label, path in (b.split("=", 1) for b in args.bin)]
    answers = {}
    # Round 0 warms the page cache of every file and is not kept.
    for round_ in range(args.rounds + 1):
        order = bins if round_ % 2 == 0 else bins[::-1]
        for label, path in order:
            if round_ == 0:
                starts(f"warm-{label}", path, answers)
            else:
                starts(label, path, answers)
    for round_ in range(args.idle_rounds):
        order = bins if round_ % 2 == 0 else bins[::-1]
        for label, path in order:
            cloud_idle(label, path, args.settle)
            daemon_idle(label, path, args.settle, "as-built")
            daemon_idle(label, path, args.settle, "full-host")
    for (label, program, metric), values in sorted(SAMPLES.items()):
        ordered = sorted(values)
        print("FOLD-SUMMARY " + json.dumps({
            "label": label, "program": program, "metric": metric, "n": len(values),
            "median": statistics.median(values), "p90": ordered[min(len(ordered) - 1, int(len(ordered) * 0.9))],
            "min": ordered[0], "max": ordered[-1]}), flush=True)


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:  # noqa: BLE001 - the harness reports and fails
        print(f"FOLD-ERROR {exc}", flush=True)
        sys.exit(1)
