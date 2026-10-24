#!/usr/bin/env python3
"""Per-view attach cost and key echo under floods: one connection per view
(today's TerminalAttachment) against client streams on one connection
(`attach-streams-v1` + `attach-frames-v1`, plans/cmux-next/app-daemon-connection-DESIGN.md).

Usage:
  stream-attach-bench.py --binary PATH/cmux-tui [--views N] [--floods F]
                         [--echoes E] [--mode legacy|streams|both] [--out FILE.json]

Starts its own headless daemon (scratch session and state dir), makes N
terminals, then per mode:
  attach   attach every view at 80x24 and time it from the first byte sent to
           the attach reply. legacy: a new connection, `identify` +
           `set-client-info` pipelined, then `attach-surface` (the per-view
           handshake). streams: `attach-surface {stream}` on the one shared
           connection. Prints the round trips and connections each view cost.
  echo     F of the views flood output (`yes`), and the bench types one key
           into another view E times, timing key sent -> its echo read back on
           that view's stream, while it drains every flood the same way the app
           does (legacy: one reader thread per connection, JSON + base64;
           streams: one reader, frames).
Run it on a fleet Mac (nx-remote), never on the laptop. Prints one
STREAM-ATTACH-BENCH json line with every number.
"""
import argparse
import base64
import json
import os
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time

now = time.perf_counter
FRAME = struct.Struct("<BBHIQ")


def percentile(values, p):
    if not values:
        return None
    ordered = sorted(values)
    return round(ordered[min(len(ordered) - 1, int(round(p / 100 * (len(ordered) - 1))))], 3)


class Wire:
    """One daemon connection: JSON lines out; JSON lines and frames in."""

    def __init__(self, path):
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.connect(path)
        self.buf = bytearray()
        self.next_id = 0
        self.lock = threading.Lock()

    def send(self, obj):
        with self.lock:
            self.next_id += 1
            rid = self.next_id
            self.sock.sendall((json.dumps(dict(obj, id=rid)) + "\n").encode())
        return rid

    def _fill(self, n, timeout):
        self.sock.settimeout(timeout)
        while len(self.buf) < n:
            chunk = self.sock.recv(1 << 20)
            if not chunk:
                raise EOFError("daemon closed the connection")
            self.buf += chunk

    def message(self, timeout=30):
        """('line', dict) or ('frame', (kind, stream, offset, payload))."""
        self._fill(1, timeout)
        if self.buf[0] == 0xFF:
            self._fill(FRAME.size, timeout)
            _, kind, stream, length, offset = FRAME.unpack_from(self.buf)
            self._fill(FRAME.size + length, timeout)
            payload = bytes(self.buf[FRAME.size:FRAME.size + length])
            del self.buf[:FRAME.size + length]
            return "frame", (kind, stream, offset, payload)
        while b"\n" not in self.buf:
            self._fill(len(self.buf) + 1, timeout)
        end = self.buf.index(b"\n")
        line = bytes(self.buf[:end])
        del self.buf[:end + 1]
        return "line", json.loads(line)

    def reply(self, rid, timeout=30, sink=None):
        while True:
            kind, value = self.message(timeout)
            if kind == "line" and value.get("id") == rid:
                if not value.get("ok"):
                    raise RuntimeError(f"request {rid} failed: {value}")
                return value
            if sink:
                sink(kind, value)

    def close(self):
        self.sock.close()


