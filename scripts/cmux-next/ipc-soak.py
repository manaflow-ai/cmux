#!/usr/bin/env python3
"""ipc-soak: the 30-minute STRESS soak of the app-daemon IPC (p05-ipc-192; IPC-12 and IPC-14 of
plans/cmux-next/chrome-parity/p05-ipc.md).

  python3 scripts/cmux-next/ipc-soak.py --tag TAG [--app APP] --minutes 30 --flood 10 --stress [--out DIR]
  python3 scripts/cmux-next/ipc-soak.py --self-test     # the pure logic, anywhere (Linux too)

Launches the tagged app through bench_launch.py (BenchApp), builds the STRESS session (perf-stress-session.py, its
busy terminals in the background workspaces) or with no --stress a light workspace, and starts --flood terminals of
the shown workspace writing --flood-mbps MB/s each (bench-typing.py's flooder). Then, for --warmup-minutes and
--minutes, every --churn-seconds it switches to a background workspace and back and splits a pane and closes the
split, all through the app's control socket (`action.run`, as a script does). Every --sample-seconds it samples:

  daemon     `server-stats` with `ipc`, `slow_requests` and `hangs` on the daemon's own socket (the pid `debug.daemon`
             names, found as blocking_hangs.DaemonProbe finds it), and the daemon's RSS
  app        `debug.daemon.wire` (stream_end frames read, output bytes the app copied), `debug.hangs` (main-thread
             stalls past 250 ms with their stacks), the app's RSS
  streams    each terminal stream that ended and why, from the input journal's attach records (`debug.journal`,
             `ended:overflow` or `ended:other`), with whether its terminal was visible when it ended
  crashes    the app's exit, the daemon's pid changing (a daemon restart), and crash reports of either

The report (report.json in --out, and one line per check) carries the keys of the two checks:

  IPC-12 (soak part)  crashes == 0; overflow_ends_visible == 0; |daemon_rss_change_pct| <= 5 (the end sample
                      against the first sample after the warm-up; the largest deviation is reported beside it)
  IPC-14              slow_requests == 0 (the daemon's `slow_requests.total` added during the soak);
                      main_hangs_daemon_wait == 0 (main-thread stalls of 250 ms and more whose stack is in daemon
                      connection code and that waited: CPU under half the stall)

A key that could not be read is null with its reason in `unseen`, and its check is not measured, never passed.
Exit 0 when both checks pass, 1 when one fails, 4 when one is not measured, 2 when the run itself failed.
Each series is also a cmux-perf-result/v1 file (BenchApp.record), story `ipc-soak-flood-<N>[-stress]`.

Chrome keeps the same watch over its IPC in the field: a channel ends on a malformed or overflowing peer
(mojo/core/channel.cc) and a UI thread that waits on IPC shows in its hang watcher (base/threading/hang_watcher.cc).
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import math
import os
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import traceback

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
PERF_LAB = os.path.join(ROOT, "scripts", "perf-lab")

RSS_LIMIT_PCT = 5.0  # IPC-12: daemon RSS within +-5% over the soak
HANG_MS = 250.0  # IPC-14: a main-thread stall of 250 ms or more
# Symbols of the app's daemon connection (CmuxNextDaemon, CmuxNextDaemonService): a main-thread stall whose stack
# names one waited on the daemon.
DAEMON_FRAME_MARKS = ("CmuxNextDaemon", "DaemonService", "LineTransport", "DaemonConnection")
WAIT_CPU_SHARE = 0.5  # a stall whose main-thread CPU is under this share of its length waited
DAEMON_SECTIONS = ["ipc", "slow_requests", "hangs"]
WINDOW = (40, 40, 1600, 1000)
JOURNAL_MARGIN = 256  # entries read past the new count: the journal may grow between its two reads
EXIT_PASS, EXIT_FAILED, EXIT_RUN_ERROR, EXIT_NOT_MEASURED = 0, 1, 2, 4


def load(name, path):
    """A sibling script as a module (python -I keeps the script's folder off sys.path)."""
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


# Pure logic (the self-test covers it).


def change_pct(start, end):
    """(end - start) / start in percent, rounded; None without both values or with start 0."""
    if not start or end is None:
        return None
    return round((end - start) * 100.0 / start, 2)


def max_change_pct(start, values):
    """The largest |change| of `values` against `start`, signed; None without a start or a value."""
    changes = [c for c in (change_pct(start, v) for v in values) if c is not None]
    return max(changes, key=abs) if changes else None


def classify_hang(record):
    """`daemon_wait`, `daemon_busy`, `other` or `unattributed` (no stack) for a `debug.hangs` record of HANG_MS or
    more; None for a shorter one or one that is not a main-thread stall."""
    if not isinstance(record, dict) or record.get("kind", "stall") != "stall":
        return None
    duration = record.get("duration_ms")
    if not isinstance(duration, (int, float)) or duration < HANG_MS:
        return None
    frames = [str(f) for f in record.get("frames") or []]
    if not frames:
        return "unattributed"
    if not any(mark in frame for frame in frames for mark in DAEMON_FRAME_MARKS):
        return "other"
    cpu = record.get("cpu_ms")
    return "daemon_wait" if not isinstance(cpu, (int, float)) or cpu < duration * WAIT_CPU_SHARE else "daemon_busy"


def attach_record(entry):
    """The attach record of a `debug.journal` entry (InputJournalEntry, Swift's synthesized Codable:
    {"kind": {"attach": {"_0": {...}}}}), or None for another kind."""
    kind = entry.get("kind") if isinstance(entry, dict) else None
    attach = kind.get("attach") if isinstance(kind, dict) else None
    if isinstance(attach, dict) and isinstance(attach.get("_0"), dict):
        attach = attach["_0"]
    return attach if isinstance(attach, dict) and attach.get("surface") else None


class StreamEnds:
    """Terminal stream ends from the input journal, in sequence order: by reason, and each overflow by whether its
    terminal was visible when it ended (its last `visible` or `hidden` record; with none seen, whether it shows in
    the window at the read, `fallback_visible`)."""

    def __init__(self, seen_seq=0):
        self.seen_seq = seen_seq
        self.visible = {}
        self.by_reason = {}
        self.overflow_visible = 0
        self.overflow_hidden = 0
        self.overflow_surfaces = []
        self.lost = 0

    def feed(self, entries, fallback_visible=frozenset()):
        new = sorted((e for e in entries or [] if isinstance(e, dict) and isinstance(e.get("seq"), int)
                      and e["seq"] > self.seen_seq), key=lambda e: e["seq"])
        if new and self.seen_seq and new[0]["seq"] > self.seen_seq + 1:
            self.lost += new[0]["seq"] - self.seen_seq - 1  # the ring overwrote them before this read
        for entry in new:
            self.seen_seq = entry["seq"]
            record = attach_record(entry)
            if not record:
                continue
            surface, event = record["surface"], str(record.get("event") or "")
            if event in ("visible", "hidden"):
                self.visible[surface] = event == "visible"
            elif event.startswith("ended:"):
                reason = event[len("ended:"):]
                self.by_reason[reason] = self.by_reason.get(reason, 0) + 1
                if reason == "overflow":
                    shown = self.visible.get(surface, surface in fallback_visible)
                    if shown:
                        self.overflow_visible += 1
                    else:
                        self.overflow_hidden += 1
                    self.overflow_surfaces.append({"surface": surface, "visible": shown, "seq": entry["seq"]})

    def report(self):
        return {"by_reason": dict(self.by_reason), "overflow_visible": self.overflow_visible,
                "overflow_hidden": self.overflow_hidden, "overflow_surfaces": self.overflow_surfaces[-32:],
                "journal_lost": self.lost}


def slow_total(stats):
    """`slow_requests.total` of a daemon `server-stats` data block, or None."""
    section = (stats or {}).get("slow_requests")
    total = section.get("total") if isinstance(section, dict) else None
    return total if isinstance(total, int) else None


def slow_records(start, end):
    """The `slow_requests.recent` entries `end` added over `start` (the newest `total` delta of them)."""
    a, b = slow_total(start), slow_total(end)
    if a is None or b is None or b <= a:
        return []
    recent = ((end or {}).get("slow_requests") or {}).get("recent") or []
    return recent[-(b - a):]


def ipc12(report):
    """IPC-12's soak keys and verdict: pass True, False, or None (not measured, `unseen` says why)."""
    crashes = report.get("crashes") or {}
    unseen = {}
    count = (1 if crashes.get("app_exit") is not None else 0) + crashes.get("daemon_restarts", 0) \
        + len(crashes.get("crash_reports") or [])
    ends = report.get("stream_ends") or {}
    visible = ends.get("overflow_visible") if ends.get("journal") == "read" else None
    if visible is None:
        unseen["overflow_ends_visible"] = ends.get("journal") or "the journal was not read"
    elif ends.get("journal_lost"):
        unseen["overflow_ends_visible"] = f"the journal ring overwrote {ends['journal_lost']} entries between reads"
    rss = report.get("daemon_rss") or {}
    change = rss.get("change_pct")
    if change is None:
        unseen["daemon_rss_change_pct"] = rss.get("unseen") or "no start and end sample of the daemon's RSS"
    keys = {"crashes": count, "overflow_ends_visible": visible, "daemon_rss_change_pct": change,
            "daemon_rss_max_change_pct": rss.get("max_change_pct")}
    failed = count > 0 or bool(visible) or (change is not None and abs(change) > RSS_LIMIT_PCT)
    keys["pass"] = False if failed else (None if unseen else True)
    keys["unseen"] = unseen
    return keys


def ipc14(report):
    """IPC-14's keys and verdict: pass True, False, or None (not measured, `unseen` says why)."""
    unseen = {}
    slow = report.get("slow_requests") or {}
    delta = slow.get("delta")
    if delta is None:
        unseen["slow_requests"] = slow.get("unseen") or "the daemon's server-stats had no slow_requests section"
    hangs = report.get("main_hangs") or {}
    waits = hangs.get("daemon_wait")
    if waits is None:
        unseen["main_hangs_daemon_wait"] = hangs.get("unseen") or "debug.hangs was not read"
    keys = {"slow_requests": delta, "main_hangs_daemon_wait": waits,
            "main_hangs_over_250ms": hangs.get("over_250ms"), "main_hangs_unattributed": hangs.get("unattributed")}
    failed = bool(delta) or bool(waits)
    keys["pass"] = False if failed else (None if unseen else True)
    keys["unseen"] = unseen
    return keys


def token(value):
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "true" if value else "false"
    return str(value)


def check_line(name, keys):
    words = " ".join(f"{k}={token(v)}" for k, v in keys.items() if k != "unseen")
    unseen = "; ".join(f"{k}: {v}" for k, v in (keys.get("unseen") or {}).items())
    return f"IPC-SOAK-{name} {words}" + (f" unseen=[{unseen}]" if unseen else "")


def exit_code(report):
    if report.get("run_error"):
        return EXIT_RUN_ERROR
    verdicts = [report.get(k, {}).get("pass") for k in ("ipc12", "ipc14")]
    if False in verdicts:
        return EXIT_FAILED
    return EXIT_NOT_MEASURED if None in verdicts else EXIT_PASS


def distribution(values):
    """n/p50/p95/p99/max (nearest rank) of `values`, or None."""
    v = sorted(x for x in values if x is not None)
    if not v:
        return None

    def rank(q):
        return v[max(0, min(len(v) - 1, math.ceil(q * len(v)) - 1))]
    return {"n": len(v), "p50": round(rank(0.50), 3), "p95": round(rank(0.95), 3), "p99": round(rank(0.99), 3),
            "max": round(v[-1], 3)}


# Reads of the running app and daemon.


def rss_bytes(pid):
    """The resident size of `pid` in bytes (`ps -o rss=`, KiB), or None once it is gone."""
    if not pid:
        return None
    try:
        out = subprocess.run(["ps", "-o", "rss=", "-p", str(int(pid))], capture_output=True, text=True,
                             timeout=10).stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        return None
    return int(out) * 1024 if out.isdigit() else None


class Soak:
    def __init__(self, opts, app, stress_module, typing_module, hangs_module, launch_module, rss_of=rss_bytes,
                 clock=time.monotonic, sleep=time.sleep):
        self.opts, self.app = opts, app
        self.st, self.typing, self.bh, self.bl = stress_module, typing_module, hangs_module, launch_module
        self.rss_of, self.clock, self.sleep = rss_of, clock, sleep
        self.stress = None
        self.probe = None
        self.daemon_pid = None
        self.workspace = None
        self.churn_pane = None
        self.switch_to = []
        self.flooders = []
        self.ends = None
        self.journal_problem = None
        self.hang_seq = 0
        self.hang_records = []
        self.cycle = 0
        self.op_ms = {"switch": [], "split": []}
        self.op_failed = {"switch": 0, "split": 0}
        self.started_wall = time.time()
        self.report = {"opts": {k: str(v) for k, v in vars(opts).items()}, "samples": [], "log": [],
                       "crashes": {"app_exit": None, "daemon_restarts": 0, "daemon_pids": [], "crash_reports": []}}

    def note(self, text):
        print(text, flush=True)
        self.report["log"].append(text)

    def rpc(self, method, params=None, timeout=60):
        return self.app.rpc(method, params, timeout=timeout)

    def app_alive(self):
        process = self.app.process
        if process is None or process.poll() is None:
            return True
        self.report["crashes"]["app_exit"] = process.returncode
        return False

    # The daemon.

    def read_daemon_pid(self):
        reply = self.rpc("debug.daemon", timeout=10)
        pid = reply.get("pid") if isinstance(reply, dict) else None
        if not isinstance(pid, (int, float)) or isinstance(pid, bool):
            return None
        pid = int(pid)
        if pid != self.daemon_pid:
            if self.daemon_pid is not None:
                self.report["crashes"]["daemon_restarts"] += 1
                self.note(f"ipc-soak: the daemon's pid changed {self.daemon_pid} -> {pid} (a daemon restart)")
            self.report["crashes"]["daemon_pids"].append(pid)
            self.daemon_pid = pid
            self.probe = self.bh.DaemonProbe(self.rpc)  # a new daemon: find its socket again
        return pid

    def daemon_stats(self):
        """The daemon's server-stats data with DAEMON_SECTIONS, or {"unseen": reason}."""
        if self.probe is None:
            return {"unseen": "debug.daemon names no daemon pid"}
        path = self.probe.locate()
        if path is None:
            return {"unseen": self.probe.reason}
        reply = self.probe.request(path, {"cmd": "server-stats", "include": DAEMON_SECTIONS})
        if not isinstance(reply, dict) or reply.get("ok") is not True:
            self.probe = self.bh.DaemonProbe(self.rpc)  # the socket may have moved; look again next time
            return {"unseen": f"server-stats failed: {json.dumps(reply)[:200]}"}
        return reply.get("data") or {}

    # The layout.

    def terminal_tab(self, workspace, pane):
        tabs = self.stress.tabs(workspace, pane)
        selected = next((t for t in tabs if t.get("kind") == "terminal" and t.get("selected")), None)
        return (selected or next((t for t in tabs if t.get("kind") == "terminal"), {})).get("id")

    def build_stress(self):
        summary = self.stress.build()
        print("STRESS-SESSION " + json.dumps(summary), flush=True)
        self.report["stress_session"] = summary
        workspace = summary.get("measured")
        panes = [p["id"] for p in self.stress.panes(self.stress.workspace(workspace))]
        if len(panes) < self.opts.flood:
            raise RuntimeError(f"STRESS's measured workspace has {len(panes)} panes, --flood {self.opts.flood}")
        self.switch_to = list(getattr(self.stress, "background", []))
        return workspace, panes[:self.opts.flood], panes[self.opts.flood] if len(panes) > self.opts.flood else panes[-1]

    def build_light(self):
        stress = self.stress
        try:
            stress.size_window()
        except self.st.StressShapeError as error:
            self.note(f"light layout: {error} (the light layout does not need the STRESS grid)")
        other = stress.new_workspace()  # the workspace the switches go to
        workspace = stress.new_workspace()
        if not workspace or not other:
            raise RuntimeError("the soak's workspaces did not appear")
        stress.show(workspace)
        churn = stress.panes(stress.workspace(workspace))[0]["id"]
        flood = []
        if self.opts.flood:
            column = stress.split(workspace, churn, "splitRight")
            if not column:
                raise RuntimeError(f"no flood column ({stress.refusals[-1:]})")
            flood, share = [column], {column: 1.0}
            while len(flood) < self.opts.flood:
                tallest = max(flood, key=share.get)  # halves, then quarters
                new = stress.split(workspace, tallest, "splitDown")
                if not new:
                    raise RuntimeError(f"flood pane {len(flood) + 1} refused ({stress.refusals[-1:]})")
                share[tallest] /= 2
                share[new] = share[tallest]
                flood.insert(flood.index(tallest) + 1, new)
            stress.equalize(column)
        self.switch_to = [other]
        return workspace, flood, churn

    def visible_surfaces(self):
        """The surfaces of the selected tabs in every workspace a window shows."""
        topology = self.stress.topology()
        shown = {w.get("workspace") for w in topology.get("windows") or []}
        return frozenset(t.get("surface") for w in topology.get("workspaces") or [] if w.get("id") in shown
                         for p in self.stress.panes(w) for t in p.get("tabs") or [] if t.get("selected") and t.get("surface"))

    # Floods.

    def start_floods(self, panes):
        flooder = os.path.join(self.opts.out, "flooder.py")
        with open(flooder, "w") as handle:
            handle.write(self.typing.FLOODER)
        for index, pane in enumerate(panes):
            tab = self.terminal_tab(self.workspace, pane)
            if not tab:
                raise RuntimeError(f"flood pane {pane} has no terminal")
            stats = os.path.join(self.opts.out, f"flood-{index}.json")
            command = " ".join(shlex.quote(p) for p in (sys.executable, "-I", flooder, str(self.opts.flood_mbps), stats))
            self.stress.send(tab, command + "\r")
            self.flooders.append((tab, stats))
        self.note(f"ipc-soak: {len(self.flooders)} floods at {self.opts.flood_mbps} MB/s each")

    def stop_floods(self):
        for tab, _ in self.flooders:
            self.stress.send(tab, "\x03")  # Ctrl-C: the flooder writes its achieved rate
        if self.flooders:
            self.sleep(1.0)  # bench: the flooders' last stats land
        self.report["flood_mbps"] = [self.typing.flood_rate(stats) for _, stats in self.flooders]

    # The churn.

    def timed(self, op, fn):
        start = self.clock()
        try:
            fn()
            self.op_ms[op].append((self.clock() - start) * 1000)
        except Exception as error:  # noqa: BLE001 - a failed step is counted; the soak goes on
            self.op_failed[op] += 1
            if self.op_failed[op] <= 10:
                self.note(f"ipc-soak: {op} failed: {type(error).__name__}: {str(error)[:200]}")

    def switch(self):
        target = self.switch_to[self.cycle % len(self.switch_to)]
        self.stress.show(target)
        self.stress.show(self.workspace)

    def split(self):
        verb = "splitDown" if self.cycle % 2 == 0 else "splitRight"
        new = self.stress.split(self.workspace, self.churn_pane, verb)
        if not new:
            raise RuntimeError(f"{verb} refused ({self.stress.refusals[-1:]})")
        self.stress.made.pop(new, None)
        self.stress.action("closePane", target=f"pane:{new}", focus=False)
        if not self.st.wait(lambda: all(p.get("id") != new for p in self.stress.panes(self.stress.workspace(self.workspace))), 15):
            raise RuntimeError(f"pane {new} did not close")

    def churn_once(self):
        if self.switch_to:
            self.timed("switch", self.switch)
        self.timed("split", self.split)
        self.cycle += 1

    def churn_for(self, seconds, label):
        """Churns for `seconds`, sampling every --sample-seconds (label `label-<n>`); False once the app is gone."""
        end = self.clock() + seconds
        next_sample = self.clock() + self.opts.sample_seconds
        index = 0
        while self.clock() < end:
            if not self.app_alive():
                return False
            began = self.clock()
            self.churn_once()
            if self.clock() >= next_sample:
                index += 1
                self.sample(f"{label}-{index}")
                next_sample = self.clock() + self.opts.sample_seconds
            rest = self.opts.churn_seconds - (self.clock() - began)
            if rest > 0:
                self.sleep(min(rest, max(0.0, end - self.clock())))  # bench: the churn's pace
        return self.app_alive()

    # Samples.

    def read_journal(self):
        if self.ends is None:
            return
        head = self.rpc("debug.journal", {"last": 0}, timeout=20)
        stats = head.get("stats") if isinstance(head, dict) else None
        if not isinstance(stats, dict) or not stats.get("enabled"):
            self.journal_problem = f"the input journal is off or unread ({json.dumps(head)[:160]})"
            return
        last = stats.get("lastSeq")
        if not isinstance(last, int) or last <= self.ends.seen_seq:
            return
        want = min(last - self.ends.seen_seq + JOURNAL_MARGIN, int(stats.get("capacity") or 4096))
        reply = self.rpc("debug.journal", {"last": want}, timeout=30)
        entries = reply.get("entries") if isinstance(reply, dict) else None
        if not isinstance(entries, list):
            self.journal_problem = f"debug.journal gave no entries ({json.dumps(reply)[:160]})"
            return
        self.ends.feed(entries, self.visible_surfaces())

    def read_hangs(self):
        reply = self.rpc("debug.hangs", {"after": self.hang_seq}, timeout=30)
        if not isinstance(reply, dict) or "records" not in reply:
            return {"unseen": f"debug.hangs: {json.dumps(reply)[:160]}"}
        for record in reply.get("records") or []:
            seq = record.get("sequence") if isinstance(record, dict) else None
            if isinstance(seq, int) and seq > self.hang_seq:
                self.hang_seq = seq
                if classify_hang(record):
                    self.hang_records.append(record)
        return reply

    def sample(self, label):
        pid = self.read_daemon_pid()
        stats = self.daemon_stats()
        hangs = self.read_hangs()
        wire = self.rpc("debug.daemon.wire", timeout=20)
        self.read_journal()
        ipc = stats.get("ipc") or {}
        writes = ipc.get("writes") or {}
        frames = (wire or {}).get("frames_read") if isinstance(wire, dict) else None
        entry = {
            "label": label, "t_s": round(self.clock() - self.t0, 1), "app_pid": self.app.process.pid,
            "daemon_pid": pid, "app_rss": self.rss_of(self.app.process.pid), "daemon_rss": self.rss_of(pid),
            "daemon": stats.get("unseen") or {
                "streams_open": (ipc.get("streams") or {}).get("open"), "bad_message": ipc.get("bad_message"),
                "write_stalls": writes.get("stalls"), "messages_written": writes.get("messages"),
                "slow_requests_total": slow_total(stats),
                "hangs_over_250ms": (stats.get("hangs") or {}).get("over_250ms")},
            "app_hangs": hangs.get("unseen") or {k: hangs.get(k) for k in ("count", "count250", "max_ms")},
            "wire": {"stream_end_frames": (frames or {}).get("stream_end"),
                     "output_bytes_copied_app": (wire or {}).get("output_bytes_copied_app")} if isinstance(wire, dict) else None,
            "stream_ends": dict(self.ends.by_reason) if self.ends else None,
        }
        self.report["samples"].append(entry)
        self.note(f"IPC-SOAK-SAMPLE {json.dumps(entry, default=str)}")
        return stats

    # The run.

    def run(self):
        self.app.launch()  # LaunchError (a SystemExit) with the reason
        self.t0 = self.clock()
        self.report.update(tag=self.app.tag, app=self.app.app, pid=self.app.process.pid,
                           host=self.typing.bench_tagged.host_block())
        self.stress = self.st.Stress(self.rpc, log=self.note, busy_where="elsewhere")
        try:
            self.workspace, flood, self.churn_pane = self.build_stress() if self.opts.stress else self.build_light()
            self.report["layout"] = {"workspace": self.workspace, "flood_panes": flood, "churn_pane": self.churn_pane,
                                     "switch_to": len(self.switch_to), "session": "stress" if self.opts.stress else "light"}
            self.stress.show(self.workspace)
            self.read_daemon_pid()
            head = self.rpc("debug.journal", {"last": 0}, timeout=20)
            stats = head.get("stats") if isinstance(head, dict) else None
            if isinstance(stats, dict) and stats.get("enabled") and isinstance(stats.get("lastSeq"), int):
                self.ends = StreamEnds(stats["lastSeq"])
            else:
                self.journal_problem = f"the input journal is off ({json.dumps(head)[:160]}): launch a Debug or tagged build"
            self.rpc("debug.hangs", {"clear": True}, timeout=20)
            self.start_floods(flood)
            alive = self.churn_for(self.opts.warmup_minutes * 60, "warmup")
            start_stats = self.sample("start") if alive else {}
            if alive:
                alive = self.churn_for(self.opts.minutes * 60, "soak")
            end_stats = self.sample("end") if alive else {}
            self.finish_keys(start_stats, end_stats)
        finally:
            if self.app_alive():
                self.stop_floods()
            self.stress.close()

    def finish_keys(self, start_stats, end_stats):
        samples = self.report["samples"]
        start = next((s for s in samples if s["label"] == "start"), None)
        end = next((s for s in samples if s["label"] == "end"), None)
        soak = samples[samples.index(start):] if start in samples else []
        base = start.get("daemon_rss") if start else None
        same = bool(start and end) and end.get("daemon_pid") == start.get("daemon_pid")
        self.report["daemon_rss"] = {
            "start": base, "end": end.get("daemon_rss") if end else None,
            "change_pct": change_pct(base, end.get("daemon_rss")) if same else None,
            "max_change_pct": max_change_pct(base, [s["daemon_rss"] for s in soak if s.get("daemon_pid") == start.get("daemon_pid")]) if start else None,
            "unseen": None if same else ("the daemon restarted during the soak" if start and end
                                         else "the soak ended before its start and end samples")}
        a, b = slow_total(start_stats), slow_total(end_stats)
        restarted = self.report["crashes"]["daemon_restarts"] > 0
        self.report["slow_requests"] = {
            "start_total": a, "end_total": b, "delta": b - a if a is not None and b is not None and not restarted else None,
            "records": slow_records(start_stats, end_stats),
            "unseen": "the daemon restarted during the soak" if restarted else (start_stats or end_stats or {}).get("unseen")}
        kinds = [classify_hang(r) for r in self.hang_records]
        self.report["main_hangs"] = {
            "over_250ms": len(kinds), "daemon_wait": kinds.count("daemon_wait"), "daemon_busy": kinds.count("daemon_busy"),
            "other": kinds.count("other"), "unattributed": kinds.count("unattributed"),
            "records": [dict(r, cause=k) for r, k in zip(self.hang_records, kinds)][-32:]}
        ends = self.ends.report() if self.ends else {}
        ends["journal"] = "read" if self.ends and not self.journal_problem else (self.journal_problem or "unread")
        self.report["stream_ends"] = ends

    def finish(self):
        """The crash reports, the op latencies and the two checks; after the app stopped."""
        crashes = self.report["crashes"]
        if self.app.process is not None:  # no app ran: no report is this run's
            mine = [("cmux DEV", self.app.process.pid, self.app.binary)]
            mine += [("cmux-tui", pid, None) for pid in crashes["daemon_pids"]]
            crashes["crash_reports"] = sorted({path for name, pid, binary in mine
                                               for path in self.bl.crash_reports(self.started_wall, name, pid=pid, binary=binary)})
        self.report["ops"] = {op: {"ok": len(ms), "failed": self.op_failed[op], "ms": distribution(ms)}
                              for op, ms in self.op_ms.items()}
        self.report.setdefault("stream_ends", {"journal": self.journal_problem or "unread"})
        self.report["ipc12"] = ipc12(self.report)
        self.report["ipc14"] = ipc14(self.report)

    def record(self):
        story = f"ipc-soak-flood-{self.opts.flood}" + ("-stress" if self.opts.stress else "")
        soak = [s for s in self.report["samples"] if not s["label"].startswith("warmup")]
        series = {
            "daemon_rss_bytes": ([s.get("daemon_rss") for s in soak], "bytes"),
            "app_rss_bytes": ([s.get("app_rss") for s in soak], "bytes"),
            "slow_requests": ([self.report["ipc14"]["slow_requests"]], "count"),
            "main_hangs_daemon_wait": ([self.report["ipc14"]["main_hangs_daemon_wait"]], "count"),
            "overflow_ends_visible": ([self.report["ipc12"]["overflow_ends_visible"]], "count"),
            "split_ms": (self.op_ms["split"], "ms"),
            "switch_ms": (self.op_ms["switch"], "ms"),
        }
        written = {}
        for metric, (samples, unit) in series.items():
            written.update(self.typing.bench_tagged.record_series(self.app, story, {metric: samples}, unit=unit,
                                                                  log=self.note))
        self.report["results"] = written


def report_lines(report):
    lines = []
    ops = report.get("ops") or {}
    for op, row in ops.items():
        ms = row.get("ms") or {}
        lines.append(f"IPC-SOAK-OP {op} ok={row.get('ok')} failed={row.get('failed')} p50={ms.get('p50')} "
                     f"p95={ms.get('p95')} max={ms.get('max')}")
    ends = report.get("stream_ends") or {}
    lines.append(f"IPC-SOAK-STREAM-ENDS journal={ends.get('journal')} by_reason={json.dumps(ends.get('by_reason') or {})} "
                 f"overflow_visible={ends.get('overflow_visible')} overflow_hidden={ends.get('overflow_hidden')}")
    lines.append(check_line("IPC12", report.get("ipc12") or {}))
    lines.append(check_line("IPC14", report.get("ipc14") or {}))
    return lines


def self_test():
    assert change_pct(100, 104) == 4.0 and change_pct(100, 94) == -6.0
    assert change_pct(None, 1) is None and change_pct(0, 1) is None and change_pct(1, None) is None
    assert max_change_pct(100, [101, 93, 104]) == -7.0 and max_change_pct(100, []) is None

    stall = {"kind": "stall", "duration_ms": 300.0, "cpu_ms": 10.0,
             "frames": ["cmux DEV CmuxNextDaemon.LineTransport.sendAndWait + 40", "libsystem_kernel.dylib __psynch_cvwait + 8"]}
    assert classify_hang(stall) == "daemon_wait"
    assert classify_hang(dict(stall, cpu_ms=290.0)) == "daemon_busy"
    assert classify_hang(dict(stall, frames=["cmux DEV CmuxNextApp.Sidebar.layout + 4"])) == "other"
    assert classify_hang(dict(stall, frames=[])) == "unattributed"
    assert classify_hang(dict(stall, duration_ms=249.0)) is None
    assert classify_hang(dict(stall, kind="over_budget")) is None
    assert classify_hang(dict(stall, cpu_ms=None)) == "daemon_wait"

    def attach(seq, surface, event):
        return {"seq": seq, "uptimeNanos": seq, "kind": {"attach": {"_0": {"surface": surface, "event": event, "phase": "live"}}}}
    ends = StreamEnds(seen_seq=10)
    ends.feed([attach(9, "a", "ended:overflow"),  # before the baseline: not counted
               attach(11, "a", "hidden"), attach(12, "a", "ended:overflow"),
               attach(13, "b", "visible"), attach(14, "b", "ended:overflow"),
               attach(15, "c", "ended:other"),
               {"seq": 16, "kind": {"marker": {"_0": "x"}}},
               attach(17, "d", "ended:overflow")], fallback_visible=frozenset({"d"}))
    report = ends.report()
    assert report["by_reason"] == {"overflow": 3, "other": 1}, report
    assert report["overflow_visible"] == 2 and report["overflow_hidden"] == 1 and report["journal_lost"] == 0, report
    ends.feed([attach(17, "d", "ended:overflow"), attach(20, "e", "ended:other")])  # 17 again: not twice; 18-19 lost
    assert ends.report()["by_reason"] == {"overflow": 3, "other": 2} and ends.lost == 2, ends.report()
    assert attach_record({"kind": {"attach": {"surface": "s", "event": "start"}}})["surface"] == "s"
    assert attach_record({"kind": {"key": {}}}) is None and attach_record(None) is None

    start = {"slow_requests": {"total": 2, "recent": [{"method": "a"}, {"method": "b"}]}}
    end = {"slow_requests": {"total": 4, "recent": [{"method": "a"}, {"method": "b"}, {"method": "c"}, {"method": "d"}]}}
    assert slow_total(start) == 2 and slow_total({}) is None and slow_total({"unseen": "x"}) is None
    assert [r["method"] for r in slow_records(start, end)] == ["c", "d"] and slow_records(end, start) == []

    good = {"crashes": {"app_exit": None, "daemon_restarts": 0, "crash_reports": []},
            "stream_ends": {"journal": "read", "overflow_visible": 0, "journal_lost": 0},
            "daemon_rss": {"change_pct": 3.2, "max_change_pct": 4.1},
            "slow_requests": {"delta": 0}, "main_hangs": {"daemon_wait": 0, "over_250ms": 1, "unattributed": 0}}
    a, b = ipc12(good), ipc14(good)
    assert a["pass"] is True and a["crashes"] == 0 and a["overflow_ends_visible"] == 0, a
    assert b["pass"] is True and b["slow_requests"] == 0 and b["main_hangs_daemon_wait"] == 0, b
    assert exit_code(dict(good, ipc12=a, ipc14=b)) == EXIT_PASS
    bad = dict(good, daemon_rss={"change_pct": -5.5}, crashes={"app_exit": -9, "daemon_restarts": 1, "crash_reports": ["x.ips"]})
    assert ipc12(bad)["pass"] is False and ipc12(bad)["crashes"] == 3, ipc12(bad)
    assert ipc12(dict(good, stream_ends={"journal": "read", "overflow_visible": 1}))["pass"] is False
    lost = ipc12(dict(good, stream_ends={"journal": "read", "overflow_visible": 0, "journal_lost": 5}))
    assert lost["pass"] is None and "overflow_ends_visible" in lost["unseen"], lost
    off = ipc12(dict(good, stream_ends={"journal": "the input journal is off"}))
    assert off["pass"] is None and off["overflow_ends_visible"] is None, off
    # A failure wins over a key that is not measured.
    assert ipc12(dict(good, stream_ends={"journal": "off"}, daemon_rss={"change_pct": 9.0}))["pass"] is False
    assert ipc14(dict(good, slow_requests={"delta": 1}))["pass"] is False
    assert ipc14(dict(good, main_hangs={"daemon_wait": 2}))["pass"] is False
    unseen = ipc14(dict(good, slow_requests={"delta": None, "unseen": "the daemon restarted during the soak"}))
    assert unseen["pass"] is None and unseen["unseen"]["slow_requests"].startswith("the daemon restarted"), unseen
    assert exit_code(dict(good, ipc12=a, ipc14=unseen)) == EXIT_NOT_MEASURED
    assert exit_code(dict(good, ipc12=ipc12(bad), ipc14=unseen)) == EXIT_FAILED
    assert exit_code({"run_error": "x"}) == EXIT_RUN_ERROR

    line = check_line("IPC12", off)
    assert line.startswith("IPC-SOAK-IPC12 crashes=0 overflow_ends_visible=null daemon_rss_change_pct=3.2 "), line
    assert "pass=null" in line and "unseen=[overflow_ends_visible: the input journal is off]" in line, line
    lines = report_lines(dict(good, ipc12=a, ipc14=b, ops={"split": {"ok": 2, "failed": 0, "ms": distribution([3.0, 5.0])}}))
    assert lines[0] == "IPC-SOAK-OP split ok=2 failed=0 p50=3.0 p95=5.0 max=5.0", lines
    assert lines[-1].startswith("IPC-SOAK-IPC14 slow_requests=0 main_hangs_daemon_wait=0 ") and "pass=true" in lines[-1], lines
    assert distribution([]) is None and distribution([1, 2, 3, 4])["p50"] == 2, distribution([1, 2, 3, 4])
    run_test()
    print("ipc-soak: self-test ok")


def run_test():
    """Soak.run and finish against a fake app, STRESS builder and daemon: the samples, the stream ends of the
    journal, the slow requests the daemon added, the daemon-wait stall and the two checks' keys."""
    class Process:
        pid, returncode = 111, None

        def poll(self):
            return None

    class App:
        tag, app, binary, features = "t", "/x/cmux DEV t.app", "/x/cmux DEV t.app/Contents/MacOS/cmux DEV", None

        def __init__(self):
            self.process, self.journal_seq, self.calls = None, 5, []

        def launch(self):
            self.process = Process()

        def rpc(self, method, params=None, timeout=60):
            params = params or {}
            self.calls.append(method)
            if method == "debug.daemon":
                return {"pid": 222}
            if method == "debug.journal":
                if params.get("last") == 0:
                    self.journal_seq += 3
                    return {"stats": {"enabled": True, "lastSeq": self.journal_seq, "capacity": 4096}, "entries": []}
                s = self.journal_seq
                return {"entries": [
                    {"seq": s - 2, "kind": {"attach": {"_0": {"surface": "s-p1", "event": "hidden", "phase": "live"}}}},
                    {"seq": s - 1, "kind": {"attach": {"_0": {"surface": "s-p1", "event": "ended:overflow", "phase": "x"}}}},
                    {"seq": s, "kind": {"marker": {"_0": "m"}}}]}
            if method == "debug.hangs":
                return {"count": 1, "count250": 1, "max_ms": 400, "records": [
                    {"sequence": 1, "kind": "stall", "duration_ms": 400, "cpu_ms": 5,
                     "frames": ["cmux DEV CmuxNextDaemon.LineTransport.wait + 1"]}]}
            if method == "debug.daemon.wire":
                return {"frames_read": {"stream_end": 2}, "output_bytes_copied_app": 0}
            return {}

    class Stress:
        def __init__(self, rpc, log=None, busy_where=None):
            self.made, self.refusals, self.splits, self.background, self.sent = {}, [], 0, ["b1", "b2"], []

        def build(self):
            return {"measured": "m"}

        def workspace(self, workspace):
            tabs = [{"id": f"t-{p}", "kind": "terminal", "selected": True, "surface": f"s-{p}"} for p in ("p0", "p1", "p2")]
            return {"id": workspace, "screens": [{"panes": [{"id": t["id"][2:], "tabs": [t]} for t in tabs]}]}

        def topology(self):
            return {"windows": [{"workspace": "m"}], "workspaces": [self.workspace("m")]}

        @staticmethod
        def panes(workspace):
            return [p for s in (workspace or {}).get("screens") or [] for p in s.get("panes") or []]

        def tabs(self, workspace, pane):
            return next(p["tabs"] for p in self.panes(self.workspace(workspace)) if p["id"] == pane)

        def split(self, workspace, pane, verb):
            self.splits += 1
            return f"new-{self.splits}"

        def show(self, workspace):
            pass

        def action(self, *args, **kwargs):
            return {}

        def send(self, tab, text):
            self.sent.append((tab, text))

        def close(self):
            pass

    class Probe:
        reads = 0

        def __init__(self, rpc):
            self.reason = None

        def locate(self):
            return "/daemon.sock"

        def request(self, path, command):
            assert command == {"cmd": "server-stats", "include": DAEMON_SECTIONS}, command
            Probe.reads += 1
            total = Probe.reads  # one more slow request at each sample
            return {"ok": True, "data": {"ipc": {"streams": {"open": 3}, "bad_message": 0, "writes": {"stalls": 0}},
                                         "slow_requests": {"total": total, "recent": [{"method": f"m{i}"} for i in range(total)]},
                                         "hangs": {"over_250ms": 0}}}

    class Typing:
        FLOODER = "pass\n"
        bench_tagged = type("BenchTagged", (), {"host_block": staticmethod(lambda: {"host": "fake"})})

        @staticmethod
        def flood_rate(path):
            return 10.0

    class Launch:
        @staticmethod
        def crash_reports(since, name, pid=None, binary=None):
            return []

    def wait(predicate, seconds, step=0.1):
        return predicate()

    stress_module = type("StressModule", (), {"Stress": Stress, "StressShapeError": RuntimeError, "wait": staticmethod(wait)})
    hangs_module = type("HangsModule", (), {"DaemonProbe": Probe})
    ticks = iter(range(10 ** 6))
    out = tempfile.mkdtemp(prefix="ipc-soak-test-")
    opts = parse_args(["--minutes", "0.5", "--warmup-minutes", "0.5", "--flood", "2", "--stress", "--churn-seconds", "1",
                       "--sample-seconds", "10", "--out", out])
    rss = {111: 500, 222: 1000}
    soak = Soak(opts, App(), stress_module, Typing, hangs_module, Launch, rss_of=rss.get, clock=lambda: float(next(ticks)),
                sleep=lambda seconds: None)
    soak.run()
    soak.finish()
    report = soak.report
    assert report["layout"]["flood_panes"] == ["p0", "p1"] and report["layout"]["churn_pane"] == "p2", report["layout"]
    assert [t for t, text in soak.stress.sent if text.endswith("\r")] == ["t-p0", "t-p1"], soak.stress.sent
    assert [t for t, text in soak.stress.sent if text == "\x03"] == ["t-p0", "t-p1"] and report["flood_mbps"] == [10.0, 10.0]
    labels = [s["label"] for s in report["samples"]]
    assert labels[0].startswith("warmup-") and "start" in labels and labels[-1] == "end", labels
    added = len(labels) - labels.index("start") - 1  # the samples after the start sample
    slow = report["slow_requests"]
    assert report["daemon_rss"]["change_pct"] == 0.0 and added >= 2 and slow["delta"] == added, (labels, slow)
    assert [r["method"] for r in slow["records"]] == [f"m{i}" for i in range(slow["start_total"], slow["end_total"])], slow
    ends = report["stream_ends"]
    assert ends["journal"] == "read" and ends["overflow_hidden"] >= 1 and ends["overflow_visible"] == 0, ends
    assert report["main_hangs"]["daemon_wait"] == 1 and report["ops"]["split"]["failed"] == 0, report["main_hangs"]
    assert report["ipc12"]["pass"] is True and report["ipc14"]["pass"] is False, (report["ipc12"], report["ipc14"])
    assert report["ipc14"]["slow_requests"] == added and exit_code(report) == EXIT_FAILED
    shutil.rmtree(out, ignore_errors=True)


def parse_args(argv):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--tag", help="the tagged build (its bundle found as bench-typing.py finds it)")
    parser.add_argument("--app", help="the tagged Debug `cmux DEV <tag>.app` (default: --tag's, then $NX_APP)")
    parser.add_argument("--minutes", type=float, default=30, help="soak length after the warm-up (default 30)")
    parser.add_argument("--warmup-minutes", type=float, default=2, help="churn and flood before the start sample (default 2)")
    parser.add_argument("--flood", type=int, default=10, help="terminals of the shown workspace that flood (default 10)")
    parser.add_argument("--flood-mbps", type=float, default=10, help="each flood's rate in MB/s (default 10)")
    parser.add_argument("--stress", action="store_true", help="the STRESS session (perf-stress-session.py)")
    parser.add_argument("--churn-seconds", type=float, default=5, help="one switch and one split this often (default 5)")
    parser.add_argument("--sample-seconds", type=float, default=60, help="seconds between samples (default 60)")
    parser.add_argument("--out", help="artifacts folder (default $NX_ARTIFACTS, else a new temporary folder)")
    parser.add_argument("--self-test", action="store_true", help="check the pure logic and exit")
    opts = parser.parse_args(argv)
    opts.out = os.path.abspath(opts.out or os.environ.get("NX_ARTIFACTS") or tempfile.mkdtemp(prefix="ipc-soak-"))
    if opts.flood < 0 or opts.minutes <= 0 or opts.churn_seconds <= 0 or opts.sample_seconds <= 0:
        parser.error("--flood >= 0, and --minutes, --churn-seconds and --sample-seconds > 0")
    return opts


def interrupted(signum, _frame):
    raise KeyboardInterrupt(f"signal {signum}")


def main(argv):
    opts = parse_args(argv)
    if opts.self_test:
        self_test()
        return 0
    if sys.platform != "darwin":
        print("IPC-SOAK-ERROR macOS only: run it on a fleet Mac (cmux-ci run --class isolated)", flush=True)
        return EXIT_RUN_ERROR
    os.makedirs(opts.out, exist_ok=True)
    sys.path.insert(0, HERE)
    launch_module = load("bench_launch", os.path.join(HERE, "bench_launch.py"))
    typing_module = load("bench_typing", os.path.join(HERE, "bench-typing.py"))
    stress_module = load("perf_stress_session", os.path.join(HERE, "perf-stress-session.py"))
    hangs_module = load("blocking_hangs", os.path.join(PERF_LAB, "stories", "blocking_hangs.py"))
    bundle = typing_module.bench_tagged.resolve_app(opts.tag, opts.app)
    app = launch_module.BenchApp(bundle, out=opts.out, perf_session="stress" if opts.stress else "light",
                                 env={"CMUX_NEXT_HANG_THRESHOLD_MS": str(int(HANG_MS))}, window=WINDOW)
    soak = Soak(opts, app, stress_module, typing_module, hangs_module, launch_module)
    # A fleet cancel or timeout (SIGTERM, SIGHUP) unwinds through the cleanup and still writes the report.
    for number in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(number, interrupted)
    try:
        soak.run()
    except BaseException as exc:  # noqa: BLE001 - report what the run has
        soak.report["run_error"] = f"{type(exc).__name__}: {str(exc)[:400]}"
        print(f"IPC-SOAK-ERROR {soak.report['run_error']}", flush=True)
        traceback.print_exc()
    finally:
        app.stop()
    try:
        soak.finish()
        if soak.report["samples"] and app.features is not None:
            soak.record()
    except Exception as exc:  # noqa: BLE001 - the report is still written
        soak.report["run_error"] = soak.report.get("run_error") or f"report: {type(exc).__name__}: {str(exc)[:400]}"
        traceback.print_exc()
    for line in report_lines(soak.report):
        print(line, flush=True)
    path = os.path.join(opts.out, "report.json")
    with open(path, "w") as handle:
        json.dump(soak.report, handle, indent=1, default=str)
    print(f"ipc-soak: wrote {path}", flush=True)
    return exit_code(soak.report)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
