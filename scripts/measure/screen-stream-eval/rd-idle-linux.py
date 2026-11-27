#!/usr/bin/env python3
"""cmux.rd/1 on a still or nearly still Linux screen: what an idle share costs, no Mac.

  rd-idle-linux.py --commit SHA [--commit SHA ...] --out DIR [--deps] [--seconds 20]
  rd-idle-linux.py --bin LABEL=PATH [--bin ...] --out DIR

For each cmux commit it builds `cmux-rd` the way rd-netem-linux.py does (release, features
`bench,openh264,link`, Cisco's OpenH264 binary), then for each workload runs on one machine, over
loopback, with no netns or root:

  Xvfb 1920x1080, `cmux-rd testapp`, `cmux-rd host --profile baseline`, and
  `cmux-rd bench --carrier udp --input none --duration-s N`

Workloads:
  idle    `testapp --workload idle`: a gray screen, nothing moves
  blink   the idle screen plus a 16x32 block that flips black and white every 500 ms (a
          blinking text cursor), drawn by this script through libX11 in its own small window
  motion  `testapp --workload motion`: the whole screen changes 60 times a second

Per commit and workload it writes one JSON line (`cmux.rd-idle-linux/1`): media kbps and decoded
fps the viewer received (video and FEC datagrams, the first GUARD_S seconds after the first frame
dropped), the frames the host encoded (its CMUX_RD_TIMING_LOG lines) and the host process's CPU
(utime + stime from /proc over the same window, percent of one core). DIR/results.md is the table;
`rd-idle-linux.py table RESULTS.jsonl` redraws it.
"""

from __future__ import annotations

import argparse
import ctypes
import ctypes.util
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

SCHEMA = "cmux.rd-idle-linux/1"
WORKLOADS = ["idle", "blink", "motion"]
PORT = 4113
GUARD_S = 2
BLINK = (16, 32, 0.5)  # width, height, seconds per phase


