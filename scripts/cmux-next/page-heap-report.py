#!/usr/bin/env python3
"""JS heap per cmux page (p07-memory task 102, MQ-JSHEAP).

For every live cmux page (a PageDescriptor page, `cmux-page://<id>`, named by its descriptor id such as
`cmux.agent`), measures its JavaScript heap:

  * Chromium pages over the DevTools protocol, when the app has a DevTools port: `Runtime.getHeapUsage`
    before and after `HeapProfiler.collectGarbage`, `Memory.getDOMCounters`, and a heap snapshot summary
    (constructors by retained size, the largest retainers, detached DOM nodes). This is Chrome's own heap
    view: the Summary of DevTools' Memory panel and its dominator tree
    (front_end/entrypoints/heap_snapshot_worker/HeapSnapshot.ts: weak edges retain nothing, shortcut
    edges only from the root, Cooper-Harvey-Kennedy dominators, class retained size counted once per
    dominator path). By default (--snapshot flagged) only the pages with an MQ-JSHEAP line get a snapshot.
  * WebKit pages by their WebContent process: phys_footprint, and the JavaScriptCore regions of
    `footprint -j` (JS VM Gigacage, JS garbage collector, JS JIT, ...) as the page's JS bytes.
  * Chromium pages with no DevTools port (a Release or bench build: CMUX_NEXT_CEF_EXTRA_SWITCHES is read
    by DEBUG builds only, CEFSwitches.swift) by their renderer process: phys_footprint and its V8 regions
    (VM tag 255, partition_alloc/page_allocator_constants.h).
  `footprint -j` is read by footprint_json.py; a capture with no JS region rows is no JS measurement, and
  growth then reads the process footprint.

`debug.webui` (DEBUG and bench builds, read-only without `reset`) names every live page instance, its
engine, and the renderer and WebContent pids that run it (WebUICensus.swift), as Chrome's task manager
names the tabs each renderer hosts. Process rows take those page ids; a page no source measured gets a
row that says why.

Phases (--app): `home` (Home idle after --settle seconds) and `switches` (--chats answered agent chats
on the fake ACP agent, measured once open, then after --switches workspace switches between them).
Prints one table per phase, `PAGE-HEAP phase=...` and one `MQ-JSHEAP page=...` line for each page whose
JS heap is above 20 MB in the last phase or grew by more than 5 MB over the switches, with its top
retainers under it (each line is one webviews/ fix task, p07-memory.md section 6). Growth compares each
page's summed rows, so a page whose instance was replaced during the switches is still compared, and a
`PAGE-HEAP growth-note` says so. Writes one JSON report (--out); --from re-reads it.

Usage:
  page-heap-report.py --app BUNDLE [--phases home,switches] [--switches 50] [--chats 3] [--settle 30]
      [--snapshot none|flagged|all] [--out FILE.json]
      Launch a tagged app (scratch HOME and config), measure each phase, quit it. Fleet only
      (scripts/measure/page-heap-report.sh).
  page-heap-report.py --socket PATH --pid PID [--cdp-port N] [--snapshot none|flagged|all] [--out FILE.json]
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
import footprint_json  # noqa: E402 - the one `footprint -j` parser (memory-report.py, cold_scrollback.py)
from ext_e2e import cdp  # noqa: E402 - stdlib-only DevTools client next to this script

MB = 1048576.0
JS_LIMIT_MB = 20.0
GROWTH_LIMIT_MB = 5.0
FAKE_AGENT = os.path.join(ROOT, "cmux-tui", "crates", "acpmux", "tests", "fake_agent.py")
NO_CDP = "no DevTools port (Release and bench builds ignore CMUX_NEXT_CEF_EXTRA_SWITCHES)"
SNAPSHOT_MODES = ("none", "flagged", "all")


def page_of_url(url: str | None) -> str | None:
    """The cmux page a document URL belongs to: the host of `cmux-page://<id>/...` (the PageDescriptor
    id, `cmux.agent` for the agent page); None for any other document (browser tabs, devtools://,
    about:blank)."""
    parsed = urlparse(url or "")
    scheme, host = parsed.scheme.lower(), (parsed.hostname or "").lower()
    return host if scheme == "cmux-page" and host else None


# Process regions: `footprint -j` of a WebContent or renderer process.


def footprint_regions(document, pid: int | None = None) -> dict:
    """{js, blink, footprint, rows} of process `pid` (else the first) in `footprint -j` JSON, read by
    footprint_json.py (resident dirty plus compressed bytes per category). `js` and `blink` are None when
    no category row is of that kind: a capture with no rows, or of a shape footprint_json does not know,
    is no measurement, never 0 bytes."""
    found = footprint_json.processes(document)
    proc = next((p for p in found if int(p["pid"]) == pid), found[0] if found else None)
    if proc is None:
        return {"js": None, "blink": None, "footprint": None, "rows": 0}
    columns = footprint_json.columns(proc)
    footprint = columns["footprint"] if columns["rows"] else footprint_json.process_footprint(proc)
    return dict(region_bytes(columns["categories"]), footprint=footprint, rows=columns["rows"])


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


def region_bytes(categories: dict[str, int]) -> dict[str, int | None]:
    """{js, blink}: the bytes of each kind of region, None for a kind no category is."""
    out: dict[str, int | None] = {"js": None, "blink": None}
    for name, value in categories.items():
        kind = region_kind(name)
        if kind:
            out[kind] = (out[kind] or 0) + value
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

    def __init__(self, ws_url: str, timeout: float = 15):
        try:
            super().__init__(ws_url, timeout)
        except (OSError, ConnectionError):
            if getattr(self, "sock", None) is not None:
                self.sock.close()  # a refused handshake leaves the connected socket open
            raise

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


def cdp_page_targets(port: int) -> list[tuple[dict, str]]:
    """[(target, page)]: the page targets that show a cmux page (not browser tabs, workers or DevTools)."""
    found = []
    for target in cdp.target_infos(port):
        page = page_of_url(target.get("url"))
        if target.get("type") == "page" and page is not None:
            found.append((target, page))
    return found


def cdp_rows(port: int, gc: bool) -> list[dict]:
    """One row per page target of a cmux page: heap usage before and after GC, and DOM counters."""
    rows = []
    for target, page in cdp_page_targets(port):
        row = {"page": page, "pages": [page], "key": "cdp:" + target["targetId"], "engine": "chromium",
               "source": "cdp", "route": urlparse(target.get("url") or "").fragment[:60] or None}
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
        except (OSError, ConnectionError, RuntimeError, ValueError, KeyError) as error:
            row["error"] = f"{type(error).__name__}: {error}"[:200]
        finally:
            session.close()
        rows.append(row)
    return rows


def cdp_snapshots(port: int, keys: set[str], stem: str, top: int = 15) -> dict[str, dict]:
    """{row key: snapshot summary with its `file`, or {"error"}} for the page targets whose `cdp:<targetId>`
    key is in `keys`."""
    out: dict[str, dict] = {}
    for target, page in cdp_page_targets(port):
        key = "cdp:" + target["targetId"]
        if key not in keys:
            continue
        path = f"{stem}-{page}-{re.sub(r'[^A-Za-z0-9]', '', target['targetId'])[:12]}.heapsnapshot"
        try:
            session = SnapshotSession(f"ws://127.0.0.1:{port}/devtools/page/{target['targetId']}")
        except (OSError, ConnectionError) as error:
            out[key] = {"error": f"attach: {error}"[:200]}
            continue
        try:
            session.take_snapshot(path)
            with open(path) as handle:
                out[key] = dict(snapshot_summary(json.load(handle), top), file=path)
        except (OSError, ConnectionError, RuntimeError, ValueError, KeyError, IndexError) as error:
            out[key] = {"error": f"{type(error).__name__}: {error}"[:200]}
        finally:
            session.close()
    return out


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


def webui_census(reply: dict) -> dict:
    """{available, error, pages: [{page, instance, parked, engine, state}], pids: {pid: [host]}} from a
    `debug.webui` reply (WebUICensus.swift): each page's `renderer_pids` and `webkit_pid` name the
    processes that run it, as do the spares' (`spare:<name>`)."""
    if "error" in reply:
        return {"available": False, "error": json.dumps(reply["error"])[:200], "pages": [], "pids": {}}
    pages, pids = [], {}

    def host(numbers, name: str) -> None:
        for pid in numbers:
            if isinstance(pid, (int, float)) and not isinstance(pid, bool) and name not in pids.get(int(pid), []):
                pids.setdefault(int(pid), []).append(name)

    for entry in reply.get("pages") or []:
        if not isinstance(entry, dict) or not entry.get("page"):
            continue
        page = str(entry["page"]).lower()
        pages.append({"page": page, "instance": entry.get("instance"), "parked": entry.get("spare") is not None,
                      "engine": entry.get("engine"), "state": entry.get("state")})
        host(list(entry.get("renderer_pids") or []) + [entry.get("webkit_pid")], page)
    for spare in reply.get("spares") or []:
        if isinstance(spare, dict) and spare.get("spare"):
            host(list(spare.get("renderer_pids") or []) + [spare.get("webkit_pid")], f"spare:{spare['spare']}")
    return {"available": True, "error": None, "pages": pages, "pids": pids}


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


