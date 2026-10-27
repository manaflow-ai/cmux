#!/usr/bin/env python3
"""Measure cmux browser-frame throughput over the mux control socket.

Percentiles (median, p95, p99) come from scripts/perf-lab/perf_stats.py.

With --app (a tagged bundle), the bench launches it through
scripts/cmux-next/bench_launch.py's BenchApp and measures --url on the app's
own cmux-tui daemon. With --app and --out DIR, the raw samples are also written
through BenchApp.record as cmux-perf-result/v1 in story tui-browser-frames
(session light, engine chromium): tui_browser_frames.fps,
tui_browser_frames.frame_bytes (bytes, every frame),
tui_browser_frames.inter_frame_gap and
tui_browser_frames.wheel_to_next_frame (ms).
"""

import argparse
import base64
import importlib.util
import json
import os
import socket
import sys
import tempfile
import time


_spec = importlib.util.spec_from_file_location(
    "perf_import",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "scripts", "perf-lab", "perf_import.py"),
)
perf_import = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(perf_import)
perf_stats = perf_import.load("perf_stats")

STORY = "tui-browser-frames"
SESSION = "light"
ENGINE = "chromium"  # the app's browser provider renders the frames
REQUEST_TIMEOUT_S = 60


def default_socket() -> str:
    return os.path.join(tempfile.gettempdir(), f"cmux-tui-{os.getuid()}", "main.sock")


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
            # A daemon with no browser provider never answers new-browser-tab: fail instead of hanging a lab run.
            sock.settimeout(REQUEST_TIMEOUT_S)
            sock.connect(self.path)
            sock.sendall((json.dumps(payload) + "\n").encode())
            reader = sock.makefile("r", encoding="utf-8")
            try:
                for line in reader:
                    value = json.loads(line)
                    if value.get("id") != req_id:
                        continue
                    if not value.get("ok"):
                        raise RuntimeError(value.get("error", "request failed"))
                    return value.get("data") or {}
            except TimeoutError:
                raise RuntimeError(f"{cmd.get('cmd')}: no reply in {REQUEST_TIMEOUT_S} s") from None
        raise RuntimeError("socket closed before response")


def send_line(sock: socket.socket, payload: dict) -> None:
    sock.sendall((json.dumps(payload) + "\n").encode())


def send_browser_attach_handshake(sock: socket.socket, surface: int) -> None:
    send_line(
        sock,
        {
            "id": 0,
            "cmd": "set-client-info",
            "kind": "measure-frames",
            "capabilities": ["browser-pointer-frame-guard-v1"],
        },
    )
    send_line(sock, {"id": 1, "cmd": "attach-surface", "surface": surface})


def frame_size(data: str) -> int:
    try:
        return len(base64.b64decode(data, validate=False))
    except Exception:
        return len(data)


def pointer_frame_seq_from_event(value: dict) -> int | None:
    if value.get("status") != "live":
        return None
    pointer_frame_seq = value.get("pointer_frame_seq")
    if type(pointer_frame_seq) is not int or pointer_frame_seq < 0:
        return None
    return pointer_frame_seq


def recovery_poke(surface: int, pointer_frame_seq: int | None) -> dict:
    if pointer_frame_seq is None:
        return {"cmd": "browser-activate", "surface": surface}
    return {
        "cmd": "browser-wheel-guarded",
        "surface": surface,
        "x_px": 10,
        "y_px": 10,
        "delta_y_px": 120,
        "frame_seq": pointer_frame_seq,
    }


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


def frame_report_lines(sizes: list[int], gaps: list[float]) -> list[str]:
    """The frame_bytes and inter_frame_gap_ms report lines; `gaps` are in seconds. No line for an empty list."""
    lines = []
    if sizes:
        lines.append(
            "frame_bytes: "
            f"median={perf_stats.pct(sizes, 0.5):.0f} "
            f"p95={perf_stats.pct(sizes, 0.95):.0f} "
            f"p99={perf_stats.pct(sizes, 0.99):.0f} "
            f"max={max(sizes):.0f}"
        )
    if gaps:
        lines.append(
            "inter_frame_gap_ms: "
            f"median={perf_stats.pct(gaps, 0.5) * 1000:.1f} "
            f"p95={perf_stats.pct(gaps, 0.95) * 1000:.1f} "
            f"p99={perf_stats.pct(gaps, 0.99) * 1000:.1f} "
            f"max={max(gaps) * 1000:.1f}"
        )
    return lines


def frame_series(fps: float, sizes: list[int], gaps: list[float], wheel_latency: float | None) -> list:
    """The result-v1 series of one window (gaps and wheel latency in seconds); write_series skips empty ones."""
    return [
        perf_import.Series("tui_browser_frames.fps", "fps", "higher", [fps]),
        perf_import.Series("tui_browser_frames.frame_bytes", "bytes", "lower", list(sizes)),
        perf_import.Series("tui_browser_frames.inter_frame_gap", "ms", "lower", [g * 1000 for g in gaps]),
        perf_import.Series(
            "tui_browser_frames.wheel_to_next_frame", "ms", "lower",
            [] if wheel_latency is None else [wheel_latency * 1000],
        ),
    ]


