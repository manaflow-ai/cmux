#!/usr/bin/env python3
"""JS heap per cmux page (p07-memory task 102, MQ-JSHEAP).

For every live cmux page (a PageDescriptor page, `cmux-page://<id>`, and the agent page,
`cmux-agent://pane`), measures its JavaScript heap:

  * Chromium pages over the DevTools protocol, when the app has a DevTools port: `Runtime.getHeapUsage`
    before and after `HeapProfiler.collectGarbage`, `Memory.getDOMCounters`, and with --snapshot a heap
    snapshot summary (constructors by retained size, the largest retainers, detached DOM nodes). This is
    Chrome's own heap view: the Summary of DevTools' Memory panel and its dominator tree
    (front_end/entrypoints/heap_snapshot_worker/HeapSnapshot.ts: weak edges retain nothing, shortcut
    edges only from the root, Cooper-Harvey-Kennedy dominators, class retained size counted once per
    dominator path).
  * WebKit pages by their WebContent process: phys_footprint, and the JavaScriptCore regions of
    `footprint -j` (JS VM Gigacage, JS garbage collector, JS JIT, ...) as the page's JS bytes.
  * Chromium pages with no DevTools port (a Release or bench build: CMUX_NEXT_CEF_EXTRA_SWITCHES is read
    by DEBUG builds only, CEFSwitches.swift) by their renderer process: phys_footprint and its V8 regions
    (VM tag 255, partition_alloc/page_allocator_constants.h). Renderer and WebContent processes are
    named by page where the app says which page they host (`debug.agent_pane pid`, `debug.memory`
    process rows with a page), else listed as unmapped.

`debug.page list` (DEBUG and bench builds) names every live page instance and its engine; a page no
source measured gets a row that says why.

Phases (--app): `home` (Home idle after --settle seconds) and `switches` (--chats answered agent chats
on the fake ACP agent, measured once open, then after --switches workspace switches between them).
Prints one table per phase, `PAGE-HEAP phase=...` and one `MQ-JSHEAP page=...` line for each page whose
JS heap is above 20 MB in the last phase or grew by more than 5 MB over the switches (each line is one
webviews/ fix task, p07-memory.md section 6). Writes one JSON report (--out); --from re-reads it.

Usage:
  page-heap-report.py --app BUNDLE [--phases home,switches] [--switches 50] [--chats 3] [--settle 30]
      [--snapshot] [--out FILE.json]
      Launch a tagged app (scratch HOME and config), measure each phase, quit it. Fleet only
      (scripts/measure/page-heap-report.sh).
  page-heap-report.py --socket PATH --pid PID [--cdp-port N] [--snapshot] [--out FILE.json]
      One phase of a running tagged app.
  page-heap-report.py --from FILE.json [--js-limit-mb 20] [--growth-limit-mb 5]
  page-heap-report.py --snapshot-file FILE.heapsnapshot
      Re-read a saved report or a heap snapshot (any platform).

Always exits 0: it is a report, never a gate (CLAUDE.md: never wire it into CI or a hook).
"""

from __future__ import annotations

import argparse
import ctypes
import importlib.util
import json
import os
import re
import shutil
import signal
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
from urllib.parse import urlparse

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
if HERE not in sys.path:
    sys.path.insert(0, HERE)  # python3 -I leaves the script folder out
from ext_e2e import cdp  # noqa: E402 - stdlib-only DevTools client next to this script

MB = 1048576.0
JS_LIMIT_MB = 20.0
GROWTH_LIMIT_MB = 5.0
FAKE_AGENT = os.path.join(ROOT, "cmux-tui", "crates", "acpmux", "tests", "fake_agent.py")
NO_CDP = "no DevTools port (Release and bench builds ignore CMUX_NEXT_CEF_EXTRA_SWITCHES)"


def page_of_url(url: str | None) -> str | None:
    """The cmux page a document URL belongs to: the host of `cmux-page://<id>/...`, `agent` for
    `cmux-agent://pane/...`; None for any other document (browser tabs, devtools://, about:blank)."""
    parsed = urlparse(url or "")
    scheme, host = parsed.scheme.lower(), (parsed.hostname or "").lower()
    if scheme == "cmux-page" and host:
        return host
    if scheme == "cmux-agent":
        return "agent"
    return None


# Process regions: `footprint -j` of a WebContent or renderer process.