def _netem():
    spec = importlib.util.spec_from_file_location("rd_netem_linux", Path(__file__).with_name("rd-netem-linux.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


netem = _netem()


# ---------------------------------------------------------------- pure parsing and table


def cpu_ticks(stat_text: str) -> int:
    """utime + stime from a /proc/PID/stat line (fields 14 and 15; the comm may hold spaces)."""
    fields = stat_text.rsplit(")", 1)[1].split()
    return int(fields[11]) + int(fields[12])


def summarize(report: dict | None, guard_s: int = GUARD_S) -> dict:
    """Media kbps and decoded fps over the bench series after the first guard_s seconds."""
    rows = (report or {}).get("series") or []
    kept = rows[guard_s:]
    ms = sum(r.get("duration_ms") or 0 for r in kept)
    if not kept or ms <= 0:
        return {"ok": False, "kbps": None, "fps": None, "seconds": 0}
    total = sum(r.get("bytes") or 0 for r in kept)
    decoded = sum(r.get("decoded_frames") or 0 for r in kept)
    return {"ok": report.get("ended") is None, "kbps": round(total * 8 / ms, 2),
            "fps": round(decoded * 1000 / ms, 2), "seconds": round(ms / 1000, 2),
            "kbps_per_s": [round((r.get("bytes") or 0) * 8 / max(r.get("duration_ms") or 1, 1), 1) for r in kept]}


def frames_in(timing_text: str) -> tuple[int, int]:
    """Frames and access-unit bytes in a slice of the host's timing log."""
    frames = size = 0
    for line in timing_text.splitlines():
        try:
            row = json.loads(line)
        except ValueError:
            continue
        if not isinstance(row, dict) or "encoded_us" not in row:
            continue  # session open and input lines
        frames += 1
        size += int(row.get("encoded_bytes") or 0)
    return frames, size


def _fmt(value, digits=1):
    return "n/a" if value is None else f"{value:.{digits}f}"


def markdown_table(rows: list[dict]) -> str:
    lines = ["| commit | workload | media kbps | decoded fps | host frames/s | host CPU % |",
             "| --- | --- | ---: | ---: | ---: | ---: |"]
    for r in rows:
        if r.get("error"):
            lines.append(f"| {r['commit'][:12]} | {r['workload']} | error: {r['error'][:80]} | | | |")
            continue
        lines.append(f"| {r['commit'][:12]} | {r['workload']} | {_fmt(r.get('kbps'), 2)} | {_fmt(r.get('fps'))} "
                     f"| {_fmt(r.get('host_fps'))} | {_fmt(r.get('host_cpu_pct'), 2)} |")
    return "\n".join(lines) + "\n"


# ---------------------------------------------------------------- the blinking cursor


class Blinker:
    """A 16x32 override-redirect window at the screen's center whose block flips black and white
    every 500 ms, through libX11, until stop()."""

    def __init__(self, display: str):
        name = ctypes.util.find_library("X11") or "libX11.so.6"
        x = ctypes.CDLL(name)
        x.XOpenDisplay.restype = ctypes.c_void_p
        x.XOpenDisplay.argtypes = [ctypes.c_char_p]
        for fn in ("XDefaultRootWindow", "XCreateSimpleWindow", "XDefaultGC", "XBlackPixel", "XWhitePixel"):
            getattr(x, fn).restype = ctypes.c_ulong
        x.XDefaultRootWindow.argtypes = [ctypes.c_void_p]
        x.XDefaultGC.restype = ctypes.c_void_p
        x.XDefaultGC.argtypes = [ctypes.c_void_p, ctypes.c_int]
        x.XBlackPixel.argtypes = x.XWhitePixel.argtypes = [ctypes.c_void_p, ctypes.c_int]
        x.XCreateSimpleWindow.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int, ctypes.c_int,
                                          ctypes.c_uint, ctypes.c_uint, ctypes.c_uint, ctypes.c_ulong, ctypes.c_ulong]
        x.XMapRaised.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
        x.XSetForeground.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_ulong]
        x.XFillRectangle.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_void_p, ctypes.c_int, ctypes.c_int,
                                     ctypes.c_uint, ctypes.c_uint]
        x.XSync.argtypes = [ctypes.c_void_p, ctypes.c_int]
        x.XCloseDisplay.argtypes = [ctypes.c_void_p]
        x.XChangeWindowAttributes.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_ulong, ctypes.c_void_p]
        dpy = x.XOpenDisplay(display.encode())
        if not dpy:
            raise RuntimeError(f"XOpenDisplay({display}) failed")
        self.x, self.dpy = x, dpy
        w, h, _ = BLINK
        black, white = x.XBlackPixel(dpy, 0), x.XWhitePixel(dpy, 0)
        self.colors = (black, white)
        self.win = x.XCreateSimpleWindow(dpy, x.XDefaultRootWindow(dpy), 952, 524, w, h, 0, black, black)

        class Attrs(ctypes.Structure):  # XSetWindowAttributes, up to override_redirect
            _fields_ = [("background_pixmap", ctypes.c_ulong), ("background_pixel", ctypes.c_ulong),
                        ("border_pixmap", ctypes.c_ulong), ("border_pixel", ctypes.c_ulong),
                        ("bit_gravity", ctypes.c_int), ("win_gravity", ctypes.c_int),
                        ("backing_store", ctypes.c_int), ("backing_planes", ctypes.c_ulong),
                        ("backing_pixel", ctypes.c_ulong), ("save_under", ctypes.c_int),
                        ("event_mask", ctypes.c_long), ("do_not_propagate_mask", ctypes.c_long),
                        ("override_redirect", ctypes.c_int), ("colormap", ctypes.c_ulong),
                        ("cursor", ctypes.c_ulong)]

        attrs = Attrs(override_redirect=1)
        x.XChangeWindowAttributes(dpy, self.win, 1 << 9, ctypes.byref(attrs))  # CWOverrideRedirect
        x.XMapRaised(dpy, self.win)
        x.XSync(dpy, 0)
        self.gc = x.XDefaultGC(dpy, 0)
        self.flips = 0
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()

    def _run(self):
        w, h, period = BLINK
        while not self._stop.wait(period):
            self.flips += 1
            self.x.XSetForeground(self.dpy, self.gc, self.colors[self.flips % 2])
            self.x.XFillRectangle(self.dpy, self.win, self.gc, 0, 0, w, h)
            self.x.XSync(self.dpy, 0)

    def stop(self):
        self._stop.set()
        self._thread.join(timeout=2)
        self.x.XCloseDisplay(self.dpy)


