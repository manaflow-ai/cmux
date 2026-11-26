#!/usr/bin/env python3
"""An agy override launches the same binary from raw and daemon scratch folders."""
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


BENCH = Path(__file__).resolve().parents[2] / "cmux-next/acpmux-overhead-bench.py"


class AntigravityOverride(unittest.TestCase):
    def test_override_survives_scratch_cwd_and_conflicting_path(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            chosen = root / "chosen-agy"
            chosen.write_text("#!/bin/sh\nprintf 'chosen\\n'\n")
            chosen.chmod(0o755)
            conflict = root / "other"
            conflict.mkdir()
            other = conflict / "agy"
            other.write_text("#!/bin/sh\nprintf 'wrong\\n'\n")
            other.chmod(0o755)
            for override in (str(chosen), os.path.relpath(chosen)):
                with self.subTest(override=override), patch.dict(os.environ, {
                    "ACPMUX_BENCH_AGY": override,
                    "PATH": str(conflict) + os.pathsep + os.environ.get("PATH", os.defpath),
                }):
                    spec = importlib.util.spec_from_file_location("overhead_agy", BENCH)
                    bench = importlib.util.module_from_spec(spec)
                    spec.loader.exec_module(bench)
                    with tempfile.TemporaryDirectory(dir=root) as scratch:
                        env = bench.env_for("http://127.0.0.1:1", scratch)
                        # Use the raw driver's real process launcher, with its changed cwd.
                        raw = bench.spawn([bench.AGY, "acp"], env, scratch)
                        try:
                            output, _ = raw.communicate(timeout=5)
                            self.assertEqual(raw.returncode, 0)
                            self.assertEqual(output, b"chosen\n")
                        finally:
                            if raw.poll() is None:
                                raw.kill()
                                raw.wait()
                        # The daemon discovers agy through this same prepared environment.
                        daemon = subprocess.check_output(["agy", "acp"], env=env, cwd=scratch, timeout=5)
                        self.assertEqual(daemon, output)


if __name__ == "__main__":
    unittest.main()