def process_row(proc: dict, hosts: list[str], footprint_bytes: int | None, document=None,
                error: str | None = None) -> dict:
    """One row of a web process: phys_footprint and the JS regions of its `footprint -j` document.
    `hosts` are the pages `debug.webui` says it runs; a process that runs none is `<kind>:<pid>`."""
    names = sorted(set(hosts))
    regions = footprint_regions(document, proc["pid"]) if document is not None else \
        {"js": None, "blink": None, "footprint": None, "rows": 0}
    row = {"page": "+".join(names) or f"{proc['kind']}:{proc['pid']}", "pages": names, "mapped": bool(names),
           "key": f"pid:{proc['pid']}", "engine": proc["engine"], "source": "process", "pid": proc["pid"],
           "footprint_bytes": footprint_bytes if footprint_bytes is not None else regions["footprint"],
           "js_heap_bytes": regions["js"], "footprint_rows": regions["rows"]}
    if proc["engine"] == "chromium":
        row["blink_gc_bytes"] = regions["blink"]
    if error:
        row["error"] = error[:200]
    elif regions["js"] is None:
        row["error"] = "footprint: no JS region rows" if regions["rows"] else "footprint: no category rows"
    return row


def measure_process(proc: dict, hosts: list[str], raw_stem: str) -> dict:
    """process_row of a live process: its phys_footprint (proc_pid_rusage) and a `footprint -j` capture."""
    bench = load_module("bench_memory", "bench_memory.py")
    usage = bench.usage(proc["pid"])
    path = f"{raw_stem}-footprint-{proc['pid']}.json"
    try:
        done = subprocess.run(["footprint", "-j", path, str(proc["pid"])], capture_output=True, text=True, timeout=120)
        with open(path) as handle:
            document = json.load(handle)
        error = f"footprint exit {done.returncode}" if done.returncode != 0 else None
    except (OSError, ValueError, subprocess.TimeoutExpired) as failure:
        document, error = None, f"footprint: {failure}"
    return process_row(proc, hosts, usage[1] if usage else None, document, error)


