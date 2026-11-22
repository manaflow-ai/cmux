#!/usr/bin/env python3
"""One chat at 1 MB, 100 MB, 1 GB and 4 GB in one app at one head: what each size costs over the 1 MB chat, on five axes.

Leo, 2026-11-19: "we need to be able to have infinite chats, infinitely long chats, that sort of thing on, you know,
current day hardware ... say, like, for instance, like my machine ... Whatever's missing, whatever tools should be
built, you build them."

The perf cron's chat-size part (split-spring-terminal.py --suite=chat-size) and the producer of NOW's
infinite_chat_size_ratio_max. For each size, one chat of that many log bytes is written into a fresh acpmux home by the
app's own acpmux (`acpmux __seed-chat`, god_fixture::write_chat: the store's own writer, segments and indexes), the app
is launched on that home (bench_memory.launch, ACPMUX_HOME) --runs times, and each launch reads:

  open_ms          the chat opened in a new workspace (agent.openSessionWorkspace, then goToWorkspace, as
                   chat-open-bench.py's sidebar case) to its first content, by the app's own debug.chat_open_trace;
                   the size's value is the p50 over its launches
  scroll_frame_ms  the p95 frame interval of a --fling-seconds fling up through the transcript (debug.agent_pane fling,
                   then perf_stats raw: the page's requestAnimationFrame intervals, as agent-engine-bench.py); the
                   size's value is the median over its launches of each launch's p95 over its --flings flings
  key_paint_ms     keydown to paint in the chat's composer, p95 over --keys keys (debug.key, the page's typing_stats
                   to_paint, as agent-engine-bench.py); median over launches
  app_mb           phys_footprint of the app's page renderers and GPU process with the chat open and settled
                   (bench_memory.sample: cef-renderer + cef-gpu, and the WebKit web content and GPU processes when the
                   page runs in WebKit); median over launches
  daemon_mb        the acpmux daemon's phys_footprint with the chat open, less the same daemon's before the open (the
                   chat in its store, not loaded); median over launches

Every ratio is a size's value over the 1 MB chat's value on the same axis from the same run (rows
chat_size.<size>.<axis>_ratio, e.g. chat_size.gb4.daemon_mb_ratio); chat_size.ratio_max is the worst of them over
every size and axis. The denominators have a floor (RATIO_FLOOR): a 1 MB chat's daemon cost can read about 0 MB, and
a ratio over noise says nothing.

A size whose seed fails, whose open crashes the app, stalls past --open-timeout or shows no first content, or that
gives an axis no reading, has no value on that axis (all axes for a failed open), so its ratio and ratio_max are
missing: never skipped, never read as fine. report.json's `incomplete` names each missing row and why, and
chat_size.missing_readings counts them (target 0).

Runs on a fleet Mac (never a person's Mac): every process of the bundle ends after each launch (bench_memory.end_bundle;
bench_memory.launch refuses to start while any process of the bundle runs, so each one ended is this run's).
  chat-size-ratio.py --app BUNDLE --json report.json [--sizes mb1,mb100,gb1,gb4] [--runs 3]
  chat-size-ratio.py --copy-from "/Applications/cmux NIGHTLY.app" --json report.json   # a copy of the NIGHTLY
  chat-size-ratio.py --rows-from report.json --json rows.json   # rows again from a kept report (no app)
The seeded homes live under --work (default a temp folder; 4 GB needs about 4.5 GB free) and each is deleted once
its size is measured. The app must answer debug.chat_open_trace and debug.agent_pane (a tagged or bench-configuration
build; perf-cron's part builds the bench configuration).
Tests: scripts/cmux-next/test_chat_size_ratio.py (the rows, ratios and missing sizes; no app).
"""
from __future__ import annotations

