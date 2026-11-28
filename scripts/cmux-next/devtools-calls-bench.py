#!/usr/bin/env python3
"""Main-thread time of large Chromium DevTools calls in the real app (CEF DevTools stalls,
cmux-ad decision 5; hang records v2.2.9 seq 538 and v2.2.10 seq 356).

Each arm is a tagged app. Per round and arm (interleaved: A1, B1, A2, B2, ...), the bench launches the
app's binary with a scratch HOME and CMUX_NEXT_HANG_THRESHOLD_MS (default 8), opens a Chromium tab on a
local page and sends `Runtime.evaluate` calls of each size through `debug.cef.devtools`, the path an app
page's script batch and an agent's script take (`CEFTab.devTools`). Around every call it resets and reads
`debug.hangs`:

  gap_ms     the longest main-thread gap of any length from the reset to the read (`max_gap_ms`): the call's
             main-thread time with no threshold, plus whatever else ran in that window; size 0 (a one-byte
             script through the same reads) is that floor
  stall_ms   the longest stall record (threshold and over), with its CPU time and whether its stack
             has a DevTools or JSON frame
  wall_ms    request to reply (Chromium runs the script meanwhile; not main-thread time)

It prints, per arm and size, p50 / p95 / p99 / max of each, and writes every call to --json.

  devtools-calls-bench.py --app A=PATH --app B=PATH [--sizes 64K,512K,2560K] [--calls 20] [--rounds 3]
      [--threshold-ms 8] [--json OUT]

The script stays under the control socket's 4 MiB request line (2.5 MB of script with its escapes).
Needs CMUX_BENCH_LAUNCH=direct on a fleet step (no LaunchServices session).

--pressure-notice measures the hidden-page trim's notice (CEFHiddenPageTrim, NIGHTLY hangs in
`cmux_shim_devtools_call`): `Memory.simulatePressureNotification {"level":"critical"}`, which Chromium runs in
the browser process, on the main thread, inside the send. One launch of one --app opens --chats agent chat
workspaces (answered chats on the acpmux test agent, as bench_memory's --fake-agent), each shown once, then
shows the launch workspace again, so every chat's page is a hidden `cmux-page://` page (`debug.cef_pages`).
Per round two arms (their order alternates by round, --idle-s apart), each call sent and awaited in turn
through `debug.cef_page_devtools`, the same reads around it as above:

  per-page   the notice to each hidden page (the trim before the fix: one notice per hidden page)
  once       the notice to one hidden page (the trim after it: one per round)

Per call: gap_ms, stall_ms, stall_cpu_ms, wall_ms and request_bytes (the params' JSON); per arm and round:
the summed main-thread ms and wall ms, the app's CPU ms, and the host before it (load average, vm_stat
free and compressed pages, kern.memorystatus_level). After the run, the app's unified log lines
"devtools send held the main thread" (a build that logs each shim send over 16 ms) go into --json.

  devtools-calls-bench.py --pressure-notice --app head=PATH [--chats 9] [--rounds 6] [--json OUT]
"""
import argparse
import http.server
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import threading
import time
import uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bench_memory  # noqa: E402
from safe_log import safe_print  # noqa: E402  (a line in a cleanup path never skips the kill)
from state_wait import wait_stable  # noqa: E402

LINE = 'globalThis.__cmuxPageHostResolve?.(7, {"text":"a\\\\b é \\"q\\""});\n'
# Frames of the DevTools send path: the call itself, the JSON writer under it, the shim's parse. Not "JSONValue"
# (the control path's own type), so a stall in the request's decode is not counted.
DEVTOOLS_FRAMES = ("DevTools", "devTools", "devtools", "NSJSONSerialization", "_NSJSONWriter", "cef_parse_json", "CefParseJSON")


def parse_size(text):
    text = text.strip().upper()
    if text == "0":
        return 0
    scale = {"K": 1 << 10, "M": 1 << 20}.get(text[-1:], 1)
    return int(float(text.rstrip("KM")) * scale)


