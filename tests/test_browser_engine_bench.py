#!/usr/bin/env python3
"""Pure-logic checks for scripts/perf/browser_engine_bench.py (runs on Linux CI)."""
from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "perf" / "browser_engine_bench.py"
spec = importlib.util.spec_from_file_location("browser_engine_bench", SCRIPT)
assert spec is not None and spec.loader is not None
bench = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bench)

APP = "/tmp/apps/cmux DEV perf.app"


def test_classify_separates_engines_from_app_processes() -> None:
    webkit = "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent"
    renderer = f"{APP}/Contents/Frameworks/cmux Helper (Renderer).app/Contents/MacOS/cmux Helper (Renderer)"
    gpu = f"{APP}/Contents/Frameworks/cmux Helper (GPU).app/Contents/MacOS/cmux Helper (GPU)"
    worker = f"{APP}/Contents/Resources/bin/cmux-paste-text-worker"
    assert bench.classify(webkit, APP) == "webkit"
    assert bench.classify(renderer, APP) == "chromium"
    assert bench.classify(gpu, APP) == "chromium"
    assert bench.classify(worker, APP) == "app_aux"
    assert bench.classify("/bin/zsh", APP) == "other"
    # Another app's Chromium helpers never count against this bundle.
    other_helper = "/Applications/Other.app/Contents/Frameworks/Other Helper.app/Contents/MacOS/Other Helper"
    assert bench.classify(other_helper, APP) == "other"


def test_stats_percentiles_interpolate() -> None:
    result = bench.stats([1.0, 2.0, 3.0, 4.0, 5.0])
    assert result["n"] == 5
    assert result["p50"] == 3.0
    assert result["p95"] == 4.8
    assert result["max"] == 5.0
    assert bench.stats([]) == {}


def test_open_params_are_scoped_per_engine() -> None:
    parsed = bench.parse_open_params(["chromium:engine=chromium", "chromium:focus=true", "webkit:profile=Work"])
    assert parsed == {"chromium": {"engine": "chromium", "focus": True}, "webkit": {"profile": "Work"}}


def test_untagged_bundle_is_refused() -> None:
    try:
        bench.TaggedApp(Path("/Applications/cmux.app"), "x", Path(tempfile.gettempdir()))
    except bench.BenchFailure:
        return
    raise AssertionError("an untagged bundle must be refused")


def test_compare_renders_every_engine_row() -> None:
    run = {
        "bundle": {"app_bytes": 1048576, "chromium_framework_bytes": 0, "chromium_helper_bytes": 0,
                   "chromium_framework_linked_at_launch": False},
        "launch": {"socket_ready_ms": {"p50": 900.0}, "idle": {"app_footprint_bytes": 2097152,
                                                               "chromium_processes": 0,
                                                               "chromium_framework_mapped": False}},
        "key_latency_ms_no_browser": {"p50": 1.0, "p95": 2.0},
        "engines": {"webkit": {"first_page_load_ms": 500.0, "memory_per_tab_bytes": 1048576,
                               "snapshot": {"webkit_processes": 2}}},
    }
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "base.json"
        path.write_text(json.dumps(run))
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            assert bench.main(["compare", str(path)]) == 0
    table = out.getvalue()
    assert "| App bundle | 1.0 MB |" in table
    assert "| Idle Chromium helper processes | 0 |" in table
    assert "| webkit: first page load (ms) | 500.0 |" in table
    assert "| webkit: engine processes | 2 |" in table


if __name__ == "__main__":
    test_classify_separates_engines_from_app_processes()
    test_stats_percentiles_interpolate()
    test_open_params_are_scoped_per_engine()
    test_untagged_bundle_is_refused()
    test_compare_renders_every_engine_row()
    print("ok")
