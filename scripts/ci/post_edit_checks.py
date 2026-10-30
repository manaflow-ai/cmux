#!/usr/bin/env python3
"""Advisory checks for the files one agent edit touched (Claude Code and Codex PostToolUse).

Reads the hook payload on stdin and, for the edited paths only, reports what CI would flag, with
the fix:

  workflow    a .github workflow or action file that does not parse as YAML, or a workflow in which
              the local actionlint finds a problem the HEAD version of the file does not have
  test-reg    a new (untracked) tests/test_*.py with no tests/test-execution.toml entry (CI's registry check
              fails the pull request that adds an unregistered test)
  god-file    a CmuxNext Swift or cmux-tui Rust file that grew in lines against HEAD and that
              scripts/cmux-next/check-no-godfiles.sh, run on that file with CI's 20% warning slack,
              flags (its line, function and top-level type limits). Not covered: Swift god types
              (named Module/Type, which span files) and a Rust edit that adds functions without
              adding lines; CI still checks both.

Output: exactly one JSON object on stdout, which both hook runners read. With findings it carries
them as PostToolUse `additionalContext`, so the agent sees them; otherwise it is `{}`. A readable
copy goes to stderr. The exit status is always 0: an edit is never blocked. Files the edit did not
touch are never checked, nothing depends on the date, and the whole run stops after DEADLINE_SECONDS.

  bash scripts/ci/check-post-edit.sh < payload.json      # what the hooks run
  python3 scripts/ci/post_edit_checks.py --paths A B     # check paths directly
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path

PATH_KEYS = {"file_path", "filePath", "path", "filename", "target_file", "targetFile"}
# apply_patch-style tools carry their paths only in the patch text.
PATCH_PATH = re.compile(r"\*\*\* (?:Add File|Update File|Move to): ([^\n\\\"]+)")
WORKFLOW = re.compile(r"^\.github/(?:workflows/[^/]+|actions/.+/action)\.ya?ml$")
NEW_TEST = re.compile(r"^tests/test_[A-Za-z0-9_.-]+\.py$")
# The files check-no-godfiles.sh measures (it skips untracked and excluded Rust paths itself).
GOD_FILE = re.compile(r"^(?:Packages/macOS/CmuxNext/(?:Sources|Tests)/.+\.swift|cmux-tui/.+\.rs)$")
GOD_FILE_SCRIPT = "scripts/cmux-next/check-no-godfiles.sh"
# check-no-godfiles.sh lines that are about the base, not this edit.
GOD_FILE_NOTE = re.compile(r"on the base too|did not grow|now meets the budget|shrank to|is gone|--update-baseline")
REGISTRY = "tests/test-execution.toml"
# The hooks give this script 15 s; leave room to print.
DEADLINE_SECONDS = 12.0
MAX_LINES_SHOWN = 8
# actionlint -oneline: "path:line:col: message [rule]".
ACTIONLINT_LINE = re.compile(r"^[^:]+:\d+:\d+: (?P<message>.*)$")


class Budget:
    def __init__(self, seconds: float):
        self.end = time.monotonic() + seconds

    def left(self) -> float:
        return self.end - time.monotonic()


def payload_paths(raw: str) -> tuple[set[str], str | None]:
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
    cwd = payload.get("cwd") if isinstance(payload, dict) and isinstance(payload.get("cwd"), str) else None
    return found, cwd


def relative(root: Path, path: str, cwd: str | None) -> str | None:
    if not os.path.isabs(path) and cwd:
        path = os.path.join(cwd, path)
    if os.path.isabs(path):
        try:
            path = os.path.relpath(os.path.realpath(path), root)
        except ValueError:
            return None
    path = os.path.normpath(path)
    if path.startswith("..") or not (root / path).is_file():
        return None
    return path


def run_tool(argv: list[str], root: Path, budget: Budget, *, cap: float = 8.0, stdin: str | None = None,
             env: dict | None = None) -> subprocess.CompletedProcess | None:
    timeout = min(cap, budget.left())
    if timeout <= 0.5:
        return None
    try:
        # Its own process group, so a timeout kills every child (a pipeline the tool started too).
        proc = subprocess.Popen(argv, cwd=root, stdin=subprocess.PIPE if stdin is not None else subprocess.DEVNULL,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env,
                                start_new_session=True)
    except OSError:
        return None
    try:
        out, err = proc.communicate(stdin, timeout=timeout)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except OSError:
            pass
        proc.communicate()
        return None
    return subprocess.CompletedProcess(argv, proc.returncode, out, err)


# head_text(): HEAD has no such file, or git did not answer in time.
ABSENT, UNKNOWN = object(), object()


def head_text(root: Path, path: str, budget: Budget):
    """The file at HEAD, ABSENT when HEAD does not have it, or UNKNOWN when git did not answer."""
    shown = run_tool(["git", "show", f"HEAD:{path}"], root, budget, cap=8)
    if shown is None:
        return UNKNOWN
    return shown.stdout if shown.returncode == 0 else ABSENT


def actionlint_messages(root: Path, path: str, text: str, budget: Budget) -> list[str] | None:
    actionlint = shutil.which("actionlint")
    if actionlint is None:
        return None
    # CI's "Lint every workflow" step gates on shellcheck warnings and errors only.
    env = {**os.environ, "SHELLCHECK_OPTS": os.environ.get("SHELLCHECK_OPTS", "-S warning")}
    result = run_tool([actionlint, "-no-color", "-oneline", "-stdin-filename", path, "-"], root, budget,
                      stdin=text, env=env)
    if result is None or result.returncode not in (0, 1):
        return None
    return [line for line in result.stdout.splitlines() if line.strip()]


def check_workflow(root: Path, path: str, budget: Budget) -> list[str]:
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
    if not path.startswith(".github/workflows/"):
        return []
    now = actionlint_messages(root, path, text, budget)
    if not now:
        return []
    # Only what this change added: a local actionlint older or newer than CI's pinned one, or a
    # finding already on the base, must not warn about lines the edit never touched.
    before_text = head_text(root, path, budget)
    if before_text is UNKNOWN:
        return []  # no base to compare with: every pre-existing finding would look new
    before = actionlint_messages(root, path, before_text, budget) if before_text is not ABSENT else []
    if before is None:
        return []
    def message(line):
        match = ACTIONLINT_LINE.match(line)
        return match.group("message") if match else line
    seen = [message(line) for line in before]
    new = []
    for line in now:
        if message(line) in seen:
            seen.remove(message(line))
        else:
            new.append(line)
    if not new:
        return []
    shown = new[:MAX_LINES_SHOWN]
    more = [f"... and {len(new) - len(shown)} more"] if len(new) > len(shown) else []
    return [f"{path}: actionlint found {len(new)} new problem(s); CI's \"Lint every workflow\" guard rejects them "
            f"(rerun: actionlint {path}):", *("  " + line for line in shown + more)]


def check_test_registration(root: Path, path: str, budget: Budget) -> list[str]:
    # Not new once git knows it (the index is read without touching the object store, which is
    # slow in a clone with many packs): a test the base already carries is the registry check's
    # warning, and the pre-commit hook registers a staged one.
    tracked = run_tool(["git", "ls-files", "--error-unmatch", "--", path], root, budget, cap=5)
    if tracked is None or tracked.returncode == 0:
        return []
    try:
        registry = (root / REGISTRY).read_text(encoding="utf-8")
    except OSError:
        return []
    if re.search(r'^\s*path\s*=\s*"' + re.escape(path) + r'"', registry, re.M):
        return []
    return [f"{path} is a new test with no {REGISTRY} entry; CI fails a pull request that adds one. "
            f"Run it from a workflow step (ci-guards.yml), then: python3 scripts/ci/validate_test_execution_registry.py "
            f"--write --only {path}"]


def check_god_file(root: Path, path: str, budget: Budget) -> list[str]:
    if not GOD_FILE.match(path) or not (root / GOD_FILE_SCRIPT).is_file():
        return []
    # Only an edit that grew the file: debt it did not add is CI's warning, not this edit's.
    before = head_text(root, path, budget)
    if before is UNKNOWN:
        return []
    lines = (root / path).read_text(encoding="utf-8", errors="replace").count("\n")
    if before is not ABSENT and lines <= before.count("\n"):
        return []
    # Without --base: scoped to one file the script takes well under a second, while --base archives
    # all of CmuxNext and cmux-tui at HEAD when anything fails. NO_BLAME skips its history walk.
    env = {**os.environ, "GODFILES_WARN_SLACK": "20", "GODFILES_NO_BLAME": "1"}
    result = run_tool(["bash", GOD_FILE_SCRIPT, "--file", path], root, budget, env=env)
    if result is None:
        return []
    # This file's own findings (the script names CmuxNext files from the package root).
    name = path.removeprefix("Packages/macOS/CmuxNext/")
    found = []
    for line in (result.stdout + result.stderr).splitlines():
        if name not in line or GOD_FILE_NOTE.search(line):
            continue
        if line.startswith("::warning title=ratchet debt::"):
            found.append(f"{line.split('::', 2)[2]}: CI reports this as ratchet debt and fails it past +20%; "
                         "split the file by responsibility.")
        elif result.returncode != 0:
            found.append(f"{line}: CI's god-file check fails this; split the file by responsibility.")
    return found


def run(root: Path, paths: set[str], cwd: str | None, budget: Budget) -> list[str]:
    found: list[str] = []
    for raw in sorted(paths):
        if budget.left() <= 0.5:
            # stderr only: a timeout is not something the agent can fix in its change.
            print("post-edit checks ran out of time; CI still checks the remaining files.", file=sys.stderr)
            break
        path = relative(root, raw, cwd)
        if path is None:
            continue
        try:
            if WORKFLOW.match(path):
                found += check_workflow(root, path, budget)
            if NEW_TEST.match(path):
                found += check_test_registration(root, path, budget)
            found += check_god_file(root, path, budget)
        except (OSError, UnicodeError, subprocess.SubprocessError) as error:
            found.append(f"{path}: post-edit check could not finish ({error}); CI still checks it.")
    return found


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", default=None)
    parser.add_argument("--paths", nargs="*", default=None, help="check these paths instead of a stdin payload")
    args = parser.parse_args(argv)
    found: list[str] = []
    try:
        budget = Budget(DEADLINE_SECONDS)
        root = Path(args.root) if args.root else Path(subprocess.run(
            ["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True, timeout=5).stdout.strip())
        if args.paths is not None:
            paths, cwd = set(args.paths), None
        else:
            paths, cwd = payload_paths(sys.stdin.read())
        found = run(root.resolve(), paths, cwd, budget)
    except Exception as error:  # noqa: BLE001 - a post-edit hook is advisory and never fails the edit
        found = [f"post-edit checks could not run ({error})"]
    if found:
        text = "\n".join(line if line.startswith("  ") else f"warning: {line}" for line in found)
        print(text, file=sys.stderr)
        print(json.dumps({"hookSpecificOutput": {
            "hookEventName": "PostToolUse",
            "additionalContext": "cmux post-edit checks (advisory, edited files only):\n" + text}}))
    else:
        print("{}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