def script(size, salt):
    """About `size` bytes (whole lines, at most `size`) of valid JavaScript whose lines need escaping
    (quotes, a backslash, a non-ASCII letter)."""
    head = f"// devtools-calls {salt}\n"
    return head + LINE * max(1, (size - len(head.encode())) // len(LINE.encode()))


def rpc(path, method, params=None, timeout=120):
    request = json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n"
    reply = b""
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as stream:
        stream.settimeout(timeout)
        stream.connect(path)
        stream.sendall(request.encode())
        while not reply.endswith(b"\n"):
            chunk = stream.recv(1 << 16)
            if not chunk:
                break
            reply += chunk
    answer = json.loads(reply or b"{}")
    if answer.get("error"):
        raise RuntimeError(f"{method}: {json.dumps(answer['error'])[:300]}")
    return answer.get("result") or {}


def devtools(path, method, params, timeout=60):
    result = rpc(path, "debug.cef.devtools", {"method": method, "params": params}, timeout=timeout)
    if result.get("error"):
        raise RuntimeError(f"debug.cef.devtools {method}: {result['error']}")
    return result.get("result", "")


def serve_page():
    """A local page, so the run needs no network."""
    page = b"<!doctype html><title>devtools-calls</title><body><p>devtools calls bench</p></body>"

    class Page(http.server.BaseHTTPRequestHandler):
        def do_GET(self):  # noqa: N802 (http.server API)
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.send_header("Content-Length", str(len(page)))
            self.end_headers()
            self.wfile.write(page)

        def log_message(self, *args):
            pass

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Page)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, f"http://127.0.0.1:{server.server_address[1]}/"


def wait_page(path, deadline_s=90):
    deadline = time.monotonic() + deadline_s
    last = None
    while time.monotonic() < deadline:
        try:
            state = json.loads(devtools(path, "Runtime.evaluate", {"expression": "document.readyState", "returnByValue": True}) or "{}")
            if (state.get("result") or {}).get("value") == "complete":
                return
            last = state
        except (RuntimeError, OSError, ValueError) as error:
            last = error
        time.sleep(0.5)  # bench: waiting for the page to load
    raise SystemExit(f"devtools-calls: the Chromium page did not load within {deadline_s} s ({last})")


def has_devtools_frame(record):
    return any(any(word in (frame.get("symbol") or "") for word in DEVTOOLS_FRAMES) for frame in record.get("frame_details", []))


def page_devtools(path, browser, method, params, timeout=60):
    """A DevTools method on one of cmux's own pages (`debug.cef_page_devtools`), the path the hidden-page trim's
    notice takes (`CEFTab.devTools` on a cmux page)."""
    result = rpc(path, "debug.cef_page_devtools", {"browser": browser, "method": method, "params": params}, timeout=timeout)
    if result.get("error"):
        raise RuntimeError(f"debug.cef_page_devtools {method} on {browser}: {result['error']}")
    return result.get("result", "")


def one_call(path, method, params, send=None):
    """One call with its main-thread numbers; a failed call is a row with its error, not the end of the run.
    `send` (default: `debug.cef.devtools` on the Chromium tab) makes the call itself."""
    rpc(path, "debug.hangs", {"clear": True, "limit": 0})
    start = time.monotonic()
    error = None
    try:
        (send or devtools)(path, method, params)
    except (RuntimeError, OSError, ValueError) as failure:
        error = str(failure)[:300]
    wall = (time.monotonic() - start) * 1000
    # The watchdog records a stall after it ends: its report reads the same three times in a row, 0.1 s apart.
    seen = wait_stable(lambda: json.dumps(rpc(path, "debug.hangs", {}), sort_keys=True), "the watchdog's report",
                       timeout=5, interval=0.1, reads=3, raise_on_timeout=False)
    hangs = json.loads(seen) if seen else rpc(path, "debug.hangs", {})
    stalls = [r for r in hangs.get("records", []) if r.get("kind", "stall") == "stall"]
    worst = max(stalls, key=lambda r: r.get("duration_ms", 0), default=None)
    return {
        "wall_ms": round(wall, 2),
        "gap_ms": round(hangs.get("max_gap_ms", 0), 2),
        "stall_ms": round(worst["duration_ms"], 2) if worst else 0.0,
        "stall_cpu_ms": round(worst.get("cpu_ms", 0), 2) if worst else 0.0,
        "stall_devtools_frame": bool(worst and has_devtools_frame(worst)),
        "stalls": len(stalls),
        "threshold_ms": hangs.get("threshold_ms"),
        "error": error,
    }