class Probe:
    """Measures one phase of a running app. `list_processes` (the app's web processes) and
    `measure_process` (one process's row) are seams: the defaults read macOS."""

    def __init__(self, socket_path: str, app_pid: int, bundle: str | None, port: int | None, gc: bool,
                 exclude: set[int] = frozenset(), list_processes=None, measure_process=measure_process):
        self.socket, self.pid, self.bundle, self.gc, self.exclude = socket_path, app_pid, bundle, gc, set(exclude)
        self.asked_port, self.port, self.cdp = port, None, {}
        self.list_processes = list_processes or self.web_processes
        self.measure_process = measure_process
        self.check_cdp()

    def web_processes(self) -> list[dict]:
        if sys.platform != "darwin" or not self.bundle:
            return []
        return web_processes(self.pid, self.bundle, self.exclude)

    def check_cdp(self) -> None:
        """Whether the DevTools port answers now: Chromium starts on its first page, so each phase asks."""
        self.port = self.asked_port if cdp_port_answers(self.asked_port) else None
        self.cdp = {"port": self.port, "available": self.port is not None,
                    "reason": None if self.port else (NO_CDP if self.asked_port else "no --cdp-port")}

    def call(self, method: str, params: dict | None = None) -> dict:
        return rpc(self.socket, method, params)

    def measure(self, label: str, raw_stem: str) -> dict:
        self.check_cdp()
        census = webui_census(self.call("debug.webui"))
        rows: list[dict] = []
        errors = []
        if self.port:
            try:
                rows += cdp_rows(self.port, self.gc)
            except (OSError, ConnectionError, RuntimeError, ValueError) as error:
                errors.append(f"cdp: {error}"[:200])
        for proc in self.list_processes():
            if proc["engine"] == "chromium" and self.port:
                continue  # its pages are measured over the DevTools protocol
            rows.append(self.measure_process(proc, census["pids"].get(proc["pid"], []), f"{raw_stem}-{label}"))
        return build_phase(label, census, rows, self.cdp, errors=errors)

    def snapshot(self, phases: list[dict], args, stem: str) -> None:
        """Heap snapshots of the last phase's DevTools pages, per --snapshot (flagged: the MQ-JSHEAP pages)."""
        self.check_cdp()
        if self.port:
            add_snapshots(phases, args, self.port, stem)


