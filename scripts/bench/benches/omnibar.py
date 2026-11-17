"""omnibar: omnibar Enter to first paint in a tagged cmux NEXT Debug app, cold and prerendered.

Wraps scripts/measure/omnibar-preload.py, which runs on a Mac with a GUI session next to the app (cmux-lawrence-2
for Lawrence's captures): it teaches Chrome's AutocompleteActionPredictor each URL (3 hits), then per round
types the same text and waits for the predictor's prerender before Return (arm=prerendered), and types the URL
with a fresh query that has no hit (arm=cold). Enter is the wall clock before Return; paint is the page's
`timeOrigin + max(FCP, activationStart)`.

That host is not a controller worker, so this bench records the harness's output:
`cmux-bench omnibar --import omnibar-preload.json` (or the run's log, from its `OMNIBAR` line: medians only).

Rows: enter_to_fcp_ms (labels arm, url; and arm alone over every URL), prerender_activated and prerender_tried.
"""
from __future__ import annotations

import json
from pathlib import Path

from benchlib.bench import Bench, BenchError, Context

HARNESS = "scripts/measure/omnibar-preload.py"


class Omnibar(Bench):
    name = "omnibar"
    summary = "Omnibar Enter to first contentful paint, cold vs predictor-prerendered (cmux NEXT Debug app)"
    units = "ms, count"
    owner = "omnibar preloading (cmux#43714, cef#38)"
    hosts = ("anywhere",)
    harness = HARNESS
    version = "1"
    floors = {"enter_to_fcp_ms": 5.0}

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
        for arm in ("cold", "prerendered"):
            cell = summary.get(arm) or {}
            if cell.get("median_ms") is not None:
                ctx.row("enter_to_fcp_ms", cell["median_ms"], "ms", p50=cell["median_ms"], n=cell.get("n"),
                        labels={"arm": arm})
        self._counts(ctx, summary.get("prerender_activated"), summary.get("prerender_tried"))
        ctx.notes.append("omnibar: read from the OMNIBAR line (medians only)")

    def _samples(self, ctx: Context, samples: list[dict]) -> None:
        def good(s: dict) -> bool:
            return s.get("enter_to_fcp_ms") is not None and (s.get("arm") == "cold" or s.get("activated"))
        for arm in ("cold", "prerendered"):
            sel = [s for s in samples if s.get("arm") == arm and good(s)]
            ctx.row("enter_to_fcp_ms", unit="ms", samples=[s["enter_to_fcp_ms"] for s in sel], labels={"arm": arm})
            for url in sorted({s.get("url") for s in sel}):
                ctx.row("enter_to_fcp_ms", unit="ms", samples=[s["enter_to_fcp_ms"] for s in sel if s.get("url") == url],
                        labels={"arm": arm, "url": url})
        pre = [s for s in samples if s.get("arm") == "prerendered"]
        self._counts(ctx, sum(bool(s.get("activated")) for s in pre), len(pre))

    def _counts(self, ctx: Context, activated, tried) -> None:
        if tried is not None:
            ctx.row("prerender_activated", activated or 0, "count", better="higher")
            ctx.row("prerender_tried", tried, "count", better="none")


BENCH = Omnibar()