def run_arm(label, bundle, url, sizes, calls, threshold_ms, round_index, rows):
    """Measures one arm for one round, appending each call to `rows` as it is made: an arm that stops early
    (its app died, a page did not load) keeps the calls it made."""
    env = {"CMUX_NEXT_HANG_THRESHOLD_MS": str(threshold_ms), "CMUX_DEV_BACKEND_MODE": "local"}
    pid, path, scratch = bench_memory.launch(bundle, {}, extra_env=env, direct=True)
    start = len(rows)
    try:
        app = bench_memory.App(bundle, path)
        cef = rpc(path, "debug.cef")
        if cef.get("unavailable") or cef.get("fallback"):
            raise SystemExit(f"devtools-calls: {label}: Chromium is not available: {json.dumps(cef)[:400]}")
        opened = app.action("openBrowser.chromium", focus=True, url=url)
        if opened.get("error"):
            raise SystemExit(f"devtools-calls: {label}: openBrowser.chromium: {opened['error']}")
        wait_page(path)
        for _ in range(3):  # warm the path (lazy bridges, the first encode)
            one_call(path, "Runtime.evaluate", {"expression": script(4 << 10, uuid.uuid4().hex), "silent": True})
        for size in sizes:
            for index in range(calls):
                # Size 0 is the floor: the same wrapper and reads around a call with a one-byte script.
                expression = "0" if size == 0 else script(size, f"{round_index}-{index}-{uuid.uuid4().hex}")
                try:
                    row = one_call(path, "Runtime.evaluate", {"expression": expression, "silent": True})
                except (RuntimeError, OSError, ValueError) as failure:  # debug.hangs itself failed: the app is gone
                    row = {"wall_ms": None, "gap_ms": None, "stall_ms": None, "stall_cpu_ms": None, "stall_devtools_frame": False,
                           "stalls": 0, "threshold_ms": None, "error": f"debug.hangs: {str(failure)[:300]}"}
                row.update({"arm": label, "size": size, "round": round_index, "call": index})
                rows.append(row)
            mine = rows[start:]
            sized = [r for r in mine if r["size"] == size and r["gap_ms"] is not None]
            failed = sum(1 for r in mine if r["size"] == size and r["error"])
            print(f"  {label} round {round_index} {size >> 10} KiB: gap max {max((r['gap_ms'] for r in sized), default=0):.1f} ms, "
                  f"stalls {sum(r['stalls'] for r in sized)}, failed calls {failed}", flush=True)
    finally:
        bench_memory.end_bundle(bundle)
        shutil.rmtree(scratch, ignore_errors=True)


def pct(values, q):
    ordered = sorted(values)
    if not ordered:
        return None
    rank = q * (len(ordered) - 1)
    low = int(rank)
    high = min(low + 1, len(ordered) - 1)
    return ordered[low] + (ordered[high] - ordered[low]) * (rank - low)


