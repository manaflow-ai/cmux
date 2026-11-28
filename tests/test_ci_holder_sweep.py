"""fast-gates-base-* and ci-receipt-* temp folders of killed runs are swept by the next run (same class as
tests/test_web_lint_holder_reap.py)."""
import importlib.util
import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

SOURCE = Path(__file__).resolve().parents[1]


def load(name):
    spec = importlib.util.spec_from_file_location(name, SOURCE / "scripts" / "ci" / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def dead_pid() -> int:
    child = subprocess.Popen([sys.executable, "-c", "pass"])
    child.wait()
    return child.pid


class SweepDeadHolders(unittest.TestCase):
    def check(self, module, prefix):
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(tempfile, "tempdir", tmp):
            root = Path(tmp)
            gone, live, fresh, old, other = (root / (prefix + n) for n in ("dead", "live", "fresh", "old", "x"))
            for p in (gone, live, fresh, old):
                (p / "sub").mkdir(parents=True)
            (gone / ".owner-pid").write_text(str(dead_pid()))
            (live / ".owner-pid").write_text(str(os.getpid()))
            past = time.time() - 3600
            os.utime(old, (past, past))
            keep = root / "unrelated"
            keep.mkdir()
            self.assertEqual(module.sweep_dead_holders(prefix), 2)
            self.assertFalse(gone.exists())
            self.assertFalse(old.exists())
            self.assertTrue(live.exists())
            self.assertTrue(fresh.exists())
            self.assertTrue(keep.exists())

    def test_fast_gates(self):
        self.check(load("cmux_next_fast_gates"), "fast-gates-base-")

    def test_ci_receipt(self):
        self.check(load("ci_receipt"), "ci-receipt-")


if __name__ == "__main__":
    unittest.main()
