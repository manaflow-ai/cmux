"""launch: a Dock launch of cmux NEXT, timed from outside the app (scripts/measure/launch-ready.sh).

launch-ready.sh copies the app out of its DMG, makes a home with one priming launch, then relaunches it through
LaunchServices `runs` times (a person's Dock click on a second launch on). Each launch prints `LR-RUN <json>`, in ms
from the app's process start:
  finished_launching   the Dock's bounce ends (NSRunningApplication.isFinishedLaunching)
  window_on_screen     the first on-screen window
  active               the app became active
  request_to_start     the open request to the process start (LaunchServices' part, before exec)
and the app's own launch marks (main_start, main.nsapp, did_finish_launching_start, launch_snapshot_shown,
first_window_frame_committed, home.first_page, ...). Each becomes one row (dots become underscores) with the measured
relaunches as samples (value = median, plus p50, p95, n); the priming launch is not counted. Rows carry arm=head, or
arm=base for the other side of an A/B.

  --build nightly      the NIGHTLY the feed offers now (dmg=<its URL>), about 3 minutes on a fleet Mac
  --build <sha>        that commit built as a tagged Release app on the Mac (dmg=build head=<sha>); add
                       --arg base=<sha> to build a base too and interleave its runs (arm=base)
  --arg runs=N         measured relaunches per side (1 to 10, default 5); --arg profile=1 adds a Time Profiler pass
  --arg state=bare     every launch starts from an empty home (nothing to restore); --arg prerun=S a full run of S
                       seconds before each measured launch (60: "a launch after a 60 s full run"); both as the harness
  --arg engines=chromium,webkit  one side per default engine (arm=chromium, arm=webkit), the same DMG, interleaved;
                       Chromium's start from the app's log as cef_ready, cef_initialize_start, cef_initialize_dur, ... rows
  --arg labels=a,b     worker labels (default measure, on a display worker as the harness documents)
  --arg mode=premain   scripts/measure/launch-premain.sh instead (CMUX-629's pre-main study, NIGHTLY only, about 50
                       minutes): per arm (h, a, b, c, g, d, k, e, e2, x, f, t1, t3, t6; --arg arms=, --arg reps=N) the measured launch's
                       main_start, pageins, user_ms, system_ms, disk_read_kb, resident_before, resident_at_main and
                       pages_touched, rows labeled mode=premain arm=<arm>; the harness's header says what each arm is

`--import` takes the step's log, its report.tgz, or the runs.jsonl inside it (an LP-RUN log or runs.jsonl reads as
mode=premain).
"""
from __future__ import annotations

import json
import re
import tarfile
from pathlib import Path

from benchlib.bench import Bench, BenchError, Context, FleetResult, parse_build

RUN = re.compile(r"LR-RUN (?:(\w+) )?(\{.*\})\s*$")
NO_RESULT = re.compile(r"LR-RUN (\w+) (\w+) no result")
HOST = re.compile(r'LR host (\S+) chip="([^"]*)" macOS (\S+)')
TOP = ("finished_launching", "window_on_screen", "active", "request_to_start")
PREMAIN = "scripts/measure/launch-premain.sh"
LP_RUN = re.compile(r"LP-RUN (\{.*\})\s*$")
LP_HOST = re.compile(r'LP host (\S+) chip="([^"]*)" macOS (\S+)')
LP_KEYS = {"main_start": "ms", "pageins": "count", "system_pageins": "count", "user_ms": "ms", "system_ms": "ms",
           "disk_read_kb": "KB", "resident_before": "%", "resident_at_main": "%", "pages_touched": "count"}


def _metric(name: str) -> str:
    return re.sub(r"[^0-9a-z]+", "_", name.lower()).strip("_")


