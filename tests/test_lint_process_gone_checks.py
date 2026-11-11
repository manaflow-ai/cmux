#!/usr/bin/env python3
"""Lint: a test never probes a process with signal 0; it uses tests/process_gone.py.

`os.kill(pid, 0)` or `os.killpg(pgid, 0)` races the kernel and the reaper: on a busy machine a killed process is
still in the process table for a moment, and signal 0 still reaches a zombie, so "it is gone" fails and "it still
runs" passes on a dead one. A loop around the probe is no proof of a wait (one with a single pass, or no sleep, checks
once). So every raw probe in a test file (test_*.py, *_test.py, *-test.py, *.test.py, or anything under a tests/
folder) is flagged, in any form: the test uses process_gone.died(pid), running(pid) or group_died(pgid), and ALLOWED,
with a reason, is the only escape. A file that cannot load the helper carries a copy of its functions (COPIES), and the
copy must match the helper.

Runs under plain python3: `python3 -I tests/test_lint_process_gone_checks.py`.
"""

from __future__ import annotations

import ast
import hashlib
import importlib.util
import os
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TESTS = ROOT / "tests"


def _load(name):
    """tests/NAME.py, loaded by path (`python3 -I` puts no script folder on sys.path), once per process."""
    if name not in sys.modules:
        spec = importlib.util.spec_from_file_location(name, TESTS / ("%s.py" % name))
        assert spec is not None and spec.loader is not None
        module = importlib.util.module_from_spec(spec)
        sys.modules[name] = module
        spec.loader.exec_module(module)
    return sys.modules[name]


# Vendored from leo-workspace (tools/), byte for byte, at the commit tests/process_gone.pin names: the helper, the
# lint and its resolver, and the cases every repo runs. Change them there, then copy them and the pin here.
VENDORED = ("process_identity.py", "process_gone.py", "ast_names.py", "process_gone_lint.py", "process_gone_cases.py")
SKIPPED = {"tests/%s" % f for f in VENDORED}  # the helpers read signal 0 right; the cases hold the forms on purpose
PIN = TESTS / "process_gone.pin"
find_source = _load("process_gone_lint").find_source
cases = _load("process_gone_cases")
TheScannerFindsTheForms, TheHelpers = cases.TheScannerFindsTheForms, cases.TheHelpers  # they run here too

# "path::function": why its raw signal-0 probe is right as it is.
ALLOWED: dict = {
    "scripts/perf-bench/tests/test_session_real.py::test_the_agents_command_ends_the_cli_types_into_the_shell_and_gives_exit_0":
        "no probe: it saves os.kill in a tuple to put it back after replacing it with a recorder, and never calls it",
    "tests/test_cmux_next_prepush_gate.py::test_a_hook_stopped_by_a_signal_during_a_check_never_says_it_passed":
        "no probe: os.kill(pid, signum) sends the loop's signal.SIGTERM or signal.SIGINT to a running hook",
    "tests/test_verify_cmux_tui_hosted.py::signal_case":
        "no probe: os.kill/os.killpg(pid, signum) send the case's signal, which every caller names as signal.SIGINT, "
        "signal.SIGTERM or signal.SIGHUP",
}
# A file that cannot load tests/process_gone.py (it runs from a scratch copy) carries a copy of these functions of
# tests/process_identity.py, which process_gone answers with. Each must match IDENTITY's own, so a change to one fails
# here until the other follows.
COPIES = {
    "cmux-tui/crates/acpmux/tests/fake_claude_auto.py": ("exists", "_proc_ticks", "status"),
}
IDENTITY = "tests/process_identity.py"
THIS = "tests/test_lint_process_gone_checks.py"


SKIP_DIRS = {".git", "node_modules", "vendor", "ghostty", "ghostty-next", "homebrew-cmux", "build", ".build",
             "target", "dist", "DerivedData", ".venv", "zig-cache", ".zig-cache", "zig-out"}


def python_files(root):
    found = []
    for directory, dirs, files in os.walk(root):
        dirs[:] = sorted(d for d in dirs if d not in SKIP_DIRS)
        found += [(Path(directory) / f).relative_to(root).as_posix() for f in files if f.endswith(".py")]
    return sorted(found)


def is_test_file(rel):
    name = rel.rsplit("/", 1)[-1]
    return (name.startswith("test_") or name.endswith(("_test.py", "-test.py", ".test.py"))
            or "/tests/" in "/" + rel)


