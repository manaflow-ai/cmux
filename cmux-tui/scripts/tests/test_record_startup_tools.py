#!/usr/bin/env python3
"""Regression tests for startup benchmark tool path construction."""

from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path


SCRIPT = Path(__file__).parents[1] / "record_startup_tools.py"
SPEC = importlib.util.spec_from_file_location("record_startup_tools", SCRIPT)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"cannot load {SCRIPT}")
TOOLS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(TOOLS)


class StartupToolPathTests(unittest.TestCase):
    def test_targeted_tools_live_under_release_examples(self) -> None:
        paths = TOOLS.tool_paths(Path("/tmp/target"), "x86_64-pc-windows-gnu", ".exe")

        self.assertEqual(
            paths,
            {
                "supervisor": Path(
                    "/tmp/target/x86_64-pc-windows-gnu/release/examples/startup_benchmark_supervisor.exe"
                ),
                "preflight": Path(
                    "/tmp/target/x86_64-pc-windows-gnu/release/examples/startup_benchmark_preflight.exe"
                ),
                "harness": Path(
                    "/tmp/target/x86_64-pc-windows-gnu/release/examples/startup_benchmark.exe"
                ),
            },
        )


if __name__ == "__main__":
    unittest.main()
