#!/usr/bin/env python3
"""--lazy-start sets CMUX_TUI_LAZY_START for cmux-tui explicitly in both arms, never from the caller's environment."""
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

    def test_on_overrides_the_callers_off(self):
        self.assertEqual(self.env_of({"CMUX_TUI_LAZY_START": "0"}, lazy_start="on").get("CMUX_TUI_LAZY_START"), "1")

    def test_off_turns_it_off_over_the_default_and_the_caller(self):
        self.assertEqual(self.env_of({}, lazy_start="off").get("CMUX_TUI_LAZY_START"), "0")
        self.assertEqual(self.env_of({"CMUX_TUI_LAZY_START": "1"}, lazy_start="off").get("CMUX_TUI_LAZY_START"), "0")

    def test_the_flag_defaults_on_like_the_product(self):
        bench = load()
        with patch("sys.argv", ["infinite-items.py", "--acpmux", "a", "--tui", "t", "--help"]), \
                patch("sys.stdout"), self.assertRaises(SystemExit):
            bench.main()
        self.assertIn('choices=("off", "on"), default="on"', BENCH.read_text())


if __name__ == "__main__":
    unittest.main()
