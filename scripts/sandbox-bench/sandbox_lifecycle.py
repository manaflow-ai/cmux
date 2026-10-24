#!/usr/bin/env python3
"""Snapshot, fork, and suspend orchestration for sandbox backends.

This module is intentionally an adapter, rather than a benchmark with guessed
latencies.  Every lifecycle result contains monotonic and UTC timestamps for
the requests that actually ran.  Missing KVM, an absent image, an unsupported
operation, a failed command, and a readiness timeout are different statuses.

The Firecracker adapter speaks its Unix-socket HTTP API.  The gVisor adapter
invokes ``runsc`` with argv (never a shell), and exposes checkpoint/restore,
pause/resume, and checkpoint-then-restore fork.  Both adapters accept injected
request/runner functions so callers can test orchestration without pretending
to have started a guest.
"""

from __future__ import annotations

import argparse
import http.client
import json
import os
import signal
import socket
import subprocess
import sys
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Iterable, Mapping, Sequence


SCHEMA = 1
STATUS_COMPLETED = "completed"
STATUS_BLOCKED = "blocked"
STATUS_UNSUPPORTED = "unsupported"
STATUS_FAILED = "failed"
STATUS_TIMEOUT = "timeout"


def monotonic_ns() -> int:
    return time.monotonic_ns()


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds")


@dataclass
class LifecycleEvent:
    name: str
    monotonic_ns: int
    utc: str
    details: dict[str, Any] = field(default_factory=dict)

    def to_dict(self) -> dict[str, Any]:
        return {
            "name": self.name,
            "monotonic_ns": self.monotonic_ns,
            "utc": self.utc,
            "details": self.details,
        }


@dataclass
class LifecycleResult:
    backend: str
    operation: str
    status: str
    events: list[LifecycleEvent] = field(default_factory=list)
    error: str | None = None
    metadata: dict[str, Any] = field(default_factory=dict)

    def to_dict(self) -> dict[str, Any]:
        return {
            "schema": SCHEMA,
            "backend": self.backend,
            "operation": self.operation,
            "status": self.status,
            "error": self.error,
            "metadata": self.metadata,
            "events": [event.to_dict() for event in self.events],
        }


class _Recorder:
    def __init__(self, backend: str, operation: str):
        self.backend = backend
        self.operation = operation
        self.events: list[LifecycleEvent] = []

    def emit(self, name: str, **details: Any) -> None:
        self.events.append(
            LifecycleEvent(name, monotonic_ns(), utc_now(), details)
        )

    def result(
        self,
        status: str,
        error: str | None = None,
        **metadata: Any,
    ) -> LifecycleResult:
        self.emit("operation_finished", status=status, error=error)
        return LifecycleResult(
            backend=self.backend,
            operation=self.operation,
            status=status,
            events=self.events,
            error=error,
            metadata=metadata,
        )


def _unsupported(backend: str, operation: str, reason: str) -> LifecycleResult:
    recorder = _Recorder(backend, operation)
    recorder.emit("operation_started")
    recorder.emit("operation_blocked", reason=reason)
    return recorder.result(STATUS_UNSUPPORTED, reason)


def _blocked(backend: str, operation: str, reason: str) -> LifecycleResult:
    recorder = _Recorder(backend, operation)
    recorder.emit("operation_started")
    recorder.emit("operation_blocked", reason=reason)
    return recorder.result(STATUS_BLOCKED, reason)


def wait_ready(
    probe: Callable[[], bool],
    timeout_s: float,
    interval_s: float = 0.01,
    recorder: _Recorder | None = None,
) -> bool:
    """Wait for a caller-owned readiness probe without claiming readiness.

    The probe is deliberately a function so a caller can use a serial sentinel,
    vsock handshake, HTTP health check, or an acpmux session check.  The module
    never treats process creation as guest readiness.
    """

    deadline = time.monotonic() + timeout_s
    if recorder:
        recorder.emit("guest_ready_wait_started", timeout_s=timeout_s)
    while True:
        try:
            if probe():
                if recorder:
                    recorder.emit("guest_ready", source="caller_probe")
                return True
        except Exception as exc:  # noqa: BLE001 - probe belongs to caller
            if recorder:
                recorder.emit("guest_ready_probe_error", error=str(exc))
            return False
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            if recorder:
                recorder.emit("guest_ready_timeout", timeout_s=timeout_s)
            return False
        time.sleep(min(interval_s, remaining))


