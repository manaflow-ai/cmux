#!/usr/bin/env python3
"""Measure cmux browser-frame throughput over the mux control socket."""

import argparse
import base64
import json
import os
import socket
import statistics
import sys
import tempfile
import time


def default_socket() -> str:
    return os.path.join(tempfile.gettempdir(), f"cmux-mux-{os.getuid()}", "main.sock")


class Rpc:
    def __init__(self, path: str):
        self.path = path
        self.next_id = 1

    def request(self, cmd: dict) -> dict:
        req_id = self.next_id
        self.next_id += 1
        payload = dict(cmd)
        payload["id"] = req_id
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
            sock.connect(self.path)
            sock.sendall((json.dumps(payload) + "\n").encode())
            reader = sock.makefile("r", encoding="utf-8")
            for line in reader:
                value = json.loads(line)
                if value.get("id") != req_id:
                    continue
                if not value.get("ok"):
                    raise RuntimeError(value.get("error", "request failed"))
                return value.get("data") or {}
        raise RuntimeError("socket closed before response")


def send_line(sock: socket.socket, payload: dict) -> None:
    sock.sendall((json.dumps(payload) + "\n").encode())


def percentile(values: list[float], pct: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    index = min(len(ordered) - 1, int(round((pct / 100.0) * (len(ordered) - 1))))
    return ordered[index]


def frame_size(data: str) -> int:
    try:
        return len(base64.b64decode(data, validate=False))
    except Exception:
        return len(data)


class LineReader:
    """Buffered line reader over a timeout socket. readline() returns None on
    timeout instead of raising: socket.makefile() readers are permanently
    unusable after one timeout (OSError: cannot read from timed out object),
    so retry loops need raw recv buffering."""

    def __init__(self, sock: socket.socket) -> None:
        self._sock = sock
        self._buf = bytearray()

    def readline(self) -> str | None:
        while True:
            nl = self._buf.find(b"\n")
            if nl >= 0:
                line = self._buf[: nl + 1].decode("utf-8")
                del self._buf[: nl + 1]
                return line
            try:
                chunk = self._sock.recv(65536)
            except (socket.timeout, TimeoutError):
                return None
            if not chunk:
                return ""
            self._buf.extend(chunk)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--socket", default=default_socket(), help="mux unix socket path")
    parser.add_argument("--surface", type=int, help="existing browser surface id")
    parser.add_argument("--url", help="create and measure a temporary browser surface at this URL")
    parser.add_argument("--seconds", type=float, default=10.0, help="measurement window")
    args = parser.parse_args()

    if (args.surface is None) == (args.url is None):
        parser.error("provide exactly one of --surface or --url")
    if args.seconds <= 0:
        parser.error("--seconds must be > 0")

    rpc = Rpc(args.socket)
    created_surface = None
    surface = args.surface
    if args.url:
        data = rpc.request({"cmd": "new-browser-tab", "url": args.url})
        surface = int(data["surface"])
        created_surface = surface

    attach = None
    try:
        attach = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        attach.connect(args.socket)
        attach.settimeout(0.5)
        reader = LineReader(attach)
        send_line(attach, {"id": 1, "cmd": "attach-surface", "surface": surface})
        got_state = False
        got_response = False
        initial_seq = None
        deadline = time.monotonic() + 10.0
        while time.monotonic() < deadline and not (got_state and got_response):
            line = reader.readline()
            if line is None:
                continue
            if not line:
                raise RuntimeError("attach socket closed during handshake")
            value = json.loads(line)
            if value.get("id") == 1:
                if not value.get("ok"):
                    raise RuntimeError(value.get("error", "attach failed"))
                got_response = True
            elif value.get("event") == "browser-state":
                got_state = True
                frame = value.get("frame")
                if frame:
                    initial_seq = frame.get("seq")
            elif value.get("event") == "frame":
                initial_seq = value.get("seq")
        if not got_state:
            raise RuntimeError("attach did not return browser-state")
        if not got_response:
            raise RuntimeError("attach response was not received")

        start = time.monotonic()
        end = start + args.seconds
        frame_times: list[float] = []
        sizes: list[int] = []
        last_frame_time = None
        gaps: list[float] = []
        last_seq = initial_seq
        wheel_sent_at = None
        wheel_after_seq = initial_seq
        wheel_latency = None
        dims = (None, None)

        while time.monotonic() < end:
            now = time.monotonic()
            # Poke repeatedly until frames flow: the first interaction is what
            # un-throttles a hidden external-Chrome tab via the stall nudge.
            need_poke = wheel_sent_at is None or (not frame_times and now - wheel_sent_at >= 2.0)
            if need_poke and now - start >= min(args.seconds / 2.0, 2.0):
                try:
                    rpc.request(
                        {
                            "cmd": "browser-wheel",
                            "surface": surface,
                            "x_px": 10,
                            "y_px": 10,
                            "delta_y_px": 120,
                        }
                    )
                except RuntimeError:
                    pass  # still starting; retry on the next poke cycle
                wheel_sent_at = time.monotonic()
                wheel_after_seq = last_seq
            line = reader.readline()
            if line is None:
                continue
            if not line:
                break
            value = json.loads(line)
            if value.get("event") != "frame":
                continue
            received = time.monotonic()
            seq = value.get("seq")
            last_seq = seq
            frame_times.append(received)
            sizes.append(frame_size(value.get("data", "")))
            dims = (value.get("width"), value.get("height"))
            if last_frame_time is not None:
                gaps.append(received - last_frame_time)
            last_frame_time = received
            if wheel_sent_at is not None and wheel_latency is None and seq != wheel_after_seq:
                wheel_latency = received - wheel_sent_at

        elapsed = max(time.monotonic() - start, 0.001)
        fps = len(frame_times) / elapsed
        print(f"surface: {surface}")
        print(f"seconds: {elapsed:.2f}")
        if frame_times and dims != (None, None):
            print(f"frame_dims: {dims[0]}x{dims[1]}")
        print(f"frames: {len(frame_times)}")
        print(f"fps: {fps:.2f}")
        if sizes:
            print(
                "frame_bytes: "
                f"median={statistics.median(sizes):.0f} "
                f"p95={percentile(sizes, 95):.0f} "
                f"max={max(sizes):.0f}"
            )
        if gaps:
            print(
                "inter_frame_gap_ms: "
                f"median={statistics.median(gaps) * 1000:.1f} "
                f"p95={percentile(gaps, 95) * 1000:.1f} "
                f"max={max(gaps) * 1000:.1f}"
            )
        if wheel_sent_at is not None:
            if wheel_latency is None:
                print("wheel_to_next_frame_ms: none")
            else:
                print(f"wheel_to_next_frame_ms: {wheel_latency * 1000:.1f}")

        if not frame_times:
            print(
                "error: zero frames received; if this uses external headful Chrome, "
                "check whether the tab/window is hidden or occluded",
                file=sys.stderr,
            )
            return 2
        return 0
    finally:
        if attach is not None:
            attach.close()
        if created_surface is not None:
            try:
                rpc.request({"cmd": "close-surface", "surface": created_surface})
            except Exception as exc:
                print(f"warning: failed to close created surface {created_surface}: {exc}", file=sys.stderr)


if __name__ == "__main__":
    raise SystemExit(main())
