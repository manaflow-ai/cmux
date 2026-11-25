#!/usr/bin/env python3
"""Does a hung Chromium renderer freeze the window, and does a hidden hung page recover? (hq#13463)

Each arm is a tagged app. Per round and arm (interleaved), the bench launches the app with a scratch HOME,
opens a Chromium tab on a local page whose script spins `for(;;){}` a moment after it loads, sends it a
click (Chromium's hang monitor reports a renderer hung only when it stops acking input), waits for the
report, then opens a second tab in the same pane from another site (its own renderer), which hides the hung
page. For --hidden-s it then reads, every 0.25 s:

  ping_ms    `system.ping` round trip: the control socket answers on the main thread, so a frozen window
             shows here
  gap_ms     `debug.hangs`' longest main-thread gap over the hidden phase
  ended_s    hide to the hung page's renderer end (`debug.cef_pages` renderer clients gone or `exited`);
             none: it stayed hung
Then it closes the second tab, which shows the hung page again, and times

  answers_s  show to the page answering a DevTools call (a new renderer); none within --show-s: still hung

  hung-renderer-bench.py --app A=PATH --app B=PATH [--rounds 2] [--hidden-s 40] [--show-s 20] [--json OUT]

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

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bench_memory  # noqa: E402
from safe_log import safe_print  # noqa: E402

HUNG = b"<!doctype html><title>hung</title><body><p>hangs soon</p><script>setTimeout(() => { for (;;) {} }, 2500)</script></body>"
PLAIN = b"<!doctype html><title>plain</title><body><p>plain page</p></body>"


def rpc(path, method, params=None, timeout=30):
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


def serve():
    class Page(http.server.BaseHTTPRequestHandler):
        def do_GET(self):  # noqa: N802 (http.server API)
            body = HUNG if self.path.startswith("/hang") else PLAIN
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *args):
            pass

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Page)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, server.server_address[1]


def hung_page(path):
    """The hung page's row in `debug.cef_pages` (its origin is http://localhost; the other tab's is 127.0.0.1)."""
    pages = rpc(path, "debug.cef_pages").get("pages") or []
    return next((p for p in pages if p.get("origin") == "http://localhost"), None)


def page_answers(path, browser, timeout=4):
    try:
        reply = rpc(path, "debug.cef_page_devtools", {"browser": browser, "method": "Runtime.evaluate",
                                                      "params": {"expression": "1+1", "returnByValue": True}}, timeout=timeout + 2)
        return "error" not in reply and '"value":2' in (reply.get("result") or "").replace(" ", "")
    except (RuntimeError, OSError, ValueError):
        return False


def until(deadline_s, check, interval=0.25):
    start = time.monotonic()
    while time.monotonic() - start < deadline_s:
        if check():
            return time.monotonic() - start
        time.sleep(interval)  # bench: polling a state the app reports on request only
    return None


def pct(values, q):
    values = sorted(v for v in values if v is not None)
    return round(values[min(len(values) - 1, int(q * len(values)))], 1) if values else None


def run_arm(label, bundle, port, opts, round_index):
    row = {"arm": label, "round": round_index, "error": None}
    pid, path, scratch = bench_memory.launch(bundle, {}, extra_env={"CMUX_DEV_BACKEND_MODE": "local"}, direct=True)
    try:
        app = bench_memory.App(bundle, path)
        opened = app.action("openBrowser.chromium", focus=True, url=f"http://localhost:{port}/hang")
        if opened.get("error"):
            raise RuntimeError(f"openBrowser.chromium: {opened['error']}")
        if until(60, lambda: (hung_page(path) or {}).get("renderer_clients")) is None:
            raise RuntimeError("the hung page never got a renderer")
        browser = int(hung_page(path)["browser"])
        time.sleep(4)  # bench: the page's script starts spinning 2.5 s after it loads
        # A click the spinning renderer never acks starts Chromium's hang monitor (~15 s).
        for kind in ("mousePressed", "mouseReleased"):
            try:
                rpc(path, "debug.cef.devtools", {"method": "Input.dispatchMouseEvent", "params": {
                    "type": kind, "x": 40, "y": 40, "button": "left", "clickCount": 1}}, timeout=8)
            except (RuntimeError, OSError, ValueError):
                pass  # the hung page never answers it
        # Arms without `unresponsive` in debug.cef_pages: wait out the hang monitor.
        reported = until(30, lambda: (hung_page(path) or {}).get("unresponsive") is True)
        if reported is None and "unresponsive" not in (hung_page(path) or {}):
            time.sleep(10)  # bench: base arm, no report field; Chromium's monitor is ~15 s from the click
        row["reported_s"] = None if reported is None else round(reported, 1)
        opened = app.action("openBrowser.chromium", focus=True, url=f"http://127.0.0.1:{port}/")
        if opened.get("error"):
            raise RuntimeError(f"openBrowser.chromium (second tab): {opened['error']}")
        rpc(path, "debug.hangs", {"clear": True, "limit": 0})
        clients = list((hung_page(path) or {}).get("renderer_clients") or [])
        hide = time.monotonic()
        pings, ended = [], None
        while time.monotonic() - hide < opts.hidden_s:
            start = time.monotonic()
            try:
                rpc(path, "system.ping", timeout=30)
                pings.append((time.monotonic() - start) * 1000)
            except (RuntimeError, OSError, ValueError):
                pings.append(30000.0)
            page = hung_page(path) or {}
            if ended is None and (page.get("exited") or (page.get("renderer_clients") or []) != clients):
                ended = time.monotonic() - hide
            time.sleep(0.25)  # bench: sampling interval
        hangs = rpc(path, "debug.hangs", {})
        row.update({"hidden_on_screen": (hung_page(path) or {}).get("on_screen"),
                    "ping_p50_ms": pct(pings, 0.5), "ping_max_ms": pct(pings, 1.0), "gap_ms": round(hangs.get("max_gap_ms", 0), 1),
                    "ended_s": None if ended is None else round(ended, 1),
                    "hang_ends": (hung_page(path) or {}).get("hang_ends")})
        closed = app.action("closeTab", focus=True)
        if closed.get("error"):
            raise RuntimeError(f"closeTab: {closed['error']}")
        answers = until(opts.show_s, lambda: page_answers(path, browser))
        row["answers_s"] = None if answers is None else round(answers, 1)
    except (RuntimeError, OSError, ValueError) as failure:
        row["error"] = str(failure)[:300]
    finally:
        bench_memory.end_bundle(bundle)
        shutil.rmtree(scratch, ignore_errors=True)
    safe_print("HUNG-RENDERER " + json.dumps(row, sort_keys=True), flush=True)
    return row


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--app", action="append", required=True, help="LABEL=PATH of a tagged .app (repeatable)")
    parser.add_argument("--rounds", type=int, default=2)
    parser.add_argument("--hidden-s", type=float, default=40)
    parser.add_argument("--show-s", type=float, default=20)
    parser.add_argument("--json")
    opts = parser.parse_args()
    arms = dict(item.partition("=")[::2] for item in opts.app)
    server, port = serve()
    safe_print(f"HUNG-RENDERER-HOST host={socket.gethostname()} load={os.getloadavg()} arms={list(arms)} rounds={opts.rounds}", flush=True)
    rows = []
    try:
        for round_index in range(opts.rounds):
            for label, bundle in arms.items():
                rows.append(run_arm(label, bundle, port, opts, round_index))
    finally:
        server.shutdown()
        if opts.json:
            os.makedirs(os.path.dirname(os.path.abspath(opts.json)), exist_ok=True)
            with open(opts.json, "w") as handle:
                json.dump({"arms": arms, "rows": rows}, handle, indent=1)
    failed = [r for r in rows if r["error"]]
    if failed:
        safe_print(f"HUNG-RENDERER-INCOMPLETE {len(failed)} of {len(rows)} runs failed", flush=True)
        sys.exit(1)
    safe_print("HUNG-RENDERER-COMPLETE", flush=True)


if __name__ == "__main__":
    main()
