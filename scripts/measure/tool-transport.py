#!/usr/bin/env python3
"""Tool calls over the acpmux transport: what batching, gateway keep-alive and read prefetch could save.

The harness behind `cmux-bench tool-transport` (scripts/bench/benches/tool_transport.py). Read-only: it reads
Claude Code transcripts and opens throwaway loopback connections to this host's acpmux MCP gateway (unauthenticated,
so every request is refused with 403 before any tool runs; the key in ~/.acpmux/run/mcp-gateway.json is never read
beyond its port).

From the newest N transcripts under ~/.claude/projects (default 400) it counts:
  - calls per model step, grouped by assistant message id (a step's parallel tool calls share one id), and the share
    of calls already sent in a multi-call step: what a batched multi-read tool could add on top;
  - the model's think time between a tool result and its next step, and each tool's call-to-result time;
  - for Read: how often the file read was named in the previous tool result (the best case for prefetch);
  - tool result bytes.
Then it times N gateway requests on a fresh TCP connection each (today's `connection: close`) and the connect
alone: what HTTP keep-alive would save per call.

Prints one line: BENCH {"bench": "tool-transport", ...}.
  python3 scripts/measure/tool-transport.py [--transcripts 400] [--requests 300]
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import socket
import statistics
import time
from datetime import datetime


def _ts(value: str) -> float | None:
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    except (ValueError, AttributeError):
        return None


def _q(values: list[float], p: float) -> float | None:
    if not values:
        return None
    values = sorted(values)
    return values[int(p * (len(values) - 1))]


def transcripts(count: int) -> dict:
    files = sorted(glob.glob(os.path.expanduser("~/.claude/projects/*/*.jsonl")), key=os.path.getmtime)[-count:]
    steps: dict[tuple[str, str], int] = {}
    think_ms: list[float] = []
    exec_ms: dict[str, list[float]] = {}
    result_bytes: list[int] = []
    reads = reads_named = 0
    for path in files:
        use_at: dict[str, float | None] = {}
        use_name: dict[str, str] = {}
        last_result_at = None
        last_text = ""
        seen_step: set[str] = set()
        try:
            lines = open(path, encoding="utf-8", errors="replace")
        except OSError:
            continue
        with lines:
            for line in lines:
                try:
                    rec = json.loads(line)
                except ValueError:
                    continue
                msg = rec.get("message") or {}
                content = msg.get("content")
                if not isinstance(content, list):
                    continue
                at = _ts(rec.get("timestamp", ""))
                if rec.get("type") == "assistant":
                    uses = [b for b in content if isinstance(b, dict) and b.get("type") == "tool_use"]
                    if not uses:
                        continue
                    step = msg.get("id") or rec.get("uuid") or ""
                    key = (path, step)
                    steps[key] = steps.get(key, 0) + len(uses)
                    if step not in seen_step and last_result_at and at:
                        think_ms.append((at - last_result_at) * 1000)
                    seen_step.add(step)
                    for use in uses:
                        use_at[use.get("id")] = at
                        use_name[use.get("id")] = use.get("name") or "?"
                        if use.get("name") == "Read":
                            file_path = (use.get("input") or {}).get("file_path") or ""
                            reads += 1
                            if file_path and (file_path in last_text or os.path.basename(file_path) in last_text):
                                reads_named += 1
                elif rec.get("type") == "user":
                    for block in content:
                        if not isinstance(block, dict) or block.get("type") != "tool_result":
                            continue
                        uid = block.get("tool_use_id")
                        if use_at.get(uid) and at:
                            exec_ms.setdefault(use_name.get(uid, "?"), []).append((at - use_at[uid]) * 1000)
                        body = block.get("content")
                        text = body if isinstance(body, str) else json.dumps(body)
                        result_bytes.append(len(text))
                        last_result_at = at
                        last_text = text[:200000]
    per_step = list(steps.values())
    calls = sum(per_step) or 1
    tools = {name: {"n": len(v), "p50_ms": _q(v, 0.5), "p90_ms": _q(v, 0.9)}
             for name, v in sorted(exec_ms.items(), key=lambda kv: -len(kv[1]))[:12]}
    return {
        "files": len(files),
        "steps": len(per_step),
        "calls_per_step": statistics.mean(per_step) if per_step else None,
        "multi_call_step_pct": 100 * sum(1 for n in per_step if n > 1) / max(len(per_step), 1),
        "calls_in_multi_call_steps_pct": 100 * sum(n for n in per_step if n > 1) / calls,
        "think_p50_ms": _q(think_ms, 0.5),
        "think_p90_ms": _q(think_ms, 0.9),
        "tools": tools,
        "reads": reads,
        "read_named_in_previous_result_pct": 100 * reads_named / max(reads, 1),
        "result_bytes_p50": _q(result_bytes, 0.5),
        "result_bytes_p90": _q(result_bytes, 0.9),
    }


def gateway(requests: int) -> dict:
    path = os.path.expanduser("~/.acpmux/run/mcp-gateway.json")
    try:
        with open(path, encoding="utf-8") as f:
            port = int(json.load(f)["port"])
    except (OSError, ValueError, KeyError, TypeError):
        return {"error": "no gateway"}
    body = b"{}"
    request = (b"POST /mcp/bench HTTP/1.1\r\nhost: 127.0.0.1\r\ncontent-type: application/json\r\n"
               b"content-length: %d\r\n\r\n%s" % (len(body), body))
    whole: list[float] = []
    connect: list[float] = []
    status = b""
    for _ in range(requests):
        start = time.perf_counter()
        sock = socket.create_connection(("127.0.0.1", port), timeout=5)
        connected = time.perf_counter()
        sock.sendall(request)
        data = b""
        while chunk := sock.recv(65536):
            data += chunk
        sock.close()
        whole.append((time.perf_counter() - start) * 1e6)
        connect.append((connected - start) * 1e6)
        status = data.split(b"\r\n", 1)[0]
    return {"requests": requests, "status": status.decode("latin-1"),
            "fresh_request_p50_us": _q(whole, 0.5), "fresh_request_p90_us": _q(whole, 0.9),
            "connect_p50_us": _q(connect, 0.5), "connect_p90_us": _q(connect, 0.9)}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--transcripts", type=int, default=400)
    parser.add_argument("--requests", type=int, default=300)
    args = parser.parse_args()
    out = {"bench": "tool-transport", "host": socket.gethostname(),
           "transcripts": transcripts(args.transcripts), "gateway": gateway(args.requests)}
    print("BENCH " + json.dumps(out, separators=(",", ":")))


if __name__ == "__main__":
    main()
