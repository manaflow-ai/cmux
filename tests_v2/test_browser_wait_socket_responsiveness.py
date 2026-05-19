#!/usr/bin/env python3
"""Regression: a pending browser.wait must not block unrelated socket calls."""

import os
import queue
import sys
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET_PATH", "/tmp/cmux-debug.sock")


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def _timed_call(method: str, params: dict | None = None, timeout_s: float = 1.0) -> tuple[float, object]:
    started = time.monotonic()
    with cmux(SOCKET_PATH) as c:
        result = c._call(method, params or {}, timeout_s=timeout_s)
    return time.monotonic() - started, result


def _assert_unrelated_socket_calls_are_responsive(label: str) -> None:
    for method in ("system.ping", "workspace.list"):
        elapsed, response = _timed_call(method, timeout_s=0.75)
        _must(elapsed < 0.75, f"{method} was blocked by pending {label} for {elapsed:.3f}s")
        _must(response is not None, f"{method} returned no response during pending {label}")


def main() -> int:
    with cmux(SOCKET_PATH) as c:
        opened = c._call("browser.open_split", {"url": "about:blank"}, timeout_s=10.0) or {}
        surface_id = str(opened.get("surface_id") or "")
        _must(surface_id != "", f"browser.open_split returned no surface_id: {opened}")

    wait_result: "queue.Queue[object]" = queue.Queue()

    def run_pending_wait() -> None:
        try:
            with cmux(SOCKET_PATH) as waiter:
                waiter._call(
                    "browser.wait",
                    {
                        "surface_id": surface_id,
                        "selector": "#cmux-missing-selector",
                        "timeout_ms": 2500,
                    },
                    timeout_s=6.0,
                )
            wait_result.put(cmuxError("pending browser.wait unexpectedly succeeded"))
        except Exception as exc:
            wait_result.put(exc)

    thread = threading.Thread(target=run_pending_wait, name="pending-browser-wait")
    thread.start()

    time.sleep(0.25)
    _must(thread.is_alive(), "browser.wait finished before responsiveness probe could run")

    _assert_unrelated_socket_calls_are_responsive("browser.wait")

    thread.join(timeout=8.0)
    _must(not thread.is_alive(), "pending browser.wait did not finish after its timeout")

    wait_exc = wait_result.get_nowait()
    _must(isinstance(wait_exc, cmuxError), f"Expected browser.wait timeout error, got {wait_exc!r}")
    _must("timeout" in str(wait_exc).lower(), f"Expected timeout error from pending browser.wait, got {wait_exc!r}")

    eval_result: "queue.Queue[object]" = queue.Queue()

    def run_pending_eval() -> None:
        try:
            with cmux(SOCKET_PATH) as evaluator:
                result = evaluator._call(
                    "browser.eval",
                    {
                        "surface_id": surface_id,
                        "script": "new Promise((resolve) => setTimeout(() => resolve('done'), 2500))",
                    },
                    timeout_s=6.0,
                )
            eval_result.put(result)
        except Exception as exc:
            eval_result.put(exc)

    eval_thread = threading.Thread(target=run_pending_eval, name="pending-browser-eval")
    eval_thread.start()

    time.sleep(0.25)
    _must(eval_thread.is_alive(), "browser.eval finished before responsiveness probe could run")

    _assert_unrelated_socket_calls_are_responsive("browser.eval")

    eval_thread.join(timeout=8.0)
    _must(not eval_thread.is_alive(), "pending browser.eval did not finish")

    eval_payload = eval_result.get_nowait()
    _must(not isinstance(eval_payload, Exception), f"Expected browser.eval success, got {eval_payload!r}")
    _must(isinstance(eval_payload, dict), f"Expected browser.eval payload dict, got {eval_payload!r}")
    _must(eval_payload.get("value") == "done", f"Expected browser.eval promise result, got {eval_payload!r}")

    print("PASS: pending browser.wait and browser.eval leave unrelated socket calls responsive")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