def summary(rows, arms, sizes):
    table = []
    for size in sizes:
        for label in arms:
            every = [r for r in rows if r["arm"] == label and r["size"] == size]
            # Only clean calls count: a failed call's wall time is its timeout, and its gap is not the call's.
            sample = [r for r in every if r["gap_ms"] is not None and not r["error"]]
            if not sample:
                continue
            line = {"arm": label, "size": size, "calls": len(sample), "failed": sum(1 for r in every if r["error"]),
                    "devtools_stalls": sum(1 for r in sample if r["stall_devtools_frame"])}
            for metric in ("gap_ms", "stall_ms", "stall_cpu_ms", "wall_ms"):
                values = [r[metric] for r in sample]
                line[metric] = {name: round(pct(values, q), 2) for name, q in (("p50", .5), ("p95", .95), ("p99", .99))}
                line[metric]["max"] = round(max(values), 2)
            table.append(line)
    return table


# --pressure-notice: the hidden-page trim's notice (CEFHiddenPageTrim), as the trim sends it.
NOTICE_METHOD = "Memory.simulatePressureNotification"
NOTICE_PARAMS = {"level": "critical"}
NOTICE_ARMS = ("per-page", "once")
SLOW_SEND_TEXT = "devtools send held the main thread"
FAKE_AGENT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "cmux-tui", "crates", "acpmux", "tests", "fake_agent.py")


def hidden_cmux_pages(path):
    """Browser ids of the live hidden `cmux-page://` pages (`debug.cef_pages`), as the trim's `hiddenPages`."""
    pages = rpc(path, "debug.cef_pages", timeout=30).get("pages") or []
    return [p["browser"] for p in pages if p.get("hidden") and str(p.get("origin", "")).startswith("cmux-page://")]


def host_state(pid):
    """The host's load before an arm: load average, and on macOS vm_stat's free and compressed pages, the kernel's
    memorystatus level (percent of memory available), and the app's CPU time so far (ns)."""
    state = {"loadavg": [round(x, 2) for x in os.getloadavg()], "at": round(time.time(), 3)}
    if sys.platform == "darwin":
        try:
            text = subprocess.run(["vm_stat"], capture_output=True, text=True, timeout=10).stdout
            page = re.search(r"page size of (\d+) bytes", text)
            state["page_bytes"] = int(page.group(1)) if page else None
            for key, label in (("free_pages", "Pages free"), ("compressed_pages", "Pages occupied by compressor"),
                               ("speculative_pages", "Pages speculative")):
                found = re.search(rf"^{label}:\s+(\d+)", text, re.M)
                state[key] = int(found.group(1)) if found else None
        except (OSError, subprocess.SubprocessError) as error:
            state["vm_stat_error"] = str(error)[:200]
        try:
            level = subprocess.run(["sysctl", "-n", "kern.memorystatus_level"], capture_output=True, text=True, timeout=10).stdout
            state["memorystatus_level"] = int(level.strip()) if level.strip().isdigit() else None
        except (OSError, subprocess.SubprocessError) as error:
            state["memorystatus_error"] = str(error)[:200]
    used = bench_memory.usage(pid) if pid else None
    state["app_cpu_ns"] = used[3] if used else None
    return state


def slow_send_lines(since, pid):
    """The app's own log of shim sends over 16 ms (a head build logs each with its method and bytes) since `since`
    (local time, `log show --start`), for the app process `pid`; lines of other processes are only counted."""
    predicate = 'subsystem == "com.cmuxterm.app.next" AND category BEGINSWITH "cef"'
    try:
        out = subprocess.run(["log", "show", "--start", since, "--style", "ndjson", "--predicate", predicate],
                             capture_output=True, text=True, timeout=600)
    except (OSError, subprocess.SubprocessError) as error:
        return {"error": str(error)[:300], "lines": []}
    lines, cef_lines, other = [], 0, 0
    for raw in out.stdout.splitlines():
        try:
            entry = json.loads(raw)
        except ValueError:
            continue
        if "eventMessage" not in entry:
            continue  # the closing summary line
        if pid and entry.get("processID") != pid:
            other += SLOW_SEND_TEXT in entry.get("eventMessage", "")
            continue
        cef_lines += 1
        if SLOW_SEND_TEXT in entry.get("eventMessage", ""):
            lines.append({key: entry.get(key) for key in ("timestamp", "category", "eventMessage", "threadID")})
    return {"since": since, "cef_lines": cef_lines, "lines": lines, "other_processes": other,
            "exit": out.returncode, "stderr": out.stderr.strip()[:300]}


