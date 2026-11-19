"""idle: idle CPU, wakeups and memory of a cmux NEXT app and its headless cmux-tui, per process kind (perf-10x-idle).

Wraps scripts/measure/perf-10x-idle.sh (msg 1628, CMUX-571): it builds a tagged app at the step's ref, launches it
with a scratch HOME and measures each idle window (scripts/cmux-next/bench_memory.py), and runs the bundle's
cmux-tui headless with one terminal per workspace (cmux-tui/scripts/bench-scale.py). It prints one line per
process kind and sample, which `ingest` reads from the step log:

  PERF-IDLE app <sample> workspaces=N kind=K n=.. cpu_pct=.. wakeups_per_s=.. rss_mb=.. footprint_mb=..
  PERF-IDLE app-agents <sample> agents=N kind=K ...                (agents=: N idle agent chats)
  PERF-IDLE daemon N=.. role=R n=.. cpu_pct=.. wakeups_per_s=.. rss_each_mb=.. footprint_each_mb=.. threads=..

Rows (better = lower):
  scope=app|agents, labels sample (idle-launch, idle-N, purged-N, released-N), count, kind (bench_memory.py's
  kinds: app, cef-renderer, cef-gpu, cef-utility, webkit-webcontent, tui-daemon, acpmux-daemon, ...; and total):
  cpu (%), wakeups (per_s), footprint (MB), rss (MB), processes (count).
  scope=daemon, labels count, role (daemon, hosts, shells): cpu (%), wakeups (per_s), footprint_each (MB),
  rss_each (MB), processes (count), threads (count).

The app is built at the commit under test (--build SHA, or a NIGHTLY's source commit), a tagged build of the
same source rather than the signed NIGHTLY binary; the NIGHTLY's own idle numbers come from xbench's cmux-budget
rows. Default args: counts=1,10 measure=60 (about 25 minutes with the build). Harness args pass through:
--arg counts=1,10,50 --arg agents=10 --arg attribute=1 --arg measure=150 --arg config=bench --arg vmmap=tui-daemon ...
"""
from __future__ import annotations

import re
import subprocess
from pathlib import Path

from benchlib.bench import Bench, BenchError, Context

HARNESS = "scripts/measure/perf-10x-idle.sh"
PASS_THROUGH = ("counts", "measure", "agents", "purge", "release", "attribute", "infinite", "days",
                "chat_renderer_crash", "vmmap", "axes", "items", "visible_items", "settled")
DEFAULTS = {"counts": "1,10", "measure": "60"}
FIELD = re.compile(r"(\w+)=(\S+)")
APP_LINE = re.compile(r"^PERF-IDLE (app|app-agents) (\S+) (.*)$")
DAEMON_LINE = re.compile(r"^PERF-IDLE daemon (.*)$")
MACHINE_LINE = re.compile(r"^PERF-IDLE-MACHINE (.*)$")


def _num(fields: dict[str, str], key: str) -> float | None:
    try:
        return float(fields[key])
    except (KeyError, ValueError):  # missing, None, nan
        return None