import argparse
import json
import math
import os
import re
import shutil
import socket
import statistics
import subprocess
import sys
import tempfile
import time
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
PREFIX = "chat_size."
BASE = "mb1"
DEFAULT_SIZES = "mb1,mb100,gb1,gb4"
AXES = (("open_ms", "ms"), ("scroll_frame_ms", "ms"), ("key_paint_ms", "ms"), ("app_mb", "MB"), ("daemon_mb", "MB"))
AXIS_NAMES = tuple(name for name, _unit in AXES)
UNIT = dict(AXES)
# The least a 1 MB value counts as in a ratio's denominator: under it the 1 MB reading is noise (a daemon that grew
# 0.3 MB for a 1 MB chat, a key painted in 0.2 ms), and a ratio over noise reads a size as costly that is not.
RATIO_FLOOR = {"open_ms": 16.0, "scroll_frame_ms": 4.0, "key_paint_ms": 4.0, "app_mb": 50.0, "daemon_mb": 8.0}
# perf-cron's noise floor of each raw row (a change under it is never a regression).
ROW_FLOOR = {"ms": 5.0, "MB": 10.0}
RATIO_ROW_FLOOR = 0.1
# The page's processes (bench_memory.kind_of): Chromium's renderers and GPU process, WebKit's when the page runs there.
RENDER_KINDS = ("cef-renderer", "cef-gpu", "webkit-webcontent", "webkit-gpu")
# The acpmux daemon (bench_memory.kind_of): `acpmux daemon run`, or the multicall `cmux acp daemon run`.
DAEMON_KINDS = ("acpmux-daemon", "cmux-acp")
SIZE_RE = re.compile(r"^(kb|mb|gb)(\d+)$")
SHIFT = {"kb": 10, "mb": 20, "gb": 30}


# ---------------------------------------------------------------------------------------------------------------------
# The pure part: sizes, a size's values, ratios and rows (test_chat_size_ratio.py).

def size_bytes(name: str) -> int:
    """`mb100` -> 100 MiB. ValueError for a name that is not kb/mb/gb and a positive count."""
    match = SIZE_RE.match(name)
    if not match or int(match.group(2)) <= 0:
        raise ValueError(f"a size is kb<N>, mb<N> or gb<N>: {name!r}")
    return int(match.group(2)) << SHIFT[match.group(1)]


def parse_sizes(text: str) -> list[str]:
    """The asked sizes, smallest first, the 1 MB base among them."""
    names = list(dict.fromkeys(s.strip() for s in text.split(",") if s.strip()))
    for name in names:
        size_bytes(name)
    if BASE not in names:
        raise ValueError(f"the sizes must include {BASE}, every ratio's base: {text!r}")
    return sorted(names, key=size_bytes)


def number(value) -> float | None:
    return float(value) if type(value) in (int, float) and math.isfinite(value) else None


def pct(values, q: float) -> float | None:
    """Nearest-rank percentile of the finite numbers in `values`; None when there are none."""
    got = sorted(v for v in (number(x) for x in values or []) if v is not None)
    if not got:
        return None
    return got[min(len(got) - 1, max(0, math.ceil(q * len(got)) - 1))]


def stat_p95(obj) -> float | None:
    """p95 of a bench stat: a dict with p95/p95_ms, a list of samples, or a number."""
    if isinstance(obj, dict):
        return next((number(obj[k]) for k in ("p95", "p95_ms") if number(obj.get(k)) is not None), None)
    if isinstance(obj, list):
        return pct(obj, 0.95)
    return number(obj)


def fling_p95(fling: dict) -> float | None:
    """One fling's p95 frame interval: from the page's raw intervals (perf_stats raw) when it kept them, else the
    fling reply's own p95_ms. A fling that failed or never stopped has none."""
    if not isinstance(fling, dict) or fling.get("error") or fling.get("running"):
        return None
    samples = (fling.get("perf_stats") or {}).get("samples") if isinstance(fling.get("perf_stats"), dict) else None
    if isinstance(samples, list) and samples:
        got = pct([s.get("interval_ms") for s in samples if isinstance(s, dict)], 0.95)
        if got is not None:
            return got
    return number(fling.get("p95_ms"))


