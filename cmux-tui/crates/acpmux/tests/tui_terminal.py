#!/usr/bin/env python3
"""Exercise the real TUI in a PTY against an isolated, deterministic daemon.

    python3 tests/tui_terminal.py target/release/acpmux

No real agents, account configuration or user sessions are touched. --baseline
reports the same measurements without enforcing the new output invariants.
"""

import argparse
import fcntl
import json
import os
from pathlib import Path
import pty
import re
import select
import signal
import socket
import statistics
import struct
import tempfile
import termios
import threading
import time


def printed(data):
    data = re.sub(rb"\x1b\].*?(?:\x07|\x1b\\)", b"", data, flags=re.S)
    return re.sub(rb"\x1b\[[0-?]*[ -/]*[@-~]", b"", data)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("binary", type=Path)
    parser.add_argument("--baseline", action="store_true")
    args = parser.parse_args()
    binary = str(args.binary.resolve())
    with tempfile.TemporaryDirectory(prefix="acpmux-tui-", dir="/tmp") as home:
        path = str(Path(home) / "daemon.sock")
        Path(home, "config.json").write_text(json.dumps({"harnesses": {}, "peers": {}}))
        listener = socket.socket(socket.AF_UNIX)
        listener.bind(path)
        listener.listen(1)
        session = {"sessionId": "perf", "name": "performance fixture", "harness": "fake",
                   "cwd": "/tmp", "status": "ready", "updatedAt": 1, "pendingPermissions": 0}
        events = []

        def event(kind, msg, direction="mux"):
            return {"seq": len(events) + 1, "sessionId": "perf", "dir": direction,
                    "kind": kind, "msg": msg, "at": 1}

        for n in range(500):
            events.append(event("user_message", {"text": f"turn {n}"}))
            events.append(event("agent_message_chunk", {"method": "session/update", "params": {
                "update": {"sessionUpdate": "agent_message_chunk", "content": {"text":
                    "See src/main.rs and https://example.com.\n\n```rust\nfn main() {\n    println!(\"hello\");\n}\n```"}}}}, "in"))
            events.append(event("turn_end", {"stopReason": "end_turn"}))

        connected = threading.Event()
        send_lock = threading.Lock()
        connection = []
        server_errors = []

        def send(obj):
            with send_lock:
                connection[0].sendall((json.dumps(obj) + "\n").encode())

        def serve():
            try:
                conn, _ = listener.accept()
                connection.append(conn)
                connected.set()
                for raw in conn.makefile("rb"):
                    request = json.loads(raw)
                    method = request.get("method")
                    result = {
                        "initialize": {"protocolVersion": 1, "agentCapabilities": {}},
                        "_acpmux/watch": {"sessions": [session]},
                        "_acpmux/sessions": {"sessions": [session]},
                        "_acpmux/attach": {"session": session, "events": events},
                        "_acpmux/harnesses": {"harnesses": {"fake": {}}, "defaultHarness": "fake"},
                        "_acpmux/status": {"peers": []},
                        "_acpmux/info": session,
                    }.get(method, {})
                    if "id" in request:
                        send({"jsonrpc": "2.0", "id": request["id"], "result": result})
            except (BrokenPipeError, ConnectionResetError):
                pass
            except Exception as exc:
                server_errors.append(repr(exc))

        server = threading.Thread(target=serve, daemon=True)
        server.start()
        pid, master = pty.fork()
        if pid == 0:
            env = dict(os.environ, ACPMUX_HOME=home, ACPMUX_SOCKET=path,
                       TERM="xterm-256color", COLORTERM="truecolor")
            os.execve(binary, [binary], env)
        fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))

        def read_for(seconds):
            data = bytearray()
            deadline = time.monotonic() + seconds
            while time.monotonic() < deadline:
                if select.select([master], [], [], max(0, deadline - time.monotonic()))[0]:
                    try:
                        chunk = os.read(master, 1024 * 1024)
                    except OSError:
                        break
                    if not chunk:
                        break
                    data.extend(chunk)
            return bytes(data)

        try:
            assert connected.wait(10), "TUI did not connect to isolated daemon"
            initial = bytearray()
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline:
                initial.extend(read_for(0.2))
                if b"Error:" in printed(initial) or b"panicked" in printed(initial):
                    raise AssertionError(printed(initial).decode(errors="replace"))
                if b"file:///tmp/src/main.rs" in initial:
                    break
            assert b"file:///tmp/src/main.rs" in initial, f"fixture transcript never rendered: {printed(initial).decode(errors='replace')}"
            read_for(0.5)
            idle = read_for(1)
            latencies = []
            typing = bytearray()
            for char in b"ZXCVBNMLKJHG":
                start = time.monotonic()
                os.write(master, bytes([char]))
                output = bytearray()
                while time.monotonic() - start < 5:
                    output.extend(read_for(0.002))
                    visible = output if args.baseline else output.rsplit(b"\x1b[?2026l", 1)[0]
                    if bytes([char]) in printed(visible) and (args.baseline or b"\x1b[?2026l" in output):
                        break
                else:
                    raise AssertionError("typed key was not presented within five seconds")
                latencies.append((time.monotonic() - start) * 1000)
                typing.extend(output)
            typing.extend(read_for(0.2))

            def stream():
                send({"jsonrpc": "2.0", "method": "_acpmux/event", "params": {
                    "sessionId": "perf", "seq": 1501, "dir": "mux", "kind": "status", "msg": {"status": "running"}}})
                for n in range(1000):
                    send({"jsonrpc": "2.0", "method": "session/update", "params": {
                        "sessionId": "perf", "_meta": {"acpmux": {"seq": 1502 + n}},
                        "update": {"sessionUpdate": "agent_message_chunk", "content": {"text": "stream "}}}})
                    time.sleep(0.002)

            streamer = threading.Thread(target=stream, daemon=True)
            streamer.start()
            during = bytearray()
            stream_latencies = []
            for char in b"QAZPLMKJHGFDS":
                start = time.monotonic()
                os.write(master, bytes([char]))
                output = bytearray()
                while time.monotonic() - start < 5:
                    output.extend(read_for(0.002))
                    visible = output if args.baseline else output.rsplit(b"\x1b[?2026l", 1)[0]
                    if bytes([char]) in printed(visible) and (args.baseline or b"\x1b[?2026l" in output):
                        break
                else:
                    raise AssertionError("stream starved input for five seconds")
                stream_latencies.append((time.monotonic() - start) * 1000)
                during.extend(output)
                during.extend(read_for(0.02))
            while streamer.is_alive():
                during.extend(read_for(0.1))
            during.extend(read_for(0.1))

            if not args.baseline:
                assert len(idle) == 0, f"idle output: {len(idle)} bytes"
                assert b"\x1b]8;" not in typing, "typing repainted a transcript link"
                moves = re.findall(rb"\x1b\[(\d+);(\d+)H", typing)
                assert moves and all(int(row) >= 36 for row, _ in moves), "typing moved cursor into transcript"
                # Each published frame ends by restoring the input caret.
                frames = during.split(b"\x1b[?2026h")[1:]
                assert frames and all(re.search(rb"\x1b\[37;\d+H\x1b\[\?25h\x1b\[\?2026l", f) for f in frames)
                assert len(frames) < 220, f"1000 updates produced {len(frames)} frames"
                for rows, cols in [(5, 20), (24, 80), (40, 120)]:
                    fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
                    os.kill(pid, signal.SIGWINCH)
                    resized = bytearray()
                    deadline = time.monotonic() + 5
                    while time.monotonic() < deadline and b"\x1b[?2026l" not in resized:
                        resized.extend(read_for(0.05))
                    assert b"\x1b[?2026l" in resized, f"resize to {cols}x{rows} did not present a frame: {printed(resized)!r}"
                    assert b"panicked" not in resized
            assert not server_errors, server_errors
            print(json.dumps({
                "idle_bytes_per_second": len(idle),
                "typing_bytes": len(typing),
                "typing_latency_median_ms": round(statistics.median(latencies), 2),
                "typing_latency_max_ms": round(max(latencies), 2),
                "streaming_key_latency_median_ms": round(statistics.median(stream_latencies), 2),
                "streaming_key_latency_max_ms": round(max(stream_latencies), 2),
                "stream_frames": during.count(b"\x1b[?2026h"),
                "stream_bytes": len(during),
            }, indent=2))
        finally:
            try:
                os.write(master, b"\x11")  # detach only our isolated TUI
            except OSError:
                pass
            read_for(0.2)
            if os.waitpid(pid, os.WNOHANG)[0] == 0:
                os.kill(pid, signal.SIGTERM)
                os.waitpid(pid, 0)
            os.close(master)
            for conn in connection:
                conn.close()
            listener.close()


if __name__ == "__main__":
    main()