class _UnixHTTPConnection(http.client.HTTPConnection):
    """HTTPConnection transport for Firecracker's Unix-domain API socket."""

    def __init__(self, socket_path: str, timeout: float):
        super().__init__("localhost", timeout=timeout)
        self.socket_path = socket_path

    def connect(self) -> None:  # noqa: D401 - required HTTPConnection hook
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(self.timeout)
        self.sock.connect(self.socket_path)


RequestFn = Callable[[str, str, Mapping[str, Any] | None], tuple[int, Any]]
ForkLauncher = Callable[[str, str | None], "FirecrackerLifecycle | None"]
CleanupFn = Callable[[], None]


class FirecrackerLifecycle:
    """Firecracker API lifecycle adapter.

    ``fork_launcher`` is required for fork.  Firecracker snapshots are loaded
    by a new process/socket; there is no safe universal way for this module to
    choose a kernel, rootfs, vCPU count, or socket owner.  A missing launcher
    therefore returns ``unsupported`` instead of faking a clone.
    """

    backend = "firecracker"

    def __init__(
        self,
        socket_path: str,
        *,
        timeout_s: float = 30.0,
        request_fn: RequestFn | None = None,
        fork_launcher: ForkLauncher | None = None,
        cleanup_fn: CleanupFn | None = None,
        ready_probe: Callable[[], bool] | None = None,
    ):
        self.socket_path = socket_path
        self.timeout_s = timeout_s
        self.request_fn = request_fn
        self.fork_launcher = fork_launcher
        self.cleanup_fn = cleanup_fn
        self.ready_probe = ready_probe

    def _request(
        self, method: str, path: str, payload: Mapping[str, Any] | None
    ) -> tuple[int, Any]:
        if self.request_fn:
            return self.request_fn(method, path, payload)
        body = json.dumps(payload).encode() if payload is not None else b""
        connection = _UnixHTTPConnection(self.socket_path, self.timeout_s)
        try:
            headers = {"Content-Type": "application/json"}
            connection.request(method, path, body=body or None, headers=headers)
            response = connection.getresponse()
            raw = response.read()
            if not raw:
                decoded: Any = None
            else:
                try:
                    decoded = json.loads(raw)
                except json.JSONDecodeError:
                    decoded = raw.decode(errors="replace")
            return response.status, decoded
        finally:
            connection.close()

    def _call(
        self,
        recorder: _Recorder,
        method: str,
        path: str,
        payload: Mapping[str, Any] | None,
    ) -> tuple[bool, Any]:
        recorder.emit("api_request_started", method=method, path=path)
        try:
            status, response = self._request(method, path, payload)
        except (OSError, socket.timeout, TimeoutError, http.client.HTTPException) as exc:
            recorder.emit("api_request_failed", method=method, path=path, error=str(exc))
            return False, str(exc)
        recorder.emit(
            "api_request_finished",
            method=method,
            path=path,
            http_status=status,
        )
        if status < 200 or status >= 300:
            return False, {"http_status": status, "response": response}
        return True, response

    def _kvm_available(self, recorder: _Recorder) -> bool:
        # An injected request function is a test or remote transport and owns
        # its capability checks. The local Unix-socket transport must not turn
        # a missing KVM device into a misleading socket timing.
        if self.request_fn is None and (
            not Path("/dev/kvm").exists()
            or not os.access("/dev/kvm", os.R_OK | os.W_OK)
        ):
            recorder.emit("capability_blocked", capability="/dev/kvm")
            return False
        return True

    def _action(self, operation: str, action: str) -> LifecycleResult:
        recorder = _Recorder(self.backend, operation)
        recorder.emit("operation_started", action=action, socket=self.socket_path)
        if not self._kvm_available(recorder):
            return recorder.result(STATUS_BLOCKED, "/dev/kvm is absent")
        ok, response = self._call(
            recorder,
            "PUT",
            "/actions",
            {"action_type": action},
        )
        if not ok:
            return recorder.result(STATUS_FAILED, f"Firecracker {action} failed", response=response)
        return recorder.result(STATUS_COMPLETED, response=response)

    def suspend(self) -> LifecycleResult:
        return self._action("suspend", "Pause")

    def resume(self) -> LifecycleResult:
        return self._action("resume", "Resume")

    def cleanup(self) -> LifecycleResult:
        """Run caller-owned runtime cleanup, if one was supplied.

        Firecracker does not expose a portable "destroy this process" API.
        The launcher that owns the VM process must provide this callback so we
        never kill a process we did not create.
        """

        if not self.cleanup_fn:
            return _unsupported(
                self.backend,
                "cleanup",
                "Firecracker cleanup requires a caller-owned process cleanup callback",
            )
        recorder = _Recorder(self.backend, "cleanup")
        recorder.emit("operation_started", socket=self.socket_path)
        try:
            self.cleanup_fn()
        except Exception as exc:  # noqa: BLE001 - callback belongs to caller
            return recorder.result(STATUS_FAILED, f"Firecracker cleanup failed: {exc}")
        return recorder.result(STATUS_COMPLETED)

    def snapshot(
        self,
        snapshot_path: str,
        memory_path: str,
        *,
        pause_before: bool = True,
        resume_after: bool = False,
        snapshot_type: str = "Full",
    ) -> LifecycleResult:
        recorder = _Recorder(self.backend, "snapshot")
        recorder.emit(
            "operation_started",
            snapshot_path=snapshot_path,
            memory_path=memory_path,
            pause_before=pause_before,
            resume_after=resume_after,
        )
        if not self._kvm_available(recorder):
            return recorder.result(STATUS_BLOCKED, "/dev/kvm is absent")
        if pause_before:
            ok, response = self._call(
                recorder, "PUT", "/actions", {"action_type": "Pause"}
            )
            if not ok:
                return recorder.result(STATUS_FAILED, "Firecracker pause before snapshot failed", response=response)
        ok, response = self._call(
            recorder,
            "PUT",
            "/snapshot/create",
            {
                "snapshot_type": snapshot_type,
                "snapshot_path": snapshot_path,
                "mem_file_path": memory_path,
            },
        )
        if not ok:
            return recorder.result(STATUS_FAILED, "Firecracker snapshot failed", response=response)
        if resume_after:
            resume_ok, resume_response = self._call(
                recorder, "PUT", "/actions", {"action_type": "Resume"}
            )
            if not resume_ok:
                return recorder.result(STATUS_FAILED, "Firecracker resume after snapshot failed", response=resume_response)
        return recorder.result(
            STATUS_COMPLETED,
            snapshot_path=snapshot_path,
            memory_path=memory_path,
            snapshot_type=snapshot_type,
            response=response,
        )

    def restore(
        self,
        snapshot_path: str,
        memory_path: str,
        *,
        resume_vm: bool = False,
    ) -> LifecycleResult:
        recorder = _Recorder(self.backend, "restore")
        recorder.emit(
            "operation_started",
            snapshot_path=snapshot_path,
            memory_path=memory_path,
            resume_vm=resume_vm,
        )
        if not self._kvm_available(recorder):
            return recorder.result(STATUS_BLOCKED, "/dev/kvm is absent")
        ok, response = self._call(
            recorder,
            "PUT",
            "/snapshot/load",
            {
                "snapshot_path": snapshot_path,
                "mem_backend": {"backend_type": "File", "backend_path": memory_path},
                "resume_vm": resume_vm,
            },
        )
        if not ok:
            return recorder.result(STATUS_FAILED, "Firecracker restore failed", response=response)
        ready = None
        if resume_vm and self.ready_probe:
            ready = wait_ready(self.ready_probe, self.timeout_s, recorder=recorder)
            if not ready:
                return recorder.result(STATUS_TIMEOUT, "guest readiness probe timed out", guest_ready=False)
        elif resume_vm:
            recorder.emit("guest_ready_not_run", reason="no caller readiness probe")
        return recorder.result(
            STATUS_COMPLETED,
            snapshot_path=snapshot_path,
            memory_path=memory_path,
            resume_vm=resume_vm,
            guest_ready=ready,
            response=response,
        )

    def fork(
        self,
        snapshot_path: str,
        memory_path: str,
        *,
        ready_probe: Callable[[], bool] | None = None,
    ) -> LifecycleResult:
        if not self.fork_launcher:
            return _unsupported(
                self.backend,
                "fork",
                "Firecracker fork needs a caller-owned process/socket launcher",
            )
        recorder = _Recorder(self.backend, "fork")
        recorder.emit("operation_started", snapshot_path=snapshot_path, memory_path=memory_path)
        try:
            child = self.fork_launcher(snapshot_path, memory_path)
        except Exception as exc:  # noqa: BLE001 - launcher belongs to caller
            return recorder.result(STATUS_FAILED, f"fork launcher failed: {exc}")
        if child is None:
            return recorder.result(STATUS_BLOCKED, "fork launcher did not return a child adapter")
        child.ready_probe = ready_probe or self.ready_probe
        child_result = child.restore(snapshot_path, memory_path, resume_vm=True)
        recorder.emit("child_restore_finished", status=child_result.status)
        if child_result.status != STATUS_COMPLETED:
            return recorder.result(
                child_result.status,
                child_result.error,
                child=child_result.to_dict(),
            )
        return recorder.result(
            STATUS_COMPLETED,
            child=child_result.to_dict(),
            snapshot_path=snapshot_path,
            memory_path=memory_path,
        )