def footprint_categories(document) -> dict[str, int]:
    """{category: dirty bytes} of the first process object in `footprint -j` JSON (categories as a
    map of name to counts, or a list of named counts)."""
    def dirty(entry: dict) -> int | None:
        keys = sorted((k for k, v in entry.items() if "dirty" in k.lower() and isinstance(v, (int, float))),
                      key=lambda k: (k.lower() != "dirty", len(k)))
        return int(entry[keys[0]]) if keys else None

    def process(node):
        if isinstance(node, dict):
            if "pid" in node:
                return node
            children = node.values()
        elif isinstance(node, list):
            children = node
        else:
            return None
        return next((found for found in map(process, children) if found is not None), None)

    proc = process(document) or (document if isinstance(document, dict) else {})
    categories: dict[str, int] = {}
    for value in proc.values():
        entries = []
        if isinstance(value, dict) and value and all(isinstance(v, dict) for v in value.values()):
            entries = list(value.items())
        elif isinstance(value, list) and value and all(isinstance(v, dict) for v in value):
            entries = [(next((e[k] for k in ("category", "name", "tag", "type") if isinstance(e.get(k), str)), None), e)
                       for e in value]
        for name, entry in entries:
            size = dirty(entry)
            if name and size is not None and name != "TOTAL":
                categories[name] = categories.get(name, 0) + size
        if categories:
            break
    return categories


def region_kind(category: str) -> str | None:
    """`js` for JavaScript heap regions (JavaScriptCore's, V8's), `blink` for Oilpan, else None."""
    lower = category.strip().lower()
    tag = re.search(r"\btag\s*(\d+)\b", lower)
    if tag:
        return {255: "js", 252: "blink"}.get(int(tag.group(1)))
    if lower == "v8" or lower.startswith(("v8 ", "js ", "javascriptcore", "webassembly")):
        return "js"
    if lower.startswith("blink gc"):
        return "blink"
    return None


def region_bytes(categories: dict[str, int]) -> dict[str, int]:
    """{js, blink}: the bytes of each kind of region."""
    out = {"js": 0, "blink": 0}
    for name, value in categories.items():
        kind = region_kind(name)
        if kind:
            out[kind] += value
    return out


# Heap snapshots (V8's .heapsnapshot format).


def snapshot_summary(snapshot: dict, top: int = 15) -> dict:
    """Constructors by retained size, the largest single retainers, and detached DOM nodes of a V8 heap
    snapshot, as DevTools' Memory panel computes them (HeapSnapshot.ts)."""
    meta = snapshot["snapshot"]["meta"]
    nf, ef = meta["node_fields"], meta["edge_fields"]
    width, edge_width = len(nf), len(ef)
    nodes, edges, strings = snapshot["nodes"], snapshot["edges"], snapshot["strings"]
    node_types, edge_types = meta["node_types"][nf.index("type")], meta["edge_types"][ef.index("type")]
    t_at, name_at, size_at, count_at = nf.index("type"), nf.index("name"), nf.index("self_size"), nf.index("edge_count")
    detached_at = nf.index("detachedness") if "detachedness" in nf else None
    edge_type_at, to_at = ef.index("type"), ef.index("to_node")
    weak, shortcut = edge_types.index("weak") if "weak" in edge_types else -1, \
        edge_types.index("shortcut") if "shortcut" in edge_types else -1
    count = len(nodes) // width
    first = [0] * (count + 1)
    for i in range(count):
        first[i + 1] = first[i] + nodes[i * width + count_at] * edge_width

    def klass(i: int) -> str:
        kind = node_types[nodes[i * width + t_at]]
        if kind in ("object", "native"):
            return strings[nodes[i * width + name_at]] or f"({kind})"
        return {"hidden": "(system)", "code": "(compiled code)", "closure": "(closure)",
                "string": "(string)", "concatenated string": "(string)", "sliced string": "(string)",
                "regexp": "(regexp)", "number": "(number)", "array": "(array)"}.get(kind, f"({kind})")

    def successors(i: int):
        for e in range(first[i], first[i + 1], edge_width):
            kind = edges[e + edge_type_at]
            if kind == weak or (kind == shortcut and i != 0):
                continue  # HeapSnapshot.ts isEssentialEdge
            yield edges[e + to_at] // width

    # Postorder from the root (node 0) over retaining edges.
    order, post = [], [-1] * count
    seen = bytearray(count)
    stack = [(0, successors(0))]
    seen[0] = 1
    while stack:
        node, it = stack[-1]
        child = next(it, None)
        if child is None:
            stack.pop()
            post[node] = len(order)
            order.append(node)
        elif not seen[child]:
            seen[child] = 1
            stack.append((child, successors(child)))
    preds: dict[int, list[int]] = {}
    for node in order:
        for child in successors(node):
            preds.setdefault(child, []).append(node)
    # Cooper, Harvey, Kennedy: "A Simple, Fast Dominance Algorithm", on postorder numbers.
    idom = [-1] * len(order)
    root = post[0]
    idom[root] = root

    def intersect(a: int, b: int) -> int:
        while a != b:
            while a < b:
                a = idom[a]
            while b < a:
                b = idom[b]
        return a

    changed = True
    while changed:
        changed = False
        for number in range(len(order) - 2, -1, -1):
            new = -1
            for pred in preds.get(order[number], ()):
                p = post[pred]
                if idom[p] != -1:
                    new = p if new == -1 else intersect(p, new)
            if new != -1 and idom[number] != new:
                idom[number] = new
                changed = True
    retained = [nodes[order[n] * width + size_at] for n in range(len(order))]
    for number in range(len(order) - 1):  # a node's dominator has a higher postorder number
        if idom[number] >= 0:
            retained[idom[number]] += retained[number]

    classes: dict[str, dict] = {}
    for number, node in enumerate(order):
        row = classes.setdefault(klass(node), {"count": 0, "self_bytes": 0, "retained_bytes": 0})
        row["count"] += 1
        row["self_bytes"] += nodes[node * width + size_at]
    # A class's retained size counts each dominator subtree once: not again under one of its own class.
    children: dict[int, list[int]] = {}
    for number in range(len(order) - 1):
        if idom[number] >= 0:
            children.setdefault(idom[number], []).append(number)
    on_path: dict[str, int] = {}
    walk = [(root, False)]
    while walk:
        number, leaving = walk.pop()
        name = klass(order[number])
        if leaving:
            on_path[name] -= 1
            continue
        if number != root and not on_path.get(name):
            classes[name]["retained_bytes"] += retained[number]
        on_path[name] = on_path.get(name, 0) + 1
        walk.append((number, True))
        walk.extend((child, False) for child in children.get(number, ()))

    def path(number: int) -> list[str]:
        out = []
        while idom[number] not in (-1, number) and idom[number] != root and len(out) < 4:
            number = idom[number]
            out.append(klass(order[number]))
        return out

    synthetic = node_types.index("synthetic") if "synthetic" in node_types else -1
    largest = sorted((n for n in range(len(order)) if nodes[order[n] * width + t_at] != synthetic),
                     key=lambda n: -retained[n])[:top]
    detached = [order[n] for n in range(len(order))
                if detached_at is not None and nodes[order[n] * width + detached_at] == 2]
    return {
        "nodes": count, "reachable": len(order), "total_bytes": retained[root],
        "constructors": [dict(name=name, **row) for name, row in
                         sorted(classes.items(), key=lambda item: -item[1]["retained_bytes"])[:top]],
        "retainers": [{"class": klass(order[n]), "self_bytes": nodes[order[n] * width + size_at],
                       "retained_bytes": retained[n], "dominated_by": path(n)} for n in largest],
        "detached_dom": {"count": len(detached), "self_bytes": sum(nodes[i * width + size_at] for i in detached)},
    }


