#!/usr/bin/env python3
"""Reproducible browser-engine performance bench for a tagged cmux build.

Measures what the Chromium (CEF) engine costs next to WebKit, and that it
costs nothing while it is unused:

- bundle:  app bundle size, and the share taken by the Chromium framework and
           its helper apps.
- run:     launches the tagged app in the background (`open -g -n`, so the
           user's focus and windows are untouched), then records
             * launch time to a live control socket (median of --launches),
             * idle cost after launch: app footprint, engine helper processes,
               whether the Chromium framework is mapped at all,
             * per engine: first-page and warm-page load time, memory per tab
               (app + engine processes, physical footprint), idle CPU of the
               engine processes with hidden tabs,
             * terminal key latency (socket `simulate_shortcut` round trip on
               the main thread) with no browser, and with a visible animating
               page of each engine next to the terminal.
- compare: renders two or more result JSON files as a Markdown table.

Engine selection uses `browser.open_split` params: pass
`--open-param chromium:engine=chromium` (repeatable, `<engine>:<key>=<value>`)
so the bench keeps working whatever the per-open override is called. WebKit
opens with no extra params, which is also the shipping default.

Never point this at the user's cmux: it refuses a bundle without a tag and
only talks to the tagged socket it launched.
"""

from __future__ import annotations

import argparse
import ctypes
import http.server
import json
import os
import pathlib
import platform
import re
import select
import socket
import statistics
import subprocess
import sys
import tempfile
import threading
import time
from typing import Any

CHROMIUM_FRAMEWORK = "Chromium Embedded Framework.framework"
WEBKIT_PROCESS_MARKERS = ("com.apple.WebKit.WebContent", "com.apple.WebKit.Networking", "com.apple.WebKit.GPU")


# ---------------------------------------------------------------------------
# Process accounting (no extra tools: libproc through ctypes)


class _RUsageInfoV2(ctypes.Structure):
    _fields_ = [
        ("ri_uuid", ctypes.c_uint8 * 16),
        ("ri_user_time", ctypes.c_uint64),
        ("ri_system_time", ctypes.c_uint64),
        ("ri_pkg_idle_wkups", ctypes.c_uint64),
        ("ri_interrupt_wkups", ctypes.c_uint64),
        ("ri_pageins", ctypes.c_uint64),
        ("ri_wired_size", ctypes.c_uint64),
        ("ri_resident_size", ctypes.c_uint64),
        ("ri_phys_footprint", ctypes.c_uint64),
        ("ri_proc_start_abstime", ctypes.c_uint64),
        ("ri_proc_exit_abstime", ctypes.c_uint64),
        ("ri_child_user_time", ctypes.c_uint64),
        ("ri_child_system_time", ctypes.c_uint64),
        ("ri_child_pkg_idle_wkups", ctypes.c_uint64),
        ("ri_child_interrupt_wkups", ctypes.c_uint64),
        ("ri_child_pageins", ctypes.c_uint64),
        ("ri_child_elapsed_abstime", ctypes.c_uint64),
        ("ri_diskio_bytesread", ctypes.c_uint64),
        ("ri_diskio_byteswritten", ctypes.c_uint64),
    ]


_libproc: dict[str, Any] = {}


def _proc() -> dict[str, Any]:
    """libproc bindings, loaded on first use so the module imports on Linux CI."""
    if not _libproc:
        libc = ctypes.CDLL(None)
        libc.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
        libc.proc_pid_rusage.restype = ctypes.c_int
        responsible = getattr(libc, "responsibility_get_pid_responsible_for_pid", None)
        if responsible is not None:
            responsible.argtypes = [ctypes.c_int]
            responsible.restype = ctypes.c_int

        class Timebase(ctypes.Structure):
            _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]

        timebase = Timebase()
        libc.mach_timebase_info(ctypes.byref(timebase))
        _libproc.update(libc=libc, responsible=responsible, ratio=timebase.numer / max(1, timebase.denom))
    return _libproc


