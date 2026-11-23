"""launch-background: cmux NEXT brought back from the background against today's relaunch (ask-b2b0f899c1).

scripts/measure/background-ready.sh on a fleet Mac: per arm, one copy and home, a priming launch, then `runs` shows,
each after the arm's background step (cold: SIGTERM quit and a new instance; hide: Cmd-H; close: every window closed,
the app an accessory with no Dock icon; quit: an interactive quit, a cold relaunch when the process exits). Each show is
timed in ms since the open request (a Dock click's openApplication of the running app): rows window_on_screen, active,
frame_committed, usable and each reopen.* mark, labeled arm=ARM; failed_shows counts rounds with no window or an error.
Each arm's idle window (BR-IDLE) adds idle_mw, idle_cpu_pct, idle_wakeups_per_s, idle_footprint_mb, idle_rss_mb,
idle_open_files and idle_sockets, labeled arm=ARM state=shown|quit|hidden|closed|quit_alive.

  --build nightly      the NIGHTLY the feed offers now
  --build <sha>        that commit built as a tagged Release app on the Mac (dmg=build head=<sha>)
  --arg runs=N         shows per arm (1 to 10, default 5); --arg arms=cold,hide,close[,quit]; --arg idle=S (600; 0
                       skips); --arg settle=S (6); --arg setting=afterQuit (the quit arm's app.backgroundReady)
  --import FILE        the step's log, its report.tgz, or the runs.jsonl inside it
"""
from __future__ import annotations

import json
import re
import tarfile
from pathlib import Path

from benchlib.bench import Bench, BenchError, Context

from benches.launch import HOST, _metric

HARNESS = "scripts/measure/background-ready.sh"
RUN = re.compile(r"BR-RUN (\w+) (\{.*\})\s*$")
IDLE = re.compile(r"BR-IDLE (\w+) (\{.*\})\s*$")
BR_HOST = re.compile(HOST.pattern.replace("LR host", "BR host"))
TOP = ("window_on_screen", "active", "frame_committed", "usable")


def read_lines(path: Path) -> tuple[list[dict], list[dict], str]:
    """(BR-RUN rows, BR-IDLE rows, the text) from a step log, a report.tgz (runs.jsonl, idle.jsonl) or a runs.jsonl."""
    texts = []
    if tarfile.is_tarfile(path):
        with tarfile.open(path) as tar:
            for member in tar.getmembers():
                if member.name.rsplit("/", 1)[-1] in ("runs.jsonl", "idle.jsonl"):
                    texts.append(tar.extractfile(member).read().decode("utf-8", "replace"))
        if not texts:
            raise BenchError(f"{path}: no runs.jsonl in the archive")
    else:
        texts.append(path.read_text(encoding="utf-8", errors="replace"))
    runs, idles = [], []
    for text in texts:
        for line in text.splitlines():
            line = line.strip()
            if line.startswith("{"):  # runs.jsonl rows carry their arm; idle.jsonl rows their arm and state
                row = json.loads(line)
                (idles if "window" in row and "state" in row else runs).append(row)
                continue
            for pattern, into in ((RUN, runs), (IDLE, idles)):
                m = pattern.search(line)
                if m:
                    row = json.loads(m.group(2))
                    row["arm"] = m.group(1)
                    into.append(row)
    return runs, idles, "\n".join(texts)


class LaunchBackground(Bench):
    name = "launch-background"
    summary = "Show from the background (hide, close to accessory, quit) against a cold relaunch, and its idle cost"
    units = "ms, mW, %, count, MB"
    owner = "launch (ask-b2b0f899c1)"
    hosts = ("fleet",)
    harness = HARNESS
    version = "1"
    thresholds = {"failed_shows": 0.0}
    floors = {"failed_shows": 0.0}

    def run(self, ctx: Context) -> None:
        build = ctx.build
        args = [f"runs={ctx.arg('runs', '5')}"]
        for key in ("arms", "idle", "settle", "setting"):
            if ctx.arg(key):
                args.append(f"{key}={ctx.arg(key)}")
        if build["channel"] == "nightly":
            args.insert(0, "dmg=nightly")
            timeout = 5400
        elif build["channel"] == "sha":
            args[:0] = ["dmg=build", f"head={build['sha']}"]
            timeout = 7200
        else:
            raise BenchError("launch-background: --build nightly or --build <sha>")
        res = ctx.fleet_step(HARNESS, args, ".build/background-ready/report.tgz",
                             labels=tuple(ctx.arg("labels", "measure").split(",")), timeout=timeout, display=True)
        self.ingest(ctx, res.log_path)

    def ingest(self, ctx: Context, path: Path) -> None:
        runs, idles, text = read_lines(path)
        host = BR_HOST.search(text)
        if host and ctx.host.get("name") in ("fleet", "", None):
            ctx.host.update({"name": host.group(1), "chip": host.group(2), "os": f"macOS {host.group(3)}"})
        if not runs:
            raise BenchError(f"{path}: no BR-RUN lines")
        for arm in dict.fromkeys(r["arm"] for r in runs):
            measured = [r for r in runs if r["arm"] == arm and str(r.get("label", "")).startswith("run")]
            done = [r for r in measured if r.get("window_on_screen") is not None and not r.get("error")]
            labels = {"arm": arm}
            ctx.row("failed_shows", len(measured) - len(done), "count", labels=labels)
            ctx.row("exited_shows", sum(bool(r.get("exited")) for r in measured), "count", labels=labels, better="none")
            for key in TOP:
                ctx.row(key, unit="ms", samples=[r.get(key) for r in done], labels=labels)
            names = dict.fromkeys(n for r in done for n in (r.get("reopen_since_request") or {}))
            for name in names:
                ctx.row(_metric(name), unit="ms", labels=labels,
                        samples=[r["reopen_since_request"][name] for r in done if name in (r.get("reopen_since_request") or {})])
        for idle in idles:
            labels = {"arm": idle["arm"], "state": idle.get("state", "?")}
            window, memory, files = idle.get("window") or {}, idle.get("memory") or {}, idle.get("files") or {}
            for metric, value, unit in (("idle_mw", window.get("mw"), "mW"), ("idle_cpu_pct", window.get("cpu_pct"), "%"),
                                        ("idle_wakeups_per_s", window.get("wakeups_per_s"), "per_s"),
                                        ("idle_footprint_mb", memory.get("footprint_mb"), "MB"),
                                        ("idle_rss_mb", memory.get("rss_mb"), "MB"),
                                        ("idle_open_files", files.get("total"), "count"),
                                        ("idle_sockets", files.get("sockets"), "count")):
                if value is not None:
                    ctx.row(metric, value, unit, labels=labels)


BENCH = LaunchBackground()