def kinds_mb(sample: dict, kinds) -> float | None:
    """The footprint summed over `kinds` in a bench_memory sample; None when none of them ran."""
    found = [number((entry or {}).get("footprint_mb")) for kind, entry in ((sample or {}).get("kinds") or {}).items()
             if kind in kinds and isinstance(entry, dict)]
    found = [v for v in found if v is not None]
    return round(sum(found), 1) if found else None


def run_values(run: dict) -> dict:
    """One launch's reading on each axis (None: no reading). A launch that failed (`error`) reads nothing."""
    if not isinstance(run, dict) or run.get("error"):
        return {axis: None for axis in AXIS_NAMES}
    flings = [fling_p95(f) for f in run.get("flings") or []]
    loaded, unloaded = number(run.get("daemon_loaded_mb")), number(run.get("daemon_unloaded_mb"))
    return {
        "open_ms": number(run.get("open_ms")),
        # Every fling must read: a fling that failed is no frame time, not a fast one.
        "scroll_frame_ms": pct(flings, 0.95) if flings and all(v is not None for v in flings) else None,
        "key_paint_ms": number(run.get("key_paint_ms")),
        "app_mb": number(run.get("app_mb")),
        "daemon_mb": round(loaded - unloaded, 1) if loaded is not None and unloaded is not None else None,
    }


def size_values(record: dict) -> tuple[dict, dict]:
    """A size's value on each axis over its launches, and why each missing one is missing. Every launch must read an
    axis for the size to have it: a size whose second open stalled is not measured by its first."""
    values = {axis: None for axis in AXIS_NAMES}
    why = {}
    if not isinstance(record, dict):
        return values, {axis: "not measured" for axis in AXIS_NAMES}
    runs = record.get("runs") or []
    if record.get("error") or not runs:
        reason = str(record.get("error") or "no launch ran")
        return values, {axis: reason for axis in AXIS_NAMES}
    failed = next((r.get("error") for r in runs if isinstance(r, dict) and r.get("error")), None)
    if failed:
        return values, {axis: f"a launch failed: {failed}" for axis in AXIS_NAMES}
    per = [run_values(r) for r in runs]
    for axis in AXIS_NAMES:
        got = [p[axis] for p in per]
        if any(v is None for v in got):
            why[axis] = f"no reading in {sum(v is None for v in got)} of {len(got)} launches"
            continue
        values[axis] = round(statistics.median(got), 2)
    return values, why


def ratios(values_by_size: dict, sizes: list[str]) -> dict:
    """{size: {axis: ratio or None}} over the 1 MB values (each denominator at least RATIO_FLOOR)."""
    base = values_by_size.get(BASE) or {}
    out = {}
    for size in sizes:
        mine = values_by_size.get(size) or {}
        out[size] = {}
        for axis in AXIS_NAMES:
            low, high = base.get(axis), mine.get(axis)
            out[size][axis] = (round(max(high, 0.0) / max(low, RATIO_FLOOR[axis]), 3)
                               if low is not None and high is not None else None)
    return out


def ratio_max(table: dict, sizes: list[str]) -> tuple[float | None, str | None]:
    """The worst ratio over every size and axis, and where (`gb4.daemon_mb`); (None, None) when any is missing."""
    worst, where = None, None
    for size in sizes:
        for axis in AXIS_NAMES:
            value = (table.get(size) or {}).get(axis)
            if value is None:
                return None, None
            if worst is None or value > worst:
                worst, where = value, f"{size}.{axis}"
    return worst, where


def row(name: str, value, unit: str, floor: float, **extra) -> dict:
    return {"name": PREFIX + name, "p50": value, "p95": value, "unit": unit, "floor": floor, **extra}


