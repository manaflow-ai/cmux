#!/usr/bin/env python3
"""ui-preview-worker.py's --swift-reach: when no display Mac has pulled a Swift ask lately, the web worker runs the
standby command (a reach to another display Mac's `shoot`) instead of failing the look, and a Mac that pulls again
takes the next ask back over the pull path."""
from __future__ import annotations

import base64
import importlib.util
import io
import json
import sys
import tempfile
import time
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("ui_preview_worker_reach", ROOT / "ui-preview-worker.py")
upw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(upw)

SHA = "a" * 40
PNG = b"\x89PNG fake"


def standby_script(tmp: Path, answer: dict, exit_code: int = 0) -> str:
    """A stand-in for the reach: prints noise, then the answer line, and records the job it was given."""
    script = tmp / "standby.py"
    script.write_text(
        "import base64, json, sys, pathlib\n"
        f"pathlib.Path({str(tmp / 'job.json')!r}).write_bytes(base64.b64decode(sys.argv[1]))\n"
        "print('warming: {not json')\n"
        f"print(json.dumps({answer!r}))\n"
        f"sys.exit({exit_code})\n")
    return f"{sys.executable} {script} {{job}}"


class SwiftReach(unittest.TestCase):
    def worker(self, tmp: Path, reach: str) -> "upw.Worker":
        w = upw.Worker(tmp / "state", None, None, None)
        w.swift_on = False
        w.swift_peer = upw.PULL
        w.swift_reach = reach
        return w

    def test_before_a_stale_pull_failed_the_look(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            w = self.worker(Path(tmp), "")
            with self.assertRaisesRegex(upw.LookError, "no display Mac has pulled"):
                w.peer_shoot(SHA, ["shell.sidebar"], Path(tmp) / "out")

    def test_a_stale_pull_goes_to_the_standby_reach(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            answer = {"sha": SHA, "shots": {"shell.sidebar": base64.b64encode(PNG).decode()}}
            w = self.worker(tmp, standby_script(tmp, answer))
            shots = w.peer_shoot(SHA, ["shell.sidebar"], tmp / "out", branch="lane/x")
            self.assertEqual(shots, {"shell.sidebar": "shell.sidebar.png"})
            self.assertEqual((tmp / "out/shell.sidebar.png").read_bytes(), PNG)
            self.assertEqual(json.loads((tmp / "job.json").read_text()),
                             {"sha": SHA, "scenes": ["shell.sidebar"], "branch": "lane/x"})

    def test_a_fresh_pull_keeps_the_pull_path(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            w = self.worker(tmp, standby_script(tmp, {"error": "should not run"}))
            w.pulls.polled_at = time.monotonic()
            with mock.patch.object(w.pulls, "ask", return_value={"shots": {}, "error": "via pull"}) as ask:
                with self.assertRaisesRegex(upw.LookError, "via pull"):
                    w.peer_shoot(SHA, ["shell.sidebar"], tmp / "out")
            ask.assert_called_once()
            self.assertFalse((tmp / "job.json").exists())

    def test_the_standby_error_names_the_look(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            w = self.worker(tmp, standby_script(tmp, {"error": "no Xcode here"}, exit_code=1))
            with self.assertRaisesRegex(upw.LookError, "no Xcode here"):
                w.peer_shoot(SHA, ["shell.sidebar"], tmp / "out")

    def test_a_reach_with_no_json_says_so(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            w = self.worker(tmp, f"{sys.executable} -c \"import sys; sys.stderr.write('refused'); sys.exit(222)\"")
            with self.assertRaisesRegex(upw.LookError, "no JSON \\(exit 222\\): refused"):
                w.reach_shoot({"sha": SHA, "scenes": ["shell.sidebar"], "branch": None})

    def test_serve_parses_the_reach(self) -> None:
        ns = _parse(["serve", "--state", "/x", "--no-swift", "--swift-pull", "--swift-reach", "cmd {job}"])
        self.assertEqual((ns.swift_pull, ns.swift_reach), (True, "cmd {job}"))
        self.assertIsNone(_parse(["serve", "--state", "/x", "--no-swift", "--swift-pull"]).swift_reach)


def _parse(argv):
    import argparse
    captured = {}
    real = argparse.ArgumentParser.parse_args

    def grab(self, a=None, ns=None):
        captured["ns"] = real(self, a, ns)
        raise SystemExit(0)
    with mock.patch.object(argparse.ArgumentParser, "parse_args", grab):
        try:
            upw.main(argv)
        except SystemExit:
            pass
    return captured["ns"]


class Shoot(unittest.TestCase):
    def test_shoot_prints_the_answer_line(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            job = base64.b64encode(json.dumps({"sha": SHA, "scenes": ["shell.sidebar"]}).encode()).decode()
            with mock.patch.object(upw.Worker, "peer_answer", return_value={"sha": SHA, "shots": {"s": "eA=="}}), \
                    mock.patch.object(upw.Worker, "stop_shooter") as stop:
                out = io.StringIO()
                with redirect_stdout(out):
                    code = upw.main(["shoot", "--state", tmp, "--job", job])
            self.assertEqual(code, 0)
            self.assertEqual(json.loads(out.getvalue().splitlines()[-1]), {"sha": SHA, "shots": {"s": "eA=="}})
            stop.assert_called_once()

    def test_shoot_answers_an_error_line(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            out = io.StringIO()
            with redirect_stdout(out):
                code = upw.main(["shoot", "--state", tmp, "--job", "not base64!"])
            self.assertEqual(code, 2)
            self.assertIn("error", json.loads(out.getvalue().splitlines()[-1]))
            job = base64.b64encode(json.dumps({"sha": "short"}).encode()).decode()
            out = io.StringIO()
            with redirect_stdout(out):
                code = upw.main(["shoot", "--state", tmp, "--job", job])
            self.assertEqual(code, 1)
            self.assertEqual(json.loads(out.getvalue().splitlines()[-1]), {"error": "sha must be 40 hex"})


if __name__ == "__main__":
    unittest.main()