# DevTools protocol.


class SnapshotSession(cdp.Session):
    """A page session that also streams a heap snapshot to a file."""

    def take_snapshot(self, path: str, timeout: float = 600) -> None:
        self.call("HeapProfiler.enable")
        request_id = self.next_id
        self.next_id += 1
        self._send(json.dumps({"id": request_id, "method": "HeapProfiler.takeHeapSnapshot",
                               "params": {"reportProgress": False, "captureNumericValue": False}}))
        self.sock.settimeout(timeout)
        with open(path, "w") as handle:
            while True:
                message = self._recv()
                if message.get("method") == "HeapProfiler.addHeapSnapshotChunk":
                    handle.write(message["params"]["chunk"])
                elif message.get("id") == request_id:
                    if "error" in message:
                        raise RuntimeError(f"takeHeapSnapshot: {message['error'].get('message')}")
                    return


def cdp_port_answers(port: int | None) -> bool:
    if not port:
        return False
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/json/version", timeout=3) as response:
            return bool(json.loads(response.read()).get("webSocketDebuggerUrl"))
    except (OSError, ValueError, urllib.error.URLError):
        return False


def cdp_rows(port: int, gc: bool, snapshot_stem: str | None) -> list[dict]:
    """One row per page target of a cmux page: heap usage before and after GC, DOM counters, and the
    snapshot summary when `snapshot_stem` is set."""
    rows = []
    for target in cdp.target_infos(port):
        page = page_of_url(target.get("url"))
        if target.get("type") != "page" or page is None:
            continue
        row = {"page": page, "key": "cdp:" + target["targetId"], "engine": "chromium", "source": "cdp",
               "route": urlparse(target.get("url") or "").fragment[:60] or None}
        try:
            session = SnapshotSession(f"ws://127.0.0.1:{port}/devtools/page/{target['targetId']}")
        except (OSError, ConnectionError) as error:
            rows.append(dict(row, error=f"attach: {error}"[:200]))
            continue
        try:
            before = session.call("Runtime.getHeapUsage")
            if gc:
                session.call("HeapProfiler.collectGarbage", timeout=60)
            after = session.call("Runtime.getHeapUsage") if gc else before
            row.update(js_heap_bytes=int(after.get("usedSize", 0)), js_heap_total_bytes=int(after.get("totalSize", 0)),
                       js_heap_before_gc_bytes=int(before.get("usedSize", 0)),
                       embedder_heap_bytes=after.get("embedderHeapUsedSize"))
            counters = session.call("Memory.getDOMCounters")
            row["dom"] = {k: counters.get(k) for k in ("documents", "nodes", "jsEventListeners")}
            if snapshot_stem:
                path = f"{snapshot_stem}-{page}-{len(rows)}.heapsnapshot"
                session.take_snapshot(path)
                with open(path) as handle:
                    row["snapshot"] = dict(snapshot_summary(json.load(handle)), file=path)
        except (OSError, ConnectionError, RuntimeError, ValueError, KeyError) as error:
            row["error"] = f"{type(error).__name__}: {error}"[:200]
        finally:
            session.close()
        rows.append(row)
    return rows


