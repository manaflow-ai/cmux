"""storm-gui: a 429 storm on a published cmux NEXT app's own chat pane: delivered, lost, duplicated, stuck busy.

Wraps scripts/measure/acpmux-429-storm-gui.sh (scripts/measure/acpmux-429-storm-gui.py, the storm of
scripts/cmux-next/acpmux_429_storm.py): the app copy from a fresh home, a coordinator chat whose Claude Code talks to
a local fake endpoint that answers 429 for `storm` seconds, `agents` senders each `acpmux send` one report every
`interval` seconds, the window shot and read while it runs. It prints one line per run:

  STORM-GUI row label=L sent=N reached_model=N lost=N duplicated=N model_requests_in_storm=N
      first_reply_after_lift_s=S pane_once=N pane_missing=N pane_duplicated=N stuck_busy_at_end=B
      stuck_busy_for_s=S notice_seen=B busy_after_lift_until_s=S

Rows (better = lower), label retry_after: lost, duplicated, pane_missing, pane_duplicated (count),
model_requests_in_storm (count), first_reply_after_lift (s), stuck_busy_for (s), busy_after_lift (s); and
notice_missing (1 when no rate-limit notice was read on screen, else 0).

The build is the published app: --build nightly (app=nightly) or --arg app=https://...dmg. Harness args pass
through: --arg storm=600 --arg retry_after=60 ...
"""
from __future__ import annotations

import re
import subprocess
from pathlib import Path

from benchlib.bench import Bench, BenchError, Context

HARNESS = "scripts/measure/acpmux-429-storm-gui.sh"
PASS_THROUGH = ("app", "agents", "interval", "storm", "retry_after", "settle", "quiet", "shot_every", "after", "claude")
FIELD = re.compile(r"(\w+)=(\S+)")
ROW = re.compile(r"STORM-GUI row (.*)$")
MACHINE = re.compile(r"STORM-GUI-MACHINE (.*)$")
METRICS = (("lost", "lost", "count"), ("duplicated", "duplicated", "count"), ("pane_missing", "pane_missing", "count"),
           ("pane_duplicated", "pane_duplicated", "count"), ("model_requests_in_storm", "model_requests_in_storm", "count"),
           ("first_reply_after_lift", "first_reply_after_lift_s", "s"), ("stuck_busy_for", "stuck_busy_for_s", "s"),
           ("busy_after_lift", "busy_after_lift_until_s", "s"))


def _num(fields: dict[str, str], key: str) -> float | None:
    try:
        return float(fields[key])
    except (KeyError, ValueError):  # missing or None
        return None


class StormGui(Bench):
    name = "storm-gui"
    summary = "429 storm on a published cmux NEXT app's chat pane: messages lost or doubled, stuck busy, the notice"
    units = "count, s"
    owner = "gui-429-finish"
    hosts = ("fleet",)
    harness = HARNESS
    version = "1"
    thresholds = {"lost": 0.0, "duplicated": 0.0, "pane_missing": 0.0, "pane_duplicated": 0.0}
    nightly = False

    def harness_args(self, ctx: Context) -> list[str]:
        args = {k: v for k, v in ctx.args.items() if k in PASS_THROUGH}
        if "app" not in args:
            if ctx.build.get("channel") != "nightly":
                raise BenchError("storm-gui: measures a published app; pass --build nightly or --arg app=https://...dmg")
            args["app"] = "nightly"
        return [f"{k}={v}" for k, v in args.items()]

    def run(self, ctx: Context) -> None:
        res = ctx.fleet_step(self.harness, self.harness_args(ctx), None, step_class="exclusive",
                             labels=("measure", "gui-session-v1"), timeout=3600)
        log = res.log_path
        if "STORM-GUI row" not in res.log and res.job_id:
            full = ctx.workdir / f"{res.job_id}.log"
            got = subprocess.run(["cmux-ci", "log", res.job_id, "--tail", "200000"], text=True, capture_output=True)
            if got.returncode == 0:
                full.write_text(got.stdout)
                log = full
        self.ingest(ctx, log)

    def ingest(self, ctx: Context, path: Path) -> None:
        found = 0
        for line in Path(path).read_text(encoding="utf-8", errors="replace").splitlines():
            if m := MACHINE.search(line):
                f = dict(FIELD.findall(m.group(1)))
                if f.get("host"):
                    ctx.host.update({"name": f["host"], "role": "fleet"})
                continue
            if not (m := ROW.search(line)):
                continue
            f = dict(FIELD.findall(m.group(1)))
            labels = {"retry_after": f.get("label", "?").rsplit("-", 1)[-1]}
            for metric, key, unit in METRICS:
                v = _num(f, key)
                if v is not None:
                    ctx.row(metric, v, unit, labels=labels)
            if f.get("notice_seen") in ("True", "False"):
                ctx.row("notice_missing", 0.0 if f["notice_seen"] == "True" else 1.0, "count", labels=labels)
            found += 1
        if not found:
            raise BenchError(f"{path}: no STORM-GUI row (not an acpmux-429-storm-gui.sh log?)")


BENCH = StormGui()
