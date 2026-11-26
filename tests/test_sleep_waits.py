#!/usr/bin/env python3
"""scripts/sleep-waits.py sorts sleeps into waits, polls and marked ones; state_wait.py waits on a state."""

from __future__ import annotations

import json
import pathlib
import subprocess
import sys
import tempfile
import threading
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts" / "cmux-next"))

from state_wait import StateWaitTimeout, wait_stable, wait_until  # noqa: E402


def inventory(root: pathlib.Path) -> list[dict]:
    out = subprocess.run(
        [sys.executable, str(ROOT / "scripts" / "sleep-waits.py"), str(root), "--json"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    return json.loads(out)


class SleepWaitsInventoryTests(unittest.TestCase):
    def test_kinds(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            (root / "scripts").mkdir()
            (root / "scripts" / "tool.py").write_text(
                "import time\n"
                "time.sleep(1)\n"
                "while True:\n"
                "    time.sleep(0.1)\n"
                "# sleep-ok: a recording window of one second\n"
                "time.sleep(1)\n"
                "time.sleep(2)  # sleep-ok: the stub is slow on purpose\n"
                "s = 'time.sleep(5)'\n"
            )
            (root / "scripts" / "tool.sh").write_text(
                "#!/bin/sh\n"
                "sleep 1\n"
                "while ! test -f x; do sleep 0.1; done\n"
                "until test -f y; do\n"
                "  sleep 0.1\n"
                "done\n"
                "sleep 2 # sleep-ok: keep the child alive\n"
            )
            rows = inventory(root)
        kinds = {(r["path"], r["line"]): r["kind"] for r in rows}
        self.assertEqual(
            kinds,
            {
                ("scripts/tool.py", 2): "wait",
                ("scripts/tool.py", 4): "poll",
                ("scripts/tool.py", 6): "ok",
                ("scripts/tool.py", 7): "ok",
                ("scripts/tool.sh", 2): "wait",
                ("scripts/tool.sh", 3): "poll",
                ("scripts/tool.sh", 5): "poll",
                ("scripts/tool.sh", 7): "ok",
            },
        )


class StateWaitTests(unittest.TestCase):
    def test_wait_until_returns_when_the_event_happens(self) -> None:
        happened = threading.Event()
        threading.Timer(0.05, happened.set).start()
        self.assertTrue(wait_until(happened.is_set, "the event", timeout=30))

    def test_wait_until_names_what_never_came(self) -> None:
        with self.assertRaisesRegex(StateWaitTimeout, "the window"):
            wait_until(lambda: False, "the window", timeout=0)
        self.assertIsNone(wait_until(lambda: False, "x", timeout=0, raise_on_timeout=False))

    def test_wait_until_treats_an_error_as_not_yet(self) -> None:
        calls = iter([OSError("not up"), OSError("not up"), "ready"])

        def probe() -> str:
            value = next(calls)
            if isinstance(value, Exception):
                raise value
            return value

        self.assertEqual(wait_until(probe, "the socket", timeout=30, interval=0), "ready")

    def test_wait_stable_returns_the_settled_value(self) -> None:
        values = iter([1, 2, 3, 3, 3, 3])
        self.assertEqual(wait_stable(lambda: next(values), "the layout", timeout=30, interval=0), 3)

    def test_wait_stable_times_out_on_a_value_that_never_settles(self) -> None:
        counter = iter(range(10**9))
        with self.assertRaisesRegex(StateWaitTimeout, "the frame"):
            wait_stable(lambda: next(counter), "the frame", timeout=0)


if __name__ == "__main__":
    unittest.main()
