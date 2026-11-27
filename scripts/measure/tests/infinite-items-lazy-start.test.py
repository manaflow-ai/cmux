#!/usr/bin/env python3
"""--lazy-start sets CMUX_TUI_LAZY_START for cmux-tui only when asked, never from the caller's environment."""
import importlib.util
import os
from pathlib import Path
import shutil
import types
import unittest
from unittest.mock import patch


BENCH = Path(__file__).resolve().parents[1] / "infinite-items.py"


def load():
    spec = importlib.util.spec_from_file_location("infinite_items", BENCH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def args(**over):
    base = dict(idle_child_secs=5, terminal_host_model="product", agent_holder="on", evict_idle_secs=None,
                resident_cap=0, root_dir=None, lazy_start="off")
    base.update(over)
    return types.SimpleNamespace(**base)


class LazyStartArm(unittest.TestCase):
    def env_of(self, caller, **over):
        bench = load()
        with patch.dict(os.environ, caller, clear=False):
            run = bench.Run(args(**over), 1)
            try:
                return run.env()
            finally:
                shutil.rmtree(run.root, ignore_errors=True)

    def test_on_sets_the_switch(self):
        self.assertEqual(self.env_of({}, lazy_start="on").get("CMUX_TUI_LAZY_START"), "1")

    def test_off_drops_the_callers_switch(self):
        self.assertNotIn("CMUX_TUI_LAZY_START", self.env_of({"CMUX_TUI_LAZY_START": "1"}, lazy_start="off"))

    def test_the_flag_defaults_off(self):
        bench = load()
        with patch("sys.argv", ["infinite-items.py", "--acpmux", "a", "--tui", "t", "--help"]), \
                patch("sys.stdout"), self.assertRaises(SystemExit):
            bench.main()
        self.assertIn('choices=("off", "on"), default="off"', BENCH.read_text())


if __name__ == "__main__":
    unittest.main()
