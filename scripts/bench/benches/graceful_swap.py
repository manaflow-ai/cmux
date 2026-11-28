"""graceful-swap: what an open page shows when the web it runs changes (a layer swap, a web-dev overlay, a web update).

Wraps scripts/measure/graceful-swap.py, which films a capture Mac's display (Cua Driver, 30 fps), runs the swap's
trigger there mid-film and compares every frame after it with the regions' pictures before and at the end. A swap
of the SAME web must look like nothing happened (Leo 2026-11-22: "no shift, no anything, just... ok now it
changed"). It prints `GRACEFUL_SWAP {json}` and writes run.json.

Rows per region (labels region=NAME, trigger=KIND): transient_frames, blank_frames (count, lower), shift_px (px,
lower), lost (count: 1 when the end picture is not the before picture, a lost draft or scroll), settled_ms (ms).
Per in-page probe record (labels page=ID): probe_lost (count: composer text, selection, focus, attachments or
scroll not kept), probe_restored_ms (trigger to the restored first frame), probe_layout_shift (CLS sum, x1000).

A latency receipt (`graceful-swap.py latency --surface S`, GRACEFUL_SWAP_LATENCY) records the goal hot-swap-fast's
rows: hot_swap_mac_focused_pane_p95_ms, hot_swap_mac_unfocused_pane_p95_ms, hot_swap_mac_hidden_tab_p95_ms (save to
the first changed frame of the watched region; p50 and n beside it; labels drafts_kept = runs every other region
kept its picture / runs, bar_ms = the surface's bar: 150, 300, 100 ms).

Run: --arg capture_host=air-blue --arg trigger='CMD' [--arg region='NAME=x,y,w,h;NAME=...'] [--arg kind=overlay]
[--arg probe_file=PATH]. `--import run.json` (or a log with the line) records a run already made.
"""
from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path

from benchlib.bench import Bench, BenchError, Context

HARNESS = "scripts/measure/graceful-swap.py"
LINE = re.compile(r"GRACEFUL_SWAP (\{.*\})\s*$")
LATENCY_LINE = re.compile(r"GRACEFUL_SWAP_LATENCY (\{.*\})\s*$")
# The goal hot-swap-fast's bars per surface (Leo 11-15: "case by case"): {surface: (row key, bar ms)}.
LATENCY_ROWS = {"focused": ("hot_swap_mac_focused_pane_p95_ms", 150),
                "unfocused": ("hot_swap_mac_unfocused_pane_p95_ms", 300),
                "hidden": ("hot_swap_mac_hidden_tab_p95_ms", 100)}
ROOT = Path(__file__).resolve().parents[3]


