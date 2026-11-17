#!/usr/bin/env python3
"""A repository script a workflow runs by path (`./scripts/x.sh ARGS`) is executable in git.

cmux#25442's first DEV run (40320904962, 2026-10-26) failed in sign with
"./scripts/ci/rcodesign-sign-bundle-dev.sh: Permission denied" (exit 126): the
script landed with mode 100644, and its fixture test ran it through bash, so
nothing caught it before main. This test reads every workflow's steps, finds
each `./path` in a command position of a `run:` script (the start of a line or
after `;`, `&&`, `||`, `|`, `$(`, `!`, a reserved word such as `if`, `then`,
`while` or `do`, or a wrapper such as `time`, `env`, `exec` or `timeout N`),
after any `NAME=value` prefixes, resolves it against the step's working
directory (the step's `working-directory`, else the job's, else the
workflow's `defaults.run`), and fails when that path is a tracked file whose
mode in the index is not 100755. A path given to an interpreter (`bash ./x.sh`,
`python3 x.py`, `source ./x.sh`) is not a command position and needs no bit.
A working directory built from another expression than `github.workspace` is
not resolved, and a `cd` inside the script is not followed. Modes come from
`git ls-files -s`, not the working tree, because the index is what a checkout
restores.
"""

from __future__ import annotations

import posixpath
import re
import subprocess
import sys
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github/workflows"

# A `./path` that the shell runs as the command itself.
POSITION = r"""(?:^|[;&|(`!{]|\$\(|\b(?:if|elif|then|else|while|until|do|time|env|exec|nohup)\b|\btimeout\s+\S+|run:)"""
ASSIGNMENTS = r"""(?:\s*[A-Za-z_][A-Za-z0-9_]*=(?:"[^"]*"|'[^']*'|[^\s;&|"'`()]*)(?=\s))*"""
COMMAND = re.compile(POSITION + ASSIGNMENTS + r"""\s*["']?\./([A-Za-z0-9_.][A-Za-z0-9_./-]*)""")


def direct_scripts(text: str) -> list[tuple[int, str]]:
    """(line number, repo path) for each `./path` in a command position."""
    found = []
    for number, line in enumerate(text.splitlines(), 1):
        if line.lstrip().startswith("#"):
            continue
        for match in COMMAND.finditer(line):
            found.append((number, match.group(1).rstrip("\"'")))
    return found


def tracked_modes() -> dict[str, str]:
    out = subprocess.run(["git", "-C", str(ROOT), "ls-files", "-s"], capture_output=True, text=True, check=True).stdout
    modes = {}
    for line in out.splitlines():
        meta, path = line.split("\t", 1)
        modes[path] = meta.split()[0]
    return modes


WORKSPACE = re.compile(r"^(?:\$\{\{\s*github\.workspace\s*\}\}|\$\{?GITHUB_WORKSPACE\}?)/?")


def working_directory(*candidates: object) -> str | None:
    """The repo-relative directory of the first candidate set; None when an expression hides it."""
    for value in candidates:
        if isinstance(value, str) and value.strip():
            value = WORKSPACE.sub("", value.strip())
            if "${{" in value or "$" in value:
                return None
            return posixpath.normpath(value) if value else "."
    return "."


def defaults_dir(node: object) -> object:
    if not isinstance(node, dict):
        return None
    return ((node.get("defaults") or {}).get("run") or {}).get("working-directory")


def run_steps(text: str) -> tuple[list[tuple[str, str, str]], int]:
    """(where, working directory, run script) for each step with `run:`, and how many steps were not resolved."""
    workflow = yaml.safe_load(text) or {}
    steps, unresolved = [], 0
    for job_id, job in (workflow.get("jobs") or {}).items():
        if not isinstance(job, dict):
            continue
        for index, step in enumerate(job.get("steps") or []):
            if not isinstance(step, dict) or not isinstance(step.get("run"), str):
                continue
            directory = working_directory(step.get("working-directory"), defaults_dir(job), defaults_dir(workflow))
            if directory is None:
                unresolved += 1
                continue
            where = f"jobs.{job_id}.steps[{index}]" + (f" ({step['name']})" if step.get("name") else "")
            steps.append((where, directory, step["run"]))
    return steps, unresolved