# The app's own account of its pages and processes.


def rpc(path: str, method: str, params: dict | None = None, timeout: float = 60) -> dict:
    """One control-socket call: its result object, or {"error": ...}."""
    reply = b""
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as stream:
            stream.settimeout(timeout)
            stream.connect(path)
            stream.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
            while not reply.endswith(b"\n"):
                chunk = stream.recv(1 << 22)
                if not chunk:
                    break
                reply += chunk
        answer = json.loads(reply or b"{}")
    except (OSError, ValueError) as error:
        return {"error": str(error)}
    if answer.get("error") or answer.get("ok") is False:
        return {"error": answer.get("error") or "refused"}
    result = answer.get("result")
    return result if isinstance(result, dict) else {"error": f"no result object: {str(result)[:200]}"}


def page_inventory(call) -> dict:
    """{available, error, pages: [{page, instance, parked, engine}]} from `debug.page`."""
    listed = call("debug.page", {"action": "list"})
    if "error" in listed:
        return {"available": False, "error": json.dumps(listed["error"])[:200], "pages": []}
    pages = []
    for entry in listed.get("pages") or []:
        if not isinstance(entry, dict) or not entry.get("page"):
            continue
        state = call("debug.page", {"page": entry["page"], "instance": entry.get("instance"), "action": "state"})
        pages.append({"page": str(entry["page"]).lower(), "instance": entry.get("instance"),
                      "parked": bool(entry.get("parked")), "engine": state.get("engine")})
    return {"available": True, "error": None, "pages": pages}


def page_pids(agent_reply: dict, debug_memory: dict) -> dict[int, str]:
    """{pid: page} of the web processes the app names: the agent page's WebContent process, and
    `debug.memory` process rows that carry a page id."""
    out: dict[int, str] = {}
    if isinstance(agent_reply.get("pid"), (int, float)):
        out[int(agent_reply["pid"])] = "agent"
    for row in debug_memory.get("processes") or [] if isinstance(debug_memory, dict) else []:
        page = isinstance(row, dict) and (row.get("page") or row.get("page_id"))
        if page and isinstance(row.get("pid"), (int, float)):
            out[int(row["pid"])] = str(page).lower()
    return out


# Live processes (macOS).


def load_module(name: str, filename: str):
    if name not in sys.modules:
        spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, filename))
        module = importlib.util.module_from_spec(spec)
        sys.modules[name] = module
        spec.loader.exec_module(module)
    return sys.modules[name]


def responsible_pid(pid: int) -> int | None:
    """The process macOS holds responsible for `pid` (WebKit's XPC processes name their app)."""
    try:
        call = ctypes.CDLL("/usr/lib/libSystem.B.dylib").responsibility_get_pid_responsible_for_pid
    except (OSError, AttributeError):
        return None
    call.restype, call.argtypes = ctypes.c_int, [ctypes.c_int]
    found = call(pid)
    return found if found > 0 else None


def web_processes(app_pid: int, bundle: str, exclude: set[int]) -> list[dict]:
    """[{pid, engine, kind}]: the WebContent processes the app is responsible for and the bundle's
    renderer helpers (not extension renderers). An app launched as a child of this script shares this
    script's responsible process: then a WebContent process with that one, not in `exclude` (the
    processes before the launch), is the app's too."""
    bench = load_module("bench_memory", "bench_memory.py")
    owners = {app_pid, responsible_pid(app_pid)} - {None, os.getpid()}
    out = []
    for pid, _ppid, command in bench.process_table():
        if "com.apple.WebKit.WebContent" in command and pid not in exclude and responsible_pid(pid) in owners:
            out.append({"pid": pid, "engine": "webkit", "kind": "webcontent"})
        elif bench.in_bundle(command, bundle) is not None and bench.kind_of(command, bundle) == "cef-renderer" \
                and "--extension-process" not in command:
            out.append({"pid": pid, "engine": "chromium", "kind": "renderer"})
    return out


def webcontent_pids() -> set[int]:
    if sys.platform != "darwin":
        return set()
    return {pid for pid, _, command in load_module("bench_memory", "bench_memory.py").process_table()
            if "com.apple.WebKit.WebContent" in command}


