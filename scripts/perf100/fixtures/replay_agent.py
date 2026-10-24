#!/usr/bin/env python3
"""perf100 replay agent: an ACP agent (JSON-RPC over stdio) that streams a recorded fixture.

No model and no network. A prompt of the form

    perf100 stream=<fixture> speed=<x> marks=<n> tag=<id> log=<path>

replays fixtures/agent-streams/<fixture>.jsonl as `agent_message_chunk` updates at the
recorded offsets divided by `speed`, then ends the turn. With marks=n, n chunks spread evenly
over the reply start with a marker `[pm:<tag>:<k>]`, and the agent appends
`{"mark": "[pm:<tag>:<k>]", "t": <time.time()>}` to `log` right before it writes that chunk,
so a reader can time token-to-screen (or token-to-client) per marker. Any other prompt gets the
one-chunk reply "ok" (a session's first turn). With done=<fifo>, the agent writes one line to
that FIFO after the turn ends (a reader blocks on it: no polling). session/cancel stops a
running stream.
"""
from __future__ import annotations

import json
import os
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import streams  # noqa: E402

_lock = threading.Lock()
_cancel: dict[str, threading.Event] = {}
_sessions = 0


def send(obj):
    with _lock:
        sys.stdout.write(json.dumps(obj) + "\n")
        sys.stdout.flush()


def chunk(sid: str, text: str):
    send({"jsonrpc": "2.0", "method": "session/update",
          "params": {"sessionId": sid, "update": {"sessionUpdate": "agent_message_chunk",
                                                  "content": {"type": "text", "text": text}}}})


def parse(text: str) -> dict | None:
    words = text.strip().split()
    if not words or words[0] != "perf100":
        return None
    opts = {}
    for word in words[1:]:
        key, _, value = word.partition("=")
        opts[key] = value
    return opts if "stream" in opts else None


def stream(rid, sid: str, opts: dict):
    stop = _cancel.setdefault(sid, threading.Event())
    stop.clear()
    chunks = streams.load(opts.get("stream", "prose-8k"))
    speed = max(float(opts.get("speed", "1") or 1), 0.01)
    marks = int(opts.get("marks", "0") or 0)
    tag = opts.get("tag", "s")
    log_path = opts.get("log")
    every = max(1, len(chunks) // marks) if marks > 0 else 0
    log = open(log_path, "a", buffering=1) if (log_path and marks) else None
    began = time.monotonic()
    k = 0
    try:
        for i, entry in enumerate(chunks):
            due = began + entry["ms"] / 1000.0 / speed
            # The recorded cadence of the model: wait for the chunk's offset (or a cancel).
            if stop.wait(max(0.0, due - time.monotonic())):
                send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "cancelled"}})
                return
            text = entry["text"]
            if every and i % every == 0 and k < marks:
                mark = f"[pm:{tag}:{k}]"
                # Its own paragraph: a page reader finds it whole (app_scenarios._watch_page_for_marks).
                text = f"\n\n{mark}\n\n" + text.lstrip()
                if log:
                    log.write(json.dumps({"mark": mark, "t": time.time()}) + "\n")
                k += 1
            chunk(sid, text)
        send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})
    finally:
        if log:
            log.close()
        if opts.get("done"):
            try:
                with open(opts["done"], "w") as fifo:  # blocks until the harness reads it
                    fifo.write("done\n")
            except OSError:
                pass


def main():
    global _sessions
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except ValueError:
            continue
        method = msg.get("method")
        rid = msg.get("id")
        params = msg.get("params") or {}
        if method is None:
            continue  # a reply to a request this agent never sends
        if method == "initialize":
            send({"jsonrpc": "2.0", "id": rid, "result": {
                "protocolVersion": 1,
                "agentInfo": {"name": "perf100-replay", "version": "1"},
                "agentCapabilities": {"loadSession": True},
                "authMethods": [],
            }})
        elif method == "session/new":
            _sessions += 1
            send({"jsonrpc": "2.0", "id": rid, "result": {"sessionId": f"perf100-{os.getpid()}-{_sessions}"}})
        elif method == "session/load":
            send({"jsonrpc": "2.0", "id": rid, "result": None})
        elif method in ("session/set_mode", "session/set_model", "session/set_config_option"):
            send({"jsonrpc": "2.0", "id": rid, "result": {}})
        elif method == "session/prompt":
            sid = params.get("sessionId", "")
            text = "".join(b.get("text", "") for b in params.get("prompt", []) if isinstance(b, dict))
            opts = parse(text)
            if opts is None:
                chunk(sid, "ok")
                send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})
            else:
                threading.Thread(target=stream, args=(rid, sid, opts), daemon=True).start()
        elif method == "session/cancel":
            event = _cancel.get(params.get("sessionId", ""))
            if event:
                event.set()
        elif rid is not None:
            send({"jsonrpc": "2.0", "id": rid, "error": {"code": -32601, "message": "no such method"}})


if __name__ == "__main__":
    main()
