"""Import results of other lanes' benchmarks as perf100.run.v1 records, so the budget gate
(`perf100.py budget`) can check them.

chat-load: the output directory of webviews/scripts/agent-pane/chat-load/run.sh (daemon.json,
page-chromium.json, page-webkit.json). It makes one record per variant:

  daemon-<turns>            open_read_mb, open_wall_ms, first_open_wall_ms, scroll_read_mb,
                            scroll_wall_ms, scroll_cpu_ms (acpmux over its real socket)
  real-<turns>-<engine>     first_paint_ms, interactive_ms, heap_mb, dom_nodes, bytes_in,
                            scroll_to_first_ms (the shipped pane bundle on a real acpmux session)
  mock-<turns>-<engine>     first_paint_ms, interactive_ms, heap_mb, dom_nodes, seed_ms,
                            scroll_to_first_ms (the in-page mock daemon)
"""
from __future__ import annotations

import json
import os
import time

import runlib


def _record(variant: str, metrics: dict, host_class: str, sha: str | None, source: str) -> dict:
    return {"schema": runlib.SCHEMA, "scenario": "chat-load", "variant": variant, "seed": 0,
            "host": {"name": host_class, "class": host_class}, "build": {"tag": None, "sha": sha},
            "params": {"imported_from": source}, "started_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "sources": {"chat-load": "webviews/scripts/agent-pane/chat-load/run.sh (median of its runs)"},
            "phases": {}, "metrics": {k: v for k, v in metrics.items() if v is not None},
            "notes": [f"imported by scripts/perf100/importers.py from {source}"], "unverified": []}


def chat_load(results_dir: str, host_class: str, sha: str | None) -> list[dict]:
    records = []
    daemon_path = os.path.join(results_dir, "daemon.json")
    if os.path.exists(daemon_path):
        with open(daemon_path) as handle:
            daemon = json.load(handle)
        for s in daemon.get("sessions", []):
            opened, first, scroll = s.get("open") or {}, s.get("first_open") or {}, s.get("scroll_to_first") or {}
            records.append(_record(f"daemon-{s['turns']}", {
                "open_read_mb": opened.get("read_mb"), "open_wall_ms": opened.get("wall_ms"),
                "first_open_wall_ms": first.get("wall_ms"), "scroll_read_mb": scroll.get("read_mb"),
                "scroll_wall_ms": scroll.get("wall_ms"), "scroll_cpu_ms": scroll.get("cpu_ms"),
            }, host_class, sha, daemon_path))
    for engine in ("chromium", "webkit"):
        path = os.path.join(results_dir, f"page-{engine}.json")
        if not os.path.exists(path):
            continue
        with open(path) as handle:
            page = json.load(handle)
        for kind, rows in (("real", page.get("sessions", [])), ("mock", page.get("mock", []))):
            for s in rows:
                if "turns" not in s:
                    continue  # the mock's default chat: no turn count, no budget
                median = s.get("median") or {}
                scroll = s.get("scroll") or {}
                records.append(_record(f"{kind}-{s['turns']}-{engine}", {
                    "first_paint_ms": median.get("first_paint_ms"), "interactive_ms": median.get("interactive_ms"),
                    "heap_mb": median.get("heap_mb"), "dom_nodes": median.get("dom_nodes"),
                    "bytes_in": median.get("bytes_in"), "seed_ms": median.get("seed_ms"),
                    "scroll_to_first_ms": scroll.get("ms") if scroll.get("found") else None,
                }, host_class, sha, path))
    return records