def parse(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--socket", help="mux unix socket path (default: the user's daemon, or with --app the "
                                         "launched app's daemon)")
    parser.add_argument("--surface", type=int, help="existing browser surface id")
    parser.add_argument("--url", help="create and measure a temporary browser surface at this URL")
    parser.add_argument("--seconds", type=float, default=10.0, help="measurement window")
    parser.add_argument("--app", help="a tagged app bundle to launch (bench_launch.BenchApp) and measure on its "
                                      "own daemon; it names the build of the results")
    parser.add_argument("--tag", help="the lab story runner passes it; the bundle carries the tag")
    parser.add_argument("--session", choices=[SESSION], help="the lab story runner passes it; only light")
    parser.add_argument("--build-config", choices=["bench", "bench-checks", "release"],
                        help="result-v1 build config of a bench-hooks bundle that does not stamp it")
    parser.add_argument("--out", help="with --app: the folder for the app log and cmux-perf-result/v1")
    args = parser.parse_args(argv)

    if (args.surface is None) == (args.url is None):
        parser.error("provide exactly one of --surface or --url")
    if args.seconds <= 0:
        parser.error("--seconds must be > 0")
    if args.out and not args.app:
        parser.error("--out needs --app: a result names the build it measured")
    if args.app and (args.socket is not None or args.surface is not None):
        parser.error("--app launches a new app: measure a new --url there, with no --socket or --surface")
    return args


def main(argv: list[str] | None = None) -> int:
    args = parse(argv)
    if not args.app:
        args.socket = args.socket or default_socket()
        return measure(args, [])
    launch = perf_import.bench_launch()
    tagged = perf_import.load_by_path("bench_tagged", os.path.join(perf_import.ROOT, "scripts", "cmux-next",
                                                                   "bench_tagged.py"))
    bench = launch.BenchApp(args.app, out=args.out, window=None, perf_session=SESSION,
                            build_config=args.build_config)
    series: list = []
    try:
        bench.launch()
        args.socket = tagged.daemon_socket(bench.tag)
        status = measure(args, series)
        if args.out:
            for item in series:
                if item.samples:
                    bench.record(STORY, item.metric, item.unit, item.samples, better=item.better, engine=ENGINE)
            print(f"wrote result-v1 into {args.out} ({sum(1 for item in series if item.samples)} series)")
        return status
    finally:
        bench.stop()


def measure(args: argparse.Namespace, series: list) -> int:
    """One measurement window on args.socket; prints the report and appends the result-v1 series."""
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
        send_browser_attach_handshake(attach, surface)
        got_state = False
        got_response = False
        initial_seq = None
        pointer_frame_seq = None
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
                pointer_frame_seq = pointer_frame_seq_from_event(value)
                frame = value.get("frame")
                if frame:
                    initial_seq = frame.get("seq")
            elif value.get("event") == "frame":
                initial_seq = value.get("seq")
                pointer_frame_seq = pointer_frame_seq_from_event(value)
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
        activation_sent_at = None
        wheel_sent_at = None
        wheel_after_seq = initial_seq
        wheel_latency = None
        dims = (None, None)

        while time.monotonic() < end:
            now = time.monotonic()
            # Poke repeatedly until frames flow: the first interaction is what
            # un-throttles a hidden external-Chrome tab via the stall nudge.
            last_poke_at = activation_sent_at if pointer_frame_seq is None else wheel_sent_at
            need_poke = last_poke_at is None or (
                not frame_times and now - last_poke_at >= 2.0
            )
            if need_poke and now - start >= min(args.seconds / 2.0, 2.0):
                try:
                    rpc.request(recovery_poke(surface, pointer_frame_seq))
                except RuntimeError:
                    pass  # still starting; retry on the next poke cycle
                if pointer_frame_seq is None:
                    activation_sent_at = time.monotonic()
                else:
                    wheel_sent_at = time.monotonic()
                    wheel_after_seq = last_seq
            line = reader.readline()
            if line is None:
                continue
            if not line:
                break
            value = json.loads(line)
            if value.get("event") == "browser-state":
                pointer_frame_seq = pointer_frame_seq_from_event(value)
                continue
            if value.get("event") != "frame":
                continue
            received = time.monotonic()
            seq = value.get("seq")
            last_seq = seq
            pointer_frame_seq = pointer_frame_seq_from_event(value)
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
        for line in frame_report_lines(sizes, gaps):
            print(line)
        if wheel_sent_at is not None:
            if wheel_latency is None:
                print("wheel_to_next_frame_ms: none")
            else:
                print(f"wheel_to_next_frame_ms: {wheel_latency * 1000:.1f}")

        if frame_times:
            series.extend(frame_series(fps, sizes, gaps, wheel_latency))
        else:
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