def rows_from(result: dict) -> tuple[list[dict], list[dict], dict]:
    """perf-cron rows (its budgets kind), the `incomplete` entries ({name, reason}) and the table, from a result's
    `sizes` ({size: {runs, error}}) and `asked` (the sizes asked, smallest first)."""
    sizes = list(result.get("asked") or [])
    records = result.get("sizes") or {}
    values, why = {}, {}
    for size in sizes:
        values[size], why[size] = size_values(records.get(size))
    table = ratios(values, sizes)
    rows, incomplete = [], []
    for size in sizes:
        for axis in AXIS_NAMES:
            value = values[size][axis]
            if value is not None:
                rows.append(row(f"{size}.{axis}", value, UNIT[axis], ROW_FLOOR[UNIT[axis]]))
            if size == BASE:
                if value is None:
                    incomplete.append({"name": PREFIX + f"{size}.{axis}", "reason": why[size].get(axis, "no reading")})
                continue
            ratio = table[size][axis]
            if ratio is not None:
                rows.append(row(f"{size}.{axis}_ratio", ratio, "x", RATIO_ROW_FLOOR))
            else:
                reason = why[size].get(axis) or (f"{BASE}: " + why[BASE].get(axis, "no reading"))
                incomplete.append({"name": PREFIX + f"{size}.{axis}_ratio", "reason": reason})
    worst, where = ratio_max(table, sizes)
    if worst is not None:
        rows.append(row("ratio_max", worst, "x", RATIO_ROW_FLOOR, worst=where))
    else:
        incomplete.append({"name": PREFIX + "ratio_max", "reason": "a size or axis has no reading"})
    # Every missing reading, counted (target 0): the row is there even when ratio_max is not.
    missing = sum(1 for item in incomplete if item["name"] != PREFIX + "ratio_max")
    rows.append(row("missing_readings", missing, "readings", 0.5, budget=0))
    return rows, incomplete, {"values": values, "ratios": table, "ratio_max": worst, "worst": where}


def open_failure(opened, trace, timeout: float) -> str | None:
    """Why an open gave no first content (None: it did): the open refused, the trace failed, it stalled past the
    timeout, or it ended with no content."""
    opened = opened if isinstance(opened, dict) else {"error": f"open reply {opened!r}"}
    trace = trace if isinstance(trace, dict) else {"error": f"trace reply {trace!r}"}
    if opened.get("error"):
        return f"open: {str(opened['error'])[:300]}"
    if trace.get("error"):
        return f"open trace: {str(trace['error'])[:300]}"
    if trace.get("timed_out"):
        return f"open: stalled, no first content within {timeout:.0f} s"
    if number(trace.get("first_content_ms")) is None:
        return "open: no first content"
    return None


def table_text(result: dict, table: dict) -> str:
    """The per-size table for the log."""
    sizes = list(result.get("asked") or [])
    lines = ["size     " + "".join(f"{axis:>22}" for axis in AXIS_NAMES)]
    for size in sizes:
        cells = []
        for axis in AXIS_NAMES:
            value, ratio = table["values"][size][axis], table["ratios"][size][axis]
            text = "missing" if value is None else f"{value} ({'-' if ratio is None else f'{ratio}x'})"
            cells.append(f"{text:>22}")
        lines.append(f"{size:<9}" + "".join(cells))
    lines.append(f"ratio_max {table['ratio_max'] if table['ratio_max'] is not None else 'MISSING'}"
                 + (f" at {table['worst']}" if table["worst"] else ""))
    return "\n".join(lines)


# ---------------------------------------------------------------------------------------------------------------------
# The Mac part: seed, launch, open, read.

def say(*parts):
    print("chat-size:", *parts, flush=True)


def rpc(sock: str, method: str, params: dict | None = None, timeout: float = 40):
    """One control socket call: its result, or {"error": ...} (chat-open-bench.py Run.rpc)."""
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
            conn.settimeout(timeout)
            conn.connect(sock)
            conn.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
            buf = b""
            while not buf.endswith(b"\n"):
                chunk = conn.recv(1 << 20)
                if not chunk:
                    break
                buf += chunk
        answer = json.loads(buf or b"{}")
    except (OSError, ValueError) as error:
        return {"error": f"{method}: {error}"}
    return {"error": answer["error"]} if answer.get("error") else answer.get("result")


