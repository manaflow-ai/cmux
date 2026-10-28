#!/usr/bin/env python3
"""CI cleanup must treat EPERM from os.killpg like ESRCH.

macOS answers killpg with EPERM, not ESRCH, when every process left in the
group is a zombie (an exited leader not yet reaped). A cleanup path that only
catches ProcessLookupError then crashes a CI step whose real work succeeded
(nightly-next Release build, 2026-10-27). Every killpg under scripts/ci that
sends a real signal must sit in a try that also catches PermissionError.
"""
import ast
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCAN = ROOT / "scripts/ci"
TOLERANT = {"PermissionError", "OSError", "Exception", "BaseException"}


def caught_names(handler):
    if handler.type is None:
        return {"BaseException"}
    nodes = handler.type.elts if isinstance(handler.type, ast.Tuple) else [handler.type]
    return {getattr(node, "id", getattr(node, "attr", "")) for node in nodes}


def violations(source, name="<source>"):
    tree = ast.parse(source, name)
    parents = {child: node for node in ast.walk(tree) for child in ast.iter_child_nodes(node)}
    found = []
    for node in ast.walk(tree):
        if not (isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
                and node.func.attr == "killpg"):
            continue
        # killpg(pgid, 0) is a liveness probe; EPERM there has its own meaning.
        if len(node.args) == 2 and isinstance(node.args[1], ast.Constant) and node.args[1].value == 0:
            continue
        caught, child = set(), node
        while child in parents:
            parent = parents[child]
            if isinstance(parent, ast.Try) and child in parent.body:
                for handler in parent.handlers:
                    caught |= caught_names(handler)
            child = parent
        if not caught & TOLERANT:
            found.append(f"{name}:{node.lineno}")
    return found


class KillpgToleratesEpermTests(unittest.TestCase):
    def test_scripts_ci_killpg_calls_tolerate_eperm(self):
        found = []
        for path in sorted(SCAN.rglob("*.py")):
            found += violations(path.read_text(), str(path.relative_to(ROOT)))
        self.assertEqual(found, [], "killpg must also catch PermissionError (macOS zombie group)")

    def test_detects_process_lookup_only_handler(self):
        old = "import os\ntry:\n    os.killpg(1, 15)\nexcept ProcessLookupError:\n    pass\n"
        self.assertEqual(violations(old), ["<source>:3"])

    def test_accepts_permission_error_and_liveness_probe(self):
        ok = ("import os\ntry:\n    os.killpg(1, 15)\nexcept (ProcessLookupError, PermissionError):\n    pass\n"
              "try:\n    os.killpg(1, 0)\nexcept ProcessLookupError:\n    pass\n")
        self.assertEqual(violations(ok), [])


if __name__ == "__main__":
    unittest.main()
