#!/usr/bin/env python3
"""typing-frame-bench.py and sidebar-churn-typing.py start the app through the real BenchApp.launch (review 2 of
pl-typing-b23).

Both scripts called `bench.launch(timeout=180, settle=...)`, but BenchApp.launch has had no `settle` parameter since
e85bafbd6f8 (no settle sleep in the shared launch). Each launch raised TypeError before it started anything; only
LaunchError is caught, so the bench ended with a traceback and measured nothing. `py_compile` cannot see a bad keyword
argument: this test runs each script's real launch call against the real BenchApp.

The GUI-session read is injected as "no session", so the real launch() refuses at its first check (LaunchError
`no-gui-session`) and starts no process: the test needs no app, build or GUI session. A copy of /bin/sleep stands in
for the bundle's executable (never run here). Repo rule: run on the fleet.

    python3 scripts/cmux-next/tests/test_typing_bench_launch.py
"""

from __future__ import annotations

import importlib.util
import io
import os
import shutil
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(HERE))
import bench_launch as bl  # noqa: E402

NO_SESSION = {"ok": False, "user": "worker", "console_user": None, "screen_locked": None,
              "detail": "nobody is logged in on the console (login window); worker has no GUI session"}


def fake_bundle(folder: str, tag: str) -> str:
    """A `cmux DEV <tag>.app` whose main executable is a copy of /bin/sleep."""
    app = os.path.join(os.path.realpath(folder), f"cmux DEV {tag}.app")
    macos = os.path.join(app, "Contents/MacOS")
    os.makedirs(macos)
    shutil.copy("/bin/sleep", os.path.join(macos, "cmux DEV"))
    return app


def load_script(name: str, argv: list[str]):
    """Imports a bench script with `argv` as its command line (a script that runs main() at import runs it here)."""
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), HERE / name)
    module = importlib.util.module_from_spec(spec)
    with mock.patch.object(sys, "argv", [str(HERE / name), *argv]):
        spec.loader.exec_module(module)
    return module


class BenchLaunchCallTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.mkdtemp(prefix="typing-bench-launch-")
        self.tag = f"tbl-{os.getpid()}"
        self.app = fake_bundle(self.folder, self.tag)
        self.out = os.path.join(self.folder, "out")

    def tearDown(self):
        shutil.rmtree(self.folder, ignore_errors=True)

    def test_typing_frame_bench_reaches_the_launch_and_records_its_refusal(self):
        with mock.patch.object(bl, "gui_session", return_value=NO_SESSION), redirect_stdout(io.StringIO()):
            bench = load_script("typing-frame-bench.py", ["--app", self.app, "--tag", self.tag, "--out", self.out])
            bench.run_session("light")
        failures = bench.results.get("launch_failures") or []
        self.assertEqual([f["reason"] for f in failures], ["no-gui-session"],
                         "the bench did not reach BenchApp.launch's own checks")

    def test_sidebar_churn_typing_reaches_the_launch_and_records_its_refusal(self):
        with mock.patch.object(bl, "gui_session", return_value=NO_SESSION), redirect_stdout(io.StringIO()):
            with self.assertRaises(bl.LaunchError) as refused:
                load_script("sidebar-churn-typing.py", ["--app", self.app, "--tag", self.tag, "--out", self.out,
                                                        "--json", os.path.join(self.out, "report.json")])
        self.assertEqual(refused.exception.reason, "no-gui-session")


if __name__ == "__main__":
    unittest.main()
