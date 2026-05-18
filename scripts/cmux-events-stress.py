#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import pathlib
import re
import socket
import subprocess
import sys
import tempfile
import threading
import time
from typing import Any


EVENT_NAME = "app.focus_override.changed"
EVENT_LOG_CAP_BYTES = 16 * 1024 * 1024
UNIX_SOCKET_PATH_MAX_BYTES = 103


class StressFailure(RuntimeError):
    pass


class TransientReadFailure(StressFailure):
    pass


def sanitize_path(raw: str) -> str:
    cleaned = re.sub(r"[^a-z0-9]+", "-", raw.lower()).strip("-")
    cleaned = re.sub(r"-+", "-", cleaned)
    return cleaned or "agent"


def now_ms() -> float:
    return time.perf_counter() * 1000.0


def rounded_ms(value: float) -> float:
    return round(value, 2)


def redacted_frame_message(label: str, line: str) -> str:
    byte_count = len(line.encode("utf-8", errors="replace"))
    return f"{label}: <redacted frame length={byte_count} bytes>"


def summarize_frame(frame: dict[str, Any]) -> dict[str, Any]:
    summary = {
        key: frame[key]
        for key in ("id", "type", "name", "seq", "ok", "replay_count")
        if key in frame
    }
    resume = frame.get("resume")
    if isinstance(resume, dict):
        summary["resume"] = {
            key: resume[key]
            for key in ("gap", "gap_reason", "requested_after_seq", "first_available_seq", "last_seq")
            if key in resume
        }
    result = frame.get("result")
    if isinstance(result, dict):
        summary["result_keys"] = sorted(str(key) for key in result)
    elif result is not None:
        summary["result_type"] = type(result).__name__
    if "error" in frame:
        summary["error_present"] = True
        summary["error_type"] = type(frame["error"]).__name__
    return summary


def load_json_line(line: str) -> dict[str, Any]:
    try:
        value = json.loads(line)
    except json.JSONDecodeError as exc:
        raise StressFailure(redacted_frame_message("invalid JSON frame", line)) from exc
    if not isinstance(value, dict):
        raise StressFailure(redacted_frame_message(f"expected JSON object frame, got {type(value).__name__}", line))
    return value


class SocketClient:
    def __init__(self, socket_path: pathlib.Path, timeout: float = 30.0):
        self.socket_path = socket_path
        self.timeout = timeout
        self.sock: socket.socket | None = None
        self.reader = None

    def __enter__(self) -> "SocketClient":
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(self.timeout)
        self.sock.connect(str(self.socket_path))
        self.reader = self.sock.makefile("r", encoding="utf-8", newline="\n")
        return self

    def __exit__(self, exc_type: object, exc: object, tb: object) -> None:
        if self.reader is not None:
            try:
                self.reader.close()
            except Exception:
                pass
            self.reader = None
        if self.sock is not None:
            try:
                self.sock.close()
            except Exception:
                pass
            self.sock = None

    def write_request(self, request: dict[str, Any]) -> None:
        if self.sock is None:
            raise StressFailure("socket is not connected")
        line = json.dumps(request, separators=(",", ":"), sort_keys=True) + "\n"
        self.sock.sendall(line.encode("utf-8"))

    def read_frame(self) -> dict[str, Any]:
        if self.reader is None:
            raise StressFailure("socket reader is not connected")
        try:
            line = self.reader.readline()
        except socket.timeout as exc:
            raise TransientReadFailure(f"timed out reading from {self.socket_path}: {exc}") from exc
        except OSError as exc:
            raise StressFailure(f"failed reading from {self.socket_path}: {exc}") from exc
        if not line:
            raise StressFailure(f"socket closed while reading from {self.socket_path}")
        return load_json_line(line)

    def rpc(self, method: str, params: dict[str, Any] | None = None, request_id: str | int = 1) -> dict[str, Any]:
        self.write_request({"id": request_id, "method": method, "params": params or {}})
        frame = self.read_frame()
        if frame.get("ok") is not True:
            raise StressFailure(f"{method} failed: {summarize_frame(frame)}")
        return frame