def pane(sock: str, action: str, timeout: float = 40, **params):
    got = rpc(sock, "debug.agent_pane", {"action": action, **params}, timeout=timeout)
    return got if isinstance(got, dict) else {"error": f"{action}: {got!r}"}


def seed(acpmux: str, home: str, session: str, size: str, cwd: str, timeout: float) -> dict:
    """The chat of `size` in `home`, written by the app's acpmux (`__seed-chat`)."""
    started = time.monotonic()
    env = {"HOME": os.path.dirname(home), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "ACPMUX_HOME": home,
           "USER": os.environ.get("USER", ""), "ACPMUX_LOGIN_ENV": "0"}
    try:
        done = subprocess.run([acpmux, "__seed-chat", "--home", home, "--id", session, "--bytes", str(size_bytes(size)),
                               "--name", f"Chat {size}", "--cwd", cwd], env=env, capture_output=True, text=True,
                              timeout=timeout)
    except subprocess.TimeoutExpired:
        return {"error": f"seed: no chat after {timeout:.0f} s"}
    if done.returncode != 0:
        return {"error": f"seed: exit {done.returncode}: {(done.stderr or done.stdout).strip()[-400:]}"}
    try:
        made = json.loads(done.stdout.strip().splitlines()[-1])
    except (ValueError, IndexError):
        return {"error": f"seed: no JSON line: {done.stdout.strip()[-300:]}"}
    return {**made, "seconds": round(time.monotonic() - started, 1)}


def open_workspace(app, sock: str, session: str) -> dict:
    """Opens `session` in a new workspace and shows it once the app lists it (chat-open-bench.py open_workspace)."""
    key = str(uuid.uuid4())
    opened = app.action("agent.openSessionWorkspace", focus=True, wait=False, session=session, key=key)
    if opened.get("error"):
        return opened
    deadline = time.monotonic() + 15
    while True:
        reply = app.action("goToWorkspace", focus=True, workspace=key)
        if not reply.get("error") or "not_found" not in json.dumps(reply.get("error")) or time.monotonic() > deadline:
            return {**opened, "key": key, "shown": reply}
        time.sleep(0.005)  # test script: the workspace is not listed yet


def typing(sock: str, keys: int) -> dict:
    """Keys typed into the open chat's composer, a fast typist's pace; the page's typing_stats (agent-engine-bench)."""
    pane(sock, "reset_typing")
    focused = pane(sock, "focus_composer").get("focused")
    engine = pane(sock, "engine")
    # A Chromium page's keys go to its own page window (agent-engine-bench.py typing).
    target = {"target": "page", "pane": engine.get("pane")} if engine.get("engine") == "cef" else {}
    letters = "abcdefghijklmnopqrstuvwxyz"
    errors = 0
    for index in range(keys):
        reply = rpc(sock, "debug.key", dict(target, key=letters[index % len(letters)]))
        errors += bool(isinstance(reply, dict) and reply.get("error"))
        time.sleep(0.08)  # test script: about a fast typist's pace
    time.sleep(0.5)  # test script: the last key's frame lands
    stats = pane(sock, "typing_stats")
    return {"composer_focused": focused, "engine": engine.get("engine"), "key_errors": errors, "stats": stats,
            "to_paint_p95_ms": stat_p95(stats.get("to_paint")) if not errors else None}


