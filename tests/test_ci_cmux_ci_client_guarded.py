#!/usr/bin/env python3
"""Every workflow step that runs the build-fleet client checks it is installed.

A gateway runner hands work to the build fleet with `~/.local/bin/cmux-ci`. On
a gateway without the client the shell exits 127 ("command not found"), and a
step that maps exit codes to verdicts can read that as one: fleet-compile-check
on cmux17 (run 39573725240) posted "The app did not compile" for a commit that
compiles. So a step resolves the client once, checks it, and leaves before the
call when it is missing, saying so with the runner's name:

    client="${CMUX_CI_CLIENT:-$HOME/.local/bin/cmux-ci}"
    if ! [[ -x "$client" ]]; then
      ...what a missing client means for this step...
      exit N
    fi
    "$client" run ...

The gateway jobs check nothing out, so the guard cannot live in a repository
script or local action without adding a checkout to each of them. It is three
lines, and this test is what makes a new workflow carry it.
"""

from __future__ import annotations

import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
SOURCES = sorted(
    [*(ROOT / ".github" / "workflows").glob("*.yml"), *(ROOT / ".github" / "workflows").glob("*.yaml"),
     *(ROOT / ".github" / "actions").glob("*/action.yml")]
)

RESOLVE = 'client="${CMUX_CI_CLIENT:-$HOME/.local/bin/cmux-ci}"'
CHECK = 'if ! [[ -x "$client" ]]; then'
# A run that names the client by either of these must resolve it as above.
MENTIONS = (".local/bin/cmux-ci", "CMUX_CI_CLIENT")
# The steps known to call the client today; a parse that finds fewer is broken.
KNOWN_CALLERS = 4


def check_run(run: str) -> list[str]:
    """The problems in one step's `run:`; empty when it does not call the client or guards it."""
    lines = [line.strip() for line in run.splitlines()]
    if not any(mention in line for line in lines for mention in MENTIONS):
        return []
    problems = []
    resolves = [i for i, line in enumerate(lines) if line == RESOLVE]
    others = [line for line in lines if line != RESOLVE and any(m in line for m in MENTIONS)]
    if others:
        problems.append(f"names the client outside `{RESOLVE}`: {others[0]}")
    if len(resolves) != 1:
        problems.append(f"needs exactly one `{RESOLVE}` line, found {len(resolves)}")
        return problems
    rest = [line for line in lines[resolves[0] + 1:] if line and not line.startswith("#")]
    if not rest or rest[0] != CHECK:
        problems.append(f"needs `{CHECK}` right after resolving the client")
        return problems
    block = rest[1:rest.index("fi")] if "fi" in rest else []
    if not any(line.startswith("exit ") or line == "exit" for line in block):
        problems.append("the missing-client branch must end the step with `exit`")
    first_call = next((i for i, line in enumerate(rest) if '"$client"' in line and line != CHECK), None)
    if first_call is None:
        problems.append('resolves the client but never runs "$client"')
    return problems


def runs(document: dict, where: str):
    """Every (location, run text) of a workflow's jobs or a composite action's steps."""
    owners = {f"job {name}": job for name, job in (document.get("jobs") or {}).items()}
    if isinstance(document.get("runs"), dict):
        owners["action"] = document["runs"]
    for owner, body in owners.items():
        for step in (body or {}).get("steps") or []:
            if isinstance(step.get("run"), str):
                yield f"{where} {owner} step {step.get('name') or step.get('id') or '?'}", step["run"]


def self_test() -> list[str]:
    guarded = f'set -uo pipefail\n{RESOLVE}\n{CHECK}\n  echo missing\n  exit 2\nfi\n"$client" run --x\n'
    cases = {
        "guarded": (guarded, False),
        "no client": ("echo cmux-ci compile-check passed\n", False),
        "bare call": ('"${CMUX_CI_CLIENT:-$HOME/.local/bin/cmux-ci}" run --x\n', True),
        "tilde call": ("~/.local/bin/cmux-ci run --x\n", True),
        "no exit": (f'{RESOLVE}\n{CHECK}\n  echo missing\nfi\n"$client" run\n', True),
        "check later": (f'{RESOLVE}\n"$client" run\n{CHECK}\n  exit 2\nfi\n', True),
        "second spelling": (guarded + '"$CMUX_CI_CLIENT" wait\n', True),
    }
    return [name for name, (text, bad) in cases.items() if bool(check_run(text)) != bad]


def main() -> int:
    failures = [f"self-test case {name!r} judged wrong" for name in self_test()]
    callers = 0
    for path in SOURCES:
        document = yaml.safe_load(path.read_text())
        for where, run in runs(document, str(path.relative_to(ROOT))):
            problems = check_run(run)
            if any(m in run for m in MENTIONS):
                callers += 1
            failures += [f"{where}: {problem}" for problem in problems]
    if callers < KNOWN_CALLERS:
        failures.append(f"found {callers} steps that call the build-fleet client, expected at least {KNOWN_CALLERS}")
    if failures:
        print("Build-fleet client calls without the installed check:")
        for failure in failures:
            print(f"  {failure}")
        return 1
    print(f"OK: {callers} build-fleet client calls check the client is installed first.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