def scan(root=ROOT):
    found = {}
    for rel in python_files(root):
        if rel in SKIPPED or rel == THIS or not is_test_file(rel):
            continue  # the vendored helpers and cases; this file
        try:
            source = (root / rel).read_text(encoding="utf-8", errors="replace")
        except OSError:  # a sparse checkout leaves tracked files out
            continue
        for func, line, kind in find_source(source, rel):
            if func in COPIES.get(rel, ()):
                continue  # a copy of the helper, held to it by copy_drift()
            found.setdefault("%s::%s" % (rel, func), []).append(line if kind == "signal 0" else "%s (%s)" % (line, kind))
    return found


def _functions(source, name):
    """{function name: its AST without the docstring} for SOURCE's top-level functions."""
    out = {}
    for node in ast.parse(source, name).body:
        if isinstance(node, ast.FunctionDef):
            body = node.body
            if body and isinstance(body[0], ast.Expr) and isinstance(getattr(body[0], "value", None), ast.Constant):
                body = body[1:]
            out[node.name] = ast.dump(ast.Module(body=body, type_ignores=[]))
    return out


def copy_drift(root=ROOT, copies=None):
    """["path::function"] for each copied helper function that is missing from its copy or differs from the helper."""
    helper = _functions((root / IDENTITY).read_text(encoding="utf-8"), IDENTITY)
    drift = []
    for rel, names in sorted((COPIES if copies is None else copies).items()):
        copy = _functions((root / rel).read_text(encoding="utf-8"), rel)
        drift += ["%s::%s" % (rel, n) for n in names if n not in helper or copy.get(n) != helper[n]]
    return drift


class NoRawSignalZeroProbe(unittest.TestCase):
    def test_every_copy_of_the_helper_matches_it(self):
        self.assertEqual(copy_drift(), [], "a copy of tests/process_identity.py differs from it: change both together")

    def test_no_test_probes_a_process_with_signal_zero(self):
        new = sorted("%s (line %s)" % (k, ", ".join(map(str, v))) for k, v in scan().items() if k not in ALLOWED)
        self.assertEqual(new, [], "a killed process is not gone yet: use process_gone.died(pid), running(pid) or "
                                  "group_died(pgid), or list the test in ALLOWED in tests/test_lint_process_gone_checks.py "
                                  "with why its probe is right")

    def test_no_allowed_entry_is_stale_or_unexplained(self):
        found = scan()
        for key, why in ALLOWED.items():
            with self.subTest(key=key):
                self.assertIn(key, found, "stale: no signal-0 probe left")
                self.assertGreater(len(why), 10)


class ThisRepoScan(unittest.TestCase):
    def test_a_tree_with_a_probe_in_a_test_file_is_red(self):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            (Path(d) / "tests").mkdir()
            (Path(d) / "tests" / "test_x.py").write_text("import os\ndef test_a():\n    os.kill(1, 0)\n")
            (Path(d) / "tool.py").write_text("import os\ndef alive(p):\n    os.kill(p, 0)\n")  # not a test
            self.assertEqual(sorted(scan(Path(d))), ["tests/test_x.py::test_a"])

    def test_a_copy_that_drifts_from_the_helper_is_red(self):
        import tempfile
        helper = "import os\ndef status(pid):\n    \"\"\"doc\"\"\"\n    os.kill(pid, 0)\n    return 'dead'\n"
        with tempfile.TemporaryDirectory() as d:
            (Path(d) / "tests").mkdir()
            (Path(d) / IDENTITY).write_text(helper)
            (Path(d) / "tests" / "fake.py").write_text(helper.replace('"""doc"""', '"""other doc"""'))
            copies = {"tests/fake.py": ("status",)}
            self.assertEqual(copy_drift(Path(d), copies), [])  # the same code under another docstring
            (Path(d) / IDENTITY).write_text(helper.replace("return 'dead'", "return 'alive'"))
            self.assertEqual(copy_drift(Path(d), copies), ["tests/fake.py::status"])  # the helper changed alone
            (Path(d) / "tests" / "fake.py").write_text("import os\n")
            self.assertEqual(copy_drift(Path(d), copies), ["tests/fake.py::status"])  # the copy was dropped

    def test_the_vendored_files_are_the_pinned_copy(self):
        pin = dict(kv.split("=", 1) for kv in PIN.read_text().split())
        self.assertRegex(pin.get("leo-workspace", ""), r"^[0-9a-f]{40}$")
        for f in VENDORED:
            with self.subTest(file=f):
                got = hashlib.sha256((TESTS / f).read_bytes()).hexdigest()
                self.assertEqual(got, pin.get(f), "tests/%s was edited here: change it in leo-workspace tools/%s, "
                                 "then copy it and its commit and sha256 into tests/process_gone.pin" % (f, f))


if __name__ == "__main__":
    unittest.main()
