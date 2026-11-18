"""Experiment (lane/rtc-premain, not for merge): what the relaunched app waits on between exec and main.

Each relaunch round records the previous run's processes still alive from this bundle (Chromium helpers), and while
the new process starts: its dyld trace (DYLD_PRINT_TO_FILE: each image and initializer as dyld reaches it) with the
time each line appeared, a `sample` of it, the old processes' exits, and the security daemons' log lines.
Even rounds wait for the old processes to end before relaunching (at most 10 s), odd rounds relaunch at once.
"""
from __future__ import annotations

import json
import os
import subprocess
import threading
import time
from pathlib import Path


def bundle_processes(app: Path) -> dict[int, str]:
    """pid -> command for every process running an executable inside `app`."""
    try:
        text = subprocess.run(["ps", "-axo", "pid=,command="], capture_output=True, text=True, timeout=10).stdout
    except (OSError, subprocess.SubprocessError):
        return {}
    found = {}
    prefix = str(app.resolve())
    alt = str(app)
    for line in text.splitlines():
        pid, _, command = line.strip().partition(" ")
        if prefix in command or alt in command:
            try:
                found[int(pid)] = command.rsplit("/", 1)[-1][:60] if "--type=" not in command else \
                    command.split("--type=", 1)[1].split(" ", 1)[0]
            except ValueError:
                pass
    return found


class Probe:
    def __init__(self, n: int, app: Path, out: Path):
        self.n, self.app, self.out = n, app, out
        self.dyld = out / f"dyld-{n}.txt"
        self.row: dict = {"round": n}
        self.old: dict[int, str] = {}

    def before_launch(self, asked: float, pid_before: int) -> None:
        self.old = {p: c for p, c in bundle_processes(self.app).items() if p != pid_before}
        self.row["old_alive_at_relaunch"] = sorted(set(self.old.values()))
        self.row["old_alive_count"] = len(self.old)
        if self.n % 2 == 0 and self.old:
            start = time.monotonic()
            while time.monotonic() - start < 10 and any(_alive(p) for p in self.old):
                time.sleep(0.01)
            self.row["waited_for_old_ms"] = round((time.monotonic() - start) * 1000)
            self.row["old_still_alive_after_wait"] = sorted(c for p, c in self.old.items() if _alive(p))
        self.row["relaunch_after_quit_asked_ms"] = round((time.monotonic() - asked) * 1000)

    def env(self, env: dict) -> dict:
        try:
            self.dyld.unlink()
        except OSError:
            pass
        return {**env, "DYLD_PRINT_TO_FILE": str(self.dyld), "DYLD_PRINT_LIBRARIES": "1", "DYLD_PRINT_INITIALIZERS": "1"}

    def after_launch(self, pid: int, launched: float) -> None:
        self.pid, self.launched = pid, launched
        self.wall = time.time()
        self.thread = threading.Thread(target=self._watch, daemon=True)
        self.thread.start()
        sample = self.out / f"sample-{self.n}.txt"
        try:
            self.sampler = subprocess.Popen(["/usr/bin/sample", str(pid), "2", "5", "-mayDie", "-file", str(sample)],
                                            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        except OSError as error:
            self.sampler = None
            self.row["sample_error"] = str(error)
        self.sample_path = sample

    def _watch(self) -> None:
        trace, deaths, last_size, pending = [], {}, -1, dict(self.old)
        lines_seen = 0
        end = self.launched + 4.0
        while time.monotonic() < end:
            t = round((time.monotonic() - self.launched) * 1000)
            try:
                size = self.dyld.stat().st_size
            except OSError:
                size = -1
            if size != last_size:
                last_size = size
                try:
                    lines = [l for l in self.dyld.read_text(errors="replace").splitlines() if f"[{self.pid}]" in l or "dyld[" not in l]
                except OSError:
                    lines = []
                if len(lines) != lines_seen:
                    trace.append([t, len(lines), lines[-1][-140:] if lines else ""])
                    lines_seen = len(lines)
            for p in list(pending):
                if not _alive(p):
                    deaths[pending.pop(p) + f"#{p}"] = t
            time.sleep(0.005)
        self.trace, self.deaths = trace, deaths

    def finish(self, marks: dict) -> None:
        self.thread.join(timeout=10)
        if self.sampler is not None:
            try:
                _, err = self.sampler.communicate(timeout=30)
                if self.sampler.returncode:
                    self.row["sample_error"] = (err or b"").decode(errors="replace")[-300:]
            except subprocess.TimeoutExpired:
                self.sampler.kill()
        main = marks.get("main_start")
        self.row["main_start"] = main
        # The biggest gaps in the dyld trace: where the new process sat before main.
        gaps = []
        trace = getattr(self, "trace", [])
        for (t0, _, l0), (t1, _, l1) in zip(trace, trace[1:]):
            gaps.append((t1 - t0, t0, l0, l1))
        gaps.sort(reverse=True)
        self.row["dyld_lines"] = trace[-1][1] if trace else 0
        self.row["dyld_first_ms"] = trace[0][0] if trace else None
        self.row["dyld_top_gaps"] = [{"ms": g, "at": t0, "after": l0, "next": l1} for g, t0, l0, l1 in gaps[:4]]
        self.row["dyld_trace_head"] = trace[:3]
        self.row["dyld_trace_tail"] = trace[-3:]
        self.row["old_exit_ms_after_launch"] = getattr(self, "deaths", {})
        self.row["sample_main_thread"] = _sample_summary(self.sample_path)
        self.row["log"] = _security_log(self.wall - 0.5, self.pid)
        print("L5-PREMAIN " + json.dumps(self.row, default=str), flush=True)


def _alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def _sample_summary(path: Path) -> list[str]:
    """The heaviest frames of the sample's main thread (the first 60 call-graph lines)."""
    try:
        text = path.read_text(errors="replace")
    except OSError:
        return ["no sample file"]
    lines = text.splitlines()
    try:
        start = next(i for i, l in enumerate(lines) if l.startswith("Call graph:"))
    except StopIteration:
        return lines[:20]
    return [l[:160] for l in lines[start:start + 70]]


def _security_log(since: float, pid: int) -> list[str]:
    start = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(since))
    end = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(since + 3))
    predicate = (f'(processID == {pid} AND subsystem BEGINSWITH "com.apple.") OR process == "amfid" OR process == "syspolicyd" OR process == "trustd" '
                 'OR process == "secinitd" OR process == "XprotectService" OR (process == "kernel" AND '
                 '(sender == "AppleMobileFileIntegrity" OR sender == "Sandbox" OR eventMessage CONTAINS "cmux"))')
    try:
        text = subprocess.run(["/usr/bin/log", "show", "--style", "compact", "--start", start, "--end", end, "--predicate", predicate],
                              capture_output=True, text=True, timeout=60).stdout
    except (OSError, subprocess.SubprocessError) as error:
        return [f"log show failed: {error}"]
    return [l[:220] for l in text.splitlines()[:80]]