# ---------------------------------------------------------------- measure


def spawn(argv: list[str], env: dict | None = None, token: Path | None = None, stdout=subprocess.DEVNULL,
          stderr=subprocess.DEVNULL) -> subprocess.Popen:
    # cmux-rd refuses a token fd that is a file: hand it over as a pipe on fd 3.
    inner = ["env", *(f"{k}={v}" for k, v in (env or {}).items())]
    if token is not None:
        inner += ["bash", "-c", 'exec "$@" 3< <(cat "$0")', str(token)]
    return subprocess.Popen([*inner, *argv], stdout=stdout, stderr=stderr, start_new_session=True)


def host_pid(wrapper: subprocess.Popen) -> int:
    """The cmux-rd host's pid: `env` and `bash -c exec` replace themselves, so it is the wrapper's."""
    return wrapper.pid


def measure_workload(binary: Path, commit: str, workload: str, scratch: Path, seconds: int, lib_args: list[str]) -> dict:
    row = {"schema": SCHEMA, "commit": commit, "workload": workload, "carrier": "udp", "profile": "baseline",
           "screen": "1920x1080", "guard_s": GUARD_S}
    display = f":{120 + os.getpid() % 40}"
    procs: list[subprocess.Popen] = []
    blinker = None
    try:
        procs.append(spawn(["Xvfb", display, "-screen", "0", "1920x1080x24", "-nolisten", "tcp"]))
        x_error = netem.wait_x(display, procs[-1], 20)
        if x_error:
            row["error"] = x_error
            return row
        app = "motion" if workload == "motion" else "idle"
        procs.append(spawn([str(binary), "testapp", "--display", display, "--workload", app]))
        x_error = netem.wait_x(display, procs[-1], 20, window=True)
        if x_error:
            row["error"] = x_error
            return row
        if workload == "blink":
            blinker = Blinker(display)
        token = scratch / "token"
        token.write_text(os.urandom(32).hex())
        token.chmod(0o600)
        timing, host_log = scratch / f"timing-{workload}.jsonl", scratch / f"host-{workload}.log"
        timing.write_text("")
        with open(host_log, "wb") as log:
            host = spawn([str(binary), "host", "--owner", "owner", "--bind", "127.0.0.1", "--single-tenant-overlay", "1",
                          "--display", display, "--port", str(PORT), "--profile", "baseline", "--token-fd", "3",
                          *lib_args], env={"CMUX_RD_TIMING_LOG": str(timing)}, token=token, stdout=log, stderr=log)
        procs.append(host)
        if not netem.wait_for(host_log, "listening", host, 20):
            row["error"] = "host did not listen: " + host_log.read_text(errors="replace")[-600:]
            return row
        bench = spawn([str(binary), "bench", "--addr", f"127.0.0.1:{PORT}", "--carrier", "udp", "--user", "owner",
                       "--token-fd", "3", "--input", "none", "--duration-s", str(seconds)],
                      token=token, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        stat = Path(f"/proc/{host_pid(host)}/stat")
        # Wait for the first frame (the bench prints it), then the guard, then sample.
        deadline = time.time() + 20
        while time.time() < deadline and timing.stat().st_size == 0 and bench.poll() is None:
            time.sleep(0.05)
        time.sleep(GUARD_S)  # sleep-ok: the guard: the first GUARD_S s after the first frame are left out of the sample
        t0, c0, f0 = time.monotonic(), cpu_ticks(stat.read_text()), timing.stat().st_size
        window = max(seconds - GUARD_S - 1, 1)
        time.sleep(window)  # sleep-ok: the fixed CPU and frame sampling window
        t1, c1, f1 = time.monotonic(), cpu_ticks(stat.read_text()), timing.stat().st_size
        try:
            out, err = bench.communicate(timeout=seconds + 60)
        except subprocess.TimeoutExpired:
            netem.stop(bench)
            out, err = bench.communicate()
        report = netem.last_json_line(out.decode(errors="replace"))
        row.update(summarize(report))
        frames, size = frames_in(timing.read_bytes()[f0:f1].decode(errors="replace"))
        hz = os.sysconf("SC_CLK_TCK")
        row["host_frames"] = frames
        row["host_encoded_kbps"] = round(size * 8 / (t1 - t0) / 1000, 2)
        row["host_fps"] = round(frames / (t1 - t0), 2)
        row["host_cpu_pct"] = round((c1 - c0) / hz / (t1 - t0) * 100, 2)
        row["host_window_s"] = round(t1 - t0, 2)
        if blinker:
            row["blink_flips"] = blinker.flips
        if not report:
            row["error"] = "no bench report: " + err.decode(errors="replace")[-400:]
        return row
    finally:
        if blinker:
            blinker.stop()
        for proc in reversed(procs):
            netem.stop(proc)


def measure_binary(binary: Path, commit: str, workloads: list[str], out: Path, seconds: int) -> list[dict]:
    scratch = Path(tempfile.mkdtemp(prefix=f"rd-idle-{commit[:12]}-"))
    rows = []
    try:
        try:
            lib_args = netem.openh264_lib(binary, scratch)
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
            lib_args, setup_error = None, f"openh264: {error!r}"
        for workload in workloads:
            if lib_args is None:
                row = {"schema": SCHEMA, "commit": commit, "workload": workload, "error": setup_error}
            else:
                try:
                    row = measure_workload(binary, commit, workload, scratch, seconds, lib_args)
                except Exception as error:  # noqa: BLE001 - one workload's failure is that row's data
                    row = {"schema": SCHEMA, "commit": commit, "workload": workload, "error": repr(error)}
            print(json.dumps(row), flush=True)
            with open(out / "results.jsonl", "a") as f:
                f.write(json.dumps(row) + "\n")
            rows.append(row)
    finally:
        shutil.rmtree(scratch, ignore_errors=True)
    return rows


def main(argv: list[str]) -> int:
    if argv[:1] == ["table"]:
        if len(argv) != 2:
            raise SystemExit("usage: rd-idle-linux.py table RESULTS.jsonl")
        sys.stdout.write(markdown_table(netem.read_rows(Path(argv[1]))))
        return 0
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--commit", action="append", default=[], help="full cmux commit to build and measure")
    ap.add_argument("--bin", action="append", default=[], metavar="LABEL=PATH", help="a prebuilt cmux-rd")
    ap.add_argument("--workload", action="append", choices=WORKLOADS, help="default: all")
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--repo-url", default=netem.REPO_URL)
    ap.add_argument("--seconds", type=int, default=20)
    ap.add_argument("--repeats", type=int, default=1, help="run every commit's workloads this many times")
    ap.add_argument("--deps", action="store_true", help="apt-get the build and rig packages first")
    args = ap.parse_args(argv)
    if not args.commit and not args.bin:
        ap.error("give --commit or --bin")
    for c in args.commit:
        if not re.fullmatch(r"[0-9a-f]{40}", c):
            ap.error(f"--commit {c}: a full 40-hex sha")
    workloads = args.workload or WORKLOADS
    args.out.mkdir(parents=True, exist_ok=True)
    if args.deps:
        netem.ensure_deps()
        netem.run(netem.priv(["apt-get", "install", "-y", "-qq", "--no-install-recommends", "libx11-6"]))
    work = Path(tempfile.mkdtemp(prefix="rd-idle-build-"))
    rows = []
    try:
        targets = [(label, Path(path)) for label, path in (b.split("=", 1) for b in args.bin)]
        for commit in args.commit:
            try:
                targets.append((commit, netem.build(commit, work, args.repo_url)))
            except (subprocess.CalledProcessError, SystemExit, OSError) as error:
                rows += [{"schema": SCHEMA, "commit": commit, "workload": w, "error": f"build: {error!r}"}
                         for w in workloads]
        # Repeats interleave the commits, so a noisy neighbour lands on both.
        for _ in range(max(args.repeats, 1)):
            for label, path in targets:
                rows += measure_binary(path, label, workloads, args.out, args.seconds)
    finally:
        shutil.rmtree(work, ignore_errors=True)
    table = markdown_table(rows)
    (args.out / "results.md").write_text(table)
    print(table)
    return 0 if rows and not any(r.get("error") for r in rows) else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