def add_snapshots(phases: list[dict], args, port: int, stem: str) -> None:
    """Adds a `snapshot` (or `snapshot_error`) to the last measured phase's CDP rows: every one with
    --snapshot all, those of pages with an MQ-JSHEAP line with --snapshot flagged."""
    measured = [p for p in phases if p.get("rows")]
    if args.snapshot == "none" or not measured:
        return
    last = measured[-1]
    flagged = None if args.snapshot == "all" else \
        {e["page"] for e in mq_jsheap(phases, args.js_limit_mb, args.growth_limit_mb, growth_base(args, phases))}
    keys = {row["key"] for row in last["rows"] if row.get("source") == "cdp" and "error" not in row
            and (flagged is None or row["page"] in flagged)}
    if not keys:
        return
    found = cdp_snapshots(port, keys, f"{stem}-{last['label']}", args.top)
    for row in last["rows"]:
        summary = found.get(row.get("key"))
        if summary is not None:
            row["snapshot" if "error" not in summary else "snapshot_error"] = summary.get("error") or summary


def build_phase(label: str, inventory: dict, rows: list[dict], cdp_state: dict,
                errors: list[str] | None = None) -> dict:
    """The phase report: measured rows, plus one row for each live page no source measured."""
    measured = {page for row in rows if row.get("js_heap_bytes") is not None or row.get("footprint_bytes")
                for page in (row.get("pages") or [row["page"]])}
    pages = inventory.get("pages") or []
    unmeasured = []
    for entry in pages:
        if entry["page"] in measured or any(u["page"] == entry["page"] for u in unmeasured):
            continue
        engine = entry.get("engine") or "unknown"
        if engine == "chromium":
            why = "chromium page: " + (cdp_state.get("reason") or "no page target over CDP") + \
                "; debug.webui names no renderer pid for it"
        else:
            why = "webkit page: debug.webui names no WebContent pid for it"
        unmeasured.append({"page": entry["page"], "pages": [entry["page"]], "key": f"page:{entry['page']}",
                           "engine": engine, "source": "none",
                           "instances": sum(e["page"] == entry["page"] for e in pages), "reason": why})
    return {"label": label, "time": round(time.time()), "rows": rows + unmeasured,
            "inventory": {k: inventory.get(k) for k in ("available", "error", "pages")},
            "cdp": cdp_state, "errors": errors or []}


