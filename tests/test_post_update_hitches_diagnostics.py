"""post-update-hitches' timeout diagnostics (hq#11994): which replies take them and how the main-thread stack is read."""
import ast
import json
from pathlib import Path
import re
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]

SAMPLE = """\
Call graph:
    2345 Thread_123456   DispatchQueue_1: com.apple.main-thread  (serial)
    + 2345 start  (in dyld) + 2840  [0x18a0]
    +   2345 main  (in cmux) + 12  [0x10]
    +     2000 -[NSApplication runModalForWindow:]  (in AppKit) + 1  [0x20]
    +     ! 2000 SPUInstallerDriver.wait  (in Sparkle) + 4  [0x30]
    +     ! : 2000 semaphore_wait_trap  (in libsystem_kernel.dylib) + 8  [0x40]
    +     345 baz  (in cmux) + 3  [0x50]
    2345 Thread_123457
    + 2345 other  (in x) + 1  [0x60]
"""


def helpers(names):
    path = ROOT / "scripts/measure/post-update-hitches.py"
    tree = ast.parse(path.read_text())
    nodes = [node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name in names]
    if {node.name for node in nodes} != set(names):
        raise AssertionError(f"missing helpers in {path}")
    namespace = {"json": json, "re": re, "Path": Path}
    exec(compile(ast.Module(body=nodes, type_ignores=[]), str(path), "exec"), namespace)
    return namespace


class DiagnosticsTests(unittest.TestCase):
    def setUp(self):
        self.api = helpers(["unanswered", "main_thread_stack"])

    def test_unanswered_replies(self):
        unanswered = self.api["unanswered"]
        self.assertTrue(unanswered({"error": "timed out"}))
        self.assertTrue(unanswered({"error": {"code": "not_run", "message": "deadline"}}))
        self.assertFalse(unanswered({"error": "[Errno 61] Connection refused"}))
        self.assertFalse(unanswered({"build": "1"}))
        self.assertFalse(unanswered(None))

    def test_main_thread_heaviest_path(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "sample.txt"
            path.write_text(SAMPLE)
            stack = self.api["main_thread_stack"](path)
        self.assertEqual(stack, ["start", "main", "-[NSApplication runModalForWindow:]", "SPUInstallerDriver.wait",
                                 "semaphore_wait_trap"])

    def test_missing_sample(self):
        self.assertEqual(self.api["main_thread_stack"](Path("/nonexistent/sample.txt")), [])


if __name__ == "__main__":
    unittest.main()
