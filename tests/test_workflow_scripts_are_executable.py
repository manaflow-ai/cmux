#!/usr/bin/env python3
"""A repository script a workflow runs by path (`./scripts/x.sh ARGS`) is executable in git.

cmux#25442's first DEV run (40320904962, 2026-10-26) failed in sign with
"./scripts/ci/rcodesign-sign-bundle-dev.sh: Permission denied" (exit 126): the
script landed with mode 100644, and its fixture test ran it through bash, so
nothing caught it before main. This test reads every workflow's `run:` lines,
finds each `./path` in a command position (the start of a line or after `;`,
`&&`, `||`, `|`, `$(`, `!`, a reserved word such as `if`, `then`, `while` or
`do`, or a wrapper such as `time`, `env`, `exec` or `timeout N`), after any
`NAME=value` prefixes, and fails when that path is a tracked file whose mode
in the index is not 100755. A path
given to an interpreter (`bash ./x.sh`, `python3 x.py`, `source ./x.sh`) is
not a command position and needs no bit. Modes come from `git ls-files -s`,
not the working tree, because the index is what a checkout restores.
"""

from __future__ import annotations

import re
import subprocess
import sys
import unittest
from pathlib import Path

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


def violations(modes: dict[str, str], workflows: dict[str, str]) -> list[str]:
    problems = []
    for name, text in sorted(workflows.items()):
        for number, path in direct_scripts(text):
            mode = modes.get(path)
            if mode is not None and mode != "100755":
                problems.append(f"{name}:{number}: ./{path} is run directly but its git mode is {mode}, not 100755 "
                                f"(git update-index --chmod=+x {path})")
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
        workflow = {"w.yml": "run: ./a.sh\nrun: ./b.sh\nrun: ./untracked.sh\n"}
        problems = violations(modes, workflow)
        self.assertEqual(len(problems), 1)
        self.assertIn("./a.sh", problems[0])


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
    count = sum(len(direct_scripts(text)) for text in workflows.values())
    print(f"PASS: {count} directly run scripts in {len(workflows)} workflows are executable")
    return 0


if __name__ == "__main__":
    sys.exit(main())