def rusage(pid: int) -> _RUsageInfoV2 | None:
    info = _RUsageInfoV2()
    if _proc()["libc"].proc_pid_rusage(pid, 2, ctypes.byref(info)) != 0:
        return None
    return info


def cpu_ns(info: _RUsageInfoV2) -> float:
    return (info.ri_user_time + info.ri_system_time) * _proc()["ratio"]


def responsible_pid(pid: int) -> int:
    responsible = _proc()["responsible"]
    return responsible(pid) if responsible is not None else -1


def list_processes() -> list[tuple[int, int, str]]:
    out = subprocess.run(["ps", "-axww", "-o", "pid=,ppid=,comm="], capture_output=True, text=True).stdout
    rows = []
    for line in out.splitlines():
        parts = line.strip().split(None, 2)
        if len(parts) == 3:
            rows.append((int(parts[0]), int(parts[1]), parts[2]))
    return rows


def classify(path: str, app_path: str) -> str:
    if any(marker in path for marker in WEBKIT_PROCESS_MARKERS):
        return "webkit"
    inside = path.startswith(app_path.rstrip("/") + "/")
    if inside and "Helper" in os.path.basename(path):
        return "chromium"
    if inside:
        return "app_aux"
    return "other"


def app_processes(app_pid: int, app_path: str) -> list[tuple[int, str]]:
    """Every process the app is responsible for (children and XPC services), with its group."""
    rows = list_processes()
    children: dict[int, list[int]] = {}
    for pid, ppid, _ in rows:
        children.setdefault(ppid, []).append(pid)
    descendants: set[int] = set()
    stack = [app_pid]
    while stack:
        for child in children.get(stack.pop(), []):
            if child not in descendants:
                descendants.add(child)
                stack.append(child)
    found = []
    for pid, _ppid, path in rows:
        if pid == app_pid:
            continue
        if pid in descendants or responsible_pid(pid) == app_pid:
            found.append((pid, path))
    return found


def process_tree(app_pid: int, app_path: str) -> dict[str, list[dict[str, Any]]]:
    groups: dict[str, list[dict[str, Any]]] = {"webkit": [], "chromium": [], "app_aux": [], "other": []}
    for pid, path in app_processes(app_pid, app_path):
        info = rusage(pid)
        groups[classify(path, app_path)].append({
            "pid": pid,
            "name": os.path.basename(path),
            "footprint_bytes": int(info.ri_phys_footprint) if info else 0,
        })
    return groups


def chromium_framework_mapped(pid: int) -> bool:
    out = subprocess.run(["lsof", "-p", str(pid), "-Fn"], capture_output=True, text=True).stdout
    return CHROMIUM_FRAMEWORK in out


def app_footprint_median(app_pid: int, samples: int = 5, interval_s: float = 0.4) -> int:
    """The app's footprint as the median of a few reads: Debug builds allocate and free
    hundreds of MB in background work, so one read is too noisy to diff."""
    reads = []
    for index in range(samples):
        info = rusage(app_pid)
        reads.append(int(info.ri_phys_footprint) if info else 0)
        if index < samples - 1:
            time.sleep(interval_s)
    return int(statistics.median(reads))


def engine_snapshot(app_pid: int, app_path: str) -> dict[str, Any]:
    groups = process_tree(app_pid, app_path)
    return {
        "app_footprint_bytes": app_footprint_median(app_pid),
        "app_resident_bytes": int(getattr(rusage(app_pid), "ri_resident_size", 0)),
        "webkit_processes": len(groups["webkit"]),
        "webkit_footprint_bytes": sum(p["footprint_bytes"] for p in groups["webkit"]),
        "chromium_processes": len(groups["chromium"]),
        "chromium_footprint_bytes": sum(p["footprint_bytes"] for p in groups["chromium"]),
        "chromium_process_names": sorted({p["name"] for p in groups["chromium"]}),
        "chromium_framework_mapped": chromium_framework_mapped(app_pid),
    }


