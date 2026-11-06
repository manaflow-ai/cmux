#!/usr/bin/env python3
"""A streaming ACP agent for the daemon's performance tests (tests/perf_ops.rs).

A prompt "stream N GAP_MS" answers with N agent_message_chunk updates, GAP_MS apart (0: as
fast as the pipe takes them), then end_turn. Each chunk's text is "t<ns>;", the time it was
written on CLOCK_UPTIME_RAW (macOS), the clock the test reads on arrival, so the test measures
the daemon's token-to-client latency without any model. Any other prompt answers "ok" at once.
session/cancel ends a running stream with stopReason "cancelled".
"""
import json
import sys
import threading
import time

lock = threading.Lock()
cancelled = set()
sessions = 0


def now_ns():
    return time.clock_gettime_ns(time.CLOCK_UPTIME_RAW)


def send(obj):
    with lock:
        sys.stdout.write(json.dumps(obj) + "\n")
        sys.stdout.flush()


def chunk(sid, text):
    send({"jsonrpc": "2.0", "method": "session/update", "params": {
        "sessionId": sid,
        "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": text}}}})


def prompt(rid, params):
    sid = params.get("sessionId")
    text = "".join(b.get("text", "") for b in params.get("prompt", []) if b.get("type") == "text")
    words = text.split()
    if len(words) == 3 and words[0] == "stream":
        n, gap = int(words[1]), float(words[2]) / 1000.0
        cancelled.discard(sid)
        for _ in range(n):
            if sid in cancelled:
                send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "cancelled"}})
                return
            chunk(sid, f"t{now_ns()};")
            if gap:
                time.sleep(gap)
    else:
        chunk(sid, "ok")
    send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})


def main():
    global sessions
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        msg = json.loads(line)
        rid, m, params = msg.get("id"), msg.get("method"), msg.get("params") or {}
        if m == "initialize":
            send({"jsonrpc": "2.0", "id": rid, "result": {
                "protocolVersion": 1,
                "agentCapabilities": {"loadSession": True},
                "authMethods": []}})
        elif m == "session/new":
            sessions += 1
            send({"jsonrpc": "2.0", "id": rid, "result": {"sessionId": f"stream-{sessions}"}})
        elif m == "session/load":
            send({"jsonrpc": "2.0", "id": rid, "result": None})
        elif m == "session/prompt":
            threading.Thread(target=prompt, args=(rid, params), daemon=True).start()
        elif m == "session/cancel":
            cancelled.add(params.get("sessionId"))
        elif rid is not None and m is not None:
            send({"jsonrpc": "2.0", "id": rid, "result": {}})


if __name__ == "__main__":
    main()