# Queue lines and output.


def page_totals(rows: list[dict]) -> dict[str, dict]:
    """{page: {keys, rows, js, footprint, max_js, engine, source}} over the measured rows of a phase: `js`
    and `footprint` sum the page's rows, None when one of them has no such reading."""
    out: dict[str, dict] = {}
    for row in rows:
        if row.get("source") == "none":
            continue
        total = out.setdefault(str(row.get("page")), {"keys": [], "rows": [], "js": 0, "footprint": 0, "max_js": None,
                                                     "engine": row.get("engine"), "source": row.get("source")})
        total["keys"].append(row.get("key"))
        total["rows"].append(row)
        heap, footprint = row.get("js_heap_bytes"), row.get("footprint_bytes")
        total["js"] = None if total["js"] is None or heap is None else total["js"] + heap
        total["footprint"] = None if total["footprint"] is None or footprint is None else total["footprint"] + footprint
        if heap is not None:
            total["max_js"] = max(total["max_js"] or 0, heap)
    return out


def page_growth(phases: list[dict], base_label: str | None) -> dict:
    """{last, base, pages: {page: page_totals + growth, metric, gone, new}, absent}: each page of the last
    measured phase against the same page in the `base_label` phase, by the sum of its rows, so an instance
    discarded, restored or recreated between them is still compared. Growth reads the JS heap where both
    sums have it, else the process footprint. `gone` and `new` are the instance keys only one phase has;
    `absent` are the base pages the last phase does not measure."""
    measured = [p for p in phases if p.get("rows")]
    if not measured:
        return {"last": None, "base": None, "pages": {}, "absent": []}
    last = measured[-1]
    base = next((p for p in measured if p.get("label") == base_label), None) if base_label else None
    if base is last:
        base = None
    now, before = page_totals(last["rows"]), page_totals(base["rows"]) if base else {}
    for page, total in now.items():
        total.update(growth=None, metric=None, gone=[], new=[])
        old = before.get(page)
        if old is None:
            continue
        total["gone"] = [k for k in old["keys"] if k not in total["keys"]]
        total["new"] = [k for k in total["keys"] if k not in old["keys"]]
        for metric, key in (("js_heap", "js"), ("footprint", "footprint")):
            if total[key] is not None and old[key] is not None:
                total["growth"], total["metric"] = total[key] - old[key], metric
                break
    return {"last": last.get("label"), "base": base.get("label") if base else None, "pages": now,
            "absent": sorted(page for page in before if page not in now)}


def retainers_of(total: dict) -> tuple[list[dict], str | None]:
    """The top retainers of a page's largest snapshot, or none and why."""
    snapshots = sorted((r for r in total["rows"] if isinstance(r.get("snapshot"), dict)),
                       key=lambda r: -(r.get("js_heap_bytes") or 0))
    if snapshots:
        return snapshots[0]["snapshot"].get("retainers", [])[:5], None
    if total["source"] != "cdp":
        return [], f"{total['engine']} page measured by its process: heap snapshots need the DevTools port"
    errors = [r["snapshot_error"] for r in total["rows"] if r.get("snapshot_error")]
    return [], errors[0] if errors else "no heap snapshot taken (--snapshot none)"


def mq_jsheap(phases: list[dict], js_limit_mb: float = JS_LIMIT_MB, growth_limit_mb: float = GROWTH_LIMIT_MB,
              base_label: str | None = None) -> list[dict]:
    """One entry per page over a limit in the last phase: an instance's JS heap above `js_limit_mb`, or
    the page's growth (page_growth) above `growth_limit_mb` from the `base_label` phase (default: none)."""
    compared = page_growth(phases, base_label)
    found = []
    for page, total in compared["pages"].items():
        reasons = []
        if total["max_js"] is not None and total["max_js"] > js_limit_mb * MB:
            reasons.append("size")
        if total["growth"] is not None and total["growth"] > growth_limit_mb * MB:
            reasons.append("growth")
        if not reasons:
            continue
        retainers, why = retainers_of(total)
        found.append({"page": page, "phase": compared["last"], "keys": total["keys"],
                      "js_heap_bytes": total["max_js"] or 0, "growth_bytes": total["growth"], "reasons": reasons,
                      "engine": total["engine"], "source": total["source"], "growth_metric": total["metric"],
                      "base": compared["base"], "instances_gone": len(total["gone"]),
                      "instances_new": len(total["new"]), "retainers": retainers, "retainers_reason": why})
    return sorted(found, key=lambda e: -(e["js_heap_bytes"] + (e["growth_bytes"] or 0)))


