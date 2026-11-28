"""web-vitals: a web page's TTFB, LCP, INP and JS kB, under one throttled Chromium.

  --arg urls=URL1,URL2     the pages to load (cmux.com, docs, a built webview page served locally)
  --arg runs=N             cold loads per page (default 5); rows carry every load as samples
  --arg interact=SELECTOR  the controls scripted clicks use for INP (default: buttons, tabs, summaries)

The harness is webviews/scripts/web-perf/vitals.mjs (Playwright Chromium from webviews/, 4x CPU slowdown,
10 Mbps / 40 ms, 412x915). It needs no app: run it through `cmux-ci test -- scripts/bench/cmux-bench
web-vitals --host anywhere --arg urls=...` so before and after come from the same Linux machine.

Rows, one set per page (labels url=<url>): ttfb, lcp, inp (ms), js_wire, js_decoded (KB), js_files (count).
"""
from __future__ import annotations

import json
import subprocess
import tempfile
from pathlib import Path

from benchlib.bench import REPO_ROOT, Bench, BenchError, Context

HARNESS = REPO_ROOT / "webviews/scripts/web-perf/vitals.mjs"
METRICS = (
    ("ttfb", "ttfb", "ms"),
    ("lcp", "lcp", "ms"),
    ("inp", "inp", "ms"),
    ("js_wire", "jsWireKB", "KB"),
    ("js_decoded", "jsDecodedKB", "KB"),
    ("js_files", "jsFiles", "count"),
)


class WebVitals(Bench):
    name = "web-vitals"
    summary = "A web page's TTFB, LCP, INP and JS kB in throttled Chromium (cmux.com, docs, webviews)"
    units = "ms, KB, count"
    owner = "web perf audit"
    hosts = ("anywhere",)
    harness = "webviews/scripts/web-perf/vitals.mjs"
    version = "1"
    thresholds = {"ttfb": 20.0, "lcp": 10.0, "inp": 20.0, "js_wire": 2.0, "js_decoded": 2.0}
    floors = {"ttfb": 20.0, "lcp": 50.0, "inp": 16.0, "js_wire": 2.0, "js_decoded": 5.0, "js_files": 0}

    def run(self, ctx: Context) -> None:
        urls = [u for u in (ctx.arg("urls") or "").split(",") if u]
        if not urls:
            raise BenchError("web-vitals needs --arg urls=URL1,URL2")
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "vitals.json"
            cmd = ["node", str(HARNESS), "--runs", ctx.arg("runs") or "5", "--out", str(out)]
            if ctx.arg("interact"):
                cmd += ["--interact", ctx.arg("interact")]
            done = subprocess.run(cmd + urls, cwd=REPO_ROOT / "webviews")
            if not out.exists():
                raise BenchError(f"{HARNESS.name} wrote no output (exit {done.returncode})")
            self.ingest(ctx, out)
            if done.returncode != 0:
                raise BenchError(f"{HARNESS.name} exited {done.returncode}: a page collected no sample")

    def ingest(self, ctx: Context, path: Path) -> None:
        data = json.loads(Path(path).read_text(encoding="utf-8"))
        for page in data["results"]:
            labels = {"url": page["url"]}
            samples = page.get("samples") or []
            for metric, key, unit in METRICS:
                if samples:
                    ctx.row(metric, unit=unit, samples=[s.get(key) for s in samples], labels=labels)
                else:
                    ctx.row(metric, page.get(f"{key}Ms", page.get(key)), unit, labels=labels)


BENCH = WebVitals()
