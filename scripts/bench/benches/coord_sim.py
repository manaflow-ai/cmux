"""coord-sim: several synthetic coordinator chats at once against a release acpmux on Linux, one report per run.

Wraps scripts/measure/coord-sim-linux.sh (crate cmux-tui/crates/coord-sim): it builds coord-sim and acpmux, generates
N coordinator chats shaped like the heaviest real ones from histograms only (shapes/leo-peak.json, no transcript),
drives them at once at a rate multiplier with readers attached (`coord-sim drive`), then `coord-sim report RUN_DIR
--rows`, which prints the report (schema coord-sim-run.v1) on one line and its rows as {"rows": [...]} on the last
line. `ingest` reads that last line (or a report.json / run dir: the rows come from the report itself then).

Rows (labels: coordinators, rate), better = lower; each is a PERF_ROW of the report (perf-cron stores the same rows as
webui.coord_sim.<metric>):
  delivery_ms, delivery_p99_ms: an event's agent write to a reader seeing it (p50, p95; p99)
  events.lost, events.duplicated, events.lost_or_duplicated (events): exact counts over every (coordinator, reader)
    stream, target 0
  attach_ms, first_paint_ms: a reader's attach under load, and to the first event it shows
  page_ms, scroll.over_33ms (ops): a reader paging history, and pages over two 60 Hz frames
  typing.ack_ms, typing.echo_ms: a prompt to the daemon's ack and to its echo
  daemon.peak_rss_mb, daemon.rss_slope_mb_per_min (the leak signal), daemon.cpu_pct, per_chat.rss_mb, per_chat.cpu_pct
  fanin.n<N>.{attach_ms, fanout_ms, fanout_max_ms, list_ms, list_paged_ms, list_under_churn_ms,
    controller_rss_mb_per_session, controller_life_cpu_pct_per_session (whole-life CPU), lost_or_duplicated}, and
    fanin.slope.controller_{rss_mb,cpu_pct}_per_session_per_ksession: the fan-in ramp (`coord-sim fanin`, one
    controller, N sessions over many host daemons), when the run had one (harness arg fanin=RAMPS)

Run: `cmux-bench coord-sim [--arg coordinators=3] [--arg rate=10] [--arg seconds=300]` sends the harness through
`cmux-ci test --setup rust` (Linux; on a lane VM at the caller's open PR head) and reads its log. `--import PATH`
reads a harness log, a report.json, or a run dir holding one.
"""
from __future__ import annotations

import json
import re
import shlex
import subprocess
from pathlib import Path

from benchlib.bench import Bench, BenchError, Context

HARNESS = "scripts/measure/coord-sim-linux.sh"
PASS_THROUGH = ("coordinators", "rate", "seconds", "seed", "readers", "fanin", "fanin_window", "fanin_hosts")
# A GitHub Actions log prefixes each line with its time.
STAMP = re.compile(r"^\d{4}-\d\d-\d\dT[\d:.]+Z ")
PREFIX = "coord_sim."
# The report's units in cmux-bench's (benchlib/schema.py UNITS): counts are counts; the slope's name says per minute.
UNITS = {"events": "count", "ops": "count", "MB/min": "MB"}


def rows_of_report(report: dict) -> list[dict]:
    """PERF_ROW-shaped rows of a coord-sim-run.v1 report, as `coord-sim report --rows` prints them (the Rust
    perf_rows is the source; this reads the same report keys for an import of report.json alone)."""
    out = []

    def dist(name, d, unit):
        if isinstance(d, dict) and isinstance(d.get("p50"), (int, float)) and isinstance(d.get("p95"), (int, float)):
            out.append({"name": PREFIX + name, "p50": d["p50"], "p95": d["p95"], "unit": unit})

    def one(name, v, unit):
        if isinstance(v, (int, float)) and not isinstance(v, bool):
            out.append({"name": PREFIX + name, "p50": v, "p95": v, "unit": unit})

    g = lambda *keys: _get(report, *keys)  # noqa: E731
    dist("delivery_ms", g("delivery_ms"), "ms")
    dist("attach_ms", g("attach_ms"), "ms")
    dist("first_paint_ms", g("first_paint_ms"), "ms")
    dist("page_ms", g("scroll", "page_ms"), "ms")
    dist("typing.ack_ms", g("typing", "ack_ms"), "ms")
    dist("typing.echo_ms", g("typing", "echo_ms"), "ms")
    dist("daemon.cpu_pct", g("daemon", "cpu_pct"), "%")
    dist("per_chat.rss_mb", g("per_chat", "rss_mb"), "MB")
    dist("per_chat.cpu_pct", g("per_chat", "cpu_pct"), "%")
    if g("files", "events") is True:
        lost, dup = g("events", "lost"), g("events", "duplicated")
        if isinstance(lost, int) and isinstance(dup, int):
            one("events.lost_or_duplicated", lost + dup, "events")
        one("events.lost", g("events", "lost"), "events")
        one("events.duplicated", g("events", "duplicated"), "events")
    one("delivery_p99_ms", g("delivery_ms", "p99"), "ms")
    if (g("scroll", "page_ms", "n") or 0) > 0:
        one("scroll.over_33ms", g("scroll", "over_33_3ms"), "ops")
    one("daemon.peak_rss_mb", g("daemon", "peak_rss_mb"), "MB")
    one("daemon.rss_slope_mb_per_min", g("daemon", "rss_slope_mb_per_min"), "MB/min")
    fanin = report.get("fanin") if isinstance(report.get("fanin"), dict) else {}
    for t in fanin.get("ramps") or []:
        if not isinstance(t, dict) or t.get("error") or not isinstance(t.get("n"), int):
            continue
        p = f"fanin.n{t['n']}."
        dist(p + "attach_ms", t.get("attach_ms"), "ms")
        dist(p + "fanout_ms", t.get("fanout_ms"), "ms")
        one(p + "fanout_max_ms", _get(t, "fanout_ms", "max"), "ms")
        one(p + "list_ms", _get(t, "list_ms", "whole_at_rest"), "ms")
        one(p + "list_paged_ms", _get(t, "list_ms", "paged_at_rest"), "ms")
        one(p + "list_under_churn_ms", _get(t, "list_ms", "whole_under_churn_p95"), "ms")
        one(p + "controller_rss_mb_per_session", _get(t, "controller", "rss_mb_per_session"), "MB")
        one(p + "controller_life_cpu_pct_per_session", _get(t, "controller", "cpu_pct_per_session"), "%")
        ev = t.get("events") or {}
        one(p + "lost_or_duplicated", (ev.get("lost") or 0) + (ev.get("duplicated") or 0), "events")
    for name, unit in (("controller_rss_mb_per_session", "MB"), ("controller_cpu_pct_per_session", "%")):
        v = _get(fanin, "slope_per_1000_sessions", name)
        if isinstance(v, (int, float)):
            one(f"fanin.slope.{name.replace('controller_cpu', 'controller_life_cpu')}_per_ksession", max(v, 0.0), unit)
    return out