def one_launch(bm, app_path: str, home: str, session: str, opts) -> dict:
    """One launch on `home`: the chat's open, flings, typing and memory. Every process of the bundle ends after it."""
    out: dict = {}
    scratch = None
    try:
        try:
            pid, sock, scratch = bm.launch(app_path, {}, {"ACPMUX_HOME": home})
        except SystemExit as error:  # bench_memory says why a launch did not come up
            return {"error": f"launch: {error}"}
        app = bm.App(app_path, sock)
        deadline = time.monotonic() + 60
        while not app.ping() and time.monotonic() < deadline:
            time.sleep(0.5)  # test script: the app's socket answers once it runs
        time.sleep(opts.settle)  # test script: the launch settles before the chat is read

        def alive(step):
            if bm.gone(pid):
                out["error"] = f"the app exited during {step}"
                return False
            return True

        before = bm.sample(pid, app_path, "unloaded", 1)
        out["daemon_unloaded_mb"] = kinds_mb(before, DAEMON_KINDS)
        armed = rpc(sock, "debug.chat_open_trace", {"action": "arm"})
        if not isinstance(armed, dict) or armed.get("error"):
            out["error"] = f"debug.chat_open_trace arm: {armed}"
            return out
        opened = open_workspace(app, sock, session)
        trace = rpc(sock, "debug.chat_open_trace", {"action": "wait", "timeout_ms": int(opts.open_timeout * 1000),
                                                    "settle_ms": 600}, timeout=opts.open_timeout + 30) or {}
        out["open"] = {"reply": opened, "marks_ms": trace.get("marks_ms"), "timed_out": trace.get("timed_out"),
                       "engine": trace.get("engine"), "error": trace.get("error")}
        if not alive("the open"):
            return out
        why = open_failure(opened, trace, opts.open_timeout)
        if why:
            out["error"] = why
            return out
        out["open_ms"] = number(trace["first_content_ms"])
        time.sleep(opts.settle)  # test script: the open chat settles before its memory is read
        loaded = bm.sample(pid, app_path, "loaded", 1)
        out["daemon_loaded_mb"] = kinds_mb(loaded, DAEMON_KINDS)
        out["app_mb"] = kinds_mb(loaded, RENDER_KINDS)
        out["kinds_loaded"] = {k: (v or {}).get("footprint_mb") for k, v in (loaded.get("kinds") or {}).items()}
        if not alive("the memory read"):
            return out
        flings = []
        for _ in range(opts.flings):
            fling = pane(sock, "fling", seconds=opts.fling_seconds, wait=True, timeout=max(60, opts.fling_seconds + 30))
            fling["perf_stats"] = pane(sock, "perf_stats", raw=True)
            flings.append(fling)
            if not alive("a fling"):
                return out
        out["flings"] = [{"p95_ms": f.get("p95_ms"), "frames": f.get("frames"), "error": f.get("error"),
                          "running": f.get("running"), "perf_stats": {"samples": (f.get("perf_stats") or {}).get("samples")}}
                         for f in flings]
        typed = typing(sock, opts.keys)
        out["typing"] = {k: v for k, v in typed.items() if k != "stats"}
        out["key_paint_ms"] = typed["to_paint_p95_ms"]
        if not alive("typing"):
            return out
        after = bm.sample(pid, app_path, "after", 1)
        out["app_mb_after_fling"] = kinds_mb(after, RENDER_KINDS)  # shown only: the flings paged older rows in
        return out
    finally:
        bm.end_bundle(app_path)
        if scratch:
            shutil.rmtree(scratch, ignore_errors=True)


def measure(opts, app_path: str) -> dict:
    sys.path.insert(0, HERE)
    import bench_memory as bm  # noqa: E402  (macOS only: libproc)
    import idle_cost_load as icl  # noqa: E402
    acpmux = opts.acpmux or icl.bundled_acpmux(app_path)
    sizes = parse_sizes(opts.sizes)
    work = tempfile.mkdtemp(prefix="chat-size-", dir=opts.work)
    result = {"asked": sizes, "sizes": {}, "app": os.path.basename(app_path.rstrip("/")), "host": os.uname().nodename,
              "runs": opts.runs, "acpmux": os.path.basename(acpmux)}
    try:
        for size in sizes:
            root = os.path.join(work, size)
            home = os.path.join(root, "acpmux")
            cwd = os.path.join(root, "work")
            os.makedirs(cwd, mode=0o700)
            os.makedirs(home, mode=0o700)
            session = str(uuid.uuid4())
            record = {"seed": seed(acpmux, home, session, size, cwd, opts.seed_timeout), "runs": []}
            say(size, "seed", json.dumps(record["seed"]))
            if record["seed"].get("error"):
                record["error"] = record["seed"]["error"]
            else:
                for index in range(opts.runs):
                    got = one_launch(bm, app_path, home, session, opts)
                    record["runs"].append(got)
                    say(size, f"launch {index + 1}", json.dumps({k: got.get(k) for k in
                        ("error", "open_ms", "app_mb", "daemon_unloaded_mb", "daemon_loaded_mb", "key_paint_ms")}))
                    if got.get("error"):
                        break  # the size is missing now; more launches would not bring it back
            result["sizes"][size] = record
            shutil.rmtree(root, ignore_errors=True)  # the next size's disk
    finally:
        shutil.rmtree(work, ignore_errors=True)
    return result