def read_runs(path: Path) -> tuple[list[dict], str]:
    """The LR-RUN objects (each with its side) and the text they came from, from a log, report.tgz or runs.jsonl."""
    if tarfile.is_tarfile(path):
        with tarfile.open(path) as tar:
            member = next((m for m in tar.getmembers() if m.name.rsplit("/", 1)[-1] == "runs.jsonl"), None)
            if member is None:
                raise BenchError(f"{path}: no runs.jsonl in the archive")
            text = tar.extractfile(member).read().decode("utf-8", "replace")
    else:
        text = path.read_text(encoding="utf-8", errors="replace")
    runs = []
    for line in text.splitlines():
        line = line.strip()
        if line.startswith("{"):  # runs.jsonl: the side is a key
            row = json.loads(line)
            runs.append(row)
            continue
        m = NO_RESULT.search(line)
        if m:  # the probe printed nothing: a failed launch
            runs.append({"side": m.group(1), "label": m.group(2), "error": "no result"})
            continue
        m = RUN.search(line)
        if m and m.group(1) is not None:  # `LR-RUN head {...}`; the probe's own unsided line is skipped
            row = json.loads(m.group(2))
            row["side"] = m.group(1)
            runs.append(row)
    return runs, text


class Launch(Bench):
    name = "launch"
    summary = "Dock launch of cmux NEXT: bounce end, first on-screen window, main and first frame (relaunches)"
    units = "ms, count"
    owner = "launch (CMUX-629, CMUX-631)"
    hosts = ("fleet",)
    harness = "scripts/measure/launch-ready.sh"
    version = "1"
    # A relaunch's marks move by 5 to 10 % run to run on one Mac; request_to_start is a few ms of LaunchServices.
    thresholds = {"request_to_start": 50.0, "failed_launches": 0.0}
    floors = {"request_to_start": 10.0, "failed_launches": 0.0}
    nightly = True
    nightly_args = {"runs": "5"}

    def run(self, ctx: Context) -> None:
        build = ctx.build
        if ctx.arg("mode") == "premain":
            if build["channel"] != "nightly" and not ctx.arg("dmg"):
                raise BenchError("launch mode=premain: --build nightly or --arg dmg=https://... (a DMG)")
            args = [f"dmg={build.get('url') or ctx.arg('dmg') or 'nightly'}", f"reps={ctx.arg('reps', '5')}"]
            if ctx.arg("arms"):
                args.append(f"arms={ctx.arg('arms')}")
            res = ctx.fleet_step(PREMAIN, args, ".build/launch-premain/report.tgz",
                                 labels=tuple(ctx.arg("labels", "measure").split(",")), timeout=5400, display=True)
            self.ingest(ctx, res.log_path)
            return
        self.ingest(ctx, self.ready_step(ctx).log_path)

    def ready_step(self, ctx: Context, **extra: str) -> FleetResult:
        """One launch-ready.sh step on a fleet Mac for ctx's build, `extra` over ctx's own arguments."""
        args, timeout = self.ready_args(ctx, **extra)
        return ctx.fleet_step(self.harness, args, ".build/launch-ready/report.tgz",
                              labels=tuple(ctx.arg("labels", "measure").split(",")), timeout=timeout, display=True)

    def ready_args(self, ctx: Context, **extra: str) -> tuple[list[str], int]:
        """launch-ready.sh's arguments for ctx's build, with `extra` (state=, prerun=) over ctx's own, and the step's
        timeout."""
        build = ctx.build
        args = [f"runs={ctx.arg('runs', '5')}"]
        for key in ("profile", "state", "prerun", "engines"):
            value = extra.get(key, ctx.arg(key))
            if value:
                args.append(f"{key}={value}")
        if build["channel"] == "nightly":
            args.insert(0, f"dmg={build.get('url') or ctx.arg('dmg') or 'nightly'}")
            timeout = 1800
        elif build["channel"] == "sha":
            args[:0] = ["dmg=build", f"head={build['sha']}"]
            if ctx.arg("base"):
                args.append(f"base={parse_build(ctx.arg('base'))['sha']}")
            timeout = 3600
        elif ctx.arg("dmg"):
            args.insert(0, f"dmg={ctx.arg('dmg')}")
            timeout = 1800
        else:
            raise BenchError("launch: --build nightly, --build <sha>, or --arg dmg=https://... (a DMG)")
        # A prerun adds S seconds and a quit to each of the runs and the priming launch.
        prerun = int(extra.get("prerun", ctx.arg("prerun", "0")) or 0)
        # engines=chromium,webkit: the second side's launches.
        timeout += 900 * max(0, len((extra.get("engines", ctx.arg("engines")) or "").split(",")) - 1)
        return args, timeout + prerun * (int(ctx.arg("runs", "5")) + 1)

    def ingest(self, ctx: Context, path: Path) -> None:
        if ctx.arg("mode") == "premain" or _is_premain(path):
            return self.ingest_premain(ctx, path)
        self.ingest_ready(ctx, path)

    def ingest_ready(self, ctx: Context, path: Path, extra: dict[str, str] | None = None) -> dict[str, list[dict]]:
        """launch-ready.sh's measured launches, one row per key and side labeled arm=SIDE and `extra`; returns each
        side's finished launches."""
        runs, text = read_runs(path)
        host = HOST.search(text)
        if host and ctx.host.get("name") in ("fleet", "", None):
            ctx.host.update({"name": host.group(1), "chip": host.group(2), "os": f"macOS {host.group(3)}"})
        if not runs:
            raise BenchError(f"{path}: no LR-RUN lines")
        finished = {}
        for side in dict.fromkeys(r["side"] for r in runs):
            # The measured relaunches (runN): not the priming launch, nor a prerun's full run before each (fullN).
            measured = [r for r in runs if r["side"] == side and str(r.get("label", "")).startswith("run")]
            done = [r for r in measured if r.get("window_on_screen") is not None and not r.get("error")]
            finished[side] = done
            labels = {"arm": side, **(extra or {})}
            ctx.row("failed_launches", len(measured) - len(done), "count", labels=labels)
            for key in TOP:
                ctx.row(key, unit="ms", samples=[r[key] for r in done if r.get(key) is not None], labels=labels)
            if any(r.get("shell_requested") is not None for r in done):  # state=bare: the probe opened a terminal
                ctx.row("shell_requested", unit="ms", samples=[r.get("shell_requested") for r in done], labels=labels)
            names = dict.fromkeys(n for r in done for n in (r.get("marks") or {}))
            for name in names:
                ctx.row(_metric(name), unit="ms", samples=[r["marks"][name] for r in done if name in r["marks"]],
                        labels=labels)
        return finished


    def ingest_premain(self, ctx: Context, path: Path) -> None:
        """launch-premain.sh's measured launches (role B), one row per key and arm."""
        text = _premain_text(path)
        host = LP_HOST.search(text)
        if host and ctx.host.get("name") in ("fleet", "", None):
            ctx.host.update({"name": host.group(1), "chip": host.group(2), "os": f"macOS {host.group(3)}"})
        runs = []
        for line in text.splitlines():
            m = LP_RUN.search(line) if "LP-RUN" in line else None
            if m or line.startswith("{"):
                row = json.loads(m.group(1) if m else line)
                if row.get("role") == "B":
                    runs.append(row)
        if not runs:
            raise BenchError(f"{path}: no LP-RUN lines with role B")
        for arm in dict.fromkeys(r["arm"] for r in runs):
            measured = [r for r in runs if r["arm"] == arm]
            done = [r for r in measured if r.get("main_start") is not None and not r.get("error")]
            labels = {"mode": "premain", "arm": arm}
            ctx.row("failed_launches", len(measured) - len(done), "count", labels=labels)
            for key, unit in LP_KEYS.items():
                scale = 100.0 if unit == "%" else 1.0  # the harness's residency is a fraction
                ctx.row(key, unit=unit, samples=[r[key] * scale for r in done if r.get(key) is not None], labels=labels,
                        better="higher" if key.startswith("resident") else "lower")


def _premain_text(path: Path) -> str:
    if tarfile.is_tarfile(path):
        with tarfile.open(path) as tar:
            member = next((m for m in tar.getmembers() if m.name.rsplit("/", 1)[-1] == "runs.jsonl"), None)
            if member is None:
                raise BenchError(f"{path}: no runs.jsonl in the archive")
            return tar.extractfile(member).read().decode("utf-8", "replace")
    return path.read_text(encoding="utf-8", errors="replace")


def _is_premain(path: Path) -> bool:
    """A launch-premain.sh log or runs.jsonl (its rows carry role), not a launch-ready.sh one."""
    text = _premain_text(path)
    return "LP-RUN " in text or '"role": "B"' in text


BENCH = Launch()
