#!/usr/bin/env python3
"""Advisory checks for the files one agent edit touched (Claude Code and Codex PostToolUse).

Reads the hook payload on stdin and, for the edited paths only, prints a warning with the fix:

  workflow    a .github workflow or action file that does not parse as YAML, or that actionlint
              rejects (when actionlint is on PATH; CI runs it on every workflow)
  test-reg    a new tests/test_*.py with no tests/test-execution.toml entry (CI's registry check
              fails the pull request that adds an unregistered test)
  god-file    a CmuxNext Swift or cmux-tui Rust file this edit grew past check-no-godfiles.sh's
              line cap (a file that was already over the cap warns only when it grows)

It never fails and never blocks the edit: every problem is a warning on stderr, and the exit status
is always 0. Files the edit did not touch are never looked at, and nothing depends on the date.

  bash scripts/ci/check-post-edit.sh < payload.json      # what the hooks run
  python3 scripts/ci/post_edit_checks.py --paths A B     # check paths directly
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

PATH_KEYS = {"file_path", "filePath", "path", "filename", "target_file", "targetFile"}
# apply_patch-style tools carry their paths only in the patch text.
PATCH_PATH = re.compile(r"\*\*\* (?:Add|Update) File: ([^\n\\\"]+)")
WORKFLOW = re.compile(r"^\.github/(?:workflows/[^/]+|actions/.+/action)\.ya?ml$")
NEW_TEST = re.compile(r"^tests/test_[A-Za-z0-9_.-]+\.py$")
REGISTRY = "tests/test-execution.toml"
ACTIONLINT_SECONDS = 8
MAX_LINES_SHOWN = 8
# scripts/cmux-next/check-no-godfiles.sh's per-file line caps.
SWIFT_SCOPE, SWIFT_LIMIT, SWIFT_TEST_LIMIT = "Packages/macOS/CmuxNext/", 400, 600
RUST_SCOPE, RUST_LIMIT, RUST_TEST_LIMIT = "cmux-tui/", 1000, 1500


def payload_paths(raw: str) -> set[str]:
    try:
        payload = json.loads(raw)
    except (TypeError, ValueError):
        payload = {}
    found: set[str] = set()

    def visit(value):
        if isinstance(value, dict):
            for key, child in value.items():
                if key in PATH_KEYS and isinstance(child, str):
                    found.add(child)
                else:
                    visit(child)
        elif isinstance(value, list):
            for child in value:
                visit(child)

    visit(payload)
    found.update(match.group(1).strip() for match in PATCH_PATH.finditer(raw))
    return found


def relative(root: Path, path: str) -> str | None:
    if os.path.isabs(path):
        try:
            path = os.path.relpath(os.path.realpath(path), root)
        except ValueError:
            return None
    path = os.path.normpath(path)
    if path.startswith("..") or not (root / path).is_file():
        return None
    return path


def git(root: Path, *args: str) -> subprocess.CompletedProcess:
    return subprocess.run(["git", "-C", str(root), *args], capture_output=True, text=True, timeout=5)


def head_text(root: Path, path: str) -> str | None:
    """The file at HEAD, or None when HEAD does not have it."""
    try:
        shown = git(root, "show", f"HEAD:{path}")
    except (OSError, subprocess.SubprocessError):
        return None
    return shown.stdout if shown.returncode == 0 else None


def check_workflow(root: Path, path: str) -> list[str]:
    text = (root / path).read_text(encoding="utf-8", errors="replace")
    try:
        import yaml
    except ImportError:
        yaml = None
    if yaml is not None:
        try:
            yaml.safe_load(text)
        except yaml.YAMLError as error:
            mark = getattr(error, "problem_mark", None)
            where = f"{path}:{mark.line + 1}" if mark is not None else path
            problem = getattr(error, "problem", None) or str(error).splitlines()[0]
            return [f"{where}: the YAML does not parse ({problem}); GitHub will not run this workflow."]
    actionlint = shutil.which("actionlint")
    if actionlint is None or not path.startswith(".github/workflows/"):
        return []
    try:
        # CI's "Lint every workflow" step gates on shellcheck warnings and errors only.
        env = {**os.environ, "SHELLCHECK_OPTS": os.environ.get("SHELLCHECK_OPTS", "-S warning")}
        result = subprocess.run([actionlint, "-no-color", "-oneline", path], cwd=root, capture_output=True,
                                text=True, timeout=ACTIONLINT_SECONDS, env=env)
    except subprocess.TimeoutExpired:
        return []
    except OSError:
        return []
    if result.returncode == 0:
        return []
    lines = [line for line in result.stdout.splitlines() if line.strip()]
    if not lines:
        return []
    shown = lines[:MAX_LINES_SHOWN]
    more = [f"... and {len(lines) - len(shown)} more"] if len(lines) > len(shown) else []
    return [f"{path}: actionlint found {len(lines)} problem(s); CI's actionlint guard rejects them "
            f"(rerun: actionlint {path}):", *("  " + line for line in shown + more)]


def check_test_registration(root: Path, path: str) -> list[str]:
    if head_text(root, path) is not None:
        return []  # not new: a test the base already carries is the registry check's warning, not this edit's
    try:
        registry = (root / REGISTRY).read_text(encoding="utf-8")
    except OSError:
        return []
    if re.search(r'^\s*path\s*=\s*"' + re.escape(path) + r'"', registry, re.M):
        return []
    return [f"{path} is a new test with no {REGISTRY} entry; CI fails a pull request that adds one. "
            f"Run it from a workflow step (ci-guards.yml), then: python3 scripts/ci/validate_test_execution_registry.py "
            f"--write --only {path}"]


def god_file_limit(path: str) -> int | None:
    if path.startswith(SWIFT_SCOPE) and path.endswith(".swift"):
        return SWIFT_TEST_LIMIT if "/Tests/" in path else SWIFT_LIMIT
    if path.startswith(RUST_SCOPE) and path.endswith(".rs"):
        test = "/tests/" in path or path.endswith(("_test.rs", "_tests.rs", "/tests.rs"))
        return RUST_TEST_LIMIT if test else RUST_LIMIT
    return None


def check_god_file(root: Path, path: str) -> list[str]:
    limit = god_file_limit(path)
    if limit is None:
        return []
    lines = (root / path).read_text(encoding="utf-8", errors="replace").count("\n")
    before = head_text(root, path)
    was = before.count("\n") if before is not None else 0
    if lines <= limit or lines <= was:
        return []
    past = f"was {was} at HEAD" if before is not None else "new file"
    return [f"{path} is {lines} lines, over the {limit}-line cap ({past}); scripts/cmux-next/check-no-godfiles.sh "
            "fails a pull request that grows a file past it. Split it by responsibility."]


def run(root: Path, paths: set[str], stream) -> int:
    warned = 0
    for raw in sorted(paths):
        path = relative(root, raw)
        if path is None:
            continue
        found: list[str] = []
        try:
            if WORKFLOW.match(path):
                found += check_workflow(root, path)
            if NEW_TEST.match(path):
                found += check_test_registration(root, path)
            found += check_god_file(root, path)
        except (OSError, UnicodeError, subprocess.SubprocessError) as error:
            found.append(f"{path}: post-edit check could not finish ({error}); CI still checks it.")
        for line in found:
            print(("warning: " if not line.startswith("  ") else "") + line, file=stream)
        warned += bool(found)
    return warned


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", default=None)
    parser.add_argument("--paths", nargs="*", default=None, help="check these paths instead of a stdin payload")
    args = parser.parse_args(argv)
    try:
        root = Path(args.root or git(Path.cwd(), "rev-parse", "--show-toplevel").stdout.strip()).resolve()
        paths = set(args.paths) if args.paths is not None else payload_paths(sys.stdin.read())
        run(root, paths, sys.stderr)
    except Exception as error:  # noqa: BLE001 - a post-edit hook is advisory and never fails the edit
        print(f"warning: post-edit checks could not run ({error})", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