class Idle(Bench):
    name = "idle"
    summary = "Idle CPU %, wakeups/s and footprint per process kind of a tagged cmux NEXT app and headless cmux-tui"
    units = "%, per_s, MB, count"
    owner = "perf (msg 1628, CMUX-571)"
    hosts = ("fleet",)
    harness = HARNESS
    version = "1"
    # Idle CPU and wakeups at fractions of a percent swing by more than 10 % run to run.
    thresholds = {"cpu": 25.0, "wakeups": 25.0, "footprint": 10.0, "footprint_each": 10.0, "rss": 15.0}
    nightly = False  # builds a tagged app (not the signed NIGHTLY); xbench's cmux-budget rows cover the NIGHTLY

    def harness_args(self, ctx: Context) -> tuple[list[str], str | None]:
        args = dict(DEFAULTS)
        args.update({k: v for k, v in ctx.args.items() if k in PASS_THROUGH})
        out = [f"{k}={v}" for k, v in args.items()]
        if ctx.arg("config"):
            out.append(f"--config={ctx.arg('config')}")
        sha = ctx.build.get("sha")
        if ctx.build.get("channel") in ("sha", "nightly") and sha:
            return out, sha
        if ctx.build.get("channel") == "nightly":
            ctx.notes.append("idle: the NIGHTLY feed names no source commit; measuring the feat-cmux-next tip")
            return out, None
        raise BenchError(f"idle: --build {ctx.build.get('channel')} has no commit to build; pass --build SHA")

    def run(self, ctx: Context) -> None:
        args, ref = self.harness_args(ctx)
        res = ctx.fleet_step(self.harness, args, None, step_class="exclusive", labels=("measure",), timeout=5400,
                             ref=ref)
        log = res.log_path
        if "PERF-IDLE " not in res.log and res.job_id:
            full = ctx.workdir / f"{res.job_id}.log"
            got = subprocess.run(["cmux-ci", "log", res.job_id, "--tail", "200000"], text=True, capture_output=True)
            if got.returncode == 0:
                full.write_text(got.stdout)
                log = full
        self.ingest(ctx, log)

    def ingest(self, ctx: Context, path: Path) -> None:
        text = Path(path).read_text(encoding="utf-8", errors="replace")
        totals: dict[tuple[str, str, str], dict[str, float]] = {}
        found = 0
        for line in text.splitlines():
            line = line.strip()
            if m := MACHINE_LINE.match(line):
                f = dict(FIELD.findall(m.group(1)))
                if f.get("host"):
                    ctx.host.update({"name": f["host"], "role": "fleet"})
                if f.get("macos"):
                    ctx.host["os"] = f"macOS {f['macos']}"
                continue
            if m := APP_LINE.match(line):
                scope = "app" if m.group(1) == "app" else "agents"
                f = dict(FIELD.findall(m.group(3)))
                count = f.get("workspaces") or f.get("agents") or "?"
                labels = {"scope": scope, "sample": m.group(2), "count": count, "kind": f.get("kind", "?")}
                tot = totals.setdefault((scope, m.group(2), count), {})
                for metric, key, unit in (("cpu", "cpu_pct", "%"), ("wakeups", "wakeups_per_s", "per_s"),
                                          ("footprint", "footprint_mb", "MB"), ("rss", "rss_mb", "MB"),
                                          ("processes", "n", "count"), ("disk_write", "disk_write_mb_per_h", "MB_per_h"),
                                          ("disk_read", "disk_read_mb_per_h", "MB_per_h")):
                    v = _num(f, key)
                    if v is None:
                        continue
                    ctx.row(metric, v, unit, labels=labels)
                    tot[metric] = tot.get(metric, 0.0) + v
                found += 1
                continue
            if m := DAEMON_LINE.match(line):
                f = dict(FIELD.findall(m.group(1)))
                labels = {"scope": "daemon", "count": f.get("N", "?"), "role": f.get("role", "?")}
                for metric, key, unit in (("cpu", "cpu_pct", "%"), ("wakeups", "wakeups_per_s", "per_s"),
                                          ("footprint_each", "footprint_each_mb", "MB"), ("rss_each", "rss_each_mb", "MB"),
                                          ("processes", "n", "count"), ("threads", "threads", "count")):
                    v = _num(f, key)
                    if v is not None:
                        ctx.row(metric, v, unit, labels=labels)
                found += 1
        if not found:
            raise BenchError(f"{path}: no PERF-IDLE line (not a perf-10x-idle.sh log?)")
        units = {"cpu": "%", "wakeups": "per_s", "footprint": "MB", "rss": "MB", "processes": "count",
                 "disk_write": "MB_per_h", "disk_read": "MB_per_h"}
        for (scope, sample, count), tot in totals.items():
            for metric, v in tot.items():
                ctx.row(metric, v, units[metric], labels={"scope": scope, "sample": sample, "count": count, "kind": "total"})


BENCH = Idle()
