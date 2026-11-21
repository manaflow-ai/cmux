#!/usr/bin/env python3
"""A CI check's own timeout is never a failure of the change it judges, unless the change touched what timed out.

A check that turns `subprocess.TimeoutExpired` into a red makes a busy or cold runner look like a broken pull
request: cargo-locks.py under --strict (cmux#41742), generated_files_guard.py's generator --check, car_guards.py's
entries. The fixed shape: retry once with a longer limit, then fail only when the change touched the item that
timed out, and otherwise warn naming it.

This test reads every scripts/ci/*.py and finds each `except ... TimeoutExpired` handler that fails (returns or
exits nonzero, or sets a fail/timeout/error result, a failure count or an errors list) without reading a
changed-paths set (a name with changed, touched, touches or diff in it). Such a handler is either fixed or listed
in ALLOWED with the reason its timeout is the change's own red or no red at all. An ALLOWED entry that no longer
matches fails too, so the list only shrinks.
"""
from __future__ import annotations

import ast
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "scripts" / "ci"

# "file.py:function" -> why its failing timeout handler is right.
ALLOWED: dict[str, str] = {
    "nightly_release_notes.py:<module>": "the nightly publish step judges no change; its timeouts already fall back "
                                         "to a warning inside main, and only a broken publish exits 1",
    "react_doctor_gate.py:main": "it scans only the projects the change touches (--changed-from in "
                                 "cmux-next-react-doctor.yml), so a scan that times out is in a touched project",
    "run_with_timeout.py:main": "a wrapper whose whole job is to end a command at its limit and say so (exit 124); "
                                "its callers decide what a timeout means",
}

FAIL_WORDS = re.compile(r"^(fail|failed|failure|timeout|timed[ -]?out|error|red)$", re.I)
FAIL_NAMES = re.compile(r"fail|error", re.I)
# A name that holds why the check failed: a message assigned to it is the failure.
VERDICT_NAMES = re.compile(r"verdict|fail|error", re.I)
CHANGE_NAMES = re.compile(r"changed|touched|touches|diff", re.I)
EXITS = {"exit", "_exit"}


def catches_timeout(handler: ast.ExceptHandler) -> bool:
    if handler.type is None:
        return False
    names = handler.type.elts if isinstance(handler.type, ast.Tuple) else [handler.type]
    return any((isinstance(n, ast.Attribute) and n.attr == "TimeoutExpired")
               or (isinstance(n, ast.Name) and n.id == "TimeoutExpired") for n in names)


def nonzero(node: ast.AST | None) -> bool:
    return isinstance(node, ast.Constant) and isinstance(node.value, int) and not isinstance(node.value, bool) \
        and node.value != 0


def fail_value(node: ast.AST | None) -> bool:
    """A string like "fail" or "timeout", alone or first in a tuple."""
    if isinstance(node, ast.Tuple) and node.elts:
        node = node.elts[0]
    return isinstance(node, ast.Constant) and isinstance(node.value, str) and bool(FAIL_WORDS.match(node.value))


def target_names(node: ast.AST) -> list[str]:
    if isinstance(node, ast.Name):
        return [node.id]
    if isinstance(node, ast.Attribute):
        return [node.attr]
    if isinstance(node, ast.Subscript):
        return target_names(node.value)
    if isinstance(node, (ast.Tuple, ast.List)):
        return [name for elt in node.elts for name in target_names(elt)]
    return []


def fails(handler: ast.ExceptHandler) -> list[str]:
    """How HANDLER fails the check, one phrase per way."""
    found = []
    for node in (n for stmt in handler.body for n in ast.walk(stmt)):
        if isinstance(node, ast.Return) and (nonzero(node.value) or fail_value(node.value)):
            found.append(f"returns {ast.unparse(node.value)}")
        elif isinstance(node, ast.Call):
            func = node.func
            name = func.attr if isinstance(func, ast.Attribute) else func.id if isinstance(func, ast.Name) else ""
            if name in EXITS and node.args and nonzero(node.args[0]):
                found.append(f"calls {ast.unparse(node)}")
            elif name == "SystemExit" and node.args and nonzero(node.args[0]):
                found.append(f"raises {ast.unparse(node)}")
            elif name in ("append", "extend") and isinstance(func, ast.Attribute) \
                    and any(FAIL_NAMES.search(t) for t in target_names(func.value)):
                found.append(f"adds to {ast.unparse(func.value)}")
        elif isinstance(node, ast.Assign) and fail_value(node.value):
            found.append(f"sets {', '.join(ast.unparse(t) for t in node.targets)} = {ast.unparse(node.value)}")
        elif isinstance(node, ast.Assign) and (isinstance(node.value, ast.JoinedStr) or (
                isinstance(node.value, ast.Constant) and isinstance(node.value.value, str))) \
                and any(VERDICT_NAMES.search(t) for tgt in node.targets for t in target_names(tgt)):
            found.append(f"sets {ast.unparse(node.targets[0])} to a failure message")
        elif isinstance(node, ast.AugAssign) and any(FAIL_NAMES.search(t) for t in target_names(node.target)):
            found.append(f"counts {ast.unparse(node.target)}")
        elif isinstance(node, ast.Assign) and isinstance(node.value, ast.Constant) and node.value.value is True \
                and any(FAIL_NAMES.search(t) for tgt in node.targets for t in target_names(tgt)):
            found.append(f"sets {ast.unparse(node.targets[0])} = True")
    return found