def open_hidden_chats(path, bundle, count, fake_agent):
    """`count` agent chat workspaces (answered chats on the acpmux test agent, bench_memory's FakeChats), each shown
    once so its page loads, then the launch workspace shown again: every chat's page is hidden and kept."""
    app = bench_memory.App(bundle, path)
    chats = bench_memory.FakeChats(app, bundle, fake_agent)
    launch_workspaces = sorted(bench_memory.workspace_ids(app))
    made = 0
    for index in range(count):
        workspace = chats.open(index)
        if workspace is None:
            continue
        app.action("goToWorkspace", workspace=workspace, focus=True)
        made += 1
        time.sleep(1)  # bench: the shown chat's page starts loading before the next one opens
    if launch_workspaces:
        app.action("goToWorkspace", workspace=launch_workspaces[0], focus=True)
    deadline = time.monotonic() + 90
    hidden = hidden_cmux_pages(path)
    while len(hidden) < count and time.monotonic() < deadline:
        time.sleep(1)  # bench: waiting for the hidden chats' pages to be listed hidden
        hidden = hidden_cmux_pages(path)
    return made, hidden


def notice_call(path, browser):
    def send(path, method, params):
        return page_devtools(path, browser, method, params)
    row = one_call(path, NOTICE_METHOD, NOTICE_PARAMS, send=send)
    row["browser"] = browser
    row["request_bytes"] = len(json.dumps(NOTICE_PARAMS, separators=(",", ":")).encode())
    return row