def copied_app(source: str, into: str) -> str:
    """A copy of `source` (an APFS clone where it can be), so the bench never runs the installed app itself."""
    target = os.path.join(into, os.path.basename(source.rstrip("/")))
    done = subprocess.run(["cp", "-cR", source.rstrip("/"), target], capture_output=True, text=True)
    if done.returncode != 0:
        subprocess.run(["ditto", source.rstrip("/"), target], check=True)
    return target


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--app", help="the app bundle to measure")
    parser.add_argument("--copy-from", help="measure a copy of this bundle (the NIGHTLY), made and deleted by this run")
    parser.add_argument("--rows-from", help="a kept report.json: its rows again, no app")
    parser.add_argument("--json", required=True, help="the report (perf-cron's budgets kind: rows, incomplete)")
    parser.add_argument("--out", help="split-spring's artifact folder (unused; accepted)")
    parser.add_argument("--sizes", default=DEFAULT_SIZES)
    parser.add_argument("--runs", type=int, default=3, help="launches per size")
    parser.add_argument("--flings", type=int, default=2)
    parser.add_argument("--fling-seconds", type=float, default=3)
    parser.add_argument("--keys", type=int, default=40)
    parser.add_argument("--settle", type=float, default=8)
    parser.add_argument("--open-timeout", type=float, default=120, help="seconds an open may take to first content")
    parser.add_argument("--seed-timeout", type=float, default=1800)
    parser.add_argument("--acpmux", help="the acpmux that seeds (default: the app's own)")
    parser.add_argument("--work", help="where the seeded homes go (default: the temp folder)")
    opts, _rest = parser.parse_known_args(argv)  # split-spring's own args (--tag) are not this suite's
    try:
        parse_sizes(opts.sizes)
    except ValueError as error:
        parser.error(str(error))
    if opts.runs < 1 or opts.flings < 1 or opts.keys < 1:
        parser.error("--runs, --flings and --keys must be at least 1")
    if opts.rows_from:
        with open(opts.rows_from) as handle:
            result = json.load(handle)
    else:
        if bool(opts.app) == bool(opts.copy_from):
            parser.error("one of --app or --copy-from")
        if sys.platform != "darwin":
            parser.error("the measurement runs on a Mac (--rows-from works anywhere)")
        holder = tempfile.mkdtemp(prefix="chat-size-app-") if opts.copy_from else None
        try:
            app_path = copied_app(opts.copy_from, holder) if holder else os.path.realpath(opts.app.rstrip("/"))
            result = measure(opts, app_path)
        finally:
            if holder:
                shutil.rmtree(holder, ignore_errors=True)
    rows, incomplete, table = rows_from(result)
    out = {**result, "rows": rows, "table": table}
    out.pop("incomplete", None)
    if incomplete:
        out["incomplete"] = incomplete
    with open(opts.json, "w") as handle:
        json.dump(out, handle, indent=1)
    print("CHAT-SIZE-TABLE-BEGIN\n" + table_text(result, table) + "\nCHAT-SIZE-TABLE-END", flush=True)
    for item in incomplete:
        say("missing", item["name"], "-", item["reason"])
    return 1 if incomplete else 0


if __name__ == "__main__":
    raise SystemExit(main())
