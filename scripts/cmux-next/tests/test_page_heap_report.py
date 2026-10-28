#!/usr/bin/env python3
"""page-heap-report.py (p07-memory task 102, MQ-JSHEAP): page names from document URLs, JS regions of
`footprint -j`, the heap snapshot summary (dominators, class retained size, detached DOM), the MQ-JSHEAP
rules (size, growth per page across replaced instances), pages named by `debug.webui` over a fake control
socket, the DevTools path (heap usage around GC, DOM counters, streamed snapshots) over a fake endpoint, and exit 0
on every path (bad arguments, a missing or malformed file, no macOS).

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
        self.assertEqual(phr.page_of_url("cmux-page://cmux.agent/"), "cmux.agent")
        for other in ("https://example.com", "devtools://devtools/bundled/x", "about:blank", "", None,
                      "cmux-agent://pane/index.html"):  # the deleted agent scheme serves nothing now
            self.assertIsNone(phr.page_of_url(other))


class Regions(unittest.TestCase):
    def test_footprint_js_regions(self):
        document = {"processes": [{"pid": 7, "footprint": 90 * M, "categories": {
            "JS VM Gigacage": {"dirty": 12 * M}, "JS garbage collector": {"dirty": 3 * M},
            "JS JIT generated code": {"dirty": 1 * M}, "WebKit Malloc": {"dirty": 20 * M},
            "Memory Tag 255": {"dirty": 4 * M}, "Memory Tag 252": {"dirty": 2 * M}, "TOTAL": {"dirty": 90 * M}}}]}
        regions = phr.footprint_regions(document, 7)
        self.assertEqual((regions["js"], regions["blink"], regions["footprint"], regions["rows"]),
                         (20 * M, 2 * M, 90 * M, 6))

    def test_footprint_list_form(self):
        document = {"pid": 9, "categories": [{"category": "V8", "dirty": 5 * M}, {"name": "Blink GC", "dirty": M}]}
        regions = phr.footprint_regions(document)
        self.assertEqual((regions["js"], regions["blink"]), (5 * M, M))

    def test_compressed_js_counts(self):
        # A JS page compressed under memory pressure is still JS heap (footprint_json adds compressed bytes).
        document = {"pid": 9, "footprint": 14 * M, "categories": {
            "JS VM Gigacage": {"dirty": 6 * M, "swapped": 4 * M}, "WebKit Malloc": {"dirty": 4 * M}}}
        self.assertEqual(phr.footprint_regions(document, 9)["js"], 10 * M)

    def test_no_rows_is_no_measurement(self):
        for document in ({"processes": [{"pid": 9, "footprint": 40 * M}]},
                         {"pid": 9, "categories": {"WebKit Malloc": {"dirty": 4 * M}}}, {"unknown": "shape"}):
            self.assertIsNone(phr.footprint_regions(document, 9)["js"], document)
        row = phr.process_row({"pid": 9, "engine": "webkit", "kind": "webcontent"}, ["cmux.settings"], 40 * M,
                              {"processes": [{"pid": 9, "footprint": 40 * M}]})
        self.assertIsNone(row["js_heap_bytes"])
        self.assertEqual(row["error"], "footprint: no category rows")
        self.assertEqual((row["page"], row["footprint_bytes"]), ("cmux.settings", 40 * M))


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


def cdp_row(page: str, key: str, js: int) -> dict:
    return {"page": page, "pages": [page], "key": key, "engine": "chromium", "source": "cdp", "js_heap_bytes": js}


class Queue(unittest.TestCase):
    def test_size(self):
        rows = [cdp_row("cmux.agent", "cdp:a", 75 * M), cdp_row("cmux.settings", "cdp:b", 8 * M)]
        queue = phr.mq_jsheap([phase("home", rows)])
        self.assertEqual([(e["page"], e["reasons"]) for e in queue], [("cmux.agent", ["size"])])

    def test_growth_from_base(self):
        before = [cdp_row("cmux.agent", "cdp:a", 10 * M),
                  {"page": "webcontent:9", "key": "pid:9", "source": "process", "js_heap_bytes": None,
                   "footprint_bytes": 40 * M}]
        after = [cdp_row("cmux.agent", "cdp:a", 16 * M),
                 {"page": "webcontent:9", "key": "pid:9", "source": "process", "js_heap_bytes": None,
                  "footprint_bytes": 44 * M}]
        phases = [phase("home", []), phase("chats", before), phase("switches", after)]
        queue = phr.mq_jsheap(phases, base_label="chats")
        self.assertEqual(len(queue), 1)
        entry = queue[0]
        self.assertEqual((entry["page"], entry["reasons"], entry["growth_bytes"], entry["growth_metric"], entry["base"]),
                         ("cmux.agent", ["growth"], 6 * M, "js_heap", "chats"))

    def test_growth_by_footprint(self):
        before = [{"page": "webcontent:9", "key": "pid:9", "source": "process", "footprint_bytes": 40 * M}]
        after = [{"page": "webcontent:9", "key": "pid:9", "source": "process", "footprint_bytes": 52 * M}]
        queue = phr.mq_jsheap([phase("chats", before), phase("switches", after)], base_label="chats")
        self.assertEqual((queue[0]["growth_metric"], queue[0]["growth_bytes"]), ("footprint", 12 * M))

    def test_footprint_without_js_rows_still_grows(self):
        # A capture footprint_json reads no rows from is no JS reading: growth falls back to the footprint.
        proc = {"pid": 9, "engine": "webkit", "kind": "webcontent"}
        before = phr.process_row(proc, ["cmux.settings"], 40 * M, {"processes": [{"pid": 9, "footprint": 40 * M}]})
        after = phr.process_row(proc, ["cmux.settings"], 52 * M, {"processes": [{"pid": 9, "footprint": 52 * M}]})
        queue = phr.mq_jsheap([phase("chats", [before]), phase("switches", [after])], base_label="chats")
        self.assertEqual([(e["page"], e["reasons"], e["growth_metric"], e["growth_bytes"]) for e in queue],
                         [("cmux.settings", ["growth"], "footprint", 12 * M)])
        self.assertIn("heap snapshots need the DevTools port", queue[0]["retainers_reason"])

    def test_growth_when_the_instance_is_replaced(self):
        # The agent page was discarded and restored over the switches: a new target id, the same page.
        phases = [phase("chats", [cdp_row("cmux.agent", "cdp:old", 10 * M), cdp_row("cmux.settings", "cdp:s", 4 * M)]),
                  phase("switches", [cdp_row("cmux.agent", "cdp:new", 17 * M), cdp_row("cmux.settings", "cdp:s", 4 * M)])]
        queue = phr.mq_jsheap(phases, base_label="chats")
        self.assertEqual([(e["page"], e["growth_bytes"], e["instances_gone"], e["instances_new"]) for e in queue],
                         [("cmux.agent", 7 * M, 1, 1)])
        self.assertEqual(phr.growth_notes(phases, "chats"), [
            "PAGE-HEAP growth-note page=cmux.agent base=chats last=switches instances_gone=1 instances_new=1: "
            "growth compares the page's summed rows"])

    def test_growth_by_added_instances(self):
        phases = [phase("chats", [cdp_row("cmux.agent", "cdp:a", 4 * M)]),
                  phase("switches", [cdp_row("cmux.agent", "cdp:a", 4 * M), cdp_row("cmux.agent", "cdp:b", 4 * M)])]
        self.assertEqual(phr.mq_jsheap(phases, base_label="chats"), [])  # 4 MB: under the 5 MB limit
        phases[1]["rows"].append(cdp_row("cmux.agent", "cdp:c", 4 * M))
        queue = phr.mq_jsheap(phases, base_label="chats")
        self.assertEqual([(e["page"], e["growth_bytes"], e["instances_new"]) for e in queue], [("cmux.agent", 8 * M, 2)])

    def test_no_growth_without_base(self):
        rows = [cdp_row("cmux.agent", "cdp:a", 19 * M)]
        self.assertEqual(phr.mq_jsheap([phase("home", rows), phase("switches", rows)]), [])


WEBUI = {"pages": [
    {"page": "cmux.agent", "instance": 1, "engine": "chromium", "state": "visible", "spare": None,
     "renderer_pids": [501], "webkit_pid": None},
    {"page": "cmux.agent", "instance": 2, "engine": "chromium", "state": "hidden", "spare": "new_tab",
     "renderer_pids": [501], "webkit_pid": None},
    {"page": "cmux.settings", "instance": 3, "engine": "webkit", "state": "hidden", "spare": None,
     "renderer_pids": [], "webkit_pid": 602},
    {"page": "cmux.history", "instance": 4, "engine": "webkit", "state": "hidden", "spare": None,
     "renderer_pids": [], "webkit_pid": None}],
    "spares": [{"spare": "cef_pages_window", "state": "live", "renderer_pids": [503], "webkit_pid": None}],
    "browser_tabs": [], "processes": []}


class FakeApp:
    """A control socket that answers `debug.webui` like a bench build (WebUICensus.swift's keys)."""

    def __init__(self, folder: str, webui: dict | None = None):
        self.path = os.path.join(folder, "c.sock")
        self.webui, self.methods = webui, []
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.server.bind(self.path)
        self.server.listen(8)
        threading.Thread(target=self.serve, daemon=True).start()

    def answer(self, method: str, params: dict) -> dict:
        self.methods.append((method, params))
        if method == "debug.webui" and self.webui is not None:
            return {"ok": True, "result": self.webui}
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


def closed_port() -> int:
    closed = socket.socket()
    closed.bind(("127.0.0.1", 0))
    port = closed.getsockname()[1]
    closed.close()  # nothing listens there: the build has no DevTools port
    return port


FOOTPRINTS = {
    501: {"pid": 501, "footprint": 80 * M, "categories": {"Memory Tag 255": {"dirty": 30 * M},
                                                          "Memory Tag 252": {"dirty": 6 * M}}},
    602: {"pid": 602, "footprint": 50 * M, "categories": {"JS VM Gigacage": {"dirty": 9 * M},
                                                          "WebKit Malloc": {"dirty": 20 * M}}},
    503: {"pid": 503, "footprint": 20 * M, "categories": {"Memory Tag 255": {"dirty": 2 * M}}},
    777: {"pid": 777, "footprint": 30 * M, "categories": {"Memory Tag 255": {"dirty": 3 * M}}},
}


def fake_measure(proc: dict, hosts: list[str], _stem: str) -> dict:
    document = FOOTPRINTS[proc["pid"]]
    return phr.process_row(proc, hosts, document["footprint"], document)


class NoCDP(unittest.TestCase):
    def measure(self, webui: dict | None, processes: list[dict]) -> tuple[dict, list]:
        with tempfile.TemporaryDirectory() as folder:
            app = FakeApp(folder, webui)
            try:
                probe = phr.Probe(app.path, os.getpid(), None, closed_port(), gc=True,
                                  list_processes=lambda: processes, measure_process=fake_measure)
                return probe.measure("home", os.path.join(folder, "r")), app.methods
            finally:
                app.close()

    def test_process_rows_take_webui_pages(self):
        processes = [{"pid": 501, "engine": "chromium", "kind": "renderer"},
                     {"pid": 602, "engine": "webkit", "kind": "webcontent"},
                     {"pid": 503, "engine": "chromium", "kind": "renderer"},
                     {"pid": 777, "engine": "chromium", "kind": "renderer"}]
        result, methods = self.measure(WEBUI, processes)
        self.assertEqual([m for m, _ in methods], ["debug.webui"])  # read-only: no debug.agent_pane, no reset
        self.assertEqual(methods[0][1], {})
        self.assertFalse(result["cdp"]["available"])
        rows = {row["page"]: row for row in result["rows"]}
        self.assertEqual(set(rows), {"cmux.agent", "cmux.settings", "spare:cef_pages_window", "renderer:777",
                                     "cmux.history"})
        self.assertEqual((rows["cmux.agent"]["source"], rows["cmux.agent"]["js_heap_bytes"],
                          rows["cmux.agent"]["blink_gc_bytes"]), ("process", 30 * M, 6 * M))
        self.assertEqual((rows["cmux.settings"]["source"], rows["cmux.settings"]["js_heap_bytes"]), ("process", 9 * M))
        self.assertFalse(rows["renderer:777"]["mapped"])
        # Merged with the inventory: no `source=none` duplicate of a page a process row measured.
        self.assertEqual([r["page"] for r in result["rows"] if r["source"] == "none"], ["cmux.history"])
        self.assertIn("names no WebContent pid", rows["cmux.history"]["reason"])
        self.assertEqual(len(result["inventory"]["pages"]), 4)
        out = io.StringIO()
        with redirect_stdout(out):
            phr.print_phase(result)
        self.assertIn("PAGE-HEAP phase=home pages=4 rows=5 unmeasured=1 js_heap_mb=44.0 cdp=no", out.getvalue())
        queue = phr.mq_jsheap([result])
        self.assertEqual([e["page"] for e in queue], ["cmux.agent"])

    def test_renderer_shared_by_two_pages(self):
        webui = {"pages": [
            {"page": "cmux.agent", "instance": 1, "engine": "chromium", "renderer_pids": [501]},
            {"page": "cmux.history", "instance": 2, "engine": "chromium", "renderer_pids": [501]}]}
        result, _ = self.measure(webui, [{"pid": 501, "engine": "chromium", "kind": "renderer"}])
        self.assertEqual([(r["page"], r["source"]) for r in result["rows"]], [("cmux.agent+cmux.history", "process")])

    def test_without_webui(self):
        result, _ = self.measure(None, [{"pid": 777, "engine": "chromium", "kind": "renderer"}])
        self.assertFalse(result["inventory"]["available"])
        self.assertEqual([r["page"] for r in result["rows"]], ["renderer:777"])


# A DevTools endpoint: /json/version over HTTP, and the browser and page websockets on the same port.

HEAPS = {"A1": ({"usedSize": 40 * M, "totalSize": 60 * M}, {"usedSize": 30 * M, "totalSize": 50 * M,
                                                              "embedderHeapUsedSize": 2 * M}),
         "S2": ({"usedSize": 6 * M, "totalSize": 8 * M}, {"usedSize": 5 * M, "totalSize": 8 * M})}
TARGETS = [
    {"targetId": "A1", "type": "page", "url": "cmux-page://cmux.agent/#/chat"},
    {"targetId": "S2", "type": "page", "url": "cmux-page://cmux.settings/"},
    {"targetId": "X3", "type": "page", "url": "https://example.com/"},
    {"targetId": "W4", "type": "service_worker", "url": "cmux-page://cmux.agent/sw.js"},
    {"targetId": "BAD", "type": "page", "url": "cmux-page://cmux.history/"},
]


class FakeDevTools:
    def __init__(self):
        self.server = socket.socket()
        self.server.bind(("127.0.0.1", 0))
        self.server.listen(16)
        self.port = self.server.getsockname()[1]
        self.calls: list[tuple[str, str]] = []
        threading.Thread(target=self.serve, daemon=True).start()

    def serve(self):
        while True:
            try:
                conn, _ = self.server.accept()
            except OSError:
                return
            threading.Thread(target=self.handle, args=(conn,), daemon=True).start()

    def handle(self, conn):
        with conn:
            head = b""
            while b"\r\n\r\n" not in head:
                chunk = conn.recv(4096)
                if not chunk:
                    return
                head += chunk
            path = head.split(b" ", 2)[1].decode()
            if b"upgrade: websocket" not in head.lower():
                body = json.dumps({"webSocketDebuggerUrl": f"ws://127.0.0.1:{self.port}/devtools/browser/fake"}
                                  if path == "/json/version" else TARGETS).encode()
                conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: "
                             + str(len(body)).encode() + b"\r\nConnection: close\r\n\r\n" + body)
                return
            target = path.rsplit("/", 1)[1]
            if target == "BAD":
                conn.sendall(b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n")
                return
            conn.sendall(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n")
            collected = False
            while True:
                message = self.read(conn)
                if message is None:
                    return
                method, request_id = message["method"], message["id"]
                self.calls.append((target, method))
                result: dict = {}
                if method == "Target.getTargets":
                    result = {"targetInfos": TARGETS}
                elif method == "Runtime.getHeapUsage":
                    result = HEAPS[target][1 if collected else 0]
                elif method == "HeapProfiler.collectGarbage":
                    collected = True
                elif method == "Memory.getDOMCounters":
                    result = {"documents": 2, "nodes": 900, "jsEventListeners": 40}
                elif method == "HeapProfiler.takeHeapSnapshot":
                    text = json.dumps(GRAPH)
                    for start in range(0, len(text), 100):
                        self.write(conn, {"method": "HeapProfiler.addHeapSnapshotChunk",
                                          "params": {"chunk": text[start:start + 100]}})
                self.write(conn, {"id": request_id, "result": result})

    @staticmethod
    def read(conn):
        def exactly(count):
            data = b""
            while len(data) < count:
                chunk = conn.recv(count - len(data))
                if not chunk:
                    raise ConnectionError
                data += chunk
            return data
        try:
            first, second = exactly(2)
            length = second & 0x7F
            if length == 126:
                length = int.from_bytes(exactly(2), "big")
            elif length == 127:
                length = int.from_bytes(exactly(8), "big")
            mask = exactly(4)
            payload = bytes(b ^ mask[i % 4] for i, b in enumerate(exactly(length)))
        except (ConnectionError, OSError):
            return None
        return None if first & 0x0F == 0x8 else json.loads(payload)

    @staticmethod
    def write(conn, message: dict):
        payload = json.dumps(message).encode()
        if len(payload) < 126:
            head = bytes([0x81, len(payload)])
        elif len(payload) < 65536:
            head = bytes([0x81, 126]) + len(payload).to_bytes(2, "big")
        else:
            head = bytes([0x81, 127]) + len(payload).to_bytes(8, "big")
        conn.sendall(head + payload)

    def close(self):
        self.server.close()


class DevTools(unittest.TestCase):
    def setUp(self):
        self.devtools = FakeDevTools()
        self.addCleanup(self.devtools.close)

    def test_cdp_rows(self):
        rows = {row["page"]: row for row in phr.cdp_rows(self.devtools.port, gc=True)}
        self.assertEqual(set(rows), {"cmux.agent", "cmux.settings", "cmux.history"})  # no browser tab, no worker
        agent = rows["cmux.agent"]
        self.assertEqual((agent["key"], agent["route"], agent["js_heap_bytes"], agent["js_heap_total_bytes"],
                          agent["js_heap_before_gc_bytes"], agent["embedder_heap_bytes"]),
                         ("cdp:A1", "/chat", 30 * M, 50 * M, 40 * M, 2 * M))
        self.assertEqual(agent["dom"], {"documents": 2, "nodes": 900, "jsEventListeners": 40})
        self.assertEqual(rows["cmux.settings"]["js_heap_bytes"], 5 * M)
        self.assertTrue(rows["cmux.history"]["error"].startswith("attach:"))
        self.assertEqual([m for t, m in self.devtools.calls if t == "A1"],
                         ["Runtime.getHeapUsage", "HeapProfiler.collectGarbage", "Runtime.getHeapUsage",
                          "Memory.getDOMCounters"])
        self.assertFalse(any(t in ("X3", "W4") for t, _ in self.devtools.calls))

    def test_cdp_rows_without_gc(self):
        rows = {row["page"]: row for row in phr.cdp_rows(self.devtools.port, gc=False)}
        self.assertEqual((rows["cmux.agent"]["js_heap_bytes"], rows["cmux.agent"]["js_heap_before_gc_bytes"]),
                         (40 * M, 40 * M))
        self.assertNotIn(("A1", "HeapProfiler.collectGarbage"), self.devtools.calls)

    def test_snapshot_streams_chunks(self):
        with tempfile.TemporaryDirectory() as folder:
            found = phr.cdp_snapshots(self.devtools.port, {"cdp:A1"}, os.path.join(folder, "s"), top=15)
            self.assertEqual(set(found), {"cdp:A1"})
            summary = found["cdp:A1"]
            with open(summary.pop("file")) as handle:
                self.assertEqual(json.load(handle), GRAPH)
        self.assertEqual(summary, phr.snapshot_summary(GRAPH))
        self.assertEqual([m for t, m in self.devtools.calls if t == "A1"],
                         ["HeapProfiler.enable", "HeapProfiler.takeHeapSnapshot"])

    def test_flagged_pages_get_snapshots_and_retainers(self):
        args = phr.parse(["--from", "x.json"])[1]
        self.assertEqual(args.snapshot, "flagged")
        with tempfile.TemporaryDirectory() as folder:
            rows = phr.cdp_rows(self.devtools.port, gc=True)
            phases = [phr.build_phase("home", {"available": True, "pages": []}, rows, {"available": True})]
            phr.add_snapshots(phases, args, self.devtools.port, os.path.join(folder, "r"))
        snapshotted = {t for t, m in self.devtools.calls if m == "HeapProfiler.takeHeapSnapshot"}
        self.assertEqual(snapshotted, {"A1"})  # only the page over 20 MB
        queue = phr.mq_jsheap(phases)
        self.assertEqual([e["page"] for e in queue], ["cmux.agent"])
        self.assertEqual(queue[0]["retainers"][0]["class"], "Window")
        out = io.StringIO()
        with redirect_stdout(out):
            phr.print_queue(queue, None)
        lines = out.getvalue().splitlines()
        self.assertTrue(lines[0].startswith("MQ-JSHEAP page=cmux.agent phase=home js_heap_mb=30.0"))
        self.assertRegex(lines[1], r"^   retainer Window +retained +0\.0 MB  under \(root\)$")

    def test_snapshot_none(self):
        args = phr.parse(["--from", "x.json", "--snapshot", "none"])[1]
        rows = phr.cdp_rows(self.devtools.port, gc=True)
        phr.add_snapshots([phase("home", rows)], args, self.devtools.port, "/nonexistent/r")
        self.assertNotIn("HeapProfiler.takeHeapSnapshot", [m for _, m in self.devtools.calls])
        self.assertEqual(phr.parse(["--from", "x.json", "--snapshot"])[1].snapshot, "all")


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

    def saved(self, report) -> str:
        with tempfile.TemporaryDirectory() as folder:
            path = os.path.join(folder, "in.json")
            with open(path, "w") as handle:
                json.dump(report, handle)
            return run(["--from", path])

    def test_saved_report_not_an_object(self):
        for report in ([], "text", 7, None):
            self.assertIn("PAGE-HEAP error", self.saved(report), report)

    def test_saved_phase_with_missing_keys(self):
        # An older or hand-edited report: rows with no `cdp`, `inventory`, `key` or `source`.
        text = self.saved({"phases": [{"label": "home", "rows": [{"page": "cmux.agent", "js_heap_bytes": 30 * M}]},
                                      {"rows": [{"js_heap_bytes": 1}]}, "not a phase"]})
        self.assertIn("PAGE-HEAP phase=home pages=0 rows=1 unmeasured=0 js_heap_mb=30.0 cdp=no", text)
        self.assertNotIn("Traceback", text)

    def test_saved_report_round_trip(self):
        rows = [{"page": "cmux.agent", "key": "cdp:a", "engine": "chromium", "source": "cdp", "js_heap_bytes": 30 * M,
                 "dom": {"nodes": 900, "jsEventListeners": 40}}]
        report = {"tool": "page-heap-report", "phases": [phase("home", rows), {"label": "switches", "skipped": "no agent"}]}
        with tempfile.TemporaryDirectory() as folder:
            saved, out = os.path.join(folder, "in.json"), os.path.join(folder, "out.json")
            with open(saved, "w") as handle:
                json.dump(report, handle)
            text = run(["--from", saved, "--out", out])
            with open(out) as handle:
                written = json.load(handle)
        self.assertIn("MQ-JSHEAP page=cmux.agent phase=home js_heap_mb=30.0", text)
        self.assertIn("retainers: none (no heap snapshot taken (--snapshot none))", text)
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
