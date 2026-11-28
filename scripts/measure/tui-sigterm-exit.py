#!/usr/bin/env python3
"""SIGTERM to exit of a fresh Cloud-style cmux-tui session host, quiet and under fsync-heavy disk load.

A Cloud machine's bind rewrites carrier.json, and cmux-host SIGTERMs the running daemon, waits up to
its stop grace (5 s) and SIGKILLs before it starts the next one. This times that stop: it spawns
`cmux server start --session cloud --remote-ws 127.0.0.1:0 ...` with a temporary HOME, sends SIGTERM
after --delay seconds, and times the exit. Every 50 ms it samples each thread's /proc wchan; a stop
slower than --slow-ms prints the threads that were blocked in the kernel (for example
`headless-signal:jbd2_log_wait_commit`, a durable sync on the stop path).

--io-load N runs N writers, each rewriting one reused 64 MB file with conv=fsync, so every run
competes with a busy journal the way a booting Cloud machine's does; the files are deleted at exit.
Linux only. Run on a Linux host or through the fleet:
  python3 scripts/measure/tui-sigterm-exit.py --bin target/release/cmux [--runs 8] [--io-load 4]
  cmux-ci run -- python3 scripts/measure/tui-sigterm-exit.py --bin target/release/cmux --io-load 4
"""

import argparse
import os
import shutil
import signal
import statistics
import subprocess
import tempfile
import threading
import time


def threads(pid):
    out = []
    try:
        for task in sorted(os.listdir(f"/proc/{pid}/task")):
            try:
                base = f"/proc/{pid}/task/{task}"
                comm = open(f"{base}/comm").read().strip()
                state = open(f"{base}/stat").read().rsplit(")", 1)[1].split()[0]
                wchan = open(f"{base}/wchan").read().strip()
                out.append((comm, state, wchan))
            except OSError:
                pass
    except OSError:
        pass
    return out


def one_stop(binary, delay, slow_ms, scratch):
    home = tempfile.mkdtemp(prefix="home-", dir=scratch)
    env = {"HOME": home, "PATH": "/usr/bin:/bin", "TERM": "xterm-256color", "SHELL": "/bin/bash",
           "XDG_RUNTIME_DIR": home, "TMPDIR": home}
    proc = subprocess.Popen(
        [binary, "server", "start", "--session", "cloud", "--remote-ws", "127.0.0.1:0",
         "--remote-ws-insecure-bind", "--remote-ws-trusted-carrier"],
        env=env, cwd=home, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT, start_new_session=True)
    reader = threading.Thread(target=lambda: proc.stdout.read(), daemon=True)
    reader.start()
    time.sleep(delay)
    sent = time.monotonic()
    proc.send_signal(signal.SIGTERM)
    blocked = []
    while proc.poll() is None and time.monotonic() - sent < 10:
        time.sleep(0.05)
        at = round((time.monotonic() - sent) * 1000)
        for comm, state, wchan in threads(proc.pid):
            if state == "D" or wchan.startswith(("jbd2", "file_write_wait", "folio_wait")):
                blocked.append(f"+{at}ms {comm}:{state}:{wchan}")
    if proc.poll() is None:
        proc.kill()
        proc.wait()
    ms = round((time.monotonic() - sent) * 1000)
    reader.join(1)
    shutil.rmtree(home, ignore_errors=True)
    return ms, (blocked if ms > slow_ms else [])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--bin", required=True)
    parser.add_argument("--runs", type=int, default=8)
    parser.add_argument("--delay", type=float, default=2.0)
    parser.add_argument("--io-load", type=int, default=0)
    parser.add_argument("--slow-ms", type=int, default=400)
    args = parser.parse_args()
    scratch = tempfile.mkdtemp(prefix="tui-sigterm-exit-")
    writers = []
    try:
        for index in range(args.io_load):
            target = os.path.join(scratch, f"load{index}")
            writers.append(subprocess.Popen(
                ["sh", "-c", f"while :; do dd if=/dev/zero of={target} bs=1M count=64 conv=fsync status=none; done"],
                start_new_session=True))
        times = []
        for run in range(args.runs):
            ms, blocked = one_stop(args.bin, args.delay, args.slow_ms, scratch)
            times.append(ms)
            print(f"run {run + 1}: SIGTERM->exit {ms} ms")
            for line in blocked[:12]:
                print(f"    {line}")
        times.sort()
        p95 = times[min(len(times) - 1, round(0.95 * (len(times) - 1)))]
        print(f"io-load {args.io_load}: median {statistics.median(times):.0f} ms, p95 {p95} ms, "
              f"max {times[-1]} ms over {len(times)} runs")
    finally:
        for writer in writers:
            os.killpg(writer.pid, signal.SIGTERM)
            writer.wait()
        shutil.rmtree(scratch, ignore_errors=True)


if __name__ == "__main__":
    main()
