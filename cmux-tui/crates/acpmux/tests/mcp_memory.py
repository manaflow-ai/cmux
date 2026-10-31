#!/usr/bin/env python3
"""Measure the real acpmux-mcp child against a deterministic, isolated Unix hub.

Run on Linux CI, for example:
  python3 crates/acpmux/tests/mcp_memory.py --binary target/debug/acpmux

No installed daemon, credentials, or harness is used. Each tool reply is checked
in full; VmHWM is the kernel's process high-water RSS, not fixture-size arithmetic.
The optional growth assertion compares medians of the first and last call batches.
"""

import argparse
import asyncio
import collections
import json
import os
from pathlib import Path
import statistics
import tempfile
import time


def wire(value):
    return (json.dumps(value, ensure_ascii=False, separators=(",", ":")) + "\n").encode()


def memory(pid):
    fields = {}
    for line in Path(f"/proc/{pid}/status").read_text().splitlines():
        name, _, value = line.partition(":")
        if name in ("VmRSS", "VmHWM", "Threads"):
            fields[name] = int(value.split()[0])
    if len(fields) != 3:
        raise AssertionError(f"incomplete /proc memory sample: {fields}")
    return fields


def ok(text, structured):
    return {"content": [{"type": "text", "text": text}],
            "structuredContent": structured, "isError": False}


class Fixture:
    def __init__(self, rows, peers, padding):
        self.rows = [
            {"sessionId": f"fixture-{i}", "name": f"session-{i}",
             "peer": f"peer-{i % peers}",
             "status": "closed" if i % 7 == 0 else "idle",
             "title": f"Session {i} — " + "x" * padding,
             "metadata": {"number": i, "empty": None, "tags": ["fixture", "kept"]}}
            for i in range(rows)
        ]
        self.info = {"sessionId": "fixture-target", "name": "fixture-target",
                     "status": "idle", "queued": [], "title": "Fixture target"}
        self.replies = [f"Fixture reply {i}: " + "r" * 32768 for i in range(3)]
        self.events = []
        for i, text in enumerate(self.replies):
            for kind, content in [("user_message_chunk", f"Prompt {i}"),
                                  ("agent_message_chunk", text)]:
                self.events.append({"seq": len(self.events) + 1, "dir": "in",
                                    "kind": "transcript", "at": 1000 + i,
                                    "msg": {"method": "session/update", "params": {
                                        "sessionId": "fixture-target", "update": {
                                            "sessionUpdate": kind,
                                            "content": {"type": "text", "text": content}}}}})
        lines = [f'{s["peer"]}/{s["name"]}  [{s["status"]}]  {s["title"]}'
                 for s in self.rows]
        self.list_result = ok("\n".join(lines), {"sessions": self.rows})
        self.last_result = ok("\n\n---\n\n".join(self.replies[-2:]),
                              {"sessionId": "fixture-target", "replies": self.replies[-2:]})
        self.info_result = ok(json.dumps(self.info, ensure_ascii=False, indent=2, sort_keys=True),
                              self.info)
        self.calls = collections.Counter()
        self.connections = 0
        self.active = 0
        self.peak_active = 0
        self.errors = []
        self.tasks = set()
        self.writers = set()
        self.prompt_id = None

    def response(self, method, params):
        self.calls[method] += 1
        if method == "initialize":
            return {"protocolVersion": 1}
        if method == "_acpmux/sessions":
            assert params == {}, params
            return {"sessions": self.rows}
        if method == "_acpmux/info":
            assert params == {"sessionId": "fixture-target"}, params
            return self.info
        if method == "_acpmux/attach":
            assert params["sessionId"] == "fixture-target", params
            assert params["kinds"] == ["transcript"], params
            return {"events": self.events, "hasMore": False}
        if method == "_acpmux/send_queue":
            request = params["request"]
            assert request["sessionId"] == "fixture-target", request
            assert request["prompt"] == [{"type": "text", "text": "Fixture message"}]
            assert request["_meta"]["acpmux"]["steer"] is True
            self.prompt_id = request["_meta"]["acpmux"]["promptId"]
            return {"deliveryId": "fixture-delivery", "status": "queued"}
        if method == "_acpmux/send_status":
            assert params == {"deliveryId": "fixture-delivery", "waitMs": 5000}, params
            return {"deliveryId": "fixture-delivery", "status": "delivered",
                    "accepted": {"sessionId": "fixture-target", "steer": True}}
        raise AssertionError(f"unexpected fixture RPC: {method}")

    async def connection(self, reader, writer):
        task = asyncio.current_task()
        self.tasks.add(task)
        self.writers.add(writer)
        self.connections += 1
        self.active += 1
        self.peak_active = max(self.peak_active, self.active)
        try:
            while line := await reader.readline():
                request = json.loads(line)
                result = self.response(request["method"], request.get("params", {}))
                writer.write(wire({"jsonrpc": "2.0", "id": request["id"], "result": result}))
                await writer.drain()
        except (ConnectionResetError, BrokenPipeError):
            pass
        except Exception as error:
            self.errors.append(repr(error))
        finally:
            self.active -= 1
            self.tasks.discard(task)
            self.writers.discard(writer)
            writer.close()

    def tool(self, number):
        name = ("ls", "last", "ls", "info", "send")[number % 5]
        arguments = {"ls": {}, "last": {"name": "fixture-target", "count": 2},
                     "info": {"name": "fixture-target"},
                     "send": {"to": "fixture-target", "text": "Fixture message"}}[name]
        return name, {"name": name, "arguments": arguments}

    def expected(self, name):
        if name == "ls":
            return self.list_result
        if name == "last":
            return self.last_result
        if name == "info":
            return self.info_result
        assert self.prompt_id is not None
        return ok("Sent to fixture-target: steered into its running turn: it reads it at its "
                  f"next tool step (promptId {self.prompt_id}).",
                  {"deliveryId": "fixture-delivery", "target": "fixture-target",
                   "sessionId": "fixture-target", "promptId": self.prompt_id,
                   "status": "delivered", "accepted": {
                       "sessionId": "fixture-target", "steer": True}, "delivery": "next_step"})