def cpu_sample(processes: list[tuple[int, str]]) -> tuple[float, dict[int, tuple[str, float]]]:
    """CPU time per pid, read in one tight pass and stamped at its midpoint."""
    start = time.perf_counter()
    sample = {}
    for pid, group in processes:
        info = rusage(pid)
        if info is not None:
            sample[pid] = (group, cpu_ns(info))
    return (start + time.perf_counter()) / 2, sample


def cpu_percent_over(app_pid: int, app_path: str, seconds: float) -> dict[str, float]:
    """CPU use per group over a window, counting only processes alive at both ends."""
    processes = [(app_pid, "app")] + [(pid, classify(path, app_path)) for pid, path in app_processes(app_pid, app_path)]
    t0, before = cpu_sample(processes)
    time.sleep(seconds)
    t1, after = cpu_sample(processes)
    window_ns = (t1 - t0) * 1e9
    totals = {"app": 0.0, "webkit": 0.0, "chromium": 0.0}
    for pid, (group, used) in after.items():
        if pid in before and group in totals:
            totals[group] += max(0.0, used - before[pid][1])
    return {group: round(value / window_ns * 100.0, 2) for group, value in totals.items()}


# ---------------------------------------------------------------------------
# Bundle size


def tree_bytes(path: pathlib.Path) -> int:
    total = 0
    for root, _dirs, files in os.walk(path):
        for name in files:
            full = os.path.join(root, name)
            if not os.path.islink(full):
                total += os.lstat(full).st_size
    return total


def bundle_report(app: pathlib.Path) -> dict[str, Any]:
    frameworks = app / "Contents/Frameworks"
    cef = frameworks / CHROMIUM_FRAMEWORK
    helpers = sorted(frameworks.glob("*Helper*.app")) if frameworks.exists() else []
    # Zero cost when unused requires the framework to be loaded on demand
    # (dlopen), never linked into the main executable.
    linked = ""
    for binary in sorted((app / "Contents/MacOS").glob("*")):
        linked += subprocess.run(["otool", "-L", str(binary)], capture_output=True, text=True).stdout
    return {
        "chromium_framework_linked_at_launch": CHROMIUM_FRAMEWORK.removesuffix(".framework") in linked,
        "app_bytes": tree_bytes(app),
        "frameworks_bytes": tree_bytes(frameworks) if frameworks.exists() else 0,
        "chromium_framework_present": cef.exists(),
        "chromium_framework_bytes": tree_bytes(cef) if cef.exists() else 0,
        "chromium_helper_apps": [h.name for h in helpers],
        "chromium_helper_bytes": sum(tree_bytes(h) for h in helpers),
    }


# ---------------------------------------------------------------------------
# Fixture page server: a DOM-heavy page with a canvas animation so compositor
# and main-thread costs show up the way a real app page would cause them.

FIXTURE_HTML = """<!doctype html><html><head><meta charset=utf-8><title>cmux bench {n}</title>
<style>body{{font:13px -apple-system;margin:0}}.r{{padding:2px 8px;border-bottom:1px solid #ddd}}
canvas{{position:fixed;right:8px;top:8px}}</style></head><body>
<canvas id=c width=240 height=160></canvas><div id=list></div>
<script>
const list=document.getElementById('list');let h='';
for(let i=0;i<3000;i++)h+='<div class=r>row '+i+' <b>{n}</b> '+'lorem ipsum '.repeat(4)+'</div>';
list.innerHTML=h;
const c=document.getElementById('c').getContext('2d');let t=0;
function f(){{t++;c.fillStyle='hsl('+(t%360)+',70%,50%)';c.fillRect(0,0,240,160);
c.fillStyle='#fff';c.fillText('frame '+t,10,20);requestAnimationFrame(f)}}f();
</script></body></html>"""


class FixtureServer:
    def __init__(self) -> None:
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self) -> None:  # noqa: N802
                n = re.sub(r"[^a-z0-9-]", "", self.path.strip("/").lower()) or "page"
                body = FIXTURE_HTML.format(n=n).encode()
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *_args: Any) -> None:
                pass

        self.httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)

    def __enter__(self) -> "FixtureServer":
        self.thread.start()
        return self

    def __exit__(self, *_exc: Any) -> None:
        self.httpd.shutdown()
        self.httpd.server_close()

    def url(self, name: str) -> str:
        return f"http://127.0.0.1:{self.httpd.server_address[1]}/{name}"


