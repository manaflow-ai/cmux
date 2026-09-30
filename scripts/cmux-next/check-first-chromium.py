#!/usr/bin/env python3
"""First Chromium tab under a CLI storm (plans/cmux-next/architecture.md 5a).

Opens a Chromium tab of a freshly launched tagged cmux-next build while
concurrent clients fire pane actions, then checks:
  - no action waits past the 2 s action deadline (no `timeout` errors)
  - main-thread stalls (debug.hangs) stay under --max-stall-ms (default 50),
    except for the one allowed exception (architecture.md 5a): Chromium's
    main-thread steps, `CefInitialize` and creating a Chromium window
    (about 70-160 ms each), each at most --exception-max-ms (default 200).

Modes:
  --mode cold  (default) CEF has not started (debug.cef state is not ready;
               no Chromium tab was likely). Allows two exception stalls:
               CefInitialize and the tab's Chromium window.
  --mode warm  A Chromium tab was likely (a restored Chromium tab, the "+"
               engine menu, the palette entry). Waits up to --warm-timeout for
               ChromiumWarmup to finish CefInitialize at idle, then requires
               that CefInitialize never ran during the storm: only the new
               Chromium window's stall is allowed.

Launch the tagged app with a clean environment first, for example:

  env -i HOME=$HOME USER=$USER PATH=/usr/bin:/bin CMUX_NEXT_NO_ACTIVATE=1 \\
    CMUX_NEXT_SOCKET_MODE=automation open -g "<tagged app>"
  scripts/cmux-next/check-first-chromium.py <tag> [--mode cold|warm]
      [--actions 20] [--clients 2] [--interval-ms 150] [--max-stall-ms 50]
      [--exception-max-ms 200] [--warm-timeout 30] [--url URL]
      [--socket PATH] [--json OUT]

Each client waits --interval-ms between its actions, so the storm spans the
CEF start (about 1.5 s by default, like 20 sequential CLI invocations).
For warm mode, keep a Chromium tab in a background workspace and relaunch.

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
    parser.add_argument("--mode", choices=["cold", "warm"], default="cold")
    parser.add_argument("--exception-max-ms", type=float, default=200)
    parser.add_argument("--warm-timeout", type=float, default=30)
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
        before = control.call("debug.cef").get("result") or {}
    except (OSError, ConnectionError) as error:
        print(f"cannot reach {path}: {error}", file=sys.stderr)
        return 2
    if args.mode == "cold" and before.get("state") == "ready":
        print("CEF already started (debug.cef state ready): relaunch with no Chromium tab, or use --mode warm", file=sys.stderr)
        return 2
    if args.mode == "warm":
        deadline = time.monotonic() + args.warm_timeout
        while before.get("state") != "ready" and time.monotonic() < deadline:
            time.sleep(0.25)
            before = control.call("debug.cef").get("result") or {}
        if before.get("state") != "ready" or before.get("trigger") in (None, "tab"):
            print(f"FAIL  no warm start within {args.warm_timeout:g} s: debug.cef {before}")
            return 1
    control.call("debug.hangs", {"clear": True})

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
    after = control.call("debug.cef").get("result") or {}
    allowed = 2 if args.mode == "cold" else 1
    over_exception = [ms for ms in stalls if ms > args.exception_max_ms]
    stall_failure = len(stalls) > allowed or bool(over_exception)
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
        "mode": args.mode,
        "allowed_exception_stalls": allowed,
        "exception_max_ms": args.exception_max_ms,
        "cef_before": before,
        "cef_after": after,
        "top_frames": [[f for f in r.get("frames", [])[:8]] for r in records if r.get("duration_ms", 0) > args.max_stall_ms],
    }
    if args.json:
        with open(args.json, "w") as out:
            json.dump(report, out, indent=2)
    passed = chromium.get("ok") and not timeouts and not stall_failure
    print(f"{'PASS' if passed else 'FAIL'}  [{args.mode}, trigger={after.get('trigger')}, "
          f"allowed {allowed} stall(s) <= {args.exception_max_ms:g} ms] Chromium tab: open {chromium.get('ms', 0):.0f} ms "
          f"(ok={chromium.get('ok')}), {len(results)} actions over {storm_ms:.0f} ms, {len(timeouts)} deadline misses, "
          f"max action {report['latency_ms']['max']} ms, stalls > {args.max_stall_ms:g} ms: {stalls or 'none'}")
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