def process_row(proc: dict, page: str | None, raw_stem: str) -> dict:
    """One row of a web process: phys_footprint and its JS regions."""
    bench = load_module("bench_memory", "bench_memory.py")
    usage = bench.usage(proc["pid"])
    row = {"page": page or f"{proc['kind']}:{proc['pid']}", "mapped": page is not None, "key": f"pid:{proc['pid']}",
           "engine": proc["engine"], "source": "process", "pid": proc["pid"],
           "footprint_bytes": usage[1] if usage else None}
    path = f"{raw_stem}-footprint-{proc['pid']}.json"
    try:
        done = subprocess.run(["footprint", "-j", path, str(proc["pid"])], capture_output=True, text=True, timeout=120)
        with open(path) as handle:
            regions = region_bytes(footprint_categories(json.load(handle)))
        row["js_heap_bytes"] = regions["js"]
        if proc["engine"] == "chromium":
            row["blink_gc_bytes"] = regions["blink"]
        if done.returncode != 0:
            row["error"] = f"footprint exit {done.returncode}"
    except (OSError, ValueError, subprocess.TimeoutExpired) as error:
        row["js_heap_bytes"] = None
        row["error"] = f"footprint: {error}"[:200]
    return row


class Probe:
    """Measures one phase of a running app."""

    def __init__(self, socket_path: str, app_pid: int, bundle: str | None, port: int | None, gc: bool,
                 exclude: set[int] = frozenset()):
        self.socket, self.pid, self.bundle, self.gc, self.exclude = socket_path, app_pid, bundle, gc, set(exclude)
        self.asked_port, self.port, self.cdp = port, None, {}
        self.check_cdp()

    def check_cdp(self) -> None:
        """Whether the DevTools port answers now: Chromium starts on its first page, so each phase asks."""
        self.port = self.asked_port if cdp_port_answers(self.asked_port) else None
        self.cdp = {"port": self.port, "available": self.port is not None,
                    "reason": None if self.port else (NO_CDP if self.asked_port else "no --cdp-port")}

    def call(self, method: str, params: dict | None = None) -> dict:
        return rpc(self.socket, method, params)

    def measure(self, label: str, raw_stem: str, snapshot: bool = False) -> dict:
        self.check_cdp()
        inventory = page_inventory(self.call)
        rows: list[dict] = []
        errors = []
        if self.port:
            try:
                rows += cdp_rows(self.port, self.gc, f"{raw_stem}-{label}" if snapshot else None)
            except (OSError, ConnectionError, RuntimeError, ValueError) as error:
                errors.append(f"cdp: {error}"[:200])
        debug_memory = self.call("debug.memory")
        names = page_pids(self.call("debug.agent_pane", {"action": "pid"}), debug_memory)
        if sys.platform == "darwin" and self.bundle:
            for proc in web_processes(self.pid, self.bundle, self.exclude):
                if proc["engine"] == "chromium" and self.port:
                    continue  # its pages are measured over the DevTools protocol
                rows.append(process_row(proc, names.get(proc["pid"]), f"{raw_stem}-{label}"))
        return build_phase(label, inventory, rows, self.cdp, debug_memory_available="error" not in debug_memory,
                           errors=errors)


def build_phase(label: str, inventory: dict, rows: list[dict], cdp_state: dict,
                debug_memory_available: bool = False, errors: list[str] | None = None) -> dict:
    """The phase report: measured rows, plus one row for each live page no source measured."""
    measured = {row["page"] for row in rows if row.get("js_heap_bytes") is not None or row.get("footprint_bytes")}
    unmeasured = []
    for entry in inventory.get("pages") or []:
        if entry["page"] in measured or any(u["page"] == entry["page"] for u in unmeasured):
            continue
        engine = entry.get("engine") or "unknown"
        if engine == "chromium":
            why = "chromium page: " + (cdp_state.get("reason") or "no page target over CDP") + "; see renderer rows"
        else:
            why = "webkit page: the app names no WebContent process for it; see webcontent rows"
        unmeasured.append({"page": entry["page"], "key": f"page:{entry['page']}", "engine": engine,
                           "source": "none", "instances": sum(e["page"] == entry["page"] for e in inventory["pages"]),
                           "reason": why})
    return {"label": label, "time": round(time.time()), "rows": rows + unmeasured, "inventory": inventory,
            "cdp": cdp_state, "debug_memory": debug_memory_available, "errors": errors or []}


# Queue lines and output.