# ---------------------------------------------------------------------------
# Tagged app control


def sanitize(raw: str, sep: str) -> str:
    cleaned = re.sub(r"[^a-z0-9]+", sep, raw.lower()).strip(sep)
    return re.sub(re.escape(sep) + "+", sep, cleaned) or "perf"


def stats(values: list[float]) -> dict[str, float]:
    if not values:
        return {}
    ordered = sorted(values)

    def pct(p: float) -> float:
        idx = (len(ordered) - 1) * p
        lo = int(idx)
        hi = min(lo + 1, len(ordered) - 1)
        return ordered[lo] + (ordered[hi] - ordered[lo]) * (idx - lo)

    return {
        "n": len(values),
        "mean": round(statistics.mean(values), 3),
        "p50": round(pct(0.5), 3),
        "p95": round(pct(0.95), 3),
        "p99": round(pct(0.99), 3),
        "max": round(ordered[-1], 3),
    }


class BenchFailure(RuntimeError):
    pass


class TaggedApp:
    def __init__(self, app: pathlib.Path, tag: str, workdir: pathlib.Path) -> None:
        slug = sanitize(tag, "-") if tag.strip() else ""
        if not slug or app.name != f"cmux DEV {slug}.app":
            raise BenchFailure(f"refusing to bench {app}: expected a tagged 'cmux DEV {slug or '<tag>'}.app'")
        self.app = app
        self.tag = slug
        self.bundle_id = f"com.cmuxterm.app.debug.{sanitize(tag, '.')}"
        self.executable = app / "Contents/MacOS/cmux DEV"
        # Tagged Debug builds bind this path (scripts/reload.sh, perf-activation-session.py).
        self.socket_path = pathlib.Path(f"/tmp/cmux-debug-{slug}.sock")
        self.debug_log = workdir / f"bench-{slug}.log"
        self.cli_path = app / "Contents/Resources/bin/cmux"
        self.pid: int | None = None
        # Extra app environment for a scenario (for example CMUX_CEF_DEBUG_URL).
        self.extra_env: dict[str, str] = {}

    def env(self) -> dict[str, str]:
        return {
            "CMUX_SOCKET": str(self.socket_path),
            "CMUX_SOCKET_PATH": str(self.socket_path),
            "CMUX_SOCKET_MODE": "automation",
            "CMUX_DEBUG_LOG": str(self.debug_log),
            "CMUX_TAG": self.tag,
            "CMUX_BUNDLE_ID": self.bundle_id,
            **self.extra_env,
        }

    def running_pids(self) -> set[int]:
        # `comm` is the executable path; resolve /tmp -> /private/tmp before comparing.
        target = os.path.realpath(self.executable)
        return {pid for pid, _ppid, path in list_processes() if os.path.realpath(path) == target}

    def launch(self, timeout: float) -> float:
        # Never touch an instance someone else launched from this bundle.
        if self.running_pids():
            raise BenchFailure(f"{self.app.name} is already running; quit it before benchmarking")
        # Another copy of a same-tag bundle (elsewhere on disk) would own this socket.
        probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            probe.connect(str(self.socket_path))
            raise BenchFailure(f"{self.socket_path} is live: another copy of tag {self.tag} is running")
        except OSError:
            pass
        finally:
            probe.close()
        self.socket_path.unlink(missing_ok=True)
        cmd = ["open", "-g", "-n", "-F", "-a", str(self.app)]
        for key, value in self.env().items():
            cmd += ["--env", f"{key}={value}"]
        start = time.perf_counter()
        subprocess.run(cmd, check=True)
        deadline = start + timeout
        try:
            while time.perf_counter() < deadline:
                if self.pid is None:
                    started = self.running_pids()
                    if len(started) > 1:
                        raise BenchFailure(f"more than one {self.app.name} process: {sorted(started)}")
                    self.pid = next(iter(started), None)
                elif self.socket_path.exists():
                    try:
                        self.cli_json(["list-workspaces"], timeout=5)
                        return (time.perf_counter() - start) * 1000
                    except BenchFailure:
                        pass
                time.sleep(0.05)
            raise BenchFailure(f"socket {self.socket_path} not ready after {timeout}s")
        except BaseException:
            self.quit()
            raise

    def quit(self) -> None:
        pid, self.pid = self.pid, None
        if pid is None:
            return
        try:
            os.kill(pid, 15)
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                os.kill(pid, 0)
                time.sleep(0.1)
            os.kill(pid, 9)
        except ProcessLookupError:
            pass
        self.socket_path.unlink(missing_ok=True)

    def cli_env(self) -> dict[str, str]:
        env = {k: v for k, v in os.environ.items() if not k.startswith("CMUX_")}
        env.update(self.env())
        env["CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC"] = "30"
        return env

    def cli(self, args: list[str], timeout: float = 60) -> str:
        try:
            proc = subprocess.run([str(self.cli_path)] + args, capture_output=True, text=True,
                                  env=self.cli_env(), timeout=timeout)
        except subprocess.TimeoutExpired as exc:
            raise BenchFailure(f"cmux {' '.join(args)} timed out after {timeout}s") from exc
        if proc.returncode != 0:
            raise BenchFailure(f"cmux {' '.join(args)} failed: {proc.stderr.strip() or proc.stdout.strip()}")
        return proc.stdout.strip()

    def cli_json(self, args: list[str], timeout: float = 60) -> Any:
        return json.loads(self.cli(["--json"] + args, timeout=timeout))

    def rpc(self, method: str, params: dict[str, Any], timeout: float = 60) -> Any:
        return json.loads(self.cli(["rpc", method, json.dumps(params)], timeout=timeout))

    def raw_command_burst(self, command: str, count: int, warmup: int = 5) -> list[float]:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(5)
        sock.connect(str(self.socket_path))
        buffer = b""

        def roundtrip() -> str:
            nonlocal buffer
            sock.sendall((command + "\n").encode())
            while b"\n" not in buffer:
                ready, _, _ = select.select([sock], [], [], 5)
                if not ready:
                    raise BenchFailure(f"timed out on {command}")
                chunk = sock.recv(8192)
                if not chunk:
                    raise BenchFailure("socket closed")
                buffer += chunk
            line, buffer = buffer.split(b"\n", 1)
            return line.decode(errors="replace")

        try:
            for _ in range(warmup):
                reply = roundtrip()
                if not reply.startswith("OK"):
                    raise BenchFailure(f"{command}: {reply}")
            samples = []
            for _ in range(count):
                start = time.perf_counter()
                reply = roundtrip()
                samples.append((time.perf_counter() - start) * 1000)
                if not reply.startswith("OK"):
                    raise BenchFailure(f"{command}: {reply}")
            return samples
        finally:
            sock.close()


