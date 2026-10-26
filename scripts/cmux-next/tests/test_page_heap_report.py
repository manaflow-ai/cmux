#!/usr/bin/env python3
"""page-heap-report.py (p07-memory task 102, MQ-JSHEAP): page names from document URLs, JS regions of
`footprint -j`, the heap snapshot summary (dominators, class retained size, detached DOM), the MQ-JSHEAP
rules (size and growth), a phase of an app with no DevTools port over a fake control socket, and exit 0
on every path (bad arguments, a missing file, no macOS).

Run: python3 -I scripts/cmux-next/tests/test_page_heap_report.py
"""

from __future__ import annotations

import importlib.util
import io
import json
import os
import socket
import sys
import tempfile
import threading
import unittest
from contextlib import redirect_stdout
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "page-heap-report.py"
spec = importlib.util.spec_from_file_location("page_heap_report", SCRIPT)
phr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(phr)

M = 1048576

NODE_TYPES = ["hidden", "array", "string", "object", "code", "closure", "regexp", "number", "native", "synthetic",
              "concatenated string", "sliced string", "symbol", "bigint", "object shape"]
EDGE_TYPES = ["context", "element", "property", "internal", "hidden", "shortcut", "weak"]


def snapshot(nodes: list[tuple[str, str, int, int]], edges: dict[int, list[tuple[str, int]]]) -> dict:
    """A V8 .heapsnapshot: nodes as (type, name, self size, detachedness), edges as {from: [(type, to)]}."""
    strings = [""]
    flat_nodes, flat_edges = [], []
    for index, (kind, name, size, detached) in enumerate(nodes):
        strings.append(name)
        out = edges.get(index, [])
        flat_nodes += [NODE_TYPES.index(kind), len(strings) - 1, index * 2 + 1, size, len(out), 0, detached]
        for edge_kind, to in out:
            flat_edges += [EDGE_TYPES.index(edge_kind), 0, to * 7]
    return {"snapshot": {"meta": {
        "node_fields": ["type", "name", "id", "self_size", "edge_count", "trace_node_id", "detachedness"],
        "node_types": [NODE_TYPES, "string", "number", "number", "number", "number", "number"],
        "edge_fields": ["type", "name_or_index", "to_node"],
        "edge_types": [EDGE_TYPES, "string_or_number", "node"]}, "node_count": len(nodes), "edge_count": len(flat_edges) // 3},
        "nodes": flat_nodes, "edges": flat_edges, "strings": strings}


# root -> Window -> Store -> Array (1000), Store -> Item -> Item; Window -> Cache -weak-> Array;
# Cache -> Item (so Item 5 is dominated by Window, not Store); Store -> a detached div.
GRAPH = snapshot(
    [("synthetic", "", 0, 0), ("object", "Window", 100, 0), ("object", "Store", 50, 0), ("array", "", 1000, 0),
     ("object", "Cache", 10, 0), ("object", "Item", 20, 0), ("native", "Detached HTMLDivElement", 30, 2),
     ("object", "Item", 20, 0), ("object", "Orphan", 999, 0)],
    {0: [("shortcut", 1)], 1: [("property", 2), ("property", 4)], 2: [("property", 3), ("property", 5), ("internal", 6)],
     4: [("weak", 3), ("property", 5)], 5: [("property", 7)]})


class Names(unittest.TestCase):
    def test_page_of_url(self):
        self.assertEqual(phr.page_of_url("cmux-page://cmux.settings/#/appearance"), "cmux.settings")
        self.assertEqual(phr.page_of_url("CMUX-PAGE://Cmux.History/"), "cmux.history")
        self.assertEqual(phr.page_of_url("cmux-agent://pane/index.html"), "agent")
        for other in ("https://example.com", "devtools://devtools/bundled/x", "about:blank", "", None):
            self.assertIsNone(phr.page_of_url(other))


class Regions(unittest.TestCase):
    def test_footprint_js_regions(self):
        document = {"processes": [{"pid": 7, "footprint": 90 * M, "categories": {
            "JS VM Gigacage": {"dirty": 12 * M}, "JS garbage collector": {"dirty": 3 * M},
            "JS JIT generated code": {"dirty": 1 * M}, "WebKit Malloc": {"dirty": 20 * M},
            "Memory Tag 255": {"dirty": 4 * M}, "Memory Tag 252": {"dirty": 2 * M}, "TOTAL": {"dirty": 90 * M}}}]}
        categories = phr.footprint_categories(document)
        self.assertNotIn("TOTAL", categories)
        self.assertEqual(phr.region_bytes(categories), {"js": 20 * M, "blink": 2 * M})

    def test_footprint_list_form(self):
        document = {"pid": 9, "categories": [{"category": "V8", "dirty": 5 * M}, {"name": "Blink GC", "dirty": M}]}
        self.assertEqual(phr.region_bytes(phr.footprint_categories(document)), {"js": 5 * M, "blink": M})


class Snapshot(unittest.TestCase):
    def setUp(self):
        self.summary = phr.snapshot_summary(GRAPH)

    def test_totals(self):
        self.assertEqual(self.summary["nodes"], 9)
        self.assertEqual(self.summary["reachable"], 8)  # Orphan has no retaining path
        self.assertEqual(self.summary["total_bytes"], 1230)

    def test_class_retained(self):
        classes = {row["name"]: row for row in self.summary["constructors"]}
        # The array is Store's alone: the Cache edge to it is weak.
        self.assertEqual(classes["Store"]["retained_bytes"], 1080)
        self.assertEqual(classes["Cache"]["retained_bytes"], 10)
        # Item 7 sits under Item 5: the class counts that subtree once.
        self.assertEqual(classes["Item"], {"name": "Item", "count": 2, "self_bytes": 40, "retained_bytes": 40})
        self.assertEqual(classes["(array)"]["retained_bytes"], 1000)
        self.assertNotIn("Orphan", classes)

    def test_retainers(self):
        top = self.summary["retainers"][0]
        self.assertEqual((top["class"], top["retained_bytes"], top["dominated_by"]), ("Window", 1230, []))
        array = next(r for r in self.summary["retainers"] if r["class"] == "(array)")
        self.assertEqual(array["dominated_by"], ["Store", "Window"])

    def test_detached(self):
        self.assertEqual(self.summary["detached_dom"], {"count": 1, "self_bytes": 30})

    def test_snapshot_file_exit_zero(self):
        with tempfile.TemporaryDirectory() as folder:
            path = os.path.join(folder, "page.heapsnapshot")
            with open(path, "w") as handle:
                json.dump(GRAPH, handle)
            text = run([f"--snapshot-file={path}"])
            self.assertIn("class Store", text)
            self.assertIn("detached DOM 1 nodes", text)


def phase(label: str, rows: list[dict]) -> dict:
    return phr.build_phase(label, {"available": True, "pages": []}, rows, {"available": True, "port": 1})


class Queue(unittest.TestCase):
    def test_size(self):
        rows = [{"page": "agent", "key": "cdp:a", "engine": "chromium", "source": "cdp", "js_heap_bytes": 75 * M},
                {"page": "cmux.settings", "key": "cdp:b", "engine": "chromium", "source": "cdp", "js_heap_bytes": 8 * M}]
        queue = phr.mq_jsheap([phase("home", rows)])
        self.assertEqual([(e["page"], e["reasons"]) for e in queue], [("agent", ["size"])])

    def test_growth_from_base(self):
        before = [{"page": "agent", "key": "cdp:a", "source": "cdp", "js_heap_bytes": 10 * M},
                  {"page": "webcontent:9", "key": "pid:9", "source": "process", "js_heap_bytes": None,
                   "footprint_bytes": 40 * M}]
        after = [{"page": "agent", "key": "cdp:a", "source": "cdp", "js_heap_bytes": 16 * M},
                 {"page": "webcontent:9", "key": "pid:9", "source": "process", "js_heap_bytes": None,
                  "footprint_bytes": 44 * M}]
        phases = [phase("home", []), phase("chats", before), phase("switches", after)]
        queue = phr.mq_jsheap(phases, base_label="chats")
        self.assertEqual(len(queue), 1)
        entry = queue[0]
        self.assertEqual((entry["page"], entry["reasons"], entry["growth_bytes"], entry["growth_metric"], entry["base"]),
                         ("agent", ["growth"], 6 * M, "js_heap", "chats"))

    def test_growth_by_footprint(self):
        before = [{"page": "webcontent:9", "key": "pid:9", "source": "process", "footprint_bytes": 40 * M}]
        after = [{"page": "webcontent:9", "key": "pid:9", "source": "process", "footprint_bytes": 52 * M}]
        queue = phr.mq_jsheap([phase("chats", before), phase("switches", after)], base_label="chats")
        self.assertEqual((queue[0]["growth_metric"], queue[0]["growth_bytes"]), ("footprint", 12 * M))

    def test_no_growth_without_base(self):
        rows = [{"page": "agent", "key": "cdp:a", "source": "cdp", "js_heap_bytes": 19 * M}]
        self.assertEqual(phr.mq_jsheap([phase("home", rows), phase("switches", rows)]), [])


class FakeApp:
    """A control socket that answers like a bench build with two live pages and no debug.memory."""

    def __init__(self, folder: str):
        self.path = os.path.join(folder, "c.sock")
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.server.bind(self.path)
        self.server.listen(8)
        threading.Thread(target=self.serve, daemon=True).start()

    def answer(self, method: str, params: dict) -> dict:
        if method == "debug.page" and params.get("action") == "list":
            return {"ok": True, "result": {"pages": [{"page": "cmux.history", "instance": 1, "parked": False},
                                                     {"page": "cmux.settings", "instance": 2, "parked": False}]}}
        if method == "debug.page":
            engine = "chromium" if params.get("page") == "cmux.history" else "webkit"
            return {"ok": True, "result": {"engine": engine}}
        return {"ok": False, "error": {"code": "method_not_found"}}

    def serve(self):
        while True:
            try:
                conn, _ = self.server.accept()
            except OSError:
                return
            with conn:
                data = b""
                while not data.endswith(b"\n"):
                    chunk = conn.recv(65536)
                    if not chunk:
                        break
                    data += chunk
                request = json.loads(data)
                conn.sendall((json.dumps(self.answer(request["method"], request.get("params") or {})) + "\n").encode())

    def close(self):
        self.server.close()


class NoCDP(unittest.TestCase):
    def test_phase_without_devtools_port(self):
        with tempfile.TemporaryDirectory() as folder:
            app = FakeApp(folder)
            try:
                closed = socket.socket()
                closed.bind(("127.0.0.1", 0))
                port = closed.getsockname()[1]
                closed.close()  # nothing listens there: the build has no DevTools port
                probe = phr.Probe(app.path, os.getpid(), None, port, gc=True)
                result = probe.measure("home", os.path.join(folder, "r"))
            finally:
                app.close()
        self.assertFalse(result["cdp"]["available"])
        self.assertEqual(result["cdp"]["reason"], phr.NO_CDP)
        self.assertFalse(result["debug_memory"])
        rows = {row["page"]: row for row in result["rows"]}
        self.assertEqual(set(rows), {"cmux.history", "cmux.settings"})
        self.assertTrue(all(row["source"] == "none" for row in rows.values()))
        self.assertIn(phr.NO_CDP, rows["cmux.history"]["reason"])
        self.assertIn("webkit page", rows["cmux.settings"]["reason"])
        out = io.StringIO()
        with redirect_stdout(out):
            phr.print_phase(result)
        self.assertIn("PAGE-HEAP phase=home pages=2 rows=2 unmeasured=2 js_heap_mb=0.0 cdp=no", out.getvalue())


def run(argv: list[str]) -> str:
    out = io.StringIO()
    with redirect_stdout(out), redirect_stderr_to(out):
        code = phr.main(argv)
    assert code == 0, code
    return out.getvalue()


class redirect_stderr_to:
    def __init__(self, stream):
        self.stream, self.saved = stream, None

    def __enter__(self):
        self.saved, sys.stderr = sys.stderr, self.stream

    def __exit__(self, *_):
        sys.stderr = self.saved


class ExitZero(unittest.TestCase):
    def test_bad_arguments(self):
        self.assertIn("PAGE-HEAP error: arguments", run(["--switches", "many", "--from", "x.json"]))
        run([])  # no source at all

    def test_missing_files(self):
        self.assertIn("PAGE-HEAP error", run(["--from", "/nonexistent/report.json"]))
        self.assertIn("PAGE-HEAP error", run(["--snapshot-file", "/nonexistent/x.heapsnapshot"]))

    def test_saved_report_round_trip(self):
        rows = [{"page": "agent", "key": "cdp:a", "engine": "chromium", "source": "cdp", "js_heap_bytes": 30 * M,
                 "dom": {"nodes": 900, "jsEventListeners": 40}}]
        report = {"tool": "page-heap-report", "phases": [phase("home", rows), {"label": "switches", "skipped": "no agent"}]}
        with tempfile.TemporaryDirectory() as folder:
            saved, out = os.path.join(folder, "in.json"), os.path.join(folder, "out.json")
            with open(saved, "w") as handle:
                json.dump(report, handle)
            text = run(["--from", saved, "--out", out])
            with open(out) as handle:
                written = json.load(handle)
        self.assertIn("MQ-JSHEAP page=agent phase=home js_heap_mb=30.0", text)
        self.assertIn("PAGE-HEAP phase=switches skipped: no agent", text)
        self.assertIn("PAGE-HEAP-QUEUE count=1", text)
        self.assertEqual(written["mq_jsheap"][0]["reasons"], ["size"])
        self.assertEqual(written["thresholds"]["js_limit_mb"], 20.0)

    @unittest.skipIf(sys.platform == "darwin", "the live path on macOS launches an app")
    def test_live_off_macos(self):
        with tempfile.TemporaryDirectory() as folder:
            text = run(["--app", "/nonexistent/cmux DEV x.app", "--out", os.path.join(folder, "r.json")])
        self.assertIn("PAGE-HEAP error: live measurement needs macOS", text)


if __name__ == "__main__":
    unittest.main()