def growth_notes(phases: list[dict], base_label: str | None) -> list[str]:
    """`PAGE-HEAP growth-note` lines: the pages whose instances differ between the base and the last phase."""
    compared = page_growth(phases, base_label)
    if not compared["base"]:
        return []
    head = f"base={compared['base']} last={compared['last']}"
    lines = [f"PAGE-HEAP growth-note page={page} {head} instances_gone={len(total['gone'])} "
             f"instances_new={len(total['new'])}: growth compares the page's summed rows"
             for page, total in sorted(compared["pages"].items()) if total["gone"] or total["new"]]
    return lines + [f"PAGE-HEAP growth-note page={page} {head}: measured in the base phase, not in the last"
                    for page in compared["absent"]]


def mb(value) -> str:
    return "-" if value is None else f"{value / MB:.1f}"


def print_phase(phase: dict) -> None:
    cdp_state, inventory, rows = phase.get("cdp") or {}, phase.get("inventory") or {}, phase.get("rows") or []
    print(f"== {phase.get('label')}: {len(inventory.get('pages') or [])} live pages "
          f"({'debug.webui' if inventory.get('available') else 'debug.webui unavailable: ' + str(inventory.get('error'))}); "
          f"CDP {'port ' + str(cdp_state.get('port')) if cdp_state.get('available') else 'none: ' + str(cdp_state.get('reason'))}")
    print(f"   {'page':<26}{'engine':<10}{'source':<9}{'js MB':>8}{'total MB':>10}{'fp MB':>8}{'nodes':>8}"
          f"{'listeners':>10}  note")
    for row in sorted(rows, key=lambda r: (-(r.get("js_heap_bytes") or 0), str(r.get("page")))):
        dom = row.get("dom") or {}
        note = row.get("reason") or row.get("error") or row.get("route") or ""
        if row.get("source") == "process" and not row.get("mapped"):
            note = note or "no page in debug.webui"
        print(f"   {str(row.get('page'))[:25]:<26}{row.get('engine') or '?':<10}{str(row.get('source')):<9}"
              f"{mb(row.get('js_heap_bytes')):>8}{mb(row.get('js_heap_total_bytes')):>10}{mb(row.get('footprint_bytes')):>8}"
              f"{str(dom.get('nodes', '-')):>8}{str(dom.get('jsEventListeners', '-')):>10}  {str(note)[:70]}")
        if isinstance(row.get("snapshot"), dict):
            print_snapshot(row["snapshot"], indent="      ")
        elif row.get("snapshot_error"):
            print(f"      snapshot: {row['snapshot_error']}")
    total = sum(r.get("js_heap_bytes") or 0 for r in rows)
    print(f"PAGE-HEAP phase={phase.get('label')} pages={len(inventory.get('pages') or [])} "
          f"rows={len(rows)} unmeasured={sum(r.get('source') == 'none' for r in rows)} "
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
            if entry.get("growth_bytes") is not None else ""
        over = f" switches={switches}" if switches and entry.get("growth_bytes") is not None else ""
        print(f"MQ-JSHEAP page={entry['page']} phase={entry['phase']} js_heap_mb={mb(entry['js_heap_bytes'])}"
              f"{growth}{over} reasons={','.join(entry['reasons'])} engine={entry['engine']} source={entry['source']}")
        for row in entry.get("retainers") or []:
            chain = " < ".join(row.get("dominated_by") or []) or "(root)"
            print(f"   retainer {str(row.get('class'))[:40]:<41} retained {mb(row.get('retained_bytes')):>7} MB  "
                  f"under {chain[:80]}")
        if not entry.get("retainers") and entry.get("retainers_reason"):
            print(f"   retainers: none ({entry['retainers_reason']})")
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
        for label in phases:
            if label == "home":
                time.sleep(args.settle)  # test script: the idle window before a measurement
                report["phases"].append(probe.measure("home", stem))
            elif label == "switches":
                run_switches(args, report, probe, app, bundle, stem)
        probe.snapshot(report["phases"], args, stem)
    finally:
        app_quit = bench.App(bundle, socket_path).run("quit")
        if not bench.wait_gone(pid, 20):
            report.setdefault("errors", []).append(f"quit: {app_quit}"[:200])
        bench.end_bundle(bundle)
        shutil.rmtree(scratch, ignore_errors=True)


def run_switches(args, report: dict, probe: Probe, app, bundle: str, stem: str) -> None:
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
    report["phases"].append(probe.measure("switches", stem))


# Entry.


def growth_base(args, phases: list[dict]) -> str | None:
    """--growth-from, else `chats` when the last measured phase is `switches`."""
    labels = [p.get("label") for p in phases if p.get("rows")]
    return args.growth_from or ("chats" if "chats" in labels and labels[-1] == "switches" else None)


def finish(report: dict, args, out: str | None) -> None:
    for phase in report["phases"]:
        if "skipped" in phase:
            print(f"PAGE-HEAP phase={phase.get('label')} skipped: {phase['skipped']}")
        else:
            print_phase(phase)
    report["cdp"] = next((p["cdp"] for p in reversed(report["phases"]) if p.get("cdp")), report.get("cdp"))
    base = growth_base(args, report["phases"])
    report["thresholds"] = {"js_limit_mb": args.js_limit_mb, "growth_limit_mb": args.growth_limit_mb, "growth_from": base}
    report["mq_jsheap"] = mq_jsheap(report["phases"], args.js_limit_mb, args.growth_limit_mb, base)
    print_queue(report["mq_jsheap"], report.get("switch_count"))
    print(f"PAGE-HEAP-QUEUE count={len(report['mq_jsheap'])}")
    for line in growth_notes(report["phases"], base):
        print(line)
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
    parser.add_argument("--snapshot", nargs="?", const="all", default="flagged", choices=SNAPSHOT_MODES,
                        help="heap snapshots of the last phase's CDP pages: flagged (default: the pages with an "
                             "MQ-JSHEAP line), all (also bare --snapshot) or none")
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
            if not isinstance(report, dict):
                raise ValueError(f"not a report object but a JSON {type(report).__name__}")
            report["phases"] = [p for p in report.get("phases") or [] if isinstance(p, dict)]
            finish(report, args, args.out)
        except Exception as error:  # noqa: BLE001 - a saved report of any shape still exits 0
            print(f"PAGE-HEAP error: {args.saved}: {type(error).__name__}: {error}"[:500])
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
            report["phases"].append(probe.measure("attach", stem))
            probe.snapshot(report["phases"], args, stem)
    except (Exception, SystemExit) as error:  # noqa: BLE001 - a report keeps what it measured, and exits 0
        report["errors"].append(f"{type(error).__name__}: {error}"[:500])
    try:
        finish(report, args, out)
    except Exception as error:  # noqa: BLE001 - printing a partial report still exits 0
        print(f"PAGE-HEAP error: report: {type(error).__name__}: {error}"[:500])
    return 0


def bundle_of(pid: int) -> str | None:
    """The .app bundle of a running process, from its command line."""
    out = subprocess.run(["ps", "-o", "command=", "-p", str(pid)], capture_output=True, text=True).stdout
    found = re.match(r"^(.+?\.app)/Contents/MacOS/", out.strip())
    return found.group(1) if found else None


if __name__ == "__main__":
    sys.exit(main())
