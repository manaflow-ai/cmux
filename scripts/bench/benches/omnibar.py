"""omnibar: omnibar Enter to first paint in a tagged cmux NEXT Debug app, cold and prerendered.

Wraps scripts/measure/omnibar-preload.py, which runs on a Mac with a GUI session next to the app (cmux-lawrence-2
for Lawrence's captures): it teaches Chrome's AutocompleteActionPredictor each URL (3 hits), then per round
types the same text and waits for the predictor's prerender before Return (arm=prerendered); it types the full
URL in a new launch with an empty profile per sample (arm=cold: a first visit). Enter is the wall clock before
Return; paint is the page's `timeOrigin + max(FCP, activationStart)`; navigation is the page's start (a
prerender's activation).

That host is not a controller worker, so this bench records the harness's output:
`cmux-bench omnibar --import omnibar-preload.json` (or the run's log, from its `OMNIBAR` line: medians only).

Rows: enter_to_fcp_ms and enter_to_nav_ms (labels arm, url; and arm alone over every URL), prerender_activated
and prerender_tried. A prerendered sample counts only when its page was activated, a cold one only when it was not.
"""
from __future__ import annotations

import json
from pathlib import Path

from benchlib.bench import Bench, BenchError, Context

HARNESS = "scripts/measure/omnibar-preload.py"
ARMS = ("cold", "prerendered")


class Omnibar(Bench):
    name = "omnibar"
    summary = "Omnibar Enter to first contentful paint, cold vs predictor-prerendered (cmux NEXT Debug app)"
    units = "ms, count"
    owner = "omnibar preloading (cmux#43714, cef#38)"
    hosts = ("anywhere",)
    harness = HARNESS
    version = "1"
    floors = {"enter_to_fcp_ms": 5.0, "enter_to_nav_ms": 5.0}

    def run(self, ctx: Context) -> None:
        raise BenchError(f"omnibar: run {HARNESS} on a Mac with a GUI session (cmux-lawrence-2), then "
                         "`cmux-bench omnibar --import omnibar-preload.json`")

    def ingest(self, ctx: Context, path: Path) -> None:
        text = path.read_text(encoding="utf-8", errors="replace")
        try:
            doc = json.loads(text)
        except ValueError:
            doc = None
        if isinstance(doc, dict) and isinstance(doc.get("samples"), list):
            return self._samples(ctx, doc["samples"])
        lines = [ln for ln in text.splitlines() if ln.startswith("OMNIBAR {")]
        if not lines:
            raise BenchError(f"omnibar: {path}: no omnibar-preload.json document or OMNIBAR line")
        summary = json.loads(lines[-1].split(" ", 1)[1])
        for arm in ARMS:
            cell = summary.get(arm) or {}
            for metric, key in (("enter_to_fcp_ms", "median_ms"), ("enter_to_nav_ms", "nav_median_ms")):
                if cell.get(key) is not None:
                    ctx.row(metric, cell[key], "ms", p50=cell[key], n=cell.get("n"), labels={"arm": arm})
        self._counts(ctx, summary.get("prerender_activated"), summary.get("prerender_tried"))
        ctx.notes.append("omnibar: read from the OMNIBAR line (medians only)")

    def _samples(self, ctx: Context, samples: list[dict]) -> None:
        for metric in ("enter_to_fcp_ms", "enter_to_nav_ms"):
            for arm in ARMS:
                sel = [s for s in samples if s.get("arm") == arm and s.get(metric) is not None
                       and bool(s.get("activated")) == (arm == "prerendered")]
                if not sel:
                    continue
                ctx.row(metric, unit="ms", samples=[s[metric] for s in sel], labels={"arm": arm})
                for url in sorted({s.get("url") for s in sel}):
                    ctx.row(metric, unit="ms", samples=[s[metric] for s in sel if s.get("url") == url],
                            labels={"arm": arm, "url": url})
        pre = [s for s in samples if s.get("arm") == "prerendered"]
        self._counts(ctx, sum(bool(s.get("activated")) for s in pre), len(pre))

    def _counts(self, ctx: Context, activated, tried) -> None:
        if tried is not None:
            ctx.row("prerender_activated", activated or 0, "count", better="higher")
            ctx.row("prerender_tried", tried, "count", better="none")


BENCH = Omnibar()
