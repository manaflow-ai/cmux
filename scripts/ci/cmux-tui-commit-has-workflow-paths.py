#!/usr/bin/env python3
"""Fail clearly when a commit lacks a repository path that a workflow file runs.

cmux-tui.yml can test a commit other than its own revision
(scripts/verify-cmux-tui-hosted.sh --commit): the workflow file comes from the
integration branch, but every job checks out the tested commit, so the scripts
its steps call and the local actions it uses come from that commit's tree. A
step that calls a script the commit does not have yet would fail late, deep in
a job, with "No such file or directory". validate-inputs runs this first.

Usage: cmux-tui-commit-has-workflow-paths.py <commit> <workflow-file>...

Reads each workflow file as text (no YAML parser: the validate job has only
stdlib Python). Only jobs that check out the tested commit count: a job block
under `jobs:` with a line `ref: ${{ inputs.commit }}` (cmux-tui.yml) or
`ref: ${{ inputs.checkout_ref }}` (cmux-tui-build-package.yml, called with
checkout_ref = the commit). A job that checks out the workflow revision
(validate-inputs runs this file and ensure-gh.sh from there) or nothing, and
keys outside `jobs:`, are not checked: the tested commit need not have those
files. In the counted jobs it collects the repository paths named under scripts/,
.github/actions/, .github/scripts/ and cmux-tui/(dist/)scripts/. A path
written as ../scripts/... (a step in working-directory cmux-tui) or
$(git rev-parse --show-toplevel)/scripts/... counts as scripts/...; a bare
scripts/... may also be cmux-tui/scripts/... (a step in working-directory
cmux-tui), so either one is enough. Comment lines are skipped. `uses: ./.github/actions/<name>` needs
<name>/action.yml or action.yaml. Reusable workflows (.github/workflows/) come
from the workflow's own revision, so they are not checked. Paths holding a
shell or expression variable are not checked.

Reads only trees (`git ls-tree`), so a blob:none partial clone with the
commit fetched is enough. Exit 0: every path is there; 1: some are missing
(each is listed); 2: usage or git error.
"""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

# A path token: not preceded by a path character, so cmux-tui/scripts/x is not
# also read as scripts/x. The prefix group takes ../ ./ or / (after `)`).
PATH_TOKEN = re.compile(
    r"(?<![A-Za-z0-9_./${}-])(\.\./|\./|/)?"
    r"((?:\.github/(?:actions|scripts)|scripts|cmux-tui/(?:dist/)?scripts)/[A-Za-z0-9_./-]*[A-Za-z0-9_/])"
    r"(?![A-Za-z0-9_.$/{-])"
)
LOCAL_ACTION = re.compile(r"uses:\s*\./(\.github/actions/[A-Za-z0-9_.-]+)\s*$")
# A job key directly under `jobs:` (two-space indentation, as every workflow here writes it).
JOB_KEY = re.compile(r"^  ([A-Za-z0-9_-]+):\s*(?:#.*)?$")
TOP_LEVEL_KEY = re.compile(r"^[A-Za-z0-9_-]+:")
TESTED_CHECKOUT = re.compile(r"^\s*ref:\s*\$\{\{\s*inputs\.(?:commit|checkout_ref)\s*\}\}\s*$")


def tested_job_blocks(text: str) -> list[list[str]]:
    """The lines of each job under `jobs:` that checks out the tested commit."""
    blocks: list[list[str]] = []
    current: list[str] | None = None
    in_jobs = False
    for line in text.splitlines():
        if TOP_LEVEL_KEY.match(line):
            in_jobs = line.split(":", 1)[0] == "jobs"
            current = None
            continue
        if not in_jobs:
            continue
        if JOB_KEY.match(line):
            current = []
            blocks.append(current)
            continue
        if current is not None:
            current.append(line)
    return [block for block in blocks if any(TESTED_CHECKOUT.match(line) for line in block)]


def workflow_paths(text: str) -> tuple[set[tuple[str, ...]], set[str]]:
    """Return (paths, action directories) the tested-commit jobs of a workflow name, comments left out.

    Each path is a tuple of alternatives; any one of them in the tree is enough.
    """
    paths: set[tuple[str, ...]] = set()
    actions: set[str] = set()
    for line in (line for block in tested_job_blocks(text) for line in block):
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        action = LOCAL_ACTION.search(stripped)
        if action:
            actions.add(action.group(1))
            continue
        for match in PATH_TOKEN.finditer(line):
            prefix, path = match.group(1), match.group(2)
            if prefix is None and path.startswith("scripts/"):
                paths.add((path, f"cmux-tui/{path}"))
            else:
                paths.add((path,))
    return paths, actions


def tree_entries(commit: str) -> set[str]:
    """Every file path of the commit under the checked prefixes, plus their directories."""
    result = subprocess.run(
        ["git", "ls-tree", "-r", "--name-only", commit, "--",
         "scripts", ".github/actions", ".github/scripts", "cmux-tui/scripts", "cmux-tui/dist/scripts"],
        capture_output=True, text=True, check=False,
    )
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or f"git ls-tree {commit} failed")
    entries: set[str] = set()
    for name in result.stdout.splitlines():
        entries.add(name)
        parts = name.split("/")
        for depth in range(1, len(parts)):
            entries.add("/".join(parts[:depth]) + "/")
    return entries


def missing_paths(commit: str, workflow_files: list[Path]) -> list[str]:
    entries = tree_entries(commit)
    missing: set[str] = set()
    for workflow in workflow_files:
        paths, actions = workflow_paths(workflow.read_text(encoding="utf-8"))
        for alternatives in paths:
            if not any(path in entries or path.rstrip("/") + "/" in entries for path in alternatives):
                missing.add(f"{' or '.join(alternatives)} (named in {workflow.name})")
        for action in actions:
            if f"{action}/action.yml" not in entries and f"{action}/action.yaml" not in entries:
                missing.add(f"{action}/action.yml (uses: ./{action} in {workflow.name})")
    return sorted(missing)


def main(argv: list[str]) -> int:
    if len(argv) < 3 or not re.fullmatch(r"[0-9a-f]{40}", argv[1]):
        print("usage: cmux-tui-commit-has-workflow-paths.py <40-char-commit> <workflow-file>...", file=sys.stderr)
        return 2
    commit = argv[1]
    try:
        missing = missing_paths(commit, [Path(name) for name in argv[2:]])
    except (OSError, RuntimeError) as error:
        print(f"::error::could not read the paths of {commit}: {error}", file=sys.stderr)
        return 2
    if missing:
        print(f"::error::{commit} does not have {len(missing)} path(s) that this workflow runs from the "
              "tested commit's tree; rebase the commit on a newer base, or verify it on its own branch",
              file=sys.stderr)
        for path in missing:
            print(f"  missing: {path}", file=sys.stderr)
        return 1
    print(f"{commit} has every script and local action this workflow runs.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
