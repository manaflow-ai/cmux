"""snappy: an agent chat's answer to the Enter key, plain and under duress, on a fleet Mac or from a live app's perf watch.

Leo 2026-11-25: "when you press enter, the stuff should just start playing. we dont need to wait/get blocked by
anything on rendering." Wraps scripts/measure/snappy-bench.sh (a tagged app on the page's in-page mock; its probe is
webviews/bench/snappy-probe.js). It writes snappy.json (schema snappy-bench/v1): one report per duress (none,
long-session, many-tabs, offline), each with its rows.
Rows (better = lower unless named), labels duress, surface (local, cloud) and mode (active: the driver; passive: a
live app's perf watch):
  send_paint (ms, p50/p95)          Enter keydown to the frame that paints the sent row; target 16
  reserved_same_frame (%, higher)   the assistant's reserved turn painted in that frame; target 100
  shifts_per_send (count, p95 = max) layout shifts from the keydown to the first token; target 0
  send_first_token (ms)              Enter keydown to the first reply text
  chat_switch_paint (ms)             a chat turning visible to its first frame with rows; target 16
  failed_sends (count)
  shifts_per_transition (count, p95 = max)  one counter of layout shifts over every turn transition: each send, each
                                     mid-turn send (a steer or a queued prompt), each /compact, each prompt sent mid-compaction; target 0
  shifts_per_mid_turn, shifts_per_compaction, shifts_per_mid_compaction (count)  its kinds apart
Run: `cmux-bench snappy --host fleet [--arg ref=SHA] [--arg duress=none,offline] [--arg sends=12] [--arg cpu_load=1]`.
`--import PATH` reads a snappy.json, or the JSON line `snappy-bench.py --summarize ~/.acpmux/perf-watch.jsonl` prints
(the passive reading of a NIGHTLY with `acpmux perf on`, local and cloud).
"""
from __future__ import annotations

import json
from pathlib import Path

from benchlib.bench import Bench, BenchError, Context

HARNESS = "scripts/measure/snappy-bench.sh"
ARTIFACT = "snappy-bench.tar"


def reports_of(text: str) -> list[dict]:
    for line in reversed([text] + text.splitlines()):
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            data = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(data, dict) and str(data.get("schema", "")).startswith("snappy-bench/"):
            return [r for r in data.get("reports") or [] if isinstance(r, dict)]
    return []


class Snappy(Bench):
    name = "snappy"
    summary = "Agent chat Enter to sent-row paint, reserved turn in the same frame, shifts per send, first token, chat switch"
    units = "ms, %, count"
    owner = "snappy"
    hosts = ("fleet",)
    harness = HARNESS
    version = "1"
    nightly = False

    def run(self, ctx: Context) -> None:
        args = ["--config=bench", "--vdisplay=120"]
        for key in ("duress", "sends", "switches", "tabs"):
            if ctx.arg(key):
                args.append(f"--{key}={ctx.arg(key)}")
        if ctx.arg("cpu_load") == "1":
            args.append("--cpu-load")
        res = ctx.fleet_step(HARNESS, args, ARTIFACT, step_class="exclusive", labels=("measure", "gui-session-v1"),
                             timeout=3600, display=True)
        self.ingest(ctx, res.log_path)

    def ingest(self, ctx: Context, path: Path) -> None:
        reports = reports_of(Path(path).read_text(encoding="utf-8", errors="replace"))
        if not reports:
            raise BenchError(f"{path}: no snappy-bench/v1 report (a snappy.json, or snappy-bench.py --summarize's line)")
        for report in reports:
            r = report.get("rows") or {}
            labels = {"duress": report.get("duress"), "surface": report.get("surface"), "mode": report.get("mode")}
            n = r.get("sends")
            pairs = (("send_paint", "send_paint", "ms"), ("send_first_token", "send_first_token", "ms"),
                     ("chat_switch_paint", "chat_switch_paint", "ms"))
            for metric, key, unit in pairs:
                p50, p95 = r.get(f"{key}_p50_ms"), r.get(f"{key}_p95_ms")
                if p50 is not None:
                    ctx.row(metric, p50, unit, p50=p50, p95=p95, n=n, labels=labels)
            if r.get("reserved_same_frame_share") is not None:
                ctx.row("reserved_same_frame", round(r["reserved_same_frame_share"] * 100, 1), "%", better="higher", n=n, labels=labels)
            if r.get("shifts_per_send_mean") is not None:
                ctx.row("shifts_per_send", r["shifts_per_send_mean"], "count", p50=r["shifts_per_send_mean"],
                        p95=r.get("shifts_per_send_max"), n=n, labels=labels)
            ctx.row("failed_sends", float(r.get("failed_sends") or 0), "count", n=n, labels=labels)
            if r.get("shifts_per_transition_mean") is not None:
                t = r.get("transitions")
                ctx.row("shifts_per_transition", r["shifts_per_transition_mean"], "count",
                        p50=r["shifts_per_transition_mean"], p95=r.get("shifts_per_transition_max"), n=t, labels=labels)
                for kind in ("mid_turn", "compaction", "mid_compaction"):
                    if r.get(f"shifts_per_{kind}_mean") is not None:
                        ctx.row(f"shifts_per_{kind}", r[f"shifts_per_{kind}_mean"], "count", n=t, labels=labels)
                ctx.row("failed_transitions", float(r.get("failed_transitions") or 0), "count", n=t, labels=labels)


BENCH = Snappy()