def surface_id(payload: Any) -> str:
    for key in ("surface_id", "surface_ref", "surface"):
        value = payload.get(key) if isinstance(payload, dict) else None
        if isinstance(value, str):
            return value
        if isinstance(value, dict) and isinstance(value.get("id"), str):
            return value["id"]
    raise BenchFailure(f"no surface in {payload}")


def workspace_id(app: TaggedApp) -> str:
    payload = app.cli_json(["list-workspaces"])
    rows = payload.get("workspaces", payload) if isinstance(payload, dict) else payload
    for row in rows:
        if row.get("selected"):
            return row.get("id") or row.get("ref")
    return rows[0].get("id") or rows[0].get("ref")


# ---------------------------------------------------------------------------
# Scenarios


def parse_open_params(raw: list[str]) -> dict[str, dict[str, Any]]:
    result: dict[str, dict[str, Any]] = {}
    for item in raw:
        engine, _, pair = item.partition(":")
        key, _, value = pair.partition("=")
        if not engine or not key:
            raise SystemExit(f"--open-param expects <engine>:<key>=<value>, got {item!r}")
        try:
            parsed: Any = json.loads(value)
        except json.JSONDecodeError:
            parsed = value
        result.setdefault(engine, {})[key] = parsed
    return result


def key_latency(app: TaggedApp, args: argparse.Namespace) -> dict[str, Any]:
    """Every repeat's samples pooled, so one quiet or noisy burst cannot pick the result."""
    samples: list[float] = []
    for _ in range(args.key_repeats):
        samples += app.raw_command_burst(f"simulate_shortcut {args.key_combo}", args.key_events)
    return stats(samples)