def mq_jsheap(phases: list[dict], js_limit_mb: float = JS_LIMIT_MB, growth_limit_mb: float = GROWTH_LIMIT_MB,
              base_label: str | None = None) -> list[dict]:
    """One entry per page over a limit in the last phase: JS heap above `js_limit_mb`, or growth above
    `growth_limit_mb` from the `base_label` phase (default: none). Growth reads the JS heap where both
    phases have it, else the process footprint."""
    measured = [p for p in phases if p.get("rows")]
    if not measured:
        return []
    last = measured[-1]
    base = next((p for p in measured if p["label"] == base_label), None) if base_label else None
    before = {row["key"]: row for row in (base or {}).get("rows", [])}
    found: dict[str, dict] = {}
    for row in last["rows"]:
        heap = row.get("js_heap_bytes")
        reasons, growth, metric = [], None, None
        if heap is not None and heap > js_limit_mb * MB:
            reasons.append("size")
        old = before.get(row["key"])
        if old is not None and base is not last:
            metric = "js_heap" if heap is not None and old.get("js_heap_bytes") is not None else "footprint"
            new_value, old_value = (heap, old.get("js_heap_bytes")) if metric == "js_heap" else \
                (row.get("footprint_bytes"), old.get("footprint_bytes"))
            if new_value is not None and old_value is not None:
                growth = new_value - old_value
                if growth > growth_limit_mb * MB:
                    reasons.append("growth")
        if not reasons:
            continue
        entry = found.setdefault(row["page"], {"page": row["page"], "phase": last["label"], "keys": [],
                                               "js_heap_bytes": 0, "growth_bytes": None, "reasons": [],
                                               "engine": row.get("engine"), "source": row.get("source"),
                                               "growth_metric": None, "base": base["label"] if base else None})
        entry["keys"].append(row["key"])
        entry["js_heap_bytes"] = max(entry["js_heap_bytes"], heap or 0)
        if growth is not None and growth > (entry["growth_bytes"] or 0):
            entry["growth_bytes"], entry["growth_metric"] = growth, metric
        entry["reasons"] = sorted(set(entry["reasons"]) | set(reasons))
    return sorted(found.values(), key=lambda e: -(e["js_heap_bytes"] + (e["growth_bytes"] or 0)))


def mb(value) -> str:
    return "-" if value is None else f"{value / MB:.1f}"


def print_phase(phase: dict) -> None:
    cdp_state, inventory = phase["cdp"], phase["inventory"]
    print(f"== {phase['label']}: {len(inventory.get('pages') or [])} live pages "
          f"({'debug.page' if inventory.get('available') else 'debug.page unavailable: ' + str(inventory.get('error'))}); "
          f"CDP {'port ' + str(cdp_state['port']) if cdp_state.get('available') else 'none: ' + str(cdp_state.get('reason'))}; "
          f"debug.memory {'yes' if phase.get('debug_memory') else 'no'}")
    print(f"   {'page':<26}{'engine':<10}{'source':<9}{'js MB':>8}{'total MB':>10}{'fp MB':>8}{'nodes':>8}"
          f"{'listeners':>10}  note")
    for row in sorted(phase["rows"], key=lambda r: (-(r.get("js_heap_bytes") or 0), r["page"])):
        dom = row.get("dom") or {}
        note = row.get("reason") or row.get("error") or row.get("route") or ""
        if row.get("source") == "process" and not row.get("mapped"):
            note = note or "unmapped process"
        print(f"   {row['page'][:25]:<26}{row.get('engine') or '?':<10}{row['source']:<9}{mb(row.get('js_heap_bytes')):>8}"
              f"{mb(row.get('js_heap_total_bytes')):>10}{mb(row.get('footprint_bytes')):>8}"
              f"{str(dom.get('nodes', '-')):>8}{str(dom.get('jsEventListeners', '-')):>10}  {note[:70]}")
        summary = row.get("snapshot")
        if summary:
            print_snapshot(summary, indent="      ")
    total = sum(r.get("js_heap_bytes") or 0 for r in phase["rows"])
    print(f"PAGE-HEAP phase={phase['label']} pages={len(inventory.get('pages') or [])} "
          f"rows={len(phase['rows'])} unmeasured={sum(r['source'] == 'none' for r in phase['rows'])} "
          f"js_heap_mb={total / MB:.1f} cdp={'yes' if cdp_state.get('available') else 'no'}")
    for error in phase.get("errors") or []:
        print(f"   error: {error}")
    sys.stdout.flush()


def print_snapshot(summary: dict, indent: str = "   ") -> None:
    print(f"{indent}snapshot: {summary['reachable']} of {summary['nodes']} nodes reachable, "
          f"{mb(summary['total_bytes'])} MB; detached DOM {summary['detached_dom']['count']} nodes "
          f"{mb(summary['detached_dom']['self_bytes'])} MB")
    for row in summary["constructors"]:
        print(f"{indent}  class {row['name'][:40]:<41} x{row['count']:<8} self {mb(row['self_bytes']):>7} MB "
              f"retained {mb(row['retained_bytes']):>7} MB")
    for row in summary["retainers"]:
        chain = " < ".join(row["dominated_by"]) or "(root)"
        print(f"{indent}  retainer {row['class'][:40]:<41} retained {mb(row['retained_bytes']):>7} MB  under {chain[:80]}")


