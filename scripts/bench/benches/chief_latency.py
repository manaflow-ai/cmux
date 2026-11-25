"""chief-latency: a scratch Chief's tokens, first token and turn time at two refs, with a real model.

Wraps scripts/measure/chief-latency.sh (the Chief latency lane's harness; shared plan "Chief turns are slow and
large", 2026-11-23): on one fleet Mac it builds acpmux, optchat-chief and cmux-tui at `before` and `after`, then
runs the 15 asks of Native/OptChat/optchat-chief/measure/scenario.py's `latency` scenario on a new scratch Chief per
round, alternating the refs, and reads the host's trace with measure/chief_latency.py. Lines it reads:

  CHIEF-LAT-SUMMARY {"label": "before"|"after", "ref": SHA, "first_request_tokens": {"p50": ..}, ...}

One run holds one side, so `cmux-bench compare` matches the two sides row by row: the run's side is
`--arg side=before|after` (default: after when the log has it). Import one log once per side:
  cmux-bench chief-latency --import LOG --build BASE --arg side=before
  cmux-bench chief-latency --import LOG --build HEAD --arg side=after
The harness prints its own before/after markdown table too (chief_latency.py compare), for a PR body.

Rows, better = lower: first_request_tokens, first_request_tokens.p90, request_tokens (count of tokens: input +
cache read + cache write), requests_per_turn, ttft, ttft.warm, ttft.cold, turn, turn.p90, felt_first_reply,
felt_last_reply, felt_last_reply.p90 (ms), cold_share (%, turns whose first request wrote more cache than it
read), host_started_turns, refused_sends (count). The cost is a note.

Run: `cmux-bench chief-latency --host fleet --arg ref=HARNESS_SHA --arg before=BASE_SHA --arg after=HEAD_SHA`
(base_url defaults to SR2, the team route that signs requests itself).
"""
from __future__ import annotations

import json
import subprocess
from pathlib import Path

from benchlib.bench import Bench, BenchError, Context

HARNESS = "scripts/measure/chief-latency.sh"
SR2 = "http://100.120.48.119:4016"
PASS_THROUGH = ("before", "after", "base_url", "rounds", "harness", "model", "effort", "only", "claude")
MARK = "CHIEF-LAT-SUMMARY "
# (row, summary key, statistic, unit)
ROWS = (
    ("first_request_tokens", "first_request_tokens", "p50", "count"),
    ("first_request_tokens.p90", "first_request_tokens", "p90", "count"),
    ("request_tokens", "request_tokens", "p50", "count"),
    ("requests_per_turn", "requests_per_turn", "mean", "count"),
    ("ttft", "ttft_ms", "p50", "ms"),
    ("ttft.warm", "ttft_ms_warm", "p50", "ms"),
    ("ttft.cold", "ttft_ms_cold", "p50", "ms"),
    ("turn", "turn_ms", "p50", "ms"),
    ("turn.p90", "turn_ms", "p90", "ms"),
    ("felt_first_reply", "felt_first_reply_ms", "p50", "ms"),
    ("felt_last_reply", "felt_last_reply_ms", "p50", "ms"),
    ("felt_last_reply.p90", "felt_last_reply_ms", "p90", "ms"),
)
COUNTS = (("host_started_turns", "count"), ("refused_sends", "count"))


def summaries(text: str) -> dict[str, dict]:
    out = {}
    for line in text.splitlines():
        at = line.find(MARK)
        if at < 0:
            continue
        try:
            s = json.loads(line[at + len(MARK):])
        except json.JSONDecodeError:
            continue
        if isinstance(s, dict) and s.get("label"):
            out[s["label"]] = s
    return out


class ChiefLatency(Bench):
    name = "chief-latency"
    summary = "Scratch Chief at two refs, real model, 15 typical asks: input tokens per request, first token, turn p50/p90, cold share"
    units = "count (tokens), ms, %"
    owner = "chief-latency lane"
    hosts = ("fleet",)
    harness = HARNESS
    version = "1"
    nightly = False

    def run(self, ctx: Context) -> None:
        if not ctx.arg("before"):
            raise BenchError("chief-latency: name the refs (--arg before=SHA [--arg after=SHA], full SHAs)")
        args = {"base_url": SR2} | {k: v for k, v in ctx.args.items() if k in PASS_THROUGH}
        res = ctx.fleet_step(HARNESS, [f"{k}={v}" for k, v in args.items()], None, step_class="exclusive",
                             labels=("measure",), timeout=10800)
        log = res.log_path
        if MARK not in res.log and res.job_id:
            full = ctx.workdir / f"{res.job_id}.log"
            got = subprocess.run(["cmux-ci", "log", res.job_id, "--tail", "200000"], text=True, capture_output=True)
            if got.returncode == 0:
                full.write_text(got.stdout)
                log = full
        self.ingest(ctx, log)

    def ingest(self, ctx: Context, path: Path) -> None:
        found = summaries(Path(path).read_text(encoding="utf-8", errors="replace"))
        if not found:
            raise BenchError(f"{path}: no {MARK.strip()} line (not a chief-latency.sh log, or every round failed)")
        side = ctx.arg("side") or ("after" if "after" in found else "before")
        if side not in found:
            raise BenchError(f"{path}: no {side} side (it has {', '.join(sorted(found))})")
        s = found[side]
        n = s.get("chief_turns")
        for row, key, stat, unit in ROWS:
            v = (s.get(key) or {}).get(stat)
            if v is not None:
                ctx.row(row, float(v), unit, n=(s.get(key) or {}).get("n") or n)
        if s.get("cold_share") is not None:
            ctx.row("cold_share", round(100 * float(s["cold_share"]), 1), "%", n=n)
        for key, unit in COUNTS:
            if s.get(key) is not None:
                ctx.row(key, float(s[key]), unit, n=n)
        if s.get("cost_usd") is not None:
            ctx.notes.append(f"chief-latency: {side} Chief turns cost ${s['cost_usd']:.2f} (API-equivalent)")
        if s.get("asks_timed_out"):
            ctx.notes.append(f"chief-latency: {s['asks_timed_out']} of {s.get('asks')} asks timed out ({side})")
        ctx.notes.append(f"chief-latency: {side} ref {s.get('ref')}, asks correct {s.get('asks_correct')}/{s.get('asks_checked')}")


BENCH = ChiefLatency()