def run_pressure(label, bundle, opts, rows, arm_rows, logs):
    """One launch of `bundle` with `opts.chats` hidden chat pages; per round, both arms in turn (their order
    alternates by round), sequentially as the trim awaited each reply: `per-page` sends the notice to each hidden
    page, `once` to one."""
    env = {"CMUX_NEXT_HANG_THRESHOLD_MS": str(opts.threshold_ms), "CMUX_DEV_BACKEND_MODE": "local"}
    since = time.strftime("%Y-%m-%d %H:%M:%S")
    pid, path, scratch = bench_memory.launch(bundle, {}, extra_env=env, direct=True)
    try:
        cef = rpc(path, "debug.cef")
        if cef.get("unavailable") or cef.get("fallback"):
            raise SystemExit(f"devtools-calls: {label}: Chromium is not available: {json.dumps(cef)[:400]}")
        made, hidden = open_hidden_chats(path, bundle, opts.chats, opts.fake_agent)
        safe_print(f"  {label}: {made} of {opts.chats} chats made, {len(hidden)} hidden cmux pages {hidden}", flush=True)
        if len(hidden) < opts.chats:
            raise SystemExit(f"devtools-calls: {label}: {len(hidden)} hidden cmux pages, {opts.chats} asked ({made} chats made)")
        # The app's own trim round goes out 10 s after the last hide: past it, so it never lands inside an arm.
        time.sleep(opts.settle_s)  # bench: past the app's own trim round
        notice_call(path, hidden[0])  # warm the path (lazy bridges, the page's DevTools session)
        for round_index in range(opts.rounds):
            order = NOTICE_ARMS if round_index % 2 == 0 else tuple(reversed(NOTICE_ARMS))
            for arm in order:
                time.sleep(opts.idle_s)  # bench: idle between arms
                hidden = hidden_cmux_pages(path)
                before = host_state(pid)
                targets = hidden[:opts.chats] if arm == "per-page" else hidden[:1]
                start = len(rows)
                began = time.monotonic()
                for index, browser in enumerate(targets):
                    try:
                        row = notice_call(path, browser)
                    except (RuntimeError, OSError, ValueError) as failure:  # debug.hangs itself failed: the app is gone
                        row = {"wall_ms": None, "gap_ms": None, "stall_ms": None, "stall_cpu_ms": None, "stall_devtools_frame": False,
                               "stalls": 0, "threshold_ms": None, "browser": browser, "request_bytes": None,
                               "error": f"debug.hangs: {str(failure)[:300]}"}
                    row.update({"arm": arm, "size": 0, "round": round_index, "call": index})
                    rows.append(row)
                elapsed = (time.monotonic() - began) * 1000
                after = host_state(pid)
                mine = rows[start:]
                clean = [r for r in mine if r["gap_ms"] is not None and not r["error"]]
                cpu = (after["app_cpu_ns"] - before["app_cpu_ns"]) / 1e6 if after.get("app_cpu_ns") and before.get("app_cpu_ns") else None
                arm_rows.append({"arm": arm, "round": round_index, "hidden_pages": len(hidden), "calls": len(mine),
                                 "clean": len(clean), "main_ms": round(sum(r["gap_ms"] for r in clean), 2),
                                 "wall_ms": round(sum(r["wall_ms"] for r in clean), 2), "elapsed_ms": round(elapsed, 2),
                                 "app_cpu_ms": round(cpu, 2) if cpu is not None else None, "before": before, "after": after})
                safe_print(f"  {arm} round {round_index}: {len(mine)} call(s) over {len(hidden)} hidden pages, main-thread "
                           f"{arm_rows[-1]['main_ms']:.1f} ms (max call {max((r['gap_ms'] for r in clean), default=0):.1f}), "
                           f"wall {arm_rows[-1]['wall_ms']:.1f} ms, load {before['loadavg']}, "
                           f"memorystatus {before.get('memorystatus_level')}, failed {len(mine) - len(clean)}", flush=True)
    finally:
        bench_memory.end_bundle(bundle)
        shutil.rmtree(scratch, ignore_errors=True)
        logs.update(slow_send_lines(since, pid))


def stat(values):
    values = [v for v in values if v is not None]
    if not values:
        return None
    return {"p50": round(pct(values, .5), 2), "p95": round(pct(values, .95), 2), "max": round(max(values), 2),
            "min": round(min(values), 2)}


def pressure_summary(rows, arm_rows):
    table = []
    for arm in NOTICE_ARMS:
        every = [r for r in rows if r["arm"] == arm]
        sample = [r for r in every if r["gap_ms"] is not None and not r["error"]]
        rounds = [a for a in arm_rows if a["arm"] == arm]
        line = {"arm": arm, "calls": len(sample), "failed": sum(1 for r in every if r["error"]), "rounds": len(rounds),
                "devtools_stalls": sum(1 for r in sample if r["stall_devtools_frame"]),
                "request_bytes": sorted({r["request_bytes"] for r in sample}),
                "round_main_ms": stat([a["main_ms"] for a in rounds]), "round_wall_ms": stat([a["wall_ms"] for a in rounds]),
                "round_app_cpu_ms": stat([a["app_cpu_ms"] for a in rounds]),
                "load1": stat([a["before"]["loadavg"][0] for a in rounds]),
                "memorystatus_level": stat([a["before"].get("memorystatus_level") for a in rounds])}
        for metric in ("gap_ms", "stall_ms", "stall_cpu_ms", "wall_ms"):
            line[metric] = stat([r[metric] for r in sample])
        table.append(line)
    return table


