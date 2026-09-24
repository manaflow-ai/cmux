#!/usr/bin/env python3
"""Bounded GitHub observation helpers for dispatching work to an owned Mac.

nightly_mini_route.py dispatches a producer workflow, waits a bounded time for
it, and cancels it when the wait is abandoned. These are the pieces of that
loop that do not depend on which workflow is dispatched: cancellation-aware
retry, the `gh api` wrapper, job listing, run cancellation and step outputs.
"""

from __future__ import annotations

from datetime import datetime
import json
import signal
import subprocess
import sys
import threading
import time
from pathlib import Path


TERMINAL = {"completed"}


def now() -> float:
    return time.monotonic()


def parse_time(value: str | None) -> datetime | None:
    if not value:
        return None
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


class RetryCancelled(RuntimeError):
    """Raised when CI cancellation interrupts a bounded GitHub observation."""


class RetryWait:
    """Cancellation-aware bounded retry owner for GitHub control-plane observation."""

    def __init__(self, *, clock=now, wait=None):
        self._clock = clock
        self._cancelled = threading.Event()
        self._wait = wait or self._cancelled.wait
        self.cancel_signal: int | None = None

    def cancel(self, signum: int | None = None) -> None:
        if signum is not None:
            self.cancel_signal = signum
        self._cancelled.set()

    def until(self, deadline: float, probe, *, initial_delay: float = 0.5, max_delay: float = 3.0):
        delay = initial_delay
        while True:
            complete, value = probe()
            if complete:
                return value
            remaining = deadline - self._clock()
            if remaining <= 0:
                return None
            if self._cancelled.is_set() or self._wait(min(delay, remaining)):
                raise RetryCancelled("owned-Mac route observation was cancelled")
            delay = min(max_delay, delay * 2)


def install_cancel_handlers(waiter: RetryWait) -> None:
    def cancel_wait(signum, _frame) -> None:
        waiter.cancel(signum)

    signal.signal(signal.SIGINT, cancel_wait)
    signal.signal(signal.SIGTERM, cancel_wait)


class GitHub:
    def __init__(self, repository: str):
        self.repository = repository

    def api(self, path: str, *, method: str = "GET") -> object:
        result = subprocess.run(
            ["gh", "api", "--method", method, f"repos/{self.repository}/{path}"],
            text=True,
            capture_output=True,
            check=False,
        )
        if result.returncode:
            raise RuntimeError(result.stderr.strip() or f"gh api exited {result.returncode}")
        return json.loads(result.stdout) if result.stdout.strip() else {}


def jobs(api: GitHub, run_id: int) -> list[dict[str, object]]:
    payload = api.api(f"actions/runs/{run_id}/jobs?filter=latest&per_page=100")
    if not isinstance(payload, dict) or not isinstance(payload.get("jobs"), list):
        raise RuntimeError("producer job list is malformed")
    return [job for job in payload["jobs"] if isinstance(job, dict)]


def cancel(api: GitHub, run_id: int) -> None:
    try:
        api.api(f"actions/runs/{run_id}/cancel", method="POST")
    except RuntimeError as error:
        print(f"warning: producer cancellation failed: {error}", file=sys.stderr)


def write_outputs(path: Path, values: dict[str, object]) -> None:
    with path.open("a", encoding="utf-8") as stream:
        for key, value in values.items():
            stream.write(f"{key}={value}\n")
