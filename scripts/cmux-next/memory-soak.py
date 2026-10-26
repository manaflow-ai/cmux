#!/usr/bin/env python3
"""memory-soak: 2 h of STRESS churn, footprint slopes per process kind, growing heap classes (p07-memory 015).

Builds the STRESS session (perf-stress-session.py) in a tagged Debug app, then churns it for --minutes:
each cycle opens and closes a tab of each engine (terminal, Chromium, WebKit, agent chat) in the measured
workspace, opens a workspace with a Chromium page and two splits and closes a split and then the
workspace, hibernates a background Chromium page and wakes it by showing it, and switches through
background workspaces back to the measured one. Every --sample-minutes it returns to the rest state
and samples the physical footprint of every process it owns, summed per process kind (bench_memory.py's
kinds).

Steady state. The timed lifecycle would change the session under the measurement (hidden pages hibernate
after 30 min at the default `browser.hibernation`, hidden workspaces park after 15 min when parking is
on), so the run sets `browser.hibernation` to `off` for its length (restored at the end; the churn still
hibernates pages by hand) and churns --warmup-minutes (default 20, past the 15 min park timer and the
first-use caches) before the start sample and the start heap. Each sample records the hibernated pages
(debug.surfaces) and the workspace states (debug.memory) so a reader sees that the rest states match.

Rest state. After the build the run records the workspaces and the tabs of each pane. Before each sample
it closes every workspace, pane and tab not in that record (a step that failed part-way, a tab that opened
late), counts them as `leftover`, and checks the shape again. A sample whose shape still differs is
printed with rest=off and a MEMORY-SOAK-ERROR line, and is left out of the slopes.

At the end it prints, per kind and per DC12 group (app, daemon, acpmux, renderers), the least-squares
footprint slope in MB per hour over the rest samples, and from `heap -s` of the app at the start and at
the end (both at rest) the growing classes: the table is the top --heap-top by bytes and the top
--heap-top by instances, and every class that grows > 1,000 instances or > 1 MB per hour is one MQ-LEAK
line (p07-memory.md section 6): one fix task with a weak-reference regression test.

The same design as Chrome's leak detection on long sessions: Chromium's memory_instrumentation samples
private footprint per process type on a timer (components/services/heap_profiling,
services/resource_coordinator/memory_instrumentation/queued_request_dispatcher.cc), and leak triage reads
the allocation growth by type between two dumps of a steady state, never one dump.

Output lines (stdout):
  MEMORY-SOAK-SAMPLE  t_min=... label=... rest=ok|off leftover=N total_mb=... workspaces=... tabs=...
                      hibernated=N ws_states=<state:n,...> kinds=<kind:mb,...>
  MEMORY-SOAK-SLOPE   kind=<kind|group:...> mb_per_h=... start_mb=... end_mb=... samples=N r2=...
  MEMORY-SOAK-DC12    hours=... app_mb_h=... daemon_mb_h=... acpmux_mb_h=... renderer_change_pct=... mq_leak=N
                      leftover=N off_rest_samples=N (each beside its DC12 limit, for reading; nothing fails)
  MEMORY-SOAK-CLASS   rank=N process=app class=... count_delta=... bytes_delta_mb=... leak=yes|no
  MQ-LEAK             process=app class=... type=... binary=... count_per_h=... mb_per_h=...
  MQ-LEAK count: N
  MEMORY-SOAK-ERROR   what went wrong (the run still reports what it has)
JSON: --out DIR/memory-soak.json (every sample, both heap tables, the slopes, the churn counts).

Exit status is always 0 (--self-test: 1 when it fails): a measurement step reports its lines, it is
not a gate (CLAUDE.md, "Never add CI gates"). Usage:
  memory-soak.py --app "cmux DEV <tag>.app" [--minutes 120] [--warmup-minutes 20] [--sample-minutes 5]
                 [--settle 30] [--heap-top 30] [--heap-kinds app] [--vdisplay 120] [--out DIR]
  memory-soak.py --socket /tmp/cmux-debug-<tag>.sock --app-pid PID --app BUNDLE ...   (a running app)
  memory-soak.py --self-test     the slope, heap-table, growth and rest-shape logic on fixed inputs (any OS)
Fleet: cmux-ci run --class exclusive --measurement --label measure --script scripts/measure/memory-soak.sh
         --ref SHA --artifact artifacts/memory-soak.tar.gz
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
import re
import signal
import subprocess
import sys
import tempfile
import time
import traceback

HERE = os.path.dirname(os.path.abspath(__file__))
MB = 1048576.0

# MQ-LEAK threshold (p07-memory.md section 6): instances or bytes added per hour.
LEAK_COUNT_PER_H = 1000
LEAK_BYTES_PER_H = 1 * MB
# DC12 limits (p07-memory.md section 5), printed beside the numbers; nothing fails on them here.
DC12_LIMITS = {"app": 5.0, "daemon": 5.0, "acpmux": 2.0, "renderer_change_pct": 5.0}
# Heap rows that are not a class with a retain path to fix: they show as classes, never as MQ-LEAK lines.
NON_CLASSES = {"non-object"}
CHURN_ENGINES = ("terminal", "chromium", "webkit", "chat")
HEAP_TIMEOUT_S = 900
# The time-based page hibernation (BrowserHibernationSetting), off for the run so the rest states match.
HIBERNATION_SETTING = "browser.hibernation"
WEBKIT_MARK = "com.apple.WebKit."


def load(name, filename):
    """A sibling script as a module (python -I keeps the script's folder off sys.path)."""
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# Pure logic (the self-test covers it).


def slope(points):
    """Least-squares fit of [(hours, mb)]: (mb per hour, r squared), or (None, None) under 2 distinct times."""
    if len(points) < 2:
        return None, None
    n = len(points)
    mean_x = sum(x for x, _ in points) / n
    mean_y = sum(y for _, y in points) / n
    sxx = sum((x - mean_x) ** 2 for x, _ in points)
    if sxx == 0:
        return None, None
    sxy = sum((x - mean_x) * (y - mean_y) for x, y in points)
    syy = sum((y - mean_y) ** 2 for _, y in points)
    k = sxy / sxx
    r2 = (sxy * sxy) / (sxx * syy) if syy else 1.0
    return k, r2


def kind_group(kind):
    """The DC12 group of a bench_memory process kind, or None."""
    if kind == "app":
        return "app"
    if kind.startswith("tui-daemon"):
        return "daemon"
    if kind.startswith("acpmux"):
        return "acpmux"
    if kind in ("cef-renderer", "webkit-webcontent"):
        return "renderers"
    return None


def series(samples):
    """{name: [(hours, mb)]} per process kind and per `group:<DC12 group>`, from the samples' kind totals.
    A kind missing from a sample counts as 0 MB there (its processes all exited)."""
    if not samples:
        return {}
    t0 = samples[0]["time"]
    kinds = sorted({k for s in samples for k in s["kinds"]})
    out = {}
    for s in samples:
        hours = (s["time"] - t0) / 3600.0
        groups = {}
        for kind in kinds:
            mb = s["kinds"].get(kind, {}).get("footprint_mb", 0.0)
            out.setdefault(kind, []).append((hours, mb))
            group = kind_group(kind)
            if group:
                groups[group] = groups.get(group, 0.0) + mb
        for group in ("app", "daemon", "acpmux", "renderers"):
            out.setdefault(f"group:{group}", []).append((hours, round(groups.get(group, 0.0), 1)))
        out.setdefault("total", []).append((hours, s.get("total_footprint_mb", 0.0)))
    return out


def slopes(samples):
    rows = []
    for name, points in series(samples).items():
        k, r2 = slope(points)
        rows.append({"kind": name, "mb_per_h": None if k is None else round(k, 2),
                     "r2": None if r2 is None else round(r2, 3), "start_mb": points[0][1], "end_mb": points[-1][1],
                     "samples": len(points)})
    rows.sort(key=lambda r: -(r["mb_per_h"] or 0))
    return rows


_SIZE = re.compile(r"^(\d+(?:\.\d+)?)([KMG]?)B?$", re.I)


def size_bytes(token):
    """`heap` byte columns: a plain integer, or a size with a K/M/G suffix (newer heap prints 1.5M)."""
    match = _SIZE.match(token)
    if not match:
        return None
    return int(float(match.group(1)) * {"": 1, "K": 1024, "M": MB, "G": MB * 1024}[match.group(2).upper()])


def parse_heap(text):
    """{key: {class, type, binary, count, bytes}} from the first class table of `heap -s` (the All zones one).
    Columns: COUNT BYTES AVG CLASS_NAME TYPE BINARY; class names may hold single spaces, the columns are
    padded with two or more."""
    table, inside = {}, False
    for line in text.splitlines():
        if not inside:
            inside = "CLASS_NAME" in line and "COUNT" in line
            continue
        stripped = line.strip()
        if not stripped or set(stripped) <= {"=", " "}:
            if table and not stripped:
                break  # the end of the first table: per-zone tables (heap -z) follow
            continue
        parts = stripped.split(None, 3)
        if len(parts) < 4 or not parts[0].isdigit():
            if table:
                break
            continue
        count, size = int(parts[0]), size_bytes(parts[1])
        if size is None:
            continue
        fields = re.split(r"\s{2,}", parts[3].strip())
        name = fields[0]
        kind = fields[1] if len(fields) > 1 else ""
        binary = fields[2] if len(fields) > 2 else ""
        key = " | ".join(f for f in (name, kind, binary) if f)
        entry = table.setdefault(key, {"class": name, "type": kind, "binary": binary, "count": 0, "bytes": 0})
        entry["count"] += count
        entry["bytes"] += size
    return table


def growth(start, end, hours):
    """Every class that grew from `start` to `end`, by bytes then instances, each with its deltas, rates per
    hour and whether it crosses the MQ-LEAK threshold (judged on every class, never on a cut list)."""
    rows = []
    for key in set(start) | set(end):
        a = start.get(key, {"count": 0, "bytes": 0})
        b = end.get(key) or dict(a, count=0, bytes=0)
        meta = end.get(key) or start[key]
        dc, db = b["count"] - a["count"], b["bytes"] - a["bytes"]
        if dc <= 0 and db <= 0:
            continue
        per_h = max(hours, 1e-9)
        leak = meta["class"] not in NON_CLASSES and (dc / per_h > LEAK_COUNT_PER_H or db / per_h > LEAK_BYTES_PER_H)
        rows.append({"class": meta["class"], "type": meta["type"], "binary": meta["binary"],
                     "count_start": a["count"], "count_end": b["count"], "count_delta": dc,
                     "bytes_start": a["bytes"], "bytes_end": b["bytes"], "bytes_delta": db,
                     "count_per_h": round(dc / per_h, 1), "mb_per_h": round(db / per_h / MB, 3), "leak": leak})
    rows.sort(key=lambda r: (-r["bytes_delta"], -r["count_delta"], r["class"]))
    return rows


def class_table(rows, top):
    """The rows to print: the `top` by bytes and the `top` by instances (a small object that leaks by
    retain path adds instances, not bytes), in `rows`' order."""
    by_count = sorted(rows, key=lambda r: (-r["count_delta"], -r["bytes_delta"], r["class"]))[:top]
    keep = {id(r) for r in rows[:top]} | {id(r) for r in by_count}
    return [r for r in rows if id(r) in keep]


def token(value):
    """A value for a `key=value` line: no spaces, so a reader can split the line."""
    return re.sub(r"\s+", "_", str(value)) or "-"


def leak_lines(process, table, rows):
    """The MEMORY-SOAK-CLASS lines of `table`, then one MQ-LEAK line for every leaking class in `rows`."""
    lines = []
    for rank, row in enumerate(table, 1):
        lines.append(f"MEMORY-SOAK-CLASS rank={rank} process={process} class={token(row['class'])} "
                     f"type={token(row['type'])} count_delta={row['count_delta']} "
                     f"bytes_delta_mb={round(row['bytes_delta'] / MB, 3)} count_per_h={row['count_per_h']} "
                     f"mb_per_h={row['mb_per_h']} leak={'yes' if row['leak'] else 'no'}")
    for row in rows:
        if row["leak"]:
            lines.append(f"MQ-LEAK process={process} class={token(row['class'])} type={token(row['type'])} "
                         f"binary={token(row['binary'])} count_start={row['count_start']} count_end={row['count_end']} "
                         f"count_per_h={row['count_per_h']} mb_per_h={row['mb_per_h']}")
    return lines


def dc12_line(slope_rows, samples, leaks, leftover=0, off_rest=0):
    by = {r["kind"]: r for r in slope_rows}
    rate = {g: (by.get(f"group:{g}") or {}).get("mb_per_h") for g in ("app", "daemon", "acpmux")}
    renderers = by.get("group:renderers") or {}
    change = None
    if renderers.get("start_mb"):
        change = round(100.0 * (renderers["end_mb"] - renderers["start_mb"]) / renderers["start_mb"], 1)
    hours = round((samples[-1]["time"] - samples[0]["time"]) / 3600.0, 2) if len(samples) > 1 else 0
    return (f"MEMORY-SOAK-DC12 hours={hours} app_mb_h={rate['app']} app_limit={DC12_LIMITS['app']} "
            f"daemon_mb_h={rate['daemon']} daemon_limit={DC12_LIMITS['daemon']} "
            f"acpmux_mb_h={rate['acpmux']} acpmux_limit={DC12_LIMITS['acpmux']} "
            f"renderer_change_pct={change} renderer_limit_pct={DC12_LIMITS['renderer_change_pct']} mq_leak={leaks} "
            f"leftover={leftover} off_rest_samples={off_rest}")


def shape_of(workspaces, panes):
    """{workspace id: {pane id: frozenset(tab ids)}} of topology `workspaces`; `panes(workspace)` lists its panes."""
    return {w["id"]: {p["id"]: frozenset(t["id"] for t in p.get("tabs") or [] if t.get("id"))
                      for p in panes(w) if p.get("id")}
            for w in workspaces if w.get("id")}


def leftovers(built, now):
    """What `now` holds beyond `built`: ([workspace id], [(workspace id, pane id)], [(workspace id, pane id,
    tab id)]). The panes and tabs of a left-over workspace go with it, the tabs of a left-over pane with it."""
    workspaces = sorted(w for w in now if w not in built)
    panes = [(w, p) for w in sorted(now) if w in built for p in sorted(now[w]) if p not in built[w]]
    tabs = [(w, p, t) for w in sorted(now) if w in built for p in sorted(now[w]) if p in built[w]
            for t in sorted(now[w][p] - built[w][p])]
    return workspaces, panes, tabs


def shape_problem(built, now):
    """None when `now` has the built shape, else what differs (a built object gone, one not closed)."""
    if built == now:
        return None
    gone = sum(1 for w in built if w not in now)
    extra, panes_extra, tabs_extra = leftovers(built, now)
    tabs_gone = sum(len(tabs - now[w].get(p, frozenset())) for w in built if w in now for p, tabs in built[w].items())
    return (f"the shape differs from the built one: workspaces gone {gone} extra {len(extra)}, "
            f"panes extra {len(panes_extra)}, tabs gone {tabs_gone} extra {len(tabs_extra)}")


def entries(value):
    """The dicts of a debug.memory section, whether it is a list or a dict of dicts or lists."""
    if isinstance(value, list):
        return [v for v in value if isinstance(v, dict)]
    if isinstance(value, dict):
        out = []
        for key, item in value.items():
            if isinstance(item, dict):
                out.append(dict(item, id=item.get("id", key)))
            elif isinstance(item, list):
                out += [v for v in item if isinstance(v, dict)]
        return out
    return []


def memory_pids(memory):
    """The pids debug.memory (p07-memory 010) lists under `processes`, or an empty set."""
    if not isinstance(memory, dict):
        return set()
    return {int(p["pid"]) for p in entries(memory.get("processes")) if isinstance(p.get("pid"), (int, float))}


def workspace_states(memory):
    """{state: count} of debug.memory's `workspaces` (mounted, parked, unmounted), or {}."""
    if not isinstance(memory, dict):
        return {}
    states = {}
    for workspace in entries(memory.get("workspaces")):
        state = str(workspace.get("state") or "unknown")
        states[state] = states.get(state, 0) + 1
    return dict(sorted(states.items()))


def parse_start_times(text):
    """{pid: epoch seconds} from `ps -o pid=,lstart=` run with LC_ALL=C (`Mon Oct 26 10:00:00 2026`)."""
    out = {}
    for line in text.splitlines():
        parts = line.split()
        if len(parts) < 6 or not parts[0].isdigit():
            continue
        try:
            out[int(parts[0])] = time.mktime(time.strptime(" ".join(parts[1:6]), "%a %b %d %H:%M:%S %Y"))
        except ValueError:
            continue
    return out


def rest_samples(samples):
    """The samples taken in the built shape: the slopes and DC12 read only these."""
    return [s for s in samples if s.get("rest_ok", True)]


# The live run (macOS, a tagged Debug app).


class Soak:
    def __init__(self, opts, bm, st, rpc, app_pid, bundle, preexisting=frozenset()):
        self.opts, self.bm, self.st, self.rpc = opts, bm, st, rpc
        self.app_pid, self.bundle = app_pid, bundle
        # WebKit pids that ran before this script launched the app: never the app's.
        self.preexisting = frozenset(preexisting)
        self.stress = st.Stress(rpc, log=lambda line: print(line, flush=True))
        self.report = {"app": bundle, "app_pid": app_pid, "minutes": opts.minutes, "warmup_minutes": opts.warmup_minutes,
                       "sample_minutes": opts.sample_minutes, "settle_s": opts.settle, "samples": [], "heap": {},
                       "warmup_churn": {}, "churn": {}, "errors": []}
        self.cycle = 0
        self.phase = "warmup_churn"
        self.built = None  # shape_of() right after the build: the rest state
        self.hibernation_before = None  # (exists, value) of HIBERNATION_SETTING, restored at the end
        self.launcher_warned = False

    # Errors and counts.

    def error(self, what, exc=None):
        text = f"{what}: {exc}" if exc is not None else what
        if len(self.report["errors"]) < 200:
            self.report["errors"].append(text[:400])
        print(f"MEMORY-SOAK-ERROR {text[:400]}", flush=True)

    def count(self, op, ok):
        entry = self.report[self.phase].setdefault(op, {"ok": 0, "failed": 0})
        entry["ok" if ok else "failed"] += 1

    def step(self, op, fn):
        """Runs one churn step; a failure is counted and logged, and the soak goes on (the next rest
        closes what the step left)."""
        try:
            fn()
            self.count(op, True)
        except Exception as exc:  # noqa: BLE001 - a soak keeps going past one refused step
            self.count(op, False)
            if self.report[self.phase][op]["failed"] <= 3:
                self.error(f"{self.phase} {op}", exc)
        # The builder's refusal list would grow for 2 h; the counts above keep the record.
        del self.stress.refusals[:]

    # Topology helpers.

    def wait(self, predicate, seconds, step=0.1):
        return self.st.wait(predicate, seconds, step)

    def tab_ids(self, workspace, pane):
        return {t.get("id") for t in self.stress.tabs(workspace, pane)}

    def close_tab(self, workspace, pane, tab):
        self.stress.action("closeTab", target=f"tab:{tab}", focus=False)
        if not self.wait(lambda: tab not in self.tab_ids(workspace, pane), 15):
            raise RuntimeError(f"tab {tab} did not close")

    def close_pane(self, workspace, pane):
        self.stress.action("closePane", target=f"pane:{pane}", focus=False)
        if not self.wait(lambda: all(p.get("id") != pane for p in self.stress.panes(self.stress.workspace(workspace))), 15):
            raise RuntimeError(f"pane {pane} did not close")

    def close_workspace(self, workspace):
        self.stress.action("closeWorkspace", {"confirm": True}, target=f"workspace:{workspace}", focus=False)
        if not self.wait(lambda: self.stress.workspace(workspace) is None, 20):
            raise RuntimeError(f"workspace {workspace} did not close")

    def hibernated(self):
        reply = self.rpc("debug.surfaces")
        status = (reply.get("hibernation") or {}) if isinstance(reply, dict) else {}
        return set(status.get("hibernated") or [])

    # Churn steps.

    def churn_tabs(self):
        """A tab of each engine opened in the measured workspace's first pane, then closed."""
        measured = self.stress.measured
        pane = self.stress.panes(self.stress.workspace(measured))[0]["id"]
        self.stress.show(measured)
        for kind in CHURN_ENGINES:
            before = self.tab_ids(measured, pane)
            self.stress.add_tab(measured, pane, kind)
            self.stress.made[pane].pop()  # not a STRESS tab: the shape record stays the built one
            new = self.tab_ids(measured, pane) - before
            if not new:
                raise RuntimeError(f"{kind} tab did not open")
            for tab in new:
                self.close_tab(measured, pane, tab)

    def churn_workspace(self):
        """A workspace with a Chromium page, split right and down; the down split closed, then the workspace."""
        workspace = self.stress.new_workspace()
        if not workspace:
            raise RuntimeError("the churn workspace did not appear")
        try:
            self.stress.show(workspace)
            first = self.stress.panes(self.stress.workspace(workspace))[0]["id"]
            self.stress.add_tab(workspace, first, "chromium")
            right = self.stress.split(workspace, first, "splitRight")
            down = self.stress.split(workspace, right or first, "splitDown")
            if down:
                self.close_pane(workspace, down)
            for pane in (first, right, down):
                self.stress.made.pop(pane, None)
            if not right or not down:
                raise RuntimeError("a split made no pane")
        finally:
            self.close_workspace(workspace)

    def background_pages(self):
        """[(workspace, tab)] of the background workspaces' Chromium pages."""
        pages = []
        for workspace in getattr(self.stress, "background", [])[:self.st.CHROMIUM_WORKSPACES]:
            for pane in self.stress.panes(self.stress.workspace(workspace)):
                pages += [(workspace, t["id"]) for t in pane.get("tabs") or [] if t.get("kind") == "browser" and t.get("id")]
        return pages

    def churn_hibernate(self):
        """A background Chromium page hibernated (Hibernate Tab), then woken by showing and selecting it."""
        pages = self.background_pages()
        if not pages:
            raise RuntimeError("no background Chromium page to hibernate")
        workspace, tab = pages[self.cycle % len(pages)]
        self.stress.show(self.stress.measured)
        self.stress.action("hibernateTab", target=f"tab:{tab}", focus=False)
        if not self.wait(lambda: tab in self.hibernated(), 30, step=0.25):
            raise RuntimeError(f"tab {tab} did not hibernate")
        self.stress.show(workspace)
        self.stress.action("tab.focus", target=f"tab:{tab}")
        if not self.wait(lambda: tab not in self.hibernated(), 30, step=0.25):
            raise RuntimeError(f"tab {tab} did not wake")

    def churn_switches(self):
        """Five background workspaces shown in turn, then the measured one."""
        background = getattr(self.stress, "background", [])
        if not background:
            raise RuntimeError("no background workspace")
        for index in range(5):
            self.stress.show(background[(self.cycle * 5 + index) % len(background)])
        self.stress.show(self.stress.measured)

    # The steady state.

    def lifecycle_off(self):
        """Turns the time-based page hibernation off for the run (the churn hibernates by hand), remembering
        the value to restore."""
        got = self.rpc("settings.get", {"path": HIBERNATION_SETTING})
        if isinstance(got, dict) and not got.get("error"):
            self.hibernation_before = (bool(got.get("exists")), got.get("value"))
        reply = self.rpc("settings.set", {"path": HIBERNATION_SETTING, "value": "off"})
        ok = isinstance(reply, dict) and not reply.get("error")
        self.report["hibernation_off"] = ok
        if not ok:
            self.error(f"{HIBERNATION_SETTING}=off refused: hidden pages may hibernate on their timer mid-run", reply)

    def lifecycle_restore(self):
        if self.hibernation_before is None:
            return
        exists, value = self.hibernation_before
        if exists:
            reply = self.rpc("settings.set", {"path": HIBERNATION_SETTING, "value": value})
        else:
            reply = self.rpc("settings.unset", {"path": HIBERNATION_SETTING})
        if not isinstance(reply, dict) or reply.get("error"):
            self.error(f"{HIBERNATION_SETTING} not restored", reply)

    def churn_for(self, minutes, sample_every=None):
        """Churn cycles for `minutes`; with `sample_every` (minutes) a rest sample at that interval."""
        steps = (("tabs", self.churn_tabs), ("workspace", self.churn_workspace),
                 ("hibernate", self.churn_hibernate), ("switches", self.churn_switches))
        end = time.monotonic() + minutes * 60
        next_sample = time.monotonic() + (sample_every or 0) * 60
        while time.monotonic() < end:
            for op, fn in steps:
                self.step(op, fn)
            self.cycle += 1
            if sample_every and time.monotonic() >= next_sample:
                self.rest_and_sample(f"cycle-{self.cycle}")
                next_sample = time.monotonic() + sample_every * 60

    # The rest state.

    def shape(self):
        return shape_of(self.stress.workspaces(), self.stress.panes)

    def restore_rest(self):
        """Closes every workspace and tab that is not in the built shape. Returns (closed, problem): problem
        is None when the shape is the built one again."""
        closed = 0
        workspaces, panes, tabs = leftovers(self.built, self.shape())
        for workspace in workspaces:
            try:
                self.close_workspace(workspace)
                closed += 1
            except Exception as exc:  # noqa: BLE001 - the shape check below names what stays
                self.error("rest: a leftover workspace", exc)
        for workspace, pane in panes:
            try:
                self.close_pane(workspace, pane)
                closed += 1
            except Exception as exc:  # noqa: BLE001 - the shape check below names what stays
                self.error("rest: a leftover pane", exc)
        for workspace, pane, tab in tabs:
            try:
                self.close_tab(workspace, pane, tab)
                closed += 1
            except Exception as exc:  # noqa: BLE001 - the shape check below names what stays
                self.error("rest: a leftover tab", exc)
        return closed, shape_problem(self.built, self.shape())

    # Samples.

    def debug_memory(self):
        """debug.memory (p07-memory 010), or None from a build that does not answer it."""
        memory = self.rpc("debug.memory")
        return memory if isinstance(memory, dict) and not memory.get("error") else None

    def start_times(self, pids):
        if not pids:
            return {}
        run = subprocess.run(["ps", "-o", "pid=,lstart=", "-p", ",".join(str(p) for p in pids)],
                             capture_output=True, text=True, env=dict(os.environ, LC_ALL="C"))
        return parse_start_times(run.stdout)

    def owned(self, memory=None):
        """{pid: (kind, command)}: bench_memory's processes of the bundle, plus the app's WebKit processes.
        An app launched as a child of this script (no LaunchServices on a fleet step) is not responsible for
        its WebKit processes, its launcher is; then debug.memory's `processes` names the app's own, and
        without it only a WebKit process of the launcher that started after the app (and was not running
        before this script launched it) counts."""
        found = self.bm.owned(self.app_pid, self.bundle)
        responsible = self.bm._responsible
        if responsible is None or responsible(self.app_pid) == self.app_pid:
            self.report["webkit_attribution"] = "app"
            return found
        table = self.bm.process_table()
        listed = memory_pids(memory if memory is not None else self.debug_memory())
        webkit = [(pid, cmd) for pid, _, cmd in table if pid not in found and WEBKIT_MARK in cmd]
        if any(pid in listed for pid, _ in webkit):
            self.report["webkit_attribution"] = "debug.memory"
            for pid, cmd in webkit:
                if pid in listed:
                    found[pid] = (self.bm.kind_of(cmd, self.bundle), cmd)
            return found
        owner = responsible(self.app_pid)
        candidates = [(pid, cmd) for pid, cmd in webkit if pid not in self.preexisting and responsible(pid) == owner]
        started = self.start_times([self.app_pid] + [pid for pid, _ in candidates])
        app_started = started.get(self.app_pid)
        for pid, cmd in candidates:
            if app_started is None or started.get(pid, 0) >= app_started:
                found[pid] = (self.bm.kind_of(cmd, self.bundle), cmd)
        self.report["webkit_attribution"] = "launcher"
        if not self.launcher_warned:
            self.launcher_warned = True
            self.error(f"WebKit processes counted through the launcher (pid {owner}): any WebKit process it "
                       "started after the app launched counts as the app's; launch the soak from a shell "
                       "that hosts no web views, or use a build that answers debug.memory")
        return found

    def hibernated_count(self):
        reply = self.rpc("debug.surfaces")
        if not isinstance(reply, dict) or reply.get("error"):
            return None
        return len((reply.get("hibernation") or {}).get("hibernated") or [])

    def sample(self, label, leftover=0, problem=None):
        memory = self.debug_memory()
        kinds, total = {}, 0.0
        for pid, (kind, _cmd) in self.owned(memory).items():
            got = self.bm.usage(pid)
            if got is None:
                continue
            mb = got[1] / MB
            entry = kinds.setdefault(kind, {"count": 0, "footprint_mb": 0.0})
            entry["count"] += 1
            entry["footprint_mb"] = round(entry["footprint_mb"] + mb, 1)
            total += mb
        topology = self.stress.topology()
        tabs = sum(len(p.get("tabs") or []) for w in topology.get("workspaces") or [] for p in self.stress.panes(w))
        states = workspace_states(memory)
        result = {"label": label, "time": time.time(), "total_footprint_mb": round(total, 1),
                  "workspaces": len(topology.get("workspaces") or []), "tabs": tabs,
                  "rest_ok": problem is None, "rest_problem": problem, "leftover": leftover,
                  "hibernated": self.hibernated_count(), "workspace_states": states,
                  "kinds": dict(sorted(kinds.items(), key=lambda item: -item[1]["footprint_mb"]))}
        if memory is not None:
            result["debug_memory"] = memory
        self.report["samples"].append(result)
        t_min = round((result["time"] - self.report["samples"][0]["time"]) / 60.0, 1)
        kinds_text = ",".join(f"{k}:{v['footprint_mb']}" for k, v in result["kinds"].items())
        states_text = ",".join(f"{k}:{v}" for k, v in states.items()) or "-"
        print(f"MEMORY-SOAK-SAMPLE t_min={t_min} label={label} rest={'ok' if problem is None else 'off'} "
              f"leftover={leftover} total_mb={result['total_footprint_mb']} workspaces={result['workspaces']} "
              f"tabs={tabs} hibernated={result['hibernated']} ws_states={states_text} kinds={kinds_text}", flush=True)
        return result

    def rest_and_sample(self, label):
        """The rest state (nothing churned left, the measured workspace shown), settled, then a sample. A
        sample off the built shape is marked and left out of the slopes."""
        closed, problem = self.restore_rest()
        try:
            self.stress.show(self.stress.measured)
        except Exception as exc:  # noqa: BLE001 - the sample still says what the app holds
            self.error("rest: the measured workspace did not show", exc)
        if problem:
            self.error(f"rest {label}: {problem}; the sample is left out of the slopes")
        time.sleep(self.opts.settle)  # test script: the app and its helpers settle before a sample
        return self.sample(label, closed, problem)

    def heap(self, label, rest_ok=True):
        """`heap -s` of each --heap-kinds process, parsed; the raw output goes to --out."""
        snapshot = {}
        wanted = {k for k in self.opts.heap_kinds.split(",") if k}
        if not rest_ok:
            self.error(f"heap {label} taken off the built shape: its class growth includes what was not closed")
        for pid, (kind, _cmd) in sorted(self.owned().items()):
            if kind not in wanted:
                continue
            name = f"{kind}-{pid}"
            started = time.monotonic()
            try:
                run = subprocess.run(["heap", "-s", str(pid)], capture_output=True, text=True, timeout=HEAP_TIMEOUT_S)
            except (OSError, subprocess.TimeoutExpired) as exc:
                self.error(f"heap {label} {name}", exc)
                continue
            with open(os.path.join(self.opts.out, f"heap-{label}-{name}.txt"), "w") as handle:
                handle.write(run.stdout)
                handle.write(run.stderr)
            table = parse_heap(run.stdout)
            if run.returncode != 0 or not table:
                self.error(f"heap {label} {name}: exit {run.returncode}, {len(table)} classes, "
                           f"{(run.stderr or run.stdout).strip()[:200]}")
            snapshot[name] = {"kind": kind, "pid": pid, "time": time.time(), "classes": table, "rest_ok": rest_ok,
                              "seconds": round(time.monotonic() - started, 1)}
            print(f"MEMORY-SOAK-HEAP label={label} process={name} classes={len(table)} "
                  f"seconds={snapshot[name]['seconds']}", flush=True)
        self.report["heap"][label] = snapshot
        return snapshot

    def run(self):
        self.lifecycle_off()
        print("memory-soak: building STRESS", flush=True)
        summary = self.stress.build(check=False)
        self.report["stress"] = summary
        try:
            self.st.Stress.check(summary)
        except self.st.StressShapeError as exc:
            # Soaked as built: the slopes compare the session with itself.
            self.report["stress_problem"] = str(exc)[:600]
            self.error("STRESS shape", exc)
        print("STRESS-SESSION " + json.dumps(summary)[:2000], flush=True)
        self.built = self.shape()
        self.report["built_shape"] = {"workspaces": len(self.built),
                                      "tabs": sum(len(t) for panes in self.built.values() for t in panes.values())}
        # Warm-up: past the 15 min park timer and the first-use caches, so start and end are one steady state.
        print(f"memory-soak: warming up {self.opts.warmup_minutes} min", flush=True)
        self.churn_for(self.opts.warmup_minutes)
        self.phase, self.cycle = "churn", 0
        start = self.rest_and_sample("start")
        self.heap("start", start["rest_ok"])
        self.churn_for(self.opts.minutes, self.opts.sample_minutes)
        self.report["cycles"] = self.cycle
        end = self.rest_and_sample("end")
        self.heap("end", end["rest_ok"])

def report_lines(report, heap_top):
    """Every summary line of a report (the slopes, DC12, classes, MQ-LEAK), from its samples and heaps."""
    lines = []
    all_samples = report.get("samples") or []
    samples = rest_samples(all_samples)
    leftover = sum(s.get("leftover") or 0 for s in all_samples)
    off_rest = len(all_samples) - len(samples)
    slope_rows = slopes(samples)
    report["slopes"] = slope_rows
    for row in slope_rows:
        lines.append(f"MEMORY-SOAK-SLOPE kind={row['kind']} mb_per_h={row['mb_per_h']} start_mb={row['start_mb']} "
                     f"end_mb={row['end_mb']} samples={row['samples']} r2={row['r2']}")
    start, end = (report.get("heap") or {}).get("start") or {}, (report.get("heap") or {}).get("end") or {}
    leaks, classes = 0, {}
    for name, first in start.items():
        # A process is matched by kind: the app keeps its pid; a respawned helper is the same kind.
        last = end.get(name) or next((v for v in end.values() if v["kind"] == first["kind"]), None)
        if not last:
            lines.append(f"MEMORY-SOAK-CLASS process={name} none: no end heap")
            continue
        hours = (last["time"] - first["time"]) / 3600.0
        rows = growth(first["classes"], last["classes"], hours)
        table = class_table(rows, heap_top)
        leaking = [r for r in rows if r["leak"]]
        classes[name] = table + [r for r in leaking if r not in table]
        leaks += len(leaking)
        lines += leak_lines(first["kind"], table, leaking)
    if not start:
        lines.append("MEMORY-SOAK-CLASS none: no start heap")
    report["classes"] = classes
    report["mq_leak"] = leaks
    lines.append(f"MQ-LEAK count: {leaks}")
    if samples:
        lines.append(dc12_line(slope_rows, samples, leaks, leftover, off_rest))
    elif all_samples:
        lines.append(f"MEMORY-SOAK-ERROR no sample in the built shape ({off_rest} off it): no slopes")
    return lines


def finish(report, opts):
    for line in report_lines(report, opts.heap_top):
        print(line, flush=True)
    if opts.out:
        path = os.path.join(opts.out, "memory-soak.json")
        with open(path, "w") as handle:
            json.dump(report, handle, indent=1, default=str)
        print(f"memory-soak: wrote {path}", flush=True)


def self_test():
    """The pure logic on fixed inputs: slopes, the heap table, growth, the lines."""
    k, r2 = slope([(0, 100), (1, 105), (2, 110)])
    assert abs(k - 5) < 1e-9 and abs(r2 - 1) < 1e-9, (k, r2)
    assert slope([(0, 1)]) == (None, None) and slope([(1, 1), (1, 2)]) == (None, None)
    assert size_bytes("1024") == 1024 and size_bytes("1.5K") == 1536 and size_bytes("2M") == 2 * MB and size_bytes("x") is None
    text_a = """Process:         cmux DEV [123]

All zones: 1000 nodes (100000 bytes)

   COUNT     BYTES       AVG   CLASS_NAME                                        TYPE    BINARY
   =====     =====       ===   ==========                                        ====    ======
     500     50000     100.0   non-object
     100      6400      64.0   CmuxNextApp.PaneController                        Swift   cmux DEV
      40      2560      64.0   Swift closure context                             Swift   libswiftCore.dylib
      10       640      64.0   CFString                                          ObjC    CoreFoundation

Zone DefaultMallocZone_0x100: 900 nodes
   COUNT     BYTES       AVG   CLASS_NAME                                        TYPE    BINARY
     999       999       1.0   CmuxNextApp.PaneController                        Swift   cmux DEV
"""
    text_b = text_a.replace("     500     50000", "    9000   3000000").replace(
        "     100      6400      64.0   CmuxNextApp.PaneController", "    3200    204800      64.0   CmuxNextApp.PaneController").replace(
        "      10       640", "       5       320")
    a, b = parse_heap(text_a), parse_heap(text_b)
    pane = "CmuxNextApp.PaneController | Swift | cmux DEV"
    assert set(a) == {"non-object", pane, "Swift closure context | Swift | libswiftCore.dylib", "CFString | ObjC | CoreFoundation"}, a
    assert a[pane]["count"] == 100 and b[pane]["count"] == 3200, (a[pane], b[pane])  # the zone table is not added
    rows = growth(a, b, 2.0)
    assert [r["class"] for r in rows] == ["non-object", "CmuxNextApp.PaneController"], rows  # CFString shrank
    assert rows[0]["leak"] is False  # not a class: never an MQ-LEAK line
    assert rows[1]["leak"] is True and rows[1]["count_per_h"] == 1550.0, rows[1]
    # The table is the top N by bytes plus the top N by instances.
    assert class_table(rows, 1) == rows[:1] and class_table(rows, 2) == rows

    # A small class that leaks by instances, outside the top N by bytes: still an MQ-LEAK line and counted.
    big = {f"Cache{i} | Swift | cmux DEV": {"class": f"Cache{i}", "type": "Swift", "binary": "cmux DEV",
                                             "count": 10, "bytes": 1000} for i in range(40)}
    small = {"CmuxNextApp.Strip | Swift | cmux DEV": {"class": "CmuxNextApp.Strip", "type": "Swift",
                                                      "binary": "cmux DEV", "count": 100, "bytes": 4800}}
    first = dict(big, **small)
    last = {k: dict(v, bytes=v["bytes"] + 300 * 1024) for k, v in big.items()}
    last.update({k: dict(v, count=v["count"] + 3000, bytes=v["bytes"] + 144000) for k, v in small.items()})
    grown = growth(first, last, 2.0)
    assert grown[-1]["class"] == "CmuxNextApp.Strip" and grown[-1]["leak"] is True, grown[-1]
    assert sum(1 for r in grown[:30] if r["class"] == "CmuxNextApp.Strip") == 0  # outside the top 30 by bytes
    soaked = report_lines({"samples": [], "heap": {
        "start": {"app-1": {"kind": "app", "pid": 1, "time": 0, "classes": first}},
        "end": {"app-1": {"kind": "app", "pid": 1, "time": 7200, "classes": last}}}}, 30)
    assert any(l.startswith("MQ-LEAK process=app class=CmuxNextApp.Strip ") for l in soaked), soaked
    assert any(l.startswith("MEMORY-SOAK-CLASS ") and "class=CmuxNextApp.Strip " in l for l in soaked), soaked
    assert "MQ-LEAK count: 1" in soaked, soaked  # the caches grow 150 KB per hour each: below the limit

    samples = [{"label": "start", "time": 0, "total_footprint_mb": 300.0, "rest_ok": True, "leftover": 0,
                "kinds": {"app": {"footprint_mb": 200.0}, "tui-daemon": {"footprint_mb": 50.0},
                          "cef-renderer": {"footprint_mb": 50.0}}},
               # Off the built shape (a tab not closed): reported, left out of the slopes.
               {"label": "cycle-3", "time": 3600, "total_footprint_mb": 900.0, "rest_ok": False, "leftover": 2,
                "kinds": {"app": {"footprint_mb": 800.0}}},
               {"label": "end", "time": 7200, "total_footprint_mb": 320.0, "rest_ok": True, "leftover": 1,
                "kinds": {"app": {"footprint_mb": 216.0}, "tui-daemon": {"footprint_mb": 52.0},
                          "acpmux-daemon": {"footprint_mb": 2.0}, "cef-renderer": {"footprint_mb": 50.0}}}]
    report = {"samples": samples, "heap": {"start": {"app-1": {"kind": "app", "pid": 1, "time": 0, "classes": a}},
                                           "end": {"app-1": {"kind": "app", "pid": 1, "time": 7200, "classes": b}}}}
    lines = report_lines(report, 30)
    by = {r["kind"]: r["mb_per_h"] for r in report["slopes"]}
    assert by["app"] == 8.0 and by["group:daemon"] == 1.0 and by["group:acpmux"] == 1.0 and by["group:renderers"] == 0.0, by
    assert "MQ-LEAK count: 1" in lines, lines
    assert any(l.startswith("MQ-LEAK process=app class=CmuxNextApp.PaneController ") for l in lines), lines
    assert sum(1 for l in lines if l.startswith("MEMORY-SOAK-CLASS rank=")) == 2, lines
    dc12 = next(l for l in lines if l.startswith("MEMORY-SOAK-DC12"))
    assert "app_mb_h=8.0" in dc12 and "renderer_change_pct=0.0" in dc12 and "mq_leak=1" in dc12, dc12
    assert "leftover=3" in dc12 and "off_rest_samples=1" in dc12, dc12
    empty = {"samples": [], "heap": {}}
    assert report_lines(empty, 30)[-1] == "MQ-LEAK count: 0"

    # The rest shape: what the churn left is found, closed tabs of a left workspace go with it.
    def panes(workspace):
        return [p for s in workspace.get("screens") or [] for p in s.get("panes") or []]

    def ws(wid, *pane_tabs):
        return {"id": wid, "screens": [{"panes": [{"id": f"{wid}p{i}", "tabs": [{"id": t} for t in tabs]}
                                                  for i, tabs in enumerate(pane_tabs)]}]}
    built = shape_of([ws("m", ["t1", "t2"], ["t3"]), ws("b", ["t4"])], panes)
    assert shape_problem(built, built) is None and leftovers(built, built) == ([], [], [])
    now = shape_of([ws("m", ["t1", "t2", "late-chat"], ["t3"], ["split-tab"]), ws("b", ["t4"]), ws("churn", ["c1"])], panes)
    assert leftovers(built, now) == (["churn"], [("m", "mp2")], [("m", "mp0", "late-chat")]), leftovers(built, now)
    assert "extra 1, panes extra 1, tabs gone 0 extra 1" in shape_problem(built, now), shape_problem(built, now)
    gone = shape_of([ws("m", ["t1"], ["t3"])], panes)
    assert "workspaces gone 1 extra 0, panes extra 0, tabs gone 1 extra 0" in shape_problem(built, gone), shape_problem(built, gone)

    # debug.memory sections, list or keyed.
    memory = {"processes": [{"kind": "webkit-webcontent", "pid": 41}, {"kind": "app", "pid": 7.0}],
              "workspaces": {"w1": {"state": "mounted"}, "w2": {"state": "parked"}, "w3": {"state": "mounted"}}}
    assert memory_pids(memory) == {41, 7} and memory_pids(None) == set() and memory_pids({"error": "x"}) == set()
    assert workspace_states(memory) == {"mounted": 2, "parked": 1} and workspace_states(None) == {}
    stamps = parse_start_times(" 41 Mon Oct 26 10:00:00 2026\n 7 Mon Oct 26 09:59:58 2026\nbad\n")
    assert set(stamps) == {41, 7} and stamps[41] - stamps[7] == 2, stamps
    print("memory-soak: self-test ok")


def parse_args(argv):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--app", help="the tagged Debug `cmux DEV <tag>.app` (launched here unless --socket)")
    parser.add_argument("--socket", help="attach: the debug socket of a running tagged app (with --app-pid, --app)")
    parser.add_argument("--app-pid", type=int, help="attach: the running app's pid")
    parser.add_argument("--minutes", type=float, default=120, help="churn time between the start and end heaps (default 120)")
    parser.add_argument("--warmup-minutes", type=float, default=20,
                        help="churn before the start sample, past the 15 min park timer and first-use caches (default 20)")
    parser.add_argument("--sample-minutes", type=float, default=5, help="minutes between samples (default 5)")
    parser.add_argument("--settle", type=float, default=30, help="seconds at rest before each sample (default 30)")
    parser.add_argument("--heap-top", type=int, default=30, help="growing classes reported per process (default 30)")
    parser.add_argument("--heap-kinds", default="app", help="process kinds to run `heap -s` on, comma list (default app)")
    parser.add_argument("--vdisplay", type=float, default=0,
                        help="with --app: first make a 1920 x 1200 virtual main display at this refresh (Hz), as "
                             "perf-stress-session.py --vdisplay (STRESS needs a 1600 x 1000 pt window)")
    parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS") or tempfile.mkdtemp(prefix="memory-soak-"))
    parser.add_argument("--self-test", action="store_true", help="check the slope, heap, growth and rest-shape logic and exit")
    return parser.parse_args(argv)


def soak(opts, report_box):
    if sys.platform != "darwin":
        raise RuntimeError("macOS only: run it on a fleet Mac (scripts/measure/memory-soak.sh)")
    if not opts.app:
        raise RuntimeError("--app is required")
    bm = load("bench_memory", "bench_memory.py")
    st = load("perf_stress_session", "perf-stress-session.py")
    bundle = os.path.realpath(opts.app)
    app = display = None
    preexisting = frozenset()
    try:
        if opts.socket:
            if not opts.app_pid:
                raise RuntimeError("--socket needs --app-pid")
            rpc, pid = st.socket_rpc(opts.socket), opts.app_pid
        else:
            if opts.vdisplay:
                # The helper's own lifetime covers the build, the warm-up, the soak and the heaps.
                hold = (opts.warmup_minutes + opts.minutes) * 60 + 3600
                display = st.start_vdisplay(opts.vdisplay, opts.out, hold)
            preexisting = frozenset(p for p, _, cmd in bm.process_table() if WEBKIT_MARK in cmd)
            app = st.load_activation_app()(bundle, opts.out, 50)
            app.launch()
            rpc, pid = app.rpc, app.process.pid
        run = Soak(opts, bm, st, rpc, pid, bundle, preexisting)
        report_box[0] = run.report
        try:
            run.run()
        finally:
            run.lifecycle_restore()
            run.stress.close()
    finally:
        if app:
            app.stop()
        if display:
            display.terminate()  # the helper this script started, by its process


def interrupted(signum, _frame):
    raise KeyboardInterrupt(f"signal {signum}")


def main(argv):
    try:
        opts = parse_args(argv)
    except SystemExit as exc:
        # --help exits 0; a bad argument is reported, and the step still exits 0.
        if exc.code not in (0, None):
            print(f"MEMORY-SOAK-ERROR bad arguments (exit {exc.code})", flush=True)
        return 0
    if opts.self_test:
        # The developer check of the logic, not the measurement: it fails loudly.
        try:
            self_test()
        except AssertionError:
            traceback.print_exc()
            print("MEMORY-SOAK-ERROR self-test failed", flush=True)
            return 1
        return 0
    os.makedirs(opts.out, exist_ok=True)
    report_box = [{"samples": [], "heap": {}, "errors": []}]
    # A fleet cancel or timeout (SIGTERM, SIGHUP) unwinds through the cleanup and still prints the lines.
    for number in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(number, interrupted)
    try:
        soak(opts, report_box)
    except BaseException as exc:  # noqa: BLE001 - exit 0 always: report what the run has
        print(f"MEMORY-SOAK-ERROR {type(exc).__name__}: {str(exc)[:400]}", flush=True)
        traceback.print_exc()
        report_box[0].setdefault("errors", []).append(f"{type(exc).__name__}: {str(exc)[:400]}")
    try:
        finish(report_box[0], opts)
    except Exception as exc:  # noqa: BLE001 - exit 0 always
        print(f"MEMORY-SOAK-ERROR report: {exc}", flush=True)
        traceback.print_exc()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