def print_queue(entries: list[dict], switches: int | None) -> None:
    for entry in entries:
        growth = f" growth_mb={mb(entry['growth_bytes'])} growth_of={entry['growth_metric']} from={entry['base']}" \
            if entry["growth_bytes"] is not None else ""
        over = f" switches={switches}" if switches and entry["growth_bytes"] is not None else ""
        print(f"MQ-JSHEAP page={entry['page']} phase={entry['phase']} js_heap_mb={mb(entry['js_heap_bytes'])}"
              f"{growth}{over} reasons={','.join(entry['reasons'])} engine={entry['engine']} source={entry['source']}")
    sys.stdout.flush()


# Phases of a launched app.


def free_port() -> int:
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def run_launched(args, report: dict, stem: str) -> None:
    bench = load_module("bench_memory", "bench_memory.py")
    bundle = os.path.realpath(args.app)
    port = free_port()
    before = webcontent_pids()
    switches = {"CMUX_NEXT_CEF_EXTRA_SWITCHES": f"remote-debugging-port={port}:remote-allow-origins=*"}
    pid, socket_path, scratch = bench.launch(bundle, json.loads(args.config), switches)
    report.update(pid=pid, app=bundle)
    try:
        probe = Probe(socket_path, pid, bundle, port, gc=not args.no_gc, exclude=before)
        app = bench.App(bundle, socket_path)
        phases = [p for p in args.phases.split(",") if p]
        report["errors"] += [f"unknown phase {p!r} (home, switches)" for p in phases if p not in ("home", "switches")]
        for index, label in enumerate(phases):
            last = index == len(phases) - 1
            if label == "home":
                time.sleep(args.settle)  # test script: the idle window before a measurement
                report["phases"].append(probe.measure("home", stem, snapshot=args.snapshot and last))
            elif label == "switches":
                run_switches(args, report, probe, app, bundle, stem, snapshot=args.snapshot and last)
    finally:
        app_quit = bench.App(bundle, socket_path).run("quit")
        if not bench.wait_gone(pid, 20):
            report.setdefault("errors", []).append(f"quit: {app_quit}"[:200])
        bench.end_bundle(bundle)
        shutil.rmtree(scratch, ignore_errors=True)


def run_switches(args, report: dict, probe: Probe, app, bundle: str, stem: str, snapshot: bool) -> None:
    """--chats answered chats on the fake agent, measured once open (`chats`), then after --switches
    workspace switches between them (`switches`)."""
    bench = load_module("bench_memory", "bench_memory.py")
    if not os.path.exists(args.fake_agent):
        report["phases"].append({"label": "switches", "skipped": f"no fake agent at {args.fake_agent}"})
        return
    try:
        chats = bench.FakeChats(app, bundle, args.fake_agent)
    except SystemExit as error:  # its typed refusals (harness.add, no acpmux socket)
        report["phases"].append({"label": "switches", "skipped": str(error)[:300]})
        return
    workspaces = [w for w in (chats.open(i) for i in range(args.chats)) if w]
    if len(workspaces) < 2:
        report["phases"].append({"label": "switches", "skipped": f"{len(workspaces)} of {args.chats} chats opened"})
        return
    for workspace in workspaces:
        app.action("goToWorkspace", workspace=workspace)
        time.sleep(args.switch_settle)  # test script: each chat shows (its page loads) once
    time.sleep(args.settle)  # test script: the idle window before a measurement
    report["phases"].append(probe.measure("chats", stem))
    refused = 0
    for number in range(args.switches):
        reply = app.action("goToWorkspace", workspace=workspaces[(number + 1) % len(workspaces)])
        refused += bool(reply.get("error"))
        time.sleep(args.switch_settle)  # test script: a person's pace, the shown chat paints
    report["switch_count"], report["switch_refusals"] = args.switches, refused
    time.sleep(args.settle)  # test script: the idle window before a measurement
    report["phases"].append(probe.measure("switches", stem, snapshot=snapshot))


# Entry.


def finish(report: dict, args, out: str | None) -> None:
    for phase in report["phases"]:
        if "skipped" in phase:
            print(f"PAGE-HEAP phase={phase['label']} skipped: {phase['skipped']}")
        else:
            print_phase(phase)
    labels = [p["label"] for p in report["phases"] if p.get("rows")]
    report["cdp"] = next((p["cdp"] for p in reversed(report["phases"]) if p.get("cdp")), report.get("cdp"))
    base = args.growth_from or ("chats" if "chats" in labels and labels[-1] == "switches" else None)
    report["thresholds"] = {"js_limit_mb": args.js_limit_mb, "growth_limit_mb": args.growth_limit_mb, "growth_from": base}
    report["mq_jsheap"] = mq_jsheap(report["phases"], args.js_limit_mb, args.growth_limit_mb, base)
    print_queue(report["mq_jsheap"], report.get("switch_count"))
    print(f"PAGE-HEAP-QUEUE count={len(report['mq_jsheap'])}")
    for error in report.get("errors") or []:
        print(f"PAGE-HEAP error: {error}")
    if out:
        with open(out, "w") as handle:
            json.dump(report, handle, indent=1)
        print(f"page-heap-report: wrote {out}")