Runner = Callable[[Sequence[str], float], subprocess.CompletedProcess[str]]


class GVisorLifecycle:
    """runsc checkpoint/restore and pause/resume adapter."""

    backend = "gvisor"

    def __init__(
        self,
        runsc: str,
        *,
        root: str,
        container_id: str,
        timeout_s: float = 30.0,
        runsc_flags: Sequence[str] = ("--rootless", "--network=none", "--platform=systrap"),
        runner: Runner | None = None,
        ready_probe: Callable[[], bool] | None = None,
    ):
        self.runsc = runsc
        self.root = root
        self.container_id = container_id
        self.timeout_s = timeout_s
        self.runsc_flags = tuple(runsc_flags)
        self.runner = runner or self._subprocess_runner
        self.ready_probe = ready_probe

    def _argv(self, *args: str) -> list[str]:
        return [self.runsc, "--root", self.root, *self.runsc_flags, *args]

    def _subprocess_runner(
        self, argv: Sequence[str], timeout_s: float
    ) -> subprocess.CompletedProcess[str]:
        process = subprocess.Popen(
            list(argv),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            start_new_session=True,
        )
        try:
            stdout, stderr = process.communicate(timeout=timeout_s)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            stdout, stderr = process.communicate()
            raise TimeoutError(
                f"runsc command timed out after {timeout_s:.3f}s: {' '.join(argv)}"
            )
        return subprocess.CompletedProcess(argv, process.returncode, stdout, stderr)

    def _run(self, recorder: _Recorder, argv: Sequence[str]) -> tuple[bool, Any]:
        recorder.emit("command_started", argv=list(argv))
        try:
            completed = self.runner(argv, self.timeout_s)
        except TimeoutError as exc:
            recorder.emit("command_timeout", argv=list(argv), error=str(exc))
            return False, (STATUS_TIMEOUT, str(exc))
        except (OSError, subprocess.SubprocessError) as exc:
            recorder.emit("command_failed", argv=list(argv), error=str(exc))
            return False, (STATUS_FAILED, str(exc))
        recorder.emit(
            "command_finished",
            argv=list(argv),
            returncode=completed.returncode,
            stdout=(completed.stdout or "")[-400:],
            stderr=(completed.stderr or "")[-400:],
        )
        if completed.returncode != 0:
            return False, (STATUS_FAILED, f"runsc exited {completed.returncode}")
        return True, completed

    def _simple(self, operation: str, command: Sequence[str]) -> LifecycleResult:
        recorder = _Recorder(self.backend, operation)
        recorder.emit("operation_started", container_id=self.container_id)
        ok, response = self._run(recorder, self._argv(*command))
        if not ok:
            status, error = response
            return recorder.result(status, error)
        return recorder.result(STATUS_COMPLETED, container_id=self.container_id)

    def suspend(self) -> LifecycleResult:
        return self._simple("suspend", ("pause", self.container_id))

    def resume(self) -> LifecycleResult:
        return self._simple("resume", ("resume", self.container_id))

    def cleanup(self, *, force: bool = False) -> LifecycleResult:
        command = ["delete"]
        if force:
            command.append("--force")
        command.append(self.container_id)
        return self._simple("cleanup", command)

    def checkpoint(
        self,
        image_path: str,
        *,
        leave_running: bool = False,
        compression: str = "none",
    ) -> LifecycleResult:
        if not image_path:
            return _blocked(self.backend, "snapshot", "checkpoint image path is required")
        recorder = _Recorder(self.backend, "snapshot")
        recorder.emit(
            "operation_started",
            container_id=self.container_id,
            image_path=image_path,
            leave_running=leave_running,
        )
        command = ["checkpoint", "--image-path", image_path, "--compression", compression]
        if leave_running:
            command.append("--leave-running")
        command.append(self.container_id)
        ok, response = self._run(recorder, self._argv(*command))
        if not ok:
            status, error = response
            return recorder.result(status, error, image_path=image_path)
        return recorder.result(
            STATUS_COMPLETED,
            image_path=image_path,
            leave_running=leave_running,
            compression=compression,
        )

    def restore(
        self,
        image_path: str,
        bundle: str,
        *,
        container_id: str | None = None,
        detach: bool = True,
    ) -> LifecycleResult:
        if not image_path or not bundle:
            return _blocked(self.backend, "restore", "image path and bundle are required")
        target_id = container_id or self.container_id
        recorder = _Recorder(self.backend, "restore")
        recorder.emit("operation_started", image_path=image_path, bundle=bundle, container_id=target_id)
        command = ["restore", "--image-path", image_path, "--bundle", bundle]
        if detach:
            command.append("--detach")
        command.append(target_id)
        ok, response = self._run(recorder, self._argv(*command))
        if not ok:
            status, error = response
            return recorder.result(status, error, container_id=target_id)
        ready = None
        if self.ready_probe:
            ready = wait_ready(self.ready_probe, self.timeout_s, recorder=recorder)
            if not ready:
                return recorder.result(STATUS_TIMEOUT, "guest readiness probe timed out", guest_ready=False)
        else:
            recorder.emit("guest_ready_not_run", reason="no caller readiness probe")
        return recorder.result(
            STATUS_COMPLETED,
            image_path=image_path,
            bundle=bundle,
            container_id=target_id,
            guest_ready=ready,
        )

    def fork(
        self,
        image_path: str,
        bundle: str,
        *,
        child_id: str,
        compression: str = "none",
    ) -> LifecycleResult:
        if not child_id:
            return _blocked(self.backend, "fork", "child container id is required")
        recorder = _Recorder(self.backend, "fork")
        recorder.emit(
            "operation_started",
            source_id=self.container_id,
            child_id=child_id,
            image_path=image_path,
        )
        checkpoint = self.checkpoint(
            image_path,
            leave_running=True,
            compression=compression,
        )
        recorder.emit("source_checkpoint_finished", status=checkpoint.status)
        if checkpoint.status != STATUS_COMPLETED:
            return recorder.result(checkpoint.status, checkpoint.error, checkpoint=checkpoint.to_dict())
        restore = self.restore(image_path, bundle, container_id=child_id, detach=True)
        recorder.emit("child_restore_finished", status=restore.status)
        if restore.status != STATUS_COMPLETED:
            return recorder.result(restore.status, restore.error, restore=restore.to_dict())
        return recorder.result(
            STATUS_COMPLETED,
            source_id=self.container_id,
            child_id=child_id,
            checkpoint=checkpoint.to_dict(),
            restore=restore.to_dict(),
        )