def _get(obj, *keys):
    for k in keys:
        if not isinstance(obj, dict):
            return None
        obj = obj.get(k)
    return obj


class CoordSim(Bench):
    name = "coord-sim"
    summary = "Several synthetic coordinator chats at once into acpmux on Linux: delivery, loss, attach, memory slope"
    units = "ms, events, MB, MB/min, %"
    owner = "perf (coord-sim)"
    hosts = ("fleet",)
    harness = HARNESS
    version = "1"
    thresholds = {"delivery_ms": 15.0, "attach_ms": 15.0}
    floors = {"events.lost": 0.5, "events.duplicated": 0.5, "daemon.rss_slope_mb_per_min": 1.0,
              "daemon.peak_rss_mb": 5.0, "per_chat.rss_mb": 1.0, "daemon.cpu_pct": 5.0, "per_chat.cpu_pct": 2.0,
              "scroll.over_33ms": 2.0}

    def run(self, ctx: Context) -> None:
        args = [f"{k}={v}" for k, v in ctx.args.items() if k in PASS_THROUGH]
        out = ctx.workdir / "artifact"
        command = f"set -o pipefail; {HARNESS} {shlex.join(args)}"
        cmd = ["cmux-ci", "test", "--setup", "rust", "--timeout", "3600", "--artifact", str(out), "--",
               "bash", "-c", command]
        if ctx.dry_run:
            print("dry run:", shlex.join(cmd))
            raise BenchError("dry run")
        log = ctx.workdir / "coord-sim.log"
        with log.open("w", encoding="utf-8") as f:
            subprocess.run(cmd, stdout=f, stderr=subprocess.STDOUT, text=True, check=False)
        ctx.host.update({"name": "linux-ci", "os": "Linux"})
        report = out / "coord-sim" / "report.json"
        self.ingest(ctx, report if report.exists() else log)

    def ingest(self, ctx: Context, path: Path) -> None:
        path = Path(path)
        if path.is_dir():
            path = path / "report.json"
        text = path.read_text(encoding="utf-8", errors="replace")
        report, rows = None, None
        try:
            whole = json.loads(text)
        except json.JSONDecodeError:
            whole = None
        if isinstance(whole, dict) and whole.get("schema") == "coord-sim-run.v1":
            report = whole
        else:
            for raw in text.splitlines():
                line = STAMP.sub("", raw.strip())
                if not line.startswith("{"):
                    continue
                try:
                    value = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if isinstance(value, dict) and value.get("schema") == "coord-sim-run.v1":
                    report = value
                elif isinstance(value, dict) and isinstance(value.get("rows"), list):
                    rows = value["rows"]
        if report is None and rows is None:
            raise BenchError(f"{path}: no coord-sim-run.v1 report and no rows line (not a coord-sim-linux.sh log?)")
        if rows is None:
            rows = rows_of_report(report or {})
        cfg = (report or {}).get("config") or {}
        labels = {k: cfg[k] for k in ("coordinators", "rate") if cfg.get(k) is not None}
        if not rows:
            ctx.notes.append("coord-sim: the report has no value (did the driver write events, ops and proc?)")
        for r in rows:
            name = str(r.get("name") or "")
            if not name.startswith(PREFIX) or not isinstance(r.get("p95"), (int, float)):
                continue
            unit = str(r.get("unit") or "ms")
            ctx.row(name[len(PREFIX):], r.get("p50", r["p95"]), UNITS.get(unit, unit), p50=r.get("p50"),
                    p95=r["p95"], labels=labels)


BENCH = CoordSim()