def open_tab(app: TaggedApp, workspace: str, url: str, params: dict[str, Any], timeout_ms: int) -> tuple[str, float, float]:
    start = time.perf_counter()
    payload = app.rpc("browser.open_split", {"workspace_id": workspace, "url": url, "focus": False, **params})
    opened = (time.perf_counter() - start) * 1000
    sid = surface_id(payload)
    deadline = start + timeout_ms / 1000
    while True:
        remaining_ms = max(1, int((deadline - time.perf_counter()) * 1000))
        try:
            app.cli(["browser", "--surface", sid, "wait", "--load-state", "complete", "--timeout-ms", str(remaining_ms)],
                    timeout=remaining_ms / 1000 + 10)
            break
        except BenchFailure as exc:
            # A lazily started engine has no page to ask until its runtime and first
            # window exist; that wait is the cold-start cost this measures.
            if "not available" not in str(exc) or time.perf_counter() >= deadline:
                raise
            time.sleep(0.02)
    loaded = (time.perf_counter() - start) * 1000
    return sid, opened, loaded


def run_engine(app: TaggedApp, engine: str, params: dict[str, Any], server: FixtureServer,
               args: argparse.Namespace) -> dict[str, Any]:
    result: dict[str, Any] = {"open_params": params}
    workspace = app.rpc("workspace.create", {})
    ws = workspace.get("workspace_id") or workspace.get("id") or workspace_id(app)
    app.rpc("workspace.select", {"workspace_id": ws})
    before = engine_snapshot(app.pid, str(app.app))
    loads, opens, surfaces = [], [], []
    for index in range(args.tabs):
        sid, opened, loaded = open_tab(app, ws, server.url(f"{engine}-{index}"), params, args.load_timeout_ms)
        surfaces.append(sid)
        opens.append(round(opened, 2))
        loads.append(round(loaded, 2))
    result["first_page_load_ms"] = loads[0]
    result["warm_page_load_ms"] = stats(loads[1:]) if len(loads) > 1 else {}
    result["open_rpc_ms"] = stats(opens)
    time.sleep(args.settle_s)
    after = engine_snapshot(app.pid, str(app.app))
    # Only the engine under test: a previous engine's processes are closed but may still be exiting.
    key = f"{engine}_footprint_bytes"
    engine_bytes = after.get(key, 0) - before.get(key, 0)
    app_bytes = after["app_footprint_bytes"] - before["app_footprint_bytes"]
    result["tabs"] = args.tabs
    result["snapshot"] = after
    result["memory_delta_bytes"] = {"app": app_bytes, "engine_processes": engine_bytes, "total": app_bytes + engine_bytes}
    # Engine processes are the stable signal; the app delta matters for Chromium (its browser
    # process is the app) but carries Debug-build background noise.
    result["memory_per_tab_bytes"] = {
        "engine_processes": engine_bytes // max(1, args.tabs),
        "app": app_bytes // max(1, args.tabs),
        "total": (app_bytes + engine_bytes) // max(1, args.tabs),
    }
    # The browser pane shows one of its tabs (animating); the others are hidden tabs.
    result["cpu_percent_one_visible"] = cpu_percent_over(app.pid, str(app.app), args.cpu_window_s)
    # Typing in the terminal next to a visible, animating page of this engine.
    app.rpc("workspace.select", {"workspace_id": ws})
    result["key_latency_ms_with_visible_page"] = key_latency(app, args)
    # Close this engine's pages so the next engine is measured alone.
    app.rpc("workspace.close", {"workspace_id": ws})
    return result