class Daemon:
    """A scratch daemon (own session and state dir), as bench_daemon_spawn.py starts one."""

    def __init__(self, binary):
        self.binary = binary
        self.state = tempfile.mkdtemp(prefix="sab-", dir="/tmp")
        self.session = "sab-" + os.path.basename(self.state)
        tmpdir = subprocess.run(["getconf", "DARWIN_USER_TEMP_DIR"], capture_output=True, text=True).stdout.strip()
        self.env = {"HOME": os.environ["HOME"], "PATH": "/usr/bin:/bin", "TMPDIR": tmpdir or "/tmp",
                    "CMUX_TUI_STATE_DIR": self.state}
        # `server start` runs the owner in the foreground.
        self.process = subprocess.Popen([binary, "--session", self.session, "server", "start"], env=self.env,
                                        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        deadline = now() + 20
        while now() < deadline:
            status = self.cli("--json", "server", "status")
            if status.get("status") == "running":
                self.socket = status["socket"]
                return
            time.sleep(0.1)  # startup only, as bench_daemon_spawn.py: status has no wait mode
        raise SystemExit("bench: the daemon did not start")

    def cli(self, *args):
        out = subprocess.run([self.binary, "--session", self.session, *args], capture_output=True, text=True,
                             env=self.env, timeout=120)
        lines = out.stdout.strip().splitlines()
        return json.loads(lines[-1]) if lines else {}

    def stop(self):
        try:
            self.cli("--json", "server", "stop", "--end-terminals")
            self.process.wait(timeout=30)
        finally:
            shutil.rmtree(self.state, ignore_errors=True)


def make_terminals(path, count):
    control = Wire(path)
    control.reply(control.send({"cmd": "identify"}))
    surfaces = []
    for index in range(count):
        reply = control.reply(control.send({"cmd": "new-workspace", "name": f"sab-{index}", "cols": 80, "rows": 24}))
        surfaces.append(reply["data"]["surface"])
    return control, surfaces


def attach_legacy(path, surface):
    started = now()
    wire = Wire(path)
    first = wire.send({"cmd": "identify"})
    second = wire.send({"cmd": "set-client-info", "name": "sab", "kind": "frontend"})
    wire.reply(first)
    wire.reply(second)
    attach = wire.send({"cmd": "attach-surface", "surface": surface, "cols": 80, "rows": 24})
    wire.reply(attach)
    return wire, (now() - started) * 1000


def attach_stream(wire, stream, surface):
    started = now()
    rid = wire.send({"cmd": "attach-surface", "attach_stream": stream, "surface": surface, "cols": 80, "rows": 24})
    wire.reply(rid)
    return (now() - started) * 1000


def decode_output(kind, value):
    """(stream or None, bytes) of an output message, else None."""
    if kind == "frame":
        frame_kind, stream, _, payload = value
        return (stream, payload) if frame_kind == 1 else None
    if value.get("event") == "output":
        return value.get("attach_stream"), base64.b64decode(value.get("data", ""))
    return None


def echo_legacy(path, surfaces, floods, echoes):
    measured, flooding = surfaces[0], surfaces[1:1 + floods]
    stop = threading.Event()
    drained = [0]
    views = []

    def drain(wire):
        while not stop.is_set():
            try:
                kind, value = wire.message(timeout=1)
            except (socket.timeout, OSError, EOFError):
                continue
            out = decode_output(kind, value)
            if out:
                drained[0] += len(out[1])

    for surface in flooding:
        wire, _ = attach_legacy(path, surface)
        views.append(wire)
        wire.send({"cmd": "send", "surface": surface, "text": "yes 0123456789abcdefghijklmnop\r"})
        threading.Thread(target=drain, args=(wire,), daemon=True).start()
    wire, _ = attach_legacy(path, measured)
    samples = echo_loop(wire, lambda: wire.send({"cmd": "send", "surface": measured, "text": "q"}),
                        lambda kind, value: decode_output(kind, value), None, echoes,
                        lambda: wire.send({"cmd": "send", "surface": measured, "text": "\b"}))
    stop.set()
    for view in views + [wire]:
        view.close()
    return samples, drained[0]


def echo_streams(path, surfaces, floods, echoes):
    measured, flooding = surfaces[0], surfaces[1:1 + floods]
    wire = Wire(path)
    wire.reply(wire.send({"cmd": "identify"}))
    wire.reply(wire.send({"cmd": "set-client-info", "name": "sab", "kind": "frontend",
                          "capabilities": ["attach-streams-v1", "attach-frames-v1"]}))
    for index, surface in enumerate(flooding, start=2):
        attach_stream(wire, index, surface)
        wire.send({"cmd": "send", "attach_stream": index, "surface": surface,
                   "text": "yes 0123456789abcdefghijklmnop\r"})
    attach_stream(wire, 1, measured)
    drained = [0]
    samples = echo_loop(wire, lambda: wire.send({"cmd": "send", "attach_stream": 1, "surface": measured, "text": "q"}),
                        lambda kind, value: decode_output(kind, value), 1, echoes,
                        lambda: wire.send({"cmd": "send", "attach_stream": 1, "surface": measured, "text": "\b"}),
                        drained)
    wire.close()
    return samples, drained[0]


def echo_loop(wire, key, output, stream, echoes, erase, drained=None):
    """Times key -> 'q' echoed on the measured view (stream `stream`, or the
    wire's only view when None); every other output is drained."""
    samples = []
    for _ in range(echoes):
        sent = now()
        key()
        while True:
            kind, value = wire.message(timeout=30)
            out = output(kind, value)
            if not out:
                continue
            owner, data = out
            if stream is None or owner == stream:
                if b"q" in data:
                    samples.append((now() - sent) * 1000)
                    break
            elif drained is not None:
                drained[0] += len(data)
        erase()
        time.sleep(0.02)  # a typing interval between keys, not a wait for state
    return samples


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", required=True)
    parser.add_argument("--views", type=int, default=24)
    parser.add_argument("--floods", type=int, default=10)
    parser.add_argument("--echoes", type=int, default=60)
    parser.add_argument("--mode", choices=["legacy", "streams", "both"], default="both")
    parser.add_argument("--out")
    args = parser.parse_args()
    result = {"views": args.views, "floods": args.floods, "echoes": args.echoes}
    modes = ["legacy", "streams"] if args.mode == "both" else [args.mode]
    for mode in modes:
        daemon = Daemon(args.binary)
        try:
            control, surfaces = make_terminals(daemon.socket, max(args.views, args.floods + 1))
            if mode == "legacy":
                attached = [attach_legacy(daemon.socket, surface) for surface in surfaces[:args.views]]
                times = [ms for _, ms in attached]
                for wire, _ in attached:
                    wire.close()
                round_trips, connections = 2, 1
            else:
                wire = Wire(daemon.socket)
                wire.reply(wire.send({"cmd": "identify"}))
                wire.reply(wire.send({"cmd": "set-client-info", "name": "sab", "kind": "frontend",
                                      "capabilities": ["attach-streams-v1", "attach-frames-v1"]}))
                times = [attach_stream(wire, index + 1, surface) for index, surface in enumerate(surfaces[:args.views])]
                wire.close()
                round_trips, connections = 1, 0
            echo, drained = (echo_legacy if mode == "legacy" else echo_streams)(
                daemon.socket, surfaces, args.floods, args.echoes)
            result[mode] = {
                "attach_ms_p50": percentile(times, 50), "attach_ms_p95": percentile(times, 95),
                "attach_round_trips_per_view": round_trips, "connections_per_view": connections,
                "echo_ms_p50": percentile(echo, 50), "echo_ms_p95": percentile(echo, 95),
                "echo_samples": len(echo), "flood_bytes_drained": drained,
            }
            control.close()
        finally:
            daemon.stop()
    line = "STREAM-ATTACH-BENCH " + json.dumps(result)
    print(line)
    if args.out:
        with open(args.out, "w") as handle:
            handle.write(json.dumps(result) + "\n")


if __name__ == "__main__":
    sys.exit(main())