def pressure_main(opts, arms):
    if len(arms) != 1:
        raise SystemExit("devtools-calls: --pressure-notice measures one build: give one --app")
    (label, bundle), = arms.items()
    safe_print(f"DEVTOOLS-CALLS-HOST host={socket.gethostname()} load={os.getloadavg()} app={label} mode=pressure-notice "
               f"chats={opts.chats} rounds={opts.rounds} threshold={opts.threshold_ms}ms", flush=True)
    rows, arm_rows, logs = [], [], {}
    stopped = None
    try:
        run_pressure(label, bundle, opts, rows, arm_rows, logs)
    except (SystemExit, RuntimeError, OSError, ValueError) as error:
        stopped = str(error)[:400] or type(error).__name__
    table = pressure_summary(rows, arm_rows)
    if opts.json:
        os.makedirs(os.path.dirname(os.path.abspath(opts.json)), exist_ok=True)
        with open(opts.json, "w") as handle:
            json.dump({"mode": "pressure-notice", "arms": arms, "chats": opts.chats, "rounds": opts.rounds,
                       "threshold_ms": opts.threshold_ms, "host": socket.gethostname(), "method": NOTICE_METHOD,
                       "params": NOTICE_PARAMS, "stopped": stopped, "summary": table, "arm_rounds": arm_rows,
                       "slow_sends": logs, "rows": rows}, handle, indent=1)
    safe_print("\narm       calls  gap_ms p50/p95/max          round main_ms p50/max   wall_ms p50/p95   stall_cpu_ms max  load1 min-max  memorystatus min-max")
    for line in table:
        g, w, r, c = line["gap_ms"] or {}, line["wall_ms"] or {}, line["round_main_ms"] or {}, line["stall_cpu_ms"] or {}
        load, mem = line["load1"] or {}, line["memorystatus_level"] or {}
        safe_print(f"DEVTOOLS-CALLS {line['arm']:<9} {line['calls']:>4}  {g.get('p50')} {g.get('p95')} {g.get('max')}    "
                   f"{r.get('p50')} {r.get('max')}    {w.get('p50')} {w.get('p95')}    {c.get('max')}    "
                   f"{load.get('min')}-{load.get('max')}    {mem.get('min')}-{mem.get('max')}", flush=True)
    safe_print(f"DEVTOOLS-CALLS-SLOW-SENDS {len(logs.get('lines', []))} line(s) '{SLOW_SEND_TEXT}' "
               f"({logs.get('cef_lines')} cef lines of the app; log show exit {logs.get('exit')} {logs.get('error') or ''})", flush=True)
    problems = [f"stopped: {stopped}"] if stopped else []
    for line in table:
        expected = opts.rounds * (opts.chats if line["arm"] == "per-page" else 1)
        if line["calls"] < expected:
            problems.append(f"{line['arm']}: {line['calls']} of {expected} calls clean")
    failed = [r for r in rows if r.get("error")]
    if failed:
        problems.append(f"{len(failed)} failed call(s), first: {failed[0]['error']}")
    if problems:
        safe_print("DEVTOOLS-CALLS-INCOMPLETE " + "; ".join(problems), flush=True)
        sys.exit(1)
    safe_print("DEVTOOLS-CALLS-COMPLETE", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--app", action="append", required=True, help="LABEL=PATH of a tagged .app (repeatable)")
    parser.add_argument("--sizes", default="0,64K,512K,2560K", help="script sizes; 0 is the floor (a one-byte script)")
    parser.add_argument("--calls", type=int, default=20)
    parser.add_argument("--rounds", type=int, default=3)
    parser.add_argument("--threshold-ms", type=int, default=8)
    parser.add_argument("--json")
    parser.add_argument("--pressure-notice", action="store_true",
                        help="the hidden-page trim's memory-pressure notice: per round, to each hidden chat page (per-page) "
                             "and to one (once), in one launch of one --app")
    parser.add_argument("--chats", type=int, default=9, help="--pressure-notice: hidden agent chat pages")
    parser.add_argument("--idle-s", type=float, default=5, help="--pressure-notice: idle seconds before each arm")
    parser.add_argument("--settle-s", type=float, default=20,
                        help="--pressure-notice: seconds after the chats hide, past the app's own trim round (10 s)")
    parser.add_argument("--fake-agent", default=os.path.normpath(FAKE_AGENT), help="--pressure-notice: the ACP test agent the chats run")
    opts = parser.parse_args()
    arms = {}
    for item in opts.app:
        label, _, path = item.partition("=")
        if not path or not os.path.isdir(path):
            raise SystemExit(f"devtools-calls: --app {item!r}: expected LABEL=PATH of an .app")
        arms[label] = path
    if opts.pressure_notice:
        pressure_main(opts, arms)
        return
    sizes = [parse_size(s) for s in opts.sizes.split(",") if s.strip()]
    server, url = serve_page()
    safe_print(f"DEVTOOLS-CALLS-HOST host={socket.gethostname()} load={os.getloadavg()} arms={list(arms)} "
               f"sizes={[s >> 10 for s in sizes]}KiB calls={opts.calls} rounds={opts.rounds} threshold={opts.threshold_ms}ms", flush=True)
    rows = []
    stopped = None
    try:
        for round_index in range(opts.rounds):
            for label, bundle in arms.items():
                run_arm(label, bundle, url, sizes, opts.calls, opts.threshold_ms, round_index, rows)
    except (SystemExit, RuntimeError, OSError, ValueError) as error:
        stopped = str(error)[:400] or type(error).__name__
    finally:
        server.shutdown()
        # Whatever ran is kept, also when an arm ended the run (an app that died, a launch that failed).
        if opts.json:
            os.makedirs(os.path.dirname(os.path.abspath(opts.json)), exist_ok=True)
            with open(opts.json, "w") as handle:
                json.dump({"arms": arms, "sizes": sizes, "calls": opts.calls, "rounds": opts.rounds, "threshold_ms": opts.threshold_ms,
                           "stopped": stopped, "summary": summary(rows, list(arms), sizes), "rows": rows}, handle, indent=1)
    table = summary(rows, list(arms), sizes)
    safe_print("\narm   size      calls  gap_ms p50/p95/p99/max            stall_ms p50/p95/p99/max          devtools stalls (stack heuristic), failed")
    for line in table:
        g, s = line["gap_ms"], line["stall_ms"]
        safe_print(f"DEVTOOLS-CALLS {line['arm']:<5} {line['size'] >> 10:>6}KiB {line['calls']:>4}  "
                   f"{g['p50']:>6} {g['p95']:>6} {g['p99']:>6} {g['max']:>7}    "
                   f"{s['p50']:>6} {s['p95']:>6} {s['p99']:>6} {s['max']:>7}    {line['devtools_stalls']}, {line['failed']}")
    problems = incomplete(rows, table, list(arms), sizes, opts.calls * opts.rounds, stopped)
    if problems:
        # A run with failed or missing calls is not a result: it must never read as one.
        safe_print("DEVTOOLS-CALLS-INCOMPLETE " + "; ".join(problems), flush=True)
        sys.exit(1)
    safe_print("DEVTOOLS-CALLS-COMPLETE", flush=True)


def incomplete(rows, table, arms, sizes, expected, stopped):
    """Why the run is not a whole measurement: it stopped, an arm and size has fewer clean calls than asked, or a
    call failed. Empty when every arm measured every size with every call."""
    problems = [f"stopped: {stopped}"] if stopped else []
    measured = {(line["arm"], line["size"]): line for line in table}
    for label in arms:
        for size in sizes:
            line = measured.get((label, size))
            clean = line["calls"] if line else 0
            if clean < expected:
                problems.append(f"{label} {size >> 10}KiB: {clean} of {expected} calls clean")
    failed = sum(1 for r in rows if r.get("error"))
    if failed:
        problems.append(f"{failed} failed call(s), first: {next(r['error'] for r in rows if r.get('error'))}")
    return problems


if __name__ == "__main__":
    main()