def _cli(args: argparse.Namespace) -> LifecycleResult:
    if args.backend == "firecracker":
        adapter = FirecrackerLifecycle(args.socket, timeout_s=args.timeout_s)
        if args.operation == "suspend":
            return adapter.suspend()
        if args.operation == "resume":
            return adapter.resume()
        if args.operation == "cleanup":
            return adapter.cleanup()
        if args.operation == "snapshot":
            if not args.snapshot_path or not args.memory_path:
                return _blocked("firecracker", "snapshot", "--snapshot-path and --memory-path are required")
            return adapter.snapshot(args.snapshot_path, args.memory_path, resume_after=args.resume_after)
        if args.operation == "restore":
            if not args.snapshot_path or not args.memory_path:
                return _blocked("firecracker", "restore", "--snapshot-path and --memory-path are required")
            return adapter.restore(args.snapshot_path, args.memory_path, resume_vm=args.resume_after)
        return _unsupported("firecracker", args.operation, "CLI fork needs a process/socket launcher")
    if args.backend == "gvisor":
        adapter = GVisorLifecycle(
            args.runsc,
            root=args.root,
            container_id=args.container_id,
            timeout_s=args.timeout_s,
        )
        if args.operation == "suspend":
            return adapter.suspend()
        if args.operation == "resume":
            return adapter.resume()
        if args.operation == "cleanup":
            return adapter.cleanup(force=args.force)
        if args.operation == "snapshot":
            return adapter.checkpoint(args.image_path, leave_running=args.leave_running)
        if args.operation == "restore":
            return adapter.restore(args.image_path, args.bundle, detach=True)
        if args.operation == "fork":
            return adapter.fork(args.image_path, args.bundle, child_id=args.child_id)
    return _unsupported(args.backend, args.operation, "operation is not implemented")


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", action="store_true", dest="json_output")
    parser.add_argument("--backend", choices=("firecracker", "gvisor"), required=True)
    parser.add_argument(
        "--operation",
        choices=("snapshot", "restore", "fork", "suspend", "resume", "cleanup"),
        required=True,
    )
    parser.add_argument("--timeout-s", type=float, default=30.0)
    parser.add_argument("--socket", default="/tmp/firecracker.socket")
    parser.add_argument("--runsc", default="runsc")
    parser.add_argument("--root", default="/var/run/runsc")
    parser.add_argument("--container-id", default="acpmux-session")
    parser.add_argument("--child-id", default="acpmux-session-fork")
    parser.add_argument("--snapshot-path", default=None)
    parser.add_argument("--memory-path", default=None)
    parser.add_argument("--image-path", default=None)
    parser.add_argument("--bundle", default=".")
    parser.add_argument("--resume-after", action="store_true")
    parser.add_argument("--leave-running", action="store_true")
    parser.add_argument("--force", action="store_true")
    return parser


def main(argv: Iterable[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    result = _cli(args)
    print(json.dumps(result.to_dict(), indent=2, sort_keys=True))
    return 0 if result.status == STATUS_COMPLETED else 2


if __name__ == "__main__":
    raise SystemExit(main())