class ConsumerStats:
    def __init__(self, consumer_id: int):
        self.consumer_id = consumer_id
        self.events = 0
        self.line_count = 0
        self.reconnects = 0
        self.last_seq: int | None = None
        self.gaps: list[dict[str, Any]] = []
        self.errors: list[str] = []
        self.duration_ms = 0.0

    def as_json(self) -> dict[str, Any]:
        return {
            "id": self.consumer_id,
            "events": self.events,
            "line_count": self.line_count,
            "reconnects": self.reconnects,
            "last_seq": self.last_seq,
            "gaps": self.gaps,
            "errors": self.errors,
            "duration_ms": rounded_ms(self.duration_ms),
        }


class CmuxEventsStress:
    def __init__(self, args: argparse.Namespace):
        self.args = args
        self.repo_root = pathlib.Path(__file__).resolve().parents[1]
        self.tag = args.tag
        self.tag_slug = sanitize_path(args.tag)
        self.socket_path = pathlib.Path(f"/tmp/cmux-debug-{self.tag_slug}.sock")
        self.cmuxd_socket_path = pathlib.Path(
            os.path.expanduser(f"~/Library/Application Support/cmux/cmuxd-dev-{self.tag_slug}.sock")
        )
        self.debug_log_path = pathlib.Path(f"/tmp/cmux-debug-{self.tag_slug}.log")
        self.stdout_path = pathlib.Path(f"/tmp/cmux-events-stress-{self.tag_slug}-stdout.log")
        self.temp_root = pathlib.Path(args.temp_root).expanduser() if args.temp_root else pathlib.Path(
            tempfile.mkdtemp(prefix=f"cmux-events-stress-{self.tag_slug}-")
        )
        self.event_log_path = self.temp_root / "events.jsonl"
        self.app_path = pathlib.Path(args.app_path).expanduser() if args.app_path else self.default_app_path()
        self.binary_path = self.app_path / "Contents/MacOS/cmux DEV"
        self.proc: subprocess.Popen[bytes] | None = None
        self.publisher_error: str | None = None
        self.publisher_done = threading.Event()
        self.stop_sampling = threading.Event()
        self.rss_peak_kb = 0
        self.rss_end_kb = 0
        self.rss_samples: list[int] = []
        self.summary: dict[str, Any] = {
            "tag": self.tag,
            "socket_path": str(self.socket_path),
            "event_log_path": str(self.event_log_path),
            "event_name": EVENT_NAME,
            "event_count": args.events,
            "consumer_count": args.consumers,
            "consumer_segment_events": args.consumer_segment_events,
            "payload_bytes": args.payload_bytes,
        }

    def default_app_path(self) -> pathlib.Path:
        return pathlib.Path.home() / (
            f"Library/Developer/Xcode/DerivedData/cmux-{self.tag_slug}/"
            f"Build/Products/Debug/cmux DEV {self.tag_slug}.app"
        )

    def run(self) -> dict[str, Any]:
        start = now_ms()
        self.temp_root.mkdir(parents=True, exist_ok=True)
        if self.args.build:
            self.build_tagged_app()
        self.check_paths()
        self.clean_runtime_paths()

        try:
            self.launch_app()
            self.wait_for_socket()
            self.assert_ping("startup")

            sampler = threading.Thread(target=self.sample_rss_loop, name="rss-sampler", daemon=True)
            sampler.start()

            consumers = [ConsumerStats(index) for index in range(self.args.consumers)]
            ready = threading.Barrier(self.args.consumers + 1)
            threads = [
                threading.Thread(
                    target=self.consumer_loop,
                    args=(stats, ready),
                    name=f"events-consumer-{stats.consumer_id}",
                    daemon=True,
                )
                for stats in consumers
            ]
            for thread in threads:
                thread.start()

            try:
                ready.wait(timeout=self.args.consumer_ready_timeout)
            except threading.BrokenBarrierError as exc:
                raise StressFailure("not all event consumers subscribed before the flood") from exc

            publish_start = now_ms()
            publisher = threading.Thread(target=self.publish_events, name="events-publisher", daemon=True)
            publisher.start()
            publisher.join(timeout=self.args.publish_timeout)
            if publisher.is_alive():
                raise StressFailure(f"publisher did not finish within {self.args.publish_timeout}s")
            if self.publisher_error:
                raise StressFailure(self.publisher_error)
            self.summary["publish_duration_ms"] = rounded_ms(now_ms() - publish_start)

            deadline = time.monotonic() + self.args.consumer_timeout
            for thread in threads:
                thread.join(timeout=max(0.0, deadline - time.monotonic()))
            alive = [thread.name for thread in threads if thread.is_alive()]
            if alive:
                raise StressFailure(f"event consumers did not exit cleanly: {alive}")

            failed_consumers = [stats.as_json() for stats in consumers if stats.errors or stats.events < self.args.events]
            if failed_consumers:
                raise StressFailure(f"event consumers missed events or failed: {failed_consumers}")

            self.assert_ping("post_flood")
            gap_probe = self.probe_resume_gap()
            log_sizes = self.wait_for_log_sizes()
            self.assert_log_caps(log_sizes)

            self.stop_sampling.set()
            sampler.join(timeout=3)
            self.rss_end_kb = self.sample_rss_once()

            self.summary.update(
                {
                    "ok": True,
                    "duration_ms": rounded_ms(now_ms() - start),
                    "consumers": [stats.as_json() for stats in consumers],
                    "resume_gap": gap_probe,
                    "rss": {
                        "peak_kb": self.rss_peak_kb,
                        "end_kb": self.rss_end_kb,
                        "samples": len(self.rss_samples),
                    },
                    "event_log": log_sizes,
                }
            )
            return self.summary
        finally:
            self.stop_sampling.set()
            if not self.args.keep_running:
                self.stop_app()

    def build_tagged_app(self) -> None:
        command = [str(self.repo_root / "scripts/reload.sh"), "--tag", self.tag]
        proc = subprocess.run(
            command,
            cwd=self.repo_root,
            text=True,
            capture_output=True,
            timeout=self.args.build_timeout,
        )
        sys.stdout.write(proc.stdout)
        sys.stderr.write(proc.stderr)
        if proc.returncode != 0:
            raise StressFailure(f"reload.sh failed with exit {proc.returncode}")

        app_path = self.parse_reload_app_path(proc.stdout)
        if app_path is not None:
            self.app_path = app_path
            self.binary_path = self.app_path / "Contents/MacOS/cmux DEV"

    def parse_reload_app_path(self, output: str) -> pathlib.Path | None:
        lines = output.splitlines()
        for index, line in enumerate(lines):
            if line.strip() == "App path:" and index + 1 < len(lines):
                raw_candidate = lines[index + 1].strip()
                if raw_candidate:
                    return pathlib.Path(raw_candidate).expanduser()
        return None

    def check_paths(self) -> None:
        if self.socket_path.name in {"cmux.sock", "cmux-debug.sock"}:
            raise StressFailure(f"refusing to use non-tagged socket path: {self.socket_path}")
        for label, path in (
            ("CMUX_SOCKET_PATH", self.socket_path),
            ("CMUXD_UNIX_PATH", self.cmuxd_socket_path),
        ):
            path_text = path.as_posix()
            path_bytes = len(path_text.encode("utf-8"))
            if path_bytes > UNIX_SOCKET_PATH_MAX_BYTES:
                raise StressFailure(
                    f"{label} socket path too long: {path_text!r} is {path_bytes} bytes, "
                    f"limit is {UNIX_SOCKET_PATH_MAX_BYTES}"
                )
        if not self.binary_path.exists():
            raise StressFailure(f"tagged cmux app binary not found: {self.binary_path}")

    def clean_runtime_paths(self) -> None:
        self.socket_path.unlink(missing_ok=True)
        self.cmuxd_socket_path.unlink(missing_ok=True)
        self.debug_log_path.unlink(missing_ok=True)
        self.stdout_path.unlink(missing_ok=True)
        self.event_log_path.unlink(missing_ok=True)
        self.event_log_path.with_suffix(self.event_log_path.suffix + ".1").unlink(missing_ok=True)

    def app_env(self) -> dict[str, str]:
        env = os.environ.copy()
        for key in (
            "CMUX_SOCKET_PATH",
            "CMUX_SOCKET",
            "CMUX_SOCKET_MODE",
            "CMUX_TAB_ID",
            "CMUX_PANEL_ID",
            "CMUX_SURFACE_ID",
            "CMUX_WORKSPACE_ID",
            "CMUXD_UNIX_PATH",
            "CMUX_TAG",
            "CMUX_DEBUG_LOG",
            "CMUX_BUNDLE_ID",
            "CMUX_EVENT_LOG_PATH",
            "CMUX_DISABLE_SESSION_RESTORE",
            "GHOSTTY_BIN_DIR",
            "GHOSTTY_RESOURCES_DIR",
            "GHOSTTY_SHELL_FEATURES",
        ):
            env.pop(key, None)
        env.update(
            {
                "CMUX_TAG": self.tag_slug,
                "CMUX_SOCKET_ENABLE": "1",
                "CMUX_SOCKET_MODE": "automation",
                "CMUX_SOCKET_PATH": str(self.socket_path),
                "CMUX_SOCKET": str(self.socket_path),
                "CMUXD_UNIX_PATH": str(self.cmuxd_socket_path),
                "CMUX_DEBUG_LOG": str(self.debug_log_path),
                "CMUX_EVENT_LOG_PATH": str(self.event_log_path),
                "CMUX_DISABLE_SESSION_RESTORE": "1",
                "CMUX_UI_TEST_MODE": "1",
                "CMUXTERM_REPO_ROOT": str(self.repo_root),
            }
        )
        return env

    def launch_app(self) -> None:
        self.stop_app(kill_only=True)
        self.clean_runtime_paths()
        with open(self.stdout_path, "ab", buffering=0) as stdout:
            self.proc = subprocess.Popen(
                [str(self.binary_path)],
                cwd=self.repo_root,
                env=self.app_env(),
                stdout=stdout,
                stderr=subprocess.STDOUT,
                start_new_session=True,
            )
        self.summary["app_pid"] = self.proc.pid
        self.summary["app_path"] = str(self.app_path)

    def wait_for_socket(self) -> None:
        deadline = time.monotonic() + self.args.launch_timeout
        last_error: Exception | None = None
        while time.monotonic() < deadline:
            if self.proc and self.proc.poll() is not None:
                raise StressFailure(f"cmux exited before socket was ready; see {self.stdout_path}")
            if self.socket_path.exists():
                try:
                    self.assert_ping("socket_ready")
                    return
                except Exception as exc:
                    last_error = exc
            time.sleep(0.1)
        raise StressFailure(f"socket not ready at {self.socket_path}: {last_error}")

    def assert_ping(self, label: str) -> None:
        with SocketClient(self.socket_path, timeout=10) as client:
            result = client.rpc("system.ping", request_id=f"ping-{label}")
        if result.get("result", {}).get("pong") is not True:
            raise StressFailure(f"{label}: ping did not return pong: {summarize_frame(result)}")

    def consumer_loop(self, stats: ConsumerStats, ready: threading.Barrier) -> None:
        started = now_ms()
        first_connection = True
        try:
            while stats.events < self.args.events:
                with SocketClient(self.socket_path, timeout=self.args.consumer_read_timeout) as client:
                    params: dict[str, Any] = {
                        "names": [EVENT_NAME],
                        "include_heartbeats": False,
                    }
                    if stats.last_seq is not None:
                        params["after_seq"] = stats.last_seq
                    client.write_request(
                        {
                            "id": f"consumer-{stats.consumer_id}-{stats.reconnects}",
                            "method": "events.stream",
                            "params": params,
                        }
                    )
                    ack = client.read_frame()
                    stats.line_count += 1
                    if ack.get("type") != "ack":
                        raise StressFailure(
                            f"consumer {stats.consumer_id} expected ack, got {summarize_frame(ack)}"
                        )
                    resume = ack.get("resume") if isinstance(ack.get("resume"), dict) else {}
                    if resume.get("gap"):
                        stats.gaps.append(resume)
                    if first_connection:
                        first_connection = False
                        ready.wait(timeout=self.args.consumer_ready_timeout)

                    segment_events = 0
                    while stats.events < self.args.events and segment_events < self.args.consumer_segment_events:
                        try:
                            frame = client.read_frame()
                        except TransientReadFailure:
                            if self.publisher_done.is_set():
                                raise
                            break
                        stats.line_count += 1
                        frame_type = frame.get("type")
                        if frame_type == "event":
                            if frame.get("name") != EVENT_NAME:
                                continue
                            seq = frame.get("seq")
                            if not isinstance(seq, int):
                                raise StressFailure(
                                    f"consumer {stats.consumer_id} saw event without numeric seq: "
                                    f"{summarize_frame(frame)}"
                                )
                            if stats.last_seq is not None and seq <= stats.last_seq:
                                raise StressFailure(
                                    f"consumer {stats.consumer_id} sequence did not advance: {seq} after {stats.last_seq}"
                                )
                            stats.last_seq = seq
                            stats.events += 1
                            segment_events += 1
                        elif frame_type == "error":
                            raise StressFailure(
                                f"consumer {stats.consumer_id} stream error: {summarize_frame(frame)}"
                            )
                    stats.reconnects += 1
        except Exception as exc:
            stats.errors.append(str(exc))
            try:
                ready.abort()
            except Exception:
                pass
        finally:
            stats.duration_ms = now_ms() - started

    def publish_events(self) -> None:
        padding = "x" * self.args.payload_bytes
        started = now_ms()
        try:
            with SocketClient(self.socket_path, timeout=self.args.publisher_read_timeout) as client:
                for index in range(self.args.events):
                    state = "active" if index % 2 == 0 else "inactive"
                    client.rpc(
                        "app.focus_override.set",
                        {
                            "state": state,
                            "stress_index": index,
                            "stress_total": self.args.events,
                            "padding": padding,
                        },
                        request_id=f"publish-{index}",
                    )
                    if self.args.progress_interval and (index + 1) % self.args.progress_interval == 0:
                        elapsed = max(0.001, (now_ms() - started) / 1000.0)
                        rate = (index + 1) / elapsed
                        print(f"published {index + 1}/{self.args.events} events ({rate:.0f}/s)")
        except Exception as exc:
            self.publisher_error = str(exc)
        finally:
            self.publisher_done.set()

    def probe_resume_gap(self) -> dict[str, Any]:
        with SocketClient(self.socket_path, timeout=30) as client:
            client.write_request(
                {
                    "id": "gap-probe",
                    "method": "events.stream",
                    "params": {
                        "after_seq": 0,
                        "names": [EVENT_NAME],
                        "include_heartbeats": False,
                    },
                }
            )
            ack = client.read_frame()
            if ack.get("type") != "ack":
                raise StressFailure(f"gap probe expected ack, got {summarize_frame(ack)}")
            resume = ack.get("resume") if isinstance(ack.get("resume"), dict) else {}
            replay_count = int(ack.get("replay_count") or 0)
            first_seq: int | None = None
            last_seq: int | None = None
            for _ in range(replay_count):
                frame = client.read_frame()
                if frame.get("type") != "event":
                    raise StressFailure(f"gap probe expected replay event, got {summarize_frame(frame)}")
                seq = frame.get("seq")
                if isinstance(seq, int):
                    first_seq = seq if first_seq is None else first_seq
                    last_seq = seq
        if resume.get("gap") is not True:
            raise StressFailure(
                "expected retention gap for after_seq=0 after flood, "
                f"got resume={summarize_frame({'resume': resume})}"
            )
        return {
            "ack": {
                "replay_count": replay_count,
                "resume": resume,
            },
            "replay_first_seq": first_seq,
            "replay_last_seq": last_seq,
        }

    def wait_for_log_sizes(self) -> dict[str, Any]:
        rotated_path = self.event_log_path.with_suffix(self.event_log_path.suffix + ".1")
        deadline = time.monotonic() + self.args.log_settle_timeout
        stable_samples = 0
        previous: tuple[int, int] | None = None
        current = 0
        rotated = 0
        while time.monotonic() < deadline:
            current = self.file_size(self.event_log_path)
            rotated = self.file_size(rotated_path)
            sizes = (current, rotated)
            if current > 0 and rotated > 0 and sizes == previous:
                stable_samples += 1
                if stable_samples >= 4:
                    break
            else:
                stable_samples = 0
            previous = sizes
            time.sleep(0.25)
        return {
            "current_path": str(self.event_log_path),
            "rotated_path": str(rotated_path),
            "current_bytes": current,
            "rotated_bytes": rotated,
            "total_bytes": current + rotated,
            "cap_bytes": EVENT_LOG_CAP_BYTES,
        }

    def assert_log_caps(self, sizes: dict[str, Any]) -> None:
        current = int(sizes["current_bytes"])
        rotated = int(sizes["rotated_bytes"])
        if current <= 0:
            raise StressFailure(f"event log was not written: {sizes}")
        if rotated <= 0:
            raise StressFailure(f"event log did not rotate: {sizes}")
        if current > EVENT_LOG_CAP_BYTES or rotated > EVENT_LOG_CAP_BYTES:
            raise StressFailure(f"event log exceeded cap: {sizes}")

    def file_size(self, path: pathlib.Path) -> int:
        try:
            return path.stat().st_size
        except FileNotFoundError:
            return 0

    def sample_rss_loop(self) -> None:
        while not self.stop_sampling.wait(0.2):
            value = self.sample_rss_once()
            if value > 0:
                self.rss_samples.append(value)
                self.rss_peak_kb = max(self.rss_peak_kb, value)

    def sample_rss_once(self) -> int:
        proc = self.proc
        if not proc:
            return 0
        pid = proc.pid
        if proc.poll() is not None:
            return 0
        ps = subprocess.run(
            ["ps", "-o", "rss=", "-p", str(pid)],
            text=True,
            capture_output=True,
            check=False,
        )
        try:
            return int(ps.stdout.strip() or "0")
        except ValueError:
            return 0

    def stop_app(self, kill_only: bool = False) -> None:
        proc = self.proc
        if not kill_only:
            self.proc = None
        if proc and proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=5)
        subprocess.run(
            ["pkill", "-f", re.escape(f"{self.app_path}/Contents/MacOS/cmux DEV")],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        self.socket_path.unlink(missing_ok=True)
        self.cmuxd_socket_path.unlink(missing_ok=True)


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Stress cmux events.stream and durable event logging.")
    parser.add_argument("--tag", default="events-stress", help="Tagged debug app slug to build and launch.")
    parser.add_argument("--build", action="store_true", help="Build the tagged debug app with scripts/reload.sh first.")
    parser.add_argument("--app-path", default="", help="Path to an existing tagged .app.")
    parser.add_argument("--events", type=int, default=40_000, help="Number of events to publish.")
    parser.add_argument("--consumers", type=int, default=6, help="Number of reconnecting stream consumers.")
    parser.add_argument("--consumer-segment-events", type=int, default=512, help="Events read before each consumer reconnect.")
    parser.add_argument("--payload-bytes", type=int, default=768, help="Padding bytes per event payload.")
    parser.add_argument("--output", default="", help="Write JSON summary to this path.")
    parser.add_argument("--temp-root", default="", help="Directory for isolated event log files.")
    parser.add_argument("--keep-running", action="store_true", help="Leave the tagged app running after the stress run.")
    parser.add_argument("--launch-timeout", type=float, default=60)
    parser.add_argument("--build-timeout", type=float, default=900)
    parser.add_argument("--publish-timeout", type=float, default=600)
    parser.add_argument("--consumer-timeout", type=float, default=90)
    parser.add_argument("--consumer-ready-timeout", type=float, default=30)
    parser.add_argument("--consumer-read-timeout", type=float, default=45)
    parser.add_argument("--publisher-read-timeout", type=float, default=20)
    parser.add_argument("--log-settle-timeout", type=float, default=30)
    parser.add_argument("--progress-interval", type=int, default=5_000)
    return parser.parse_args(argv)


def validate_args(args: argparse.Namespace) -> None:
    if args.events <= 4_096:
        raise StressFailure("--events must be greater than 4096 to exercise retention gap handling")
    if args.payload_bytes < 0:
        raise StressFailure("--payload-bytes must be non-negative")
    if args.events * args.payload_bytes <= EVENT_LOG_CAP_BYTES:
        raise StressFailure(
            f"--events * --payload-bytes must exceed {EVENT_LOG_CAP_BYTES} to exercise event log rotation"
        )
    if args.consumers <= 0:
        raise StressFailure("--consumers must be greater than 0")
    if args.consumer_segment_events <= 0:
        raise StressFailure("--consumer-segment-events must be greater than 0")


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    runner = CmuxEventsStress(args)
    try:
        validate_args(args)
        summary = runner.run()
    except Exception as exc:
        summary = dict(runner.summary)
        summary["ok"] = False
        summary["error"] = str(exc)
        if args.output:
            output_path = pathlib.Path(args.output)
            output_path.parent.mkdir(parents=True, exist_ok=True)
            output_path.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        print(json.dumps(summary, indent=2, sort_keys=True))
        return 1

    if args.output:
        output_path = pathlib.Path(args.output)
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
