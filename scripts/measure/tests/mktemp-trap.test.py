#!/usr/bin/env python3
"""Every `mktemp -d` under scripts/measure removes its folder on every exit.

A bench script that makes a scratch folder and removes it only on its last line leaks the folder
when a build fails (ENOSPC, a bench crash, a TERM): four leaked tab-switch workspaces of 13-18 GB
each filled a bench Mac's disk. The rule, checked statically on every script (so a new one cannot
forget it):

  1. A script with `mktemp -d` registers an EXIT trap (or git_fixture_trap_exit) in the same file.
  2. After the `mktemp -d`, no bare `exec CMD`: exec replaces the shell and drops the trap.

Each registration block that also traps TERM and INT (its `mktemp -d` line down to its trap lines) is also run in bash
with an injected failure (a failing command under set -e, exit 3, TERM, INT): the folder must be gone and
the exit code kept (the failure's, 143, 130).

The checker is also run on fixtures that break each rule, and on one that follows them, so a
checker that stops seeing a violation fails here too.
Run: python3 -I scripts/measure/tests/mktemp-trap.test.py
"""
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
MEASURE = ROOT / "scripts" / "measure"

TRAP = re.compile(r"(^|[;&{(]|then|do)\s*trap\s+\S.*\bEXIT\b|\bgit_fixture_trap_exit\b")
EXEC = re.compile(r"^\s*(\w+=\S+\s+)*exec\s+[^\s<>&0-9-]")


def code_lines(text):
    for number, line in enumerate(text.splitlines(), 1):
        if not line.lstrip().startswith("#"):
            yield number, line


def violations(name, text):
    lines = list(code_lines(text))
    made = [n for n, line in lines if re.search(r"\bmktemp\s+-d\b", line)]
    if not made:
        return []
    found = []
    if not any(TRAP.search(line) for _, line in lines):
        found.append(f"{name}:{made[0]}: mktemp -d without an EXIT trap in the same file")
    for n, line in lines:
        if n > made[0] and EXEC.match(line):
            found.append(f"{name}:{n}: exec after mktemp -d drops the EXIT trap")
    return found


FIXTURES = {
    "no-trap": ('out="$(mktemp -d)"\ntrue\nrm -rf "$out"\n', 1),
    "exec-drops-trap": ('out="$(mktemp -d)"\ntrap \'rm -rf "$out"\' EXIT\nexec python3 x.py\n', 1),
    "env-exec-drops-trap": ('out="$(mktemp -d)"\ntrap \'rm -rf "$out"\' EXIT\nFOO=1 exec python3 x.py\n', 1),
    "ok": ('out="$(mktemp -d)"\ntrap \'rm -rf "$out"\' EXIT INT TERM\npython3 x.py\n', 0),
    "ok-no-mktemp": ("echo hi\nexec python3 x.py\n", 0),
    "ok-comment": ("# mktemp -d is described here\necho hi\n", 0),
}


TRAP_LINE = re.compile(r"^\s*trap\s")
INJECTED = [("false", 1), ("exit 3", 3), ("kill -TERM $$; sleep 1", 143), ("kill -INT $$; sleep 1", 130)]


def registration_blocks(text):
    """Every `mktemp -d` line with the trap lines that follow it within 15 lines, as one bash snippet.
    Only blocks that also trap TERM and INT (a script that cleans up on a kill, not only on a plain exit)."""
    lines = text.splitlines()
    for index, line in enumerate(lines):
        if line.lstrip().startswith("#") or not re.search(r"\bmktemp\s+-d\b", line):
            continue
        last = max((i for i in range(index + 1, min(index + 16, len(lines))) if TRAP_LINE.match(lines[i])), default=None)
        block = "\n".join(lines[index:last + 1]) if last is not None else ""
        if "TERM" in block and "INT" in block:
            yield index + 1, "\n".join(lines[index:last + 1])


def run_block(snippet, ending):
    with tempfile.TemporaryDirectory() as sandbox:
        script = f'set -euo pipefail\nroot="$PWD"\n{snippet}\n{ending}\n'
        # This sandbox folder is the only TMPDIR the snippet sees, so what is left in it is what leaked.
        env = dict(os.environ, TMPDIR=sandbox)
        done = subprocess.run(["bash", "-c", script], env=env, cwd=sandbox, capture_output=True, text=True, timeout=60)
        return done.returncode, sorted(os.listdir(sandbox))


def runtime_failures(name, text):
    found = []
    for line, snippet in registration_blocks(text):
        for ending, want in INJECTED:
            code, left = run_block(snippet, ending)
            if left or code != want:
                found.append(f"{name}:{line}: after `{ending}` rc={code} (wanted {want}), left behind {left}")
    return found


RUNTIME_FIXTURE_BAD = 'out="$(mktemp -d)"\ntrap true EXIT\ntrap \'exit 130\' INT\ntrap \'exit 143\' TERM\n'
RUNTIME_FIXTURE_OK = 'out="$(mktemp -d)"\ntrap \'rm -rf -- "$out"\' EXIT\ntrap \'exit 130\' INT\ntrap \'exit 143\' TERM\n'


def main():
    failed = []
    for name, (text, want) in FIXTURES.items():
        got = len(violations(name, text))
        if got != want:
            failed.append(f"fixture {name}: wanted {want} violation(s), got {got}")
    if not runtime_failures("fixture-bad", RUNTIME_FIXTURE_BAD):
        failed.append("runtime fixture without a cleanup trap did not fail")
    for problem in runtime_failures("fixture-ok", RUNTIME_FIXTURE_OK):
        failed.append("runtime fixture that cleans up failed: " + problem)
    scripts = sorted(p for p in MEASURE.rglob("*.sh") if "/tests/" not in p.as_posix())
    scripts += sorted(p for p in MEASURE.rglob("*.py") if "/tests/" not in p.as_posix())
    checked = 0
    for path in scripts:
        text = path.read_text(errors="replace")
        if "mktemp" not in text:
            continue
        checked += 1
        rel = path.relative_to(ROOT).as_posix()
        failed.extend(violations(rel, text))
        failed.extend(runtime_failures(rel, text))
    if checked < 10:
        failed.append(f"only {checked} scripts with mktemp seen: the scan lost its way")
    if failed:
        print("\n".join(failed), file=sys.stderr)
        print(f"FAIL: {len(failed)} problem(s)", file=sys.stderr)
        return 1
    print(f"ok: {checked} scripts with mktemp, every mktemp -d is removed on exit")
    return 0


if __name__ == "__main__":
    sys.exit(main())