def consults_changes(handler: ast.ExceptHandler) -> bool:
    return any(CHANGE_NAMES.search(name)
               for stmt in handler.body for node in ast.walk(stmt)
               for name in ([node.id] if isinstance(node, ast.Name) else
                            [node.attr] if isinstance(node, ast.Attribute) else
                            [node.arg] if isinstance(node, ast.keyword) and node.arg else []))


def failing_handlers(path: Path) -> dict[str, list[str]]:
    """{"file.py:function": [how it fails, ...]} for each failing timeout handler in PATH that reads no change set."""
    tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
    found: dict[str, list[str]] = {}

    def visit(node: ast.AST, where: str) -> None:
        for child in ast.iter_child_nodes(node):
            inner = f"{where}.{child.name}" if where and isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef,
                                                                             ast.ClassDef)) \
                else child.name if isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)) else where
            if isinstance(child, ast.ExceptHandler) and catches_timeout(child) and not consults_changes(child):
                how = fails(child)
                if how:
                    found.setdefault(f"{path.name}:{where or '<module>'}", []).extend(how)
            visit(child, inner)

    visit(tree, "")
    return found


def scan(directory: Path = SCRIPTS) -> dict[str, list[str]]:
    found: dict[str, list[str]] = {}
    for path in sorted(directory.glob("*.py")):
        found.update(failing_handlers(path))
    return found


class TimeoutHandlers(unittest.TestCase):
    def test_no_ci_script_turns_its_own_timeout_into_a_failure(self):
        found = scan()
        unlisted = {key: how for key, how in found.items() if key not in ALLOWED}
        self.assertEqual(unlisted, {}, "these TimeoutExpired handlers fail the check without asking whether the "
                         "change touched what timed out: retry once with a longer limit, fail only when the change "
                         "touched it, warn otherwise (cmux#41742), or list the handler in ALLOWED with a reason")

    def test_every_allowed_handler_still_exists_and_still_fails(self):
        found = scan()
        self.assertEqual(sorted(key for key in ALLOWED if key not in found), [],
                         "ALLOWED lists handlers that no longer fail on a timeout: drop them")
        self.assertTrue(all(reason.strip() for reason in ALLOWED.values()), "every ALLOWED entry needs a reason")

    def test_the_detector_tells_the_shapes_apart(self):
        import tempfile
        cases = {
            "bad_status.py": ("import subprocess\ndef run_one():\n    try:\n        subprocess.run(['x'], timeout=1)\n"
                              "    except subprocess.TimeoutExpired:\n        status = 'timeout'\n    return status\n"),
            "bad_exit.py": ("import subprocess, sys\ndef main():\n    try:\n        subprocess.run(['x'], timeout=1)\n"
                            "    except (OSError, subprocess.TimeoutExpired):\n        sys.exit(2)\n"),
            "bad_errors.py": ("import subprocess\ndef check(errors):\n    try:\n        subprocess.run(['x'], timeout=1)\n"
                              "    except subprocess.TimeoutExpired as e:\n        errors.append(str(e))\n"),
            "good_touched.py": ("import subprocess\ndef run_one(touched):\n    try:\n        subprocess.run(['x'], timeout=1)\n"
                                "    except subprocess.TimeoutExpired:\n        status = 'fail' if touched else 'warn'\n"
                                "    return status\n"),
            "bad_verdict.py": ("import subprocess\ndef regenerated(command):\n    try:\n        subprocess.run(['x'], timeout=1)\n"
                               "    except (OSError, subprocess.TimeoutExpired) as error:\n"
                               "        verdict = f'{command} did not finish: {error}'\n    return verdict\n"),
            "good_retry.py": ("import subprocess\ndef run_one():\n    try:\n        subprocess.run(['x'], timeout=1)\n"
                              "    except subprocess.TimeoutExpired:\n        return None\n"),
        }
        with tempfile.TemporaryDirectory() as tmp:
            for name, text in cases.items():
                (Path(tmp) / name).write_text(text, encoding="utf-8")
            found = scan(Path(tmp))
        self.assertEqual(sorted(found), ["bad_errors.py:check", "bad_exit.py:main", "bad_status.py:run_one",
                                       "bad_verdict.py:regenerated"])


if __name__ == "__main__":
    unittest.main()
