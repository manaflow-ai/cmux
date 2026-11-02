#!/usr/bin/env python3
"""CI cleanup must treat EPERM from os.killpg like ESRCH.

macOS answers killpg with EPERM, not ESRCH, when every process left in the
group is a zombie (an exited leader not yet reaped). A cleanup path that only
catches ProcessLookupError then crashes a CI step whose real work succeeded
(nightly-next Release build, 2026-10-27). Every killpg under scripts/ci (Python files and Python
embedded in shell scripts) that sends a real signal must sit in a try that also catches PermissionError.
"""
import ast
import re
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCAN = ROOT / "scripts/ci"
TOLERANT = {"PermissionError", "OSError", "Exception", "BaseException"}
SCOPES = (ast.FunctionDef, ast.AsyncFunctionDef, ast.Lambda, ast.ClassDef, ast.GeneratorExp)


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
        if not isinstance(node, ast.Call):
            continue
        callee = node.func
        if getattr(callee, "attr", getattr(callee, "id", None)) != "killpg":
            continue
        # killpg(pgid, 0) is a liveness probe; EPERM there has its own meaning.
        if len(node.args) == 2 and isinstance(node.args[1], ast.Constant) and node.args[1].value == 0:
            continue
        caught, child = set(), node
        while child in parents:
            parent = parents[child]
            # A handler around a definition does not cover the call when it runs.
            if isinstance(parent, SCOPES):
                break
            if isinstance(parent, ast.Try) and child in parent.body:
                for handler in parent.handlers:
                    caught |= caught_names(handler)
            child = parent
        if not caught & TOLERANT:
            found.append(f"{name}:{node.lineno}")
    return found


def shell_violations(source, name="<source>"):
    """Python embedded in shell (python3 -c '...'): each killpg's next handler."""
    found = []
    lines = source.splitlines()
    for index, line in enumerate(lines):
        if "killpg(" not in line or re.search(r"killpg\([^,]+,\s*0\s*\)", line):
            continue
        handler = next((later for later in lines[index + 1:index + 6] if later.strip().startswith("except")), "")
        if not any(word in handler for word in TOLERANT):
            found.append(f"{name}:{index + 1}")
    return found


class KillpgToleratesEpermTests(unittest.TestCase):
    def test_scripts_ci_killpg_calls_tolerate_eperm(self):
        found = []
        for path in sorted(SCAN.rglob("*.py")):
            found += violations(path.read_text(), str(path.relative_to(ROOT)))
        for path in sorted(SCAN.rglob("*.sh")):
            found += shell_violations(path.read_text(), str(path.relative_to(ROOT)))
        self.assertEqual(found, [], "killpg must also catch PermissionError (macOS zombie group)")

    def test_detects_process_lookup_only_handler(self):
        old = "import os\ntry:\n    os.killpg(1, 15)\nexcept ProcessLookupError:\n    pass\n"
        self.assertEqual(violations(old), ["<source>:3"])

    def test_detects_bare_killpg_and_handler_around_a_definition(self):
        bare = "from os import killpg\ntry:\n    killpg(1, 9)\nexcept ProcessLookupError:\n    pass\n"
        self.assertEqual(violations(bare), ["<source>:3"])
        deferred = ("import os\ntry:\n    def cleanup():\n        os.killpg(1, 9)\n"
                    "except PermissionError:\n    pass\ncleanup()\n")
        self.assertEqual(violations(deferred), ["<source>:4"])

    def test_detects_handler_around_a_generator(self):
        lazy = ("import os\ntry:\n    pending = (os.killpg(1, 9) for _ in [0])\n"
                "except PermissionError:\n    pass\nnext(pending)\n")
        self.assertEqual(violations(lazy), ["<source>:3"])

    def test_detects_embedded_python_in_shell(self):
        old = "python3 -c '\ntry:\n    os.killpg(proc.pid, signum)\nexcept ProcessLookupError:\n    pass\n'\n"
        self.assertEqual(shell_violations(old), ["<source>:3"])
        self.assertEqual(shell_violations(old.replace("ProcessLookupError", "(ProcessLookupError, PermissionError)")), [])

    def test_accepts_permission_error_and_liveness_probe(self):
        ok = ("import os\ntry:\n    os.killpg(1, 15)\nexcept (ProcessLookupError, PermissionError):\n    pass\n"
              "try:\n    os.killpg(1, 0)\nexcept ProcessLookupError:\n    pass\n")
        self.assertEqual(violations(ok), [])


if __name__ == "__main__":
    unittest.main()