def cmd_run(args: argparse.Namespace) -> int:
    app_path = pathlib.Path(args.app).expanduser().resolve()
    workdir = pathlib.Path(tempfile.mkdtemp(prefix="cmux-engine-bench-"))
    app = TaggedApp(app_path, args.tag, workdir)
    if not args.restore_session:
        # Start every run from an empty session: a page restored from an earlier run
        # (a Chromium tab) would start its engine at launch and skew every number.
        app.extra_env["CMUX_DISABLE_SESSION_RESTORE"] = "1"
    if args.launches < 1:
        raise BenchFailure("--launches must be at least 1")
    open_params = parse_open_params(args.open_param)
    engines = [e for e in args.engines.split(",") if e]
    result: dict[str, Any] = {
        "schema": 1,
        "tag": args.tag,
        "app": str(app_path),
        "commit": args.commit,
        "host": platform.node(),
        "macos": platform.mac_ver()[0],
        "machine": platform.machine(),
        "started_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "bundle": bundle_report(app_path),
        "launch": {},
        "engines": {},
    }
    with FixtureServer() as server:
        # `{fixture:<name>}` in a --launch-env value becomes a fixture page URL.
        for item in args.launch_env:
            key, _, value = item.partition("=")
            app.extra_env[key] = re.sub(r"\{fixture:([a-z0-9-]+)\}", lambda m: server.url(m.group(1)), value)
        result["launch_env"] = dict(app.extra_env)
        try:
            launch_ms = []
            for index in range(args.launches):
                launch_ms.append(round(app.launch(args.launch_timeout), 2))
                if index < args.launches - 1:
                    app.quit()
            result["launch"]["socket_ready_ms"] = stats(launch_ms)
            time.sleep(args.settle_s)
            result["launch"]["idle"] = engine_snapshot(app.pid, str(app_path))
            result["launch"]["idle_cpu_percent"] = cpu_percent_over(app.pid, str(app_path), args.cpu_window_s)
            result["key_latency_ms_no_browser"] = key_latency(app, args)
            for engine in engines:
                try:
                    result["engines"][engine] = run_engine(app, engine, open_params.get(engine, {}), server, args)
                except BenchFailure as exc:
                    # Keep the other engines' numbers; record why this one stopped.
                    result["engines"][engine] = {"error": str(exc)}
            result["final"] = engine_snapshot(app.pid, str(app_path))
        finally:
            app.quit()
    text = json.dumps(result, indent=2, sort_keys=True)
    if args.out:
        pathlib.Path(args.out).write_text(text + "\n")
    print(text)
    return 0


def cmd_bundle(args: argparse.Namespace) -> int:
    print(json.dumps(bundle_report(pathlib.Path(args.app).expanduser()), indent=2))
    return 0


def mb(value: Any) -> str:
    return f"{value / 1048576:.1f} MB" if isinstance(value, (int, float)) else "-"


