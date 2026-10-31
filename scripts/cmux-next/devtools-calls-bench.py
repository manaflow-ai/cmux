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
"""
import argparse
import http.server
import json
import os
import shutil
import socket
import sys
import threading
import time
import uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bench_memory  # noqa: E402

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


def one_call(path, method, params):
    """One call with its main-thread numbers; a failed call is a row with its error, not the end of the run."""
    rpc(path, "debug.hangs", {"clear": True, "limit": 0})
    start = time.monotonic()
    error = None
    try:
        devtools(path, method, params)
    except (RuntimeError, OSError, ValueError) as failure:
        error = str(failure)[:300]
    wall = (time.monotonic() - start) * 1000
    time.sleep(0.3)  # bench: the watchdog records a stall after it ends
    hangs = rpc(path, "debug.hangs", {})
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


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--app", action="append", required=True, help="LABEL=PATH of a tagged .app (repeatable)")
    parser.add_argument("--sizes", default="0,64K,512K,2560K", help="script sizes; 0 is the floor (a one-byte script)")
    parser.add_argument("--calls", type=int, default=20)
    parser.add_argument("--rounds", type=int, default=3)
    parser.add_argument("--threshold-ms", type=int, default=8)
    parser.add_argument("--json")
    opts = parser.parse_args()
    arms = {}
    for item in opts.app:
        label, _, path = item.partition("=")
        if not path or not os.path.isdir(path):
            raise SystemExit(f"devtools-calls: --app {item!r}: expected LABEL=PATH of an .app")
        arms[label] = path
    sizes = [parse_size(s) for s in opts.sizes.split(",") if s.strip()]
    server, url = serve_page()
    print(f"DEVTOOLS-CALLS-HOST host={socket.gethostname()} load={os.getloadavg()} arms={list(arms)} "
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
    print("\narm   size      calls  gap_ms p50/p95/p99/max            stall_ms p50/p95/p99/max          devtools stalls (stack heuristic), failed")
    for line in table:
        g, s = line["gap_ms"], line["stall_ms"]
        print(f"DEVTOOLS-CALLS {line['arm']:<5} {line['size'] >> 10:>6}KiB {line['calls']:>4}  "
              f"{g['p50']:>6} {g['p95']:>6} {g['p99']:>6} {g['max']:>7}    "
              f"{s['p50']:>6} {s['p95']:>6} {s['p99']:>6} {s['max']:>7}    {line['devtools_stalls']}, {line['failed']}")
    problems = incomplete(rows, table, list(arms), sizes, opts.calls * opts.rounds, stopped)
    if problems:
        # A run with failed or missing calls is not a result: it must never read as one (REVIEW.md section 9).
        print("DEVTOOLS-CALLS-INCOMPLETE " + "; ".join(problems), flush=True)
        sys.exit(1)
    print("DEVTOOLS-CALLS-COMPLETE", flush=True)


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
