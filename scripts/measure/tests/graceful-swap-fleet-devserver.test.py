#!/usr/bin/env python3
"""graceful-swap-fleet.py's dev server check names why no save can reach a chat page. Compiles dev_server_miss
alone from the source, so the test needs none of the fleet script's imports."""
import ast
import os
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SOURCE = open(os.path.join(HERE, "..", "graceful-swap-fleet.py"), encoding="utf-8").read()


def dev_server_miss():
    """The fleet script's dev_server_miss, compiled alone (it uses nothing else)."""
    tree = ast.parse(SOURCE)
    fn = next(n for n in ast.walk(tree) if isinstance(n, ast.FunctionDef) and n.name == "dev_server_miss")
    fn.decorator_list = []
    scope = {}
    exec(compile(ast.Module(body=[fn], type_ignores=[]), "graceful-swap-fleet.py", "exec"), scope)
    return scope["dev_server_miss"]


class DevServerCheck(unittest.TestCase):
    """server() stops before the films with the reason no save can reach a chat page (step 8c6948cc: 20 films, no
    repaint, no reason)."""

    def test_names_each_miss(self):
        miss = dev_server_miss()
        ok = {"origin": "cmux-agent://pane", "hmr": "connected"}
        self.assertIsNone(miss({"a": 1, "b": 1}, {"a": ok, "b": ok}))
        self.assertIn("chat-b is not on the dev server", miss({"a": 1, "b": 0}, {"a": ok, "b": ok}))
        self.assertIn("no hot-swap client mark", miss({"a": 1, "b": 1}, {"a": ok, "b": {"hmr": None}}))
        self.assertIn("HMR socket is connecting", miss({"a": 1, "b": 1}, {"a": {"hmr": "connecting"}, "b": ok}))


if __name__ == "__main__":
    unittest.main()