def cmd_compare(args: argparse.Namespace) -> int:
    runs = [(pathlib.Path(p).stem, json.loads(pathlib.Path(p).read_text())) for p in args.results]

    def get(run: dict[str, Any], *path: str) -> Any:
        node: Any = run
        for key in path:
            if not isinstance(node, dict) or key not in node:
                return None
            node = node[key]
        return node

    rows: list[tuple[str, list[str]]] = [
        ("App bundle", [mb(get(r, "bundle", "app_bytes")) for _, r in runs]),
        ("Chromium framework + helpers", [mb((get(r, "bundle", "chromium_framework_bytes") or 0)
                                            + (get(r, "bundle", "chromium_helper_bytes") or 0)) for _, r in runs]),
        ("Chromium framework linked at launch", [str(get(r, "bundle", "chromium_framework_linked_at_launch")) for _, r in runs]),
        ("Launch to socket p50 (ms)", [str(get(r, "launch", "socket_ready_ms", "p50")) for _, r in runs]),
        ("Idle app footprint", [mb(get(r, "launch", "idle", "app_footprint_bytes")) for _, r in runs]),
        ("Idle Chromium helper processes", [str(get(r, "launch", "idle", "chromium_processes")) for _, r in runs]),
        ("Idle Chromium framework mapped", [str(get(r, "launch", "idle", "chromium_framework_mapped")) for _, r in runs]),
        ("Key latency p50/p95, no browser (ms)", [f"{get(r, 'key_latency_ms_no_browser', 'p50')}/"
                                                  f"{get(r, 'key_latency_ms_no_browser', 'p95')}" for _, r in runs]),
    ]
    engines = sorted({e for _, r in runs for e in (r.get("engines") or {})})
    for engine in engines:
        rows += [
            (f"{engine}: first page load (ms)", [str(get(r, "engines", engine, "first_page_load_ms")) for _, r in runs]),
            (f"{engine}: warm page load p50 (ms)", [str(get(r, "engines", engine, "warm_page_load_ms", "p50")) for _, r in runs]),
            (f"{engine}: memory per tab, engine processes",
             [mb(get(r, "engines", engine, "memory_per_tab_bytes", "engine_processes")) for _, r in runs]),
            (f"{engine}: memory per tab, app process",
             [mb(get(r, "engines", engine, "memory_per_tab_bytes", "app")) for _, r in runs]),
            (f"{engine}: engine processes", [str(get(r, "engines", engine, "snapshot", f"{engine}_processes") or 0) for _, r in runs]),
            (f"{engine}: CPU% engine, 1 visible", [str(get(r, "engines", engine, "cpu_percent_one_visible", engine)) for _, r in runs]),
            (f"{engine}: key latency p50/p95 (ms)", [f"{get(r, 'engines', engine, 'key_latency_ms_with_visible_page', 'p50')}/"
                                                     f"{get(r, 'engines', engine, 'key_latency_ms_with_visible_page', 'p95')}"
                                                     for _, r in runs]),
        ]
    print("| Metric | " + " | ".join(name for name, _ in runs) + " |")
    print("|---|" + "---|" * len(runs))
    for label, values in rows:
        print(f"| {label} | " + " | ".join(values) + " |")
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    bundle = sub.add_parser("bundle", help="report bundle and Chromium framework size")
    bundle.add_argument("--app", required=True)
    bundle.set_defaults(func=cmd_bundle)

    run = sub.add_parser("run", help="launch a tagged build and measure it")
    run.add_argument("--app", required=True, help="path to 'cmux DEV <tag>.app'")
    run.add_argument("--tag", required=True)
    run.add_argument("--commit", default="", help="commit the build came from (recorded only)")
    run.add_argument("--engines", default="webkit", help="comma list, e.g. webkit,chromium")
    run.add_argument("--open-param", action="append", default=[], help="<engine>:<key>=<value> for browser.open_split")
    run.add_argument("--tabs", type=int, default=5)
    run.add_argument("--launches", type=int, default=3)
    run.add_argument("--launch-timeout", type=float, default=60)
    run.add_argument("--load-timeout-ms", type=int, default=30000)
    run.add_argument("--settle-s", type=float, default=5)
    run.add_argument("--cpu-window-s", type=float, default=5)
    run.add_argument("--key-combo", default="up")
    run.add_argument("--key-events", type=int, default=200)
    run.add_argument("--key-repeats", type=int, default=3)
    run.add_argument("--restore-session", action="store_true",
                     help="let the app restore its last session (default: start empty)")
    run.add_argument("--launch-env", action="append", default=[],
                     help="KEY=VALUE for the app; {fixture:<name>} becomes a fixture page URL, "
                          "e.g. CMUX_CEF_DEBUG_URL={fixture:chromium-debug}")
    run.add_argument("--out")
    run.set_defaults(func=cmd_run)

    compare = sub.add_parser("compare", help="Markdown table from result JSON files")
    compare.add_argument("results", nargs="+")
    compare.set_defaults(func=cmd_compare)

    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except BenchFailure as exc:
        print(f"browser_engine_bench: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
