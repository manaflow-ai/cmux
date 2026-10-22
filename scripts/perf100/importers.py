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


def _clean(metrics: dict) -> dict:
    """Drops missing and negative values: the chat-load lane writes -1 for a run it did not
    measure, which would pass a max budget. A dropped metric makes its budget FAIL (missing)."""
    return {k: v for k, v in metrics.items() if isinstance(v, (int, float)) and v >= 0}


def _record(variant: str, metrics: dict, host_class: str, sha: str | None, source: str, run_host) -> dict:
    return {"schema": runlib.SCHEMA, "scenario": "chat-load", "variant": variant, "seed": 0,
            "host": {"name": host_class, "class": host_class}, "build": {"tag": None, "sha": sha},
            "params": {"imported_from": source, "run_host": run_host,
                       "run_file_mtime": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(os.path.getmtime(source)))}, "started_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "sources": {"chat-load": "webviews/scripts/agent-pane/chat-load/run.sh (median of its runs)"},
            "phases": {}, "metrics": _clean(metrics),
            "notes": [f"imported by scripts/perf100/importers.py from {source}"], "unverified": []}


class ImportError_(Exception):
    pass


def _load(path: str) -> dict:
    try:
        with open(path) as handle:
            return json.load(handle)
    except (OSError, ValueError) as error:
        raise ImportError_(f"{path}: {error}")


def chat_load(results_dir: str, host_class: str, sha: str | None) -> list[dict]:
    """Raises ImportError_ when daemon.json or page-chromium.json is missing or unreadable, so an
    empty import can never reach the gate as an all-skipped (passing) budget run."""
    records = []
    for required in ("daemon.json", "page-chromium.json"):
        if not os.path.exists(os.path.join(results_dir, required)):
            raise ImportError_(f"{results_dir} has no {required}: not a chat-load run.sh results directory")
    daemon_path = os.path.join(results_dir, "daemon.json")
    daemon = _load(daemon_path)
    run_host = daemon.get("host")
    for s in daemon.get("sessions", []):
        if "turns" not in s:
            continue
        opened, first, scroll = s.get("open") or {}, s.get("first_open") or {}, s.get("scroll_to_first") or {}
        records.append(_record(f"daemon-{s['turns']}", {
            "open_read_mb": opened.get("read_mb"), "open_wall_ms": opened.get("wall_ms"),
            "first_open_wall_ms": first.get("wall_ms"), "scroll_read_mb": scroll.get("read_mb"),
            "scroll_wall_ms": scroll.get("wall_ms"), "scroll_cpu_ms": scroll.get("cpu_ms"),
        }, host_class, sha, daemon_path, run_host))
    for engine in ("chromium", "webkit"):
        path = os.path.join(results_dir, f"page-{engine}.json")
        if not os.path.exists(path):
            continue
        page = _load(path)
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
                }, host_class, sha, path, run_host))
    if not records:
        raise ImportError_(f"{results_dir}: no sessions with a turn count")
    return records
