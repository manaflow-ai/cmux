#!/usr/bin/env python3
"""First Chromium tab under a CLI storm (plans/cmux-next/architecture.md 5a).

Opens the first Chromium tab of a freshly launched tagged cmux-next build
while concurrent clients fire pane actions, then checks:
  - no action waits past the 2 s action deadline (no `timeout` errors)
  - main-thread stalls (debug.hangs) stay under --max-stall-ms (default 50)
The first CEF tab maps the Chromium framework (off the main thread) and runs
CefInitialize (on the main thread), so run this against a new launch whose
session has no Chromium tab yet:

  env -i HOME=$HOME USER=$USER PATH=/usr/bin:/bin CMUX_NEXT_NO_ACTIVATE=1 \\
    CMUX_NEXT_SOCKET_MODE=automation open -g "<tagged app>"
  scripts/cmux-next/check-first-chromium.py <tag> [--actions 20] [--clients 2]
      [--interval-ms 150] [--max-stall-ms 50] [--url URL] [--socket PATH]
      [--json OUT]

Each client waits --interval-ms between its actions, so the storm spans the
CEF start (about 1.5 s by default, like 20 sequential CLI invocations).

Exits 1 when a criterion fails, 2 on usage or connection errors.
"""
import argparse
import json
import os
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bench_cli_storm import Client  # noqa: E402

ACTIONS = ["pane flash-focused", "pane focus-next", "pane equalize-splits", "pane focus-previous"]


def action(client, name, args=None):
    params = {"action": name}
    if args:
        params["args"] = args
    started = time.monotonic()
    try:
        response = client.call("action.run", params)
    except (OSError, ConnectionError, ValueError) as error:
        response = {"ok": False, "error": {"code": "client", "message": str(error)}}
    return response, (time.monotonic() - started) * 1000


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("tag")
    parser.add_argument("--socket")
    parser.add_argument("--actions", type=int, default=20)
    parser.add_argument("--clients", type=int, default=2)
    parser.add_argument("--interval-ms", type=float, default=150)
    parser.add_argument("--max-stall-ms", type=float, default=50)
    parser.add_argument("--url", default="about:blank")
    parser.add_argument("--settle", type=float, default=3.0, help="seconds to wait before reading debug.hangs")
    parser.add_argument("--json")
    args = parser.parse_args()
    path = args.socket or f"/tmp/cmux-debug-{args.tag}.sock"
    if os.path.realpath(path) in {"/tmp/cmux-debug.sock", "/private/tmp/cmux-debug.sock"}:
        print("refusing the default socket", file=sys.stderr)
        return 2
    try:
        control = Client(path)
        control.call("debug.hangs", {"clear": True})
    except (OSError, ConnectionError) as error:
        print(f"cannot reach {path}: {error}", file=sys.stderr)
        return 2

    results = []
    lock = threading.Lock()
    chromium = {}

    def open_chromium():
        response, ms = action(Client(path), "tab new-chromium", {"url": args.url})
        chromium.update(ok=bool(response.get("ok")), ms=ms, error=response.get("error"))

    counter = iter(range(args.actions))

    def storm():
        client = Client(path)
        while True:
            with lock:
                index = next(counter, None)
            if index is None:
                return
            name = ACTIONS[index % len(ACTIONS)]
            if index >= args.clients:
                time.sleep(args.interval_ms / 1000)
            response, ms = action(client, name)
            error = response.get("error") or {}
            with lock:
                results.append({"action": name, "ms": round(ms, 1), "ok": bool(response.get("ok")),
                                "code": error.get("code"), "message": error.get("message")})

    opener = threading.Thread(target=open_chromium)
    workers = [threading.Thread(target=storm) for _ in range(max(1, args.clients))]
    storm_started = time.monotonic()
    opener.start()
    for worker in workers:
        worker.start()
    opener.join()
    for worker in workers:
        worker.join()
    storm_ms = (time.monotonic() - storm_started) * 1000
    time.sleep(args.settle)
    hangs = control.call("debug.hangs").get("result") or {}
    records = hangs.get("records", [])
    stalls = [round(r.get("duration_ms", 0), 1) for r in records if r.get("duration_ms", 0) > args.max_stall_ms]
    # `unavailable` (one pane, no splits) is an answer; a deadline miss is not.
    timeouts = [r for r in results if (r["code"] or "").startswith("timeout") or "did not finish" in (r["message"] or "")]
    latencies = sorted(r["ms"] for r in results)
    report = {
        "chromium": chromium,
        "storm_ms": round(storm_ms),
        "actions": len(results),
        "timeouts": len(timeouts),
        "latency_ms": {"max": latencies[-1] if latencies else None,
                       "p50": latencies[len(latencies) // 2] if latencies else None},
        "stalls_over_threshold_ms": stalls,
        "max_stall_ms": round(hangs.get("max_ms") or 0, 1),
        "threshold_ms": args.max_stall_ms,
        "top_frames": [[f for f in r.get("frames", [])[:8]] for r in records if r.get("duration_ms", 0) > args.max_stall_ms],
    }
    if args.json:
        with open(args.json, "w") as out:
            json.dump(report, out, indent=2)
    passed = chromium.get("ok") and not timeouts and not stalls
    print(f"{'PASS' if passed else 'FAIL'}  first Chromium tab: open {chromium.get('ms', 0):.0f} ms "
          f"(ok={chromium.get('ok')}), {len(results)} actions over {storm_ms:.0f} ms, {len(timeouts)} deadline misses, "
          f"max action {report['latency_ms']['max']} ms, stalls > {args.max_stall_ms:g} ms: {stalls or 'none'}")
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
