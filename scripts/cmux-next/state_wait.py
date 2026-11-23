"""Wait on a state, not on a clock: the shared replacement for a fixed time.sleep in harnesses and tools.

Leo, 2026-11-22: "surely we can think of better fixes than random timing which can shift." A fixed sleep that
stands in for "until the window opened" or "until the animation ended" passes on a quiet Mac and fails on a busy
one, and wastes its whole length when the thing was already there. These wait exactly as long as the thing takes,
up to a deadline, and say what they were waiting for when it never comes.

Import it beside the script (the harnesses already put their own folder on sys.path):

    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from state_wait import wait_until, wait_stable

    wait_until(lambda: window_open(), "the settings window", timeout=10)
    wait_stable(lambda: snapshot()["layout"], "the layout after the split", timeout=10)

scripts/sleep-waits.py counts the fixed sleeps left.
"""

from __future__ import annotations

import time
from typing import Callable, TypeVar

T = TypeVar("T")

__all__ = ["StateWaitTimeout", "wait_until", "wait_stable"]


class StateWaitTimeout(TimeoutError):
    pass


def wait_until(
    predicate: Callable[[], T],
    what: str,
    timeout: float = 10.0,
    interval: float = 0.05,
    raise_on_timeout: bool = True,
) -> T | None:
    """Return the predicate's first truthy value; past `timeout` s raise (or return None when told not to).

    A predicate that raises counts as not yet (the socket not up, the file half written); the last error is in
    the timeout's message.
    """
    deadline = time.monotonic() + timeout
    last_error: BaseException | None = None
    while True:
        try:
            value = predicate()
            if value:
                return value
        except Exception as exc:  # noqa: BLE001 - not ready yet is any error
            last_error = exc
        if time.monotonic() >= deadline:
            if not raise_on_timeout:
                return None
            detail = f" (last error: {last_error!r})" if last_error else ""
            raise StateWaitTimeout(f"timed out after {timeout:g} s waiting for {what}{detail}")
        time.sleep(interval)


def wait_stable(
    read: Callable[[], T],
    what: str,
    timeout: float = 10.0,
    interval: float = 0.05,
    reads: int = 3,
    raise_on_timeout: bool = True,
) -> T | None:
    """Return `read()` once it gave the same value `reads` times in a row (an animation or layout that settled).

    For the things that have no "done" signal of their own: the value itself stops changing. Past `timeout` s raise
    (or return the last value when told not to).
    """
    deadline = time.monotonic() + timeout
    last: object = object()
    same = 0
    value: T | None = None
    while True:
        try:
            value = read()
            same = same + 1 if value == last else 1
            last = value
            if same >= reads:
                return value
        except Exception:  # noqa: BLE001 - not readable yet
            same = 0
        if time.monotonic() >= deadline:
            if not raise_on_timeout:
                return value
            raise StateWaitTimeout(f"timed out after {timeout:g} s waiting for {what} to settle")
        time.sleep(interval)
