"""fast-gates-base-*, fast-gate-webviews-base-* and ci-receipt-* temp folders of killed runs are swept by the next run (same class as
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

    def test_webviews_base(self):
        self.check(load("fast_gate_webviews_checks"), "fast-gate-webviews-base-")

    def test_webviews_base_holder_names_its_owner(self):
        module = load("fast_gate_webviews_checks")
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(tempfile, "tempdir", tmp):
            repo = Path(tmp) / "repo"
            (repo / "webviews").mkdir(parents=True)
            git = ["git", "-C", str(repo), "-c", "user.name=t", "-c", "user.email=t@t"]
            subprocess.run(["git", "init", "-q", str(repo)], check=True)
            (repo / "webviews" / "package.json").write_text("{}")
            subprocess.run(git + ["add", "-A"], check=True)
            subprocess.run(git + ["commit", "-qm", "base"], check=True)
            stale = Path(tmp) / (module.HOLDER_PREFIX + "killed")
            stale.mkdir()
            (stale / ".owner-pid").write_text(str(dead_pid()))
            tree = module.BaseTree(repo, "HEAD")
            with mock.patch.object(module, "shares_deps", return_value=True), \
                    mock.patch.object(module, "generate_strings"):
                (repo / "webviews" / "node_modules").mkdir()
                webviews = tree.webviews()
            self.assertIsNotNone(webviews)
            self.assertFalse(stale.exists(), "a killed run's holder is swept by the next base checkout")
            self.assertEqual((webviews.parent.parent / ".owner-pid").read_text(), str(os.getpid()))
            tree.close()
            self.assertFalse(webviews.parent.parent.exists())


if __name__ == "__main__":
    unittest.main()