async def measure(args):
    fixture = Fixture(args.sessions, args.peers, args.row_padding_bytes)
    # A short private path also fits macOS Unix sockets, although RSS sampling needs Linux.
    with tempfile.TemporaryDirectory(prefix="acpmux-mcp-memory-") as scratch:
        socket = str(Path(scratch) / "hub.sock")
        server = await asyncio.start_unix_server(fixture.connection, path=socket)
        process = None
        try:
            process = await asyncio.create_subprocess_exec(
                str(Path(args.binary).resolve()), "acpmux-mcp", cwd=scratch,
                env={"PATH": os.defpath, "HOME": scratch, "LANG": "C.UTF-8",
                     "ACPMUX_HOME": scratch, "ACPMUX_SOCKET": socket,
                     "ACPMUX_SESSION_ID": "fixture-caller",
                     **({"TOKIO_WORKER_THREADS": str(args.worker_threads)}
                        if args.worker_threads is not None else {})},
                stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.DEVNULL, limit=64 * 1024 * 1024)

            async def request(number, method, params):
                process.stdin.write(wire({"jsonrpc": "2.0", "id": number,
                                          "method": method, "params": params}))
                await process.stdin.drain()
                line = await asyncio.wait_for(process.stdout.readline(), args.call_timeout)
                if not line:
                    raise AssertionError(f"MCP exited before reply {number}: {process.returncode}")
                reply = json.loads(line)
                if set(reply) != {"jsonrpc", "id", "result"}:
                    raise AssertionError(f"unexpected response envelope for {number}: {list(reply)}")
                assert reply["id"] == number and reply["jsonrpc"] == "2.0"
                if fixture.errors:
                    raise AssertionError(f"fake hub failed: {fixture.errors}")
                return reply["result"]

            initialized = await request(-1, "initialize", {"protocolVersion": "2025-06-18"})
            assert initialized["serverInfo"]["name"] == "acpmux"
            before = memory(process.pid)
            started = time.monotonic()
            batches = []
            samples = []
            for number in range(args.calls):
                name, params = fixture.tool(number)
                result = await request(number, "tools/call", params)
                if result != fixture.expected(name):
                    raise AssertionError(f"{name} reply {number} differs from the complete fixture")
                samples.append(memory(process.pid))
                if len(samples) == args.batch_size or number + 1 == args.calls:
                    batches.append({"through_call": number + 1,
                                    "rss_median_kib": statistics.median(s["VmRSS"] for s in samples),
                                    "rss_max_kib": max(s["VmRSS"] for s in samples),
                                    "hwm_kib": max(s["VmHWM"] for s in samples),
                                    "threads_max": max(s["Threads"] for s in samples)})
                    samples.clear()
            # This request/response fence ensures all tool responses were consumed before steady RSS.
            assert await request(args.calls, "ping", {}) == {}
            after = memory(process.pid)
            report = {"calls": args.calls, "sessions": args.sessions, "peers": args.peers,
                      "row_padding_bytes": args.row_padding_bytes,
                      "call_mix": ["ls", "last", "ls", "info", "send"],
                      "seconds": round(time.monotonic() - started, 3),
                      "baseline_rss_kib": before["VmRSS"], "peak_rss_kib": after["VmHWM"],
                      "steady_rss_kib": after["VmRSS"], "threads": after["Threads"],
                      "first_batch_rss_kib": batches[0]["rss_median_kib"],
                      "last_batch_rss_kib": batches[-1]["rss_median_kib"],
                      "growth_kib": batches[-1]["rss_median_kib"] - batches[0]["rss_median_kib"],
                      "batches": batches, "hub_connections": fixture.connections,
                      "hub_peak_active_connections": fixture.peak_active,
                      "hub_active_connections_after_calls": fixture.active,
                      "hub_methods": dict(fixture.calls)}
            print(json.dumps(report, sort_keys=True), flush=True)
            if args.max_rss_mib is not None:
                assert report["peak_rss_kib"] <= args.max_rss_mib * 1024, report
            if args.max_growth_mib is not None:
                assert report["growth_kib"] <= args.max_growth_mib * 1024, report
            process.stdin.close()
            await asyncio.wait_for(process.wait(), args.call_timeout)
            assert process.returncode == 0, process.returncode
        finally:
            if process is not None and process.returncode is None:
                process.terminate()
                try:
                    await asyncio.wait_for(process.wait(), 5)
                except asyncio.TimeoutError:
                    process.kill()
                    await process.wait()
            server.close()
            await server.wait_closed()
            for writer in list(fixture.writers):
                writer.close()
            tasks = list(fixture.tasks)
            for task in tasks:
                task.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True)
    parser.add_argument("--calls", type=int, default=500)
    parser.add_argument("--sessions", type=int, default=3000)
    parser.add_argument("--peers", type=int, default=30)
    parser.add_argument("--row-padding-bytes", type=int, default=256)
    parser.add_argument("--batch-size", type=int, default=50)
    parser.add_argument("--call-timeout", type=float, default=20)
    parser.add_argument("--timeout", type=float, default=180)
    parser.add_argument("--max-growth-mib", type=float)
    parser.add_argument("--max-rss-mib", type=float)
    parser.add_argument("--worker-threads", type=int)
    args = parser.parse_args()
    if min(args.calls, args.sessions, args.peers, args.batch_size, args.call_timeout, args.timeout) <= 0:
        parser.error("counts and timeouts must be positive")
    if args.calls < 2 * args.batch_size:
        parser.error("use at least two complete batches to compare growth")
    if args.worker_threads is not None and args.worker_threads <= 0:
        parser.error("worker threads must be positive")
    if args.row_padding_bytes < 0:
        parser.error("row padding must be nonnegative")

    async def bounded():
        await asyncio.wait_for(measure(args), args.timeout)

    asyncio.run(bounded())


if __name__ == "__main__":
    main()