def violations(modes: dict[str, str], workflows: dict[str, str]) -> list[str]:
    problems = []
    for name, text in sorted(workflows.items()):
        for where, directory, script in run_steps(text)[0]:
            for number, relative in direct_scripts(script):
                path = posixpath.normpath(posixpath.join(directory, relative))
                mode = modes.get(path)
                if mode is not None and mode != "100755":
                    problems.append(f"{name} {where} line {number} of run: ./{relative} ({path}) is run directly "
                                    f"but its git mode is {mode}, not 100755 (git update-index --chmod=+x {path})")
    return problems


class SelfTest(unittest.TestCase):
    def test_command_positions(self) -> None:
        text = "\n".join([
            "        run: ./a.sh x",
            "          ./b.sh \"$APP\"",
            "          out=\"$(./c.sh)\"",
            "          true && ./d.sh",
            "          if x; then ./e.sh; fi",
            "          timeout 30 ./f.sh",
            "          bash ./g.sh",
            "          python3 ./h.py",
            "          source ./i.sh",
            "          . ./j.sh",
            "          # ./k.sh",
            "          cp ./l.sh out/",
            "          CMUX_TAG=cistream ./m.sh",
            "          A=1 B=\"x y\" ./n.sh",
            "          if ./o.sh; then :; fi",
            "          while ./p.sh; do :; done",
            "          ! ./q.sh",
            "          env X=1 ./r.sh",
            "          out=\"$(FOO=1 ./s.sh)\"",
            "          X=./t.sh",
            "          [[ -x ./u.sh ]]",
            "          [[ a != ./v.sh ]]",
            "          version=\"$(bash ./w.sh)\"",
            "          ID=\"$(bash ./x.sh \"$1\")\"",
        ])
        self.assertEqual([path for _, path in direct_scripts(text)],
                         ["a.sh", "b.sh", "c.sh", "d.sh", "e.sh", "f.sh", "m.sh", "n.sh", "o.sh", "p.sh", "q.sh",
                          "r.sh", "s.sh"])

    def test_flags_only_tracked_non_executable(self) -> None:
        modes = {"a.sh": "100644", "b.sh": "100755"}
        workflow = {"w.yml": "jobs:\n  j:\n    steps:\n      - run: ./a.sh\n      - run: ./b.sh\n"
                             "      - run: ./untracked.sh\n"}
        problems = violations(modes, workflow)
        self.assertEqual(len(problems), 1)
        self.assertIn("./a.sh", problems[0])

    def test_working_directory(self) -> None:
        modes = {"web/scripts/t.sh": "100644", "app/u.sh": "100644", "v.sh": "100644", "w.sh": "100644",
                 "scripts/t.sh": "100755"}
        workflow = {"w.yml": """
defaults:
  run:
    working-directory: web
jobs:
  a:
    steps:
      - run: ./scripts/t.sh
  b:
    defaults:
      run:
        working-directory: app
    steps:
      - run: ./u.sh
      - run: ./v.sh
        working-directory: .
      - run: ./w.sh
        working-directory: ${{ github.workspace }}
      - run: ./x.sh
        working-directory: ${{ matrix.dir }}
"""}
        problems = violations(modes, workflow)
        self.assertEqual([problem.split(" is run")[0].split("run: ", 1)[1] for problem in problems],
                         ["./scripts/t.sh (web/scripts/t.sh)", "./u.sh (app/u.sh)", "./v.sh (v.sh)", "./w.sh (w.sh)"])
        self.assertEqual(run_steps(workflow["w.yml"])[1], 1)


def main() -> int:
    suite = unittest.TestLoader().loadTestsFromTestCase(SelfTest)
    if not unittest.TextTestRunner(stream=sys.stderr, verbosity=0).run(suite).wasSuccessful():
        return 1
    workflows = {path.name: path.read_text() for path in sorted(WORKFLOWS.glob("*.y*ml"))}
    problems = violations(tracked_modes(), workflows)
    for problem in problems:
        print(f"FAIL: {problem}", file=sys.stderr)
    if problems:
        return 1
    steps = [run_steps(text) for text in workflows.values()]
    count = sum(len(direct_scripts(script)) for found, _ in steps for _, _, script in found)
    unresolved = sum(skipped for _, skipped in steps)
    print(f"PASS: {count} directly run scripts in {len(workflows)} workflows are executable "
          f"({unresolved} steps with an expression working directory not checked)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