def parse(argv: list[str] | None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0], exit_on_error=False,
                                     formatter_class=argparse.RawDescriptionHelpFormatter,
                                     epilog=__doc__.split("\n\n", 1)[1])
    where = parser.add_mutually_exclusive_group(required=True)
    where.add_argument("--app", help="a tagged cmux app bundle to launch (bench, Debug or Release config)")
    where.add_argument("--socket", help="a running app's control socket (with --pid)")
    where.add_argument("--from", dest="saved", help="offline: a saved report to print again")
    where.add_argument("--snapshot-file", help="offline: summarize one .heapsnapshot")
    parser.add_argument("--pid", type=int, help="with --socket: the app's pid")
    parser.add_argument("--cdp-port", type=int, help="with --socket: the app's DevTools port, if it has one")
    parser.add_argument("--phases", default="home,switches", help="with --app: home, switches (default both)")
    parser.add_argument("--switches", type=int, default=50, help="workspace switches between chats (default 50)")
    parser.add_argument("--chats", type=int, default=3, help="answered chats to switch between (default 3)")
    parser.add_argument("--fake-agent", default=FAKE_AGENT, help="the ACP agent script the chats use")
    parser.add_argument("--settle", type=float, default=30, help="idle seconds before each measurement (default 30)")
    parser.add_argument("--switch-settle", type=float, default=1.0, help="seconds after each switch (default 1)")
    parser.add_argument("--snapshot", action="store_true", help="heap snapshots of the CDP pages in the last phase")
    parser.add_argument("--no-gc", action="store_true", help="read the heaps without a collection first")
    parser.add_argument("--config", default="{}", help="with --app: the app's cmux.json as JSON")
    parser.add_argument("--js-limit-mb", type=float, default=JS_LIMIT_MB)
    parser.add_argument("--growth-limit-mb", type=float, default=GROWTH_LIMIT_MB)
    parser.add_argument("--growth-from", help="the phase growth is counted from (default chats, with switches)")
    parser.add_argument("--top", type=int, default=15, help="constructors and retainers per snapshot")
    parser.add_argument("--out", help="the JSON report (default page-heap-report.json next to the cwd)")
    return parser, parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    try:
        parser, args = parse(argv)
    except (argparse.ArgumentError, SystemExit) as error:
        if not isinstance(error, SystemExit) or error.code not in (0, None):
            print(f"PAGE-HEAP error: arguments: {error}")
        return 0
    if args.snapshot_file:
        try:
            with open(args.snapshot_file) as handle:
                summary = snapshot_summary(json.load(handle), args.top)
            print_snapshot(summary)
            if args.out:
                with open(args.out, "w") as handle:
                    json.dump(summary, handle, indent=1)
        except (OSError, ValueError, KeyError, IndexError) as error:
            print(f"PAGE-HEAP error: {args.snapshot_file}: {error}")
        return 0
    if args.saved:
        try:
            with open(args.saved) as handle:
                report = json.load(handle)
            report["phases"] = report.get("phases") or []
        except (OSError, ValueError) as error:
            print(f"PAGE-HEAP error: {args.saved}: {error}")
            return 0
        finish(report, args, args.out)
        return 0
    out = os.path.abspath(args.out or "page-heap-report.json")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    stem = os.path.splitext(out)[0]
    report: dict = {"tool": "page-heap-report", "time": round(time.time()), "phases": [], "errors": []}
    # A fleet cancel or timeout sends SIGTERM: leave through the finally blocks, so the app ends with the run.
    for number in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(number, lambda signum, _frame: sys.exit(128 + signum))
    try:
        if sys.platform != "darwin":
            report["errors"].append("live measurement needs macOS (a fleet Mac); --from and --snapshot-file work anywhere")
        elif args.app:
            run_launched(args, report, stem)
        elif not args.pid:
            report["errors"].append("--socket needs --pid")
        else:
            probe = Probe(args.socket, args.pid, bundle_of(args.pid), args.cdp_port, gc=not args.no_gc)
            report["pid"] = args.pid
            report["phases"].append(probe.measure("attach", stem, snapshot=args.snapshot))
    except (Exception, SystemExit) as error:  # noqa: BLE001 - a report keeps what it measured, and exits 0
        report["errors"].append(f"{type(error).__name__}: {error}"[:500])
    finish(report, args, out)
    return 0


def bundle_of(pid: int) -> str | None:
    """The .app bundle of a running process, from its command line."""
    out = subprocess.run(["ps", "-o", "command=", "-p", str(pid)], capture_output=True, text=True).stdout
    found = re.match(r"^(.+?\.app)/Contents/MacOS/", out.strip())
    return found.group(1) if found else None


if __name__ == "__main__":
    sys.exit(main())