class GracefulSwap(Bench):
    name = "graceful-swap"
    summary = "Web bundle swap on open pages: transient/blank frames, shift, drafts kept (capture Mac)"
    units = "count, px, ms"
    owner = "graceful web swap (desktop-leo web owner)"
    hosts = ("anywhere",)
    harness = HARNESS
    version = "1"
    nightly = False

    def run(self, ctx: Context) -> None:
        host, trigger = ctx.arg("capture_host"), ctx.arg("trigger")
        if not host or not trigger:
            raise BenchError("graceful-swap: needs --arg capture_host=HOST --arg trigger='CMD'")
        out = ctx.workdir / "graceful-swap"
        cmd = [sys.executable, str(ROOT / HARNESS), "record", "--host", host, "--trigger", trigger, "--out", str(out),
               "--label", ctx.arg("kind", "swap")]
        for region in filter(None, (ctx.arg("region") or "").split(";")):
            cmd += ["--region", region]
        if ctx.arg("probe_file"):
            cmd += ["--probe-file", ctx.arg("probe_file")]
        done = subprocess.run(cmd, text=True, capture_output=True)
        if done.returncode:
            raise BenchError(f"graceful-swap: harness failed: {done.stderr.strip()[-600:]}")
        self.ingest(ctx, out / "run.json")

    @staticmethod
    def receipt(path: Path) -> dict:
        text = Path(path).read_text(encoding="utf-8", errors="replace")
        try:
            whole = json.loads(text)
            if isinstance(whole, dict) and "regions" in whole:
                return whole
        except ValueError:
            pass
        found = None
        for line in text.splitlines():
            if m := LATENCY_LINE.search(line) or LINE.search(line):
                found = json.loads(m.group(1))
        if not isinstance(found, dict):
            raise BenchError(f"{path}: no GRACEFUL_SWAP receipt")
        return found

    def ingest(self, ctx: Context, path: Path) -> None:
        receipt = self.receipt(path)
        if "watch" in receipt:
            return self.ingest_latency(ctx, receipt, path)
        kind = receipt.get("label") or "swap"
        for region, r in (receipt.get("regions") or {}).items():
            if "error" in r:
                continue
            labels = {"region": region, "trigger": kind}
            ctx.row("transient_frames", float(r["transient_frames"]), "count", labels=labels)
            ctx.row("blank_frames", float(r["blank_frames"]), "count", labels=labels)
            ctx.row("shift_px", float(abs(r["shift_px"])), "px", labels=labels)
            ctx.row("lost", 0.0 if r["kept"] else 1.0, "count", labels=labels)
            ctx.row("settled_ms", float(r["settled_ms"] or 0), "ms", labels=labels)
        for probe in receipt.get("probe") or []:
            labels = {"page": str(probe.get("page", "?")), "trigger": kind}
            lost = sum(1 for key in ("text", "selection", "focus", "attachments", "scroll")
                       if probe.get("kept_" + key) is False)
            ctx.row("probe_lost", float(lost), "count", labels=labels)
            if probe.get("restored_ms") is not None:
                ctx.row("probe_restored_ms", float(probe["restored_ms"]), "ms", labels=labels)
            if probe.get("layout_shift") is not None:
                ctx.row("probe_layout_shift", float(probe["layout_shift"]) * 1000, "count", labels=labels)
        if not ctx.rows:
            raise BenchError(f"{path}: the receipt has no numbers")
        if not receipt.get("ok"):
            ctx.notes.append("not imperceptible: a region showed a transient or blank frame, shifted or lost state")

    @staticmethod
    def ingest_latency(ctx: Context, receipt: dict, path: Path) -> None:
        surface = receipt.get("surface")
        if surface not in LATENCY_ROWS:
            raise BenchError(f"{path}: a latency receipt needs its surface (graceful-swap.py latency --surface)")
        key, bar = LATENCY_ROWS[surface]
        regions = receipt.get("regions") or {}
        watched = regions.get(receipt["watch"]) or {}
        samples = [float(v) for v in watched.get("samples_ms") or []]
        if not samples:
            raise BenchError(f"{path}: the watched region {receipt['watch']!r} never changed")
        others = [r for name, r in regions.items() if name != receipt["watch"]]
        runs = int(receipt.get("runs") or len(samples))
        missed = int(watched.get("missed") or 0)
        censored = False
        if missed:
            # A missed run is a save that had not shown when its film ended: its latency is at least the film's
            # window, never "no sample". Dropping it turned 2 fast runs of 20 into a green p95 (cmux 75ef6ec3).
            window = receipt.get("window_ms")
            if not isinstance(window, (int, float)) or window <= 0:
                raise BenchError(f"{path}: {missed} of {runs} runs missed and the receipt has no window_ms to bound "
                                 "them; a p95 of the runs that showed is not a p95 (recapture with a harness that "
                                 "writes window_ms)")
            bounded = sorted(samples + [float(window)] * missed)
            p50_v, p95_v = (bounded[max(1, -(-len(bounded) * q // 100)) - 1] for q in (50, 95))
            censored = p95_v >= window
        kept = min((int(r.get("kept", 0)) for r in others), default=runs)
        transient = sum(int(r.get("transient_frames", 0)) for r in others)
        labels = {"surface": surface, "watch": receipt["watch"], "trigger": receipt.get("label") or "latency",
                  "drafts_kept": f"{kept}/{runs}", "transient_frames": transient, "bar_ms": bar,
                  "missed": missed}
        if missed:
            p50, p95 = float(p50_v), float(p95_v)
            labels["censored"] = censored  # true: the p95 is the window, a lower bound ("over window_ms")
        else:
            p50, p95 = float(watched["p50_ms"]), float(watched["p95_ms"])
        ctx.row(key, p95, "ms", p50=p50, p95=p95, n=len(samples) + missed, labels=labels)
        if p95 > bar or kept < runs or transient or censored:
            over = "over " if censored else ""
            ctx.notes.append(f"{key}: p95 {over}{p95:.0f} ms against {bar} ms ({missed}/{runs} runs missed the "
                             f"window), drafts kept {kept}/{runs}, {transient} transient frames")


BENCH = GracefulSwap()
