#!/usr/bin/env python3
"""Guard that every variable a workflow sets for the console session survives the hop.

`scripts/ci/run-in-console-session.sh` re-enters the console user's Aqua session
through `sudo -n launchctl asuser ... sudo -n -u <user> -E env ...`. The outer
`sudo` has no `-E`, so the environment is reset there and rebuilt from an explicit
`forward=(...)` allowlist. A workflow that prefixes the wrapper with `FOO=1` and
forgets to extend that allowlist fails silently: the variable never reaches the
command, the test it gates stays skipped, and CI still reports success.

That is not hypothetical. `CMUX_RENDERER_MEMORY_REGRESSION=1` was added to the
renderer-memory step and never reached `run-app-host-xcodebuild.sh`, so the
regression it gates skipped itself on every run.
"""

from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[1]
CONSOLE_WRAPPER_PATH = ROOT / "scripts/ci/run-in-console-session.sh"
WRAPPER_NAME = "scripts/ci/run-in-console-session.sh"
WORKFLOW_DIR = ROOT / ".github/workflows"

# A shell assignment prefixing a command: NAME=value. Names are screaming snake
# case so this does not match YAML keys or step names.
ASSIGNMENT = re.compile(r"\b([A-Z][A-Z0-9_]{3,})=")


def forwarded_variables(source: str) -> set[str]:
    """Every name the wrapper copies across the sudo hop."""
    names: set[str] = set()
    base = re.search(r"forward=\((.*?)\)\n", source, re.S)
    if base is None:
        raise SystemExit(f"FAIL: no forward=(...) allowlist in {WRAPPER_NAME}")
    names |= set(re.findall(r"[A-Z][A-Z0-9_]+", base.group(1)))
    # Conditional extensions (e.g. the cleanup test helper) count as forwarded.
    for extra in re.findall(r"forward\+=\((.*?)\)", source, re.S):
        names |= set(re.findall(r"[A-Z][A-Z0-9_]+", extra))
    return names


def assignments_before_wrapper(lines: list[str], index: int) -> list[str]:
    """Names assigned on the backslash-continued lines leading into the call."""
    names: list[str] = []
    cursor = index - 1
    while cursor >= 0 and lines[cursor].rstrip().endswith("\\"):
        names.extend(ASSIGNMENT.findall(lines[cursor]))
        cursor -= 1
    return names


def main() -> int:
    forwarded = forwarded_variables(
        CONSOLE_WRAPPER_PATH.read_text(encoding="utf-8")
    )

    call_sites = 0
    stranded: list[str] = []
    for workflow in sorted(WORKFLOW_DIR.glob("*.yml")):
        lines = workflow.read_text(encoding="utf-8").splitlines()
        for index, line in enumerate(lines):
            if WRAPPER_NAME not in line:
                continue
            call_sites += 1
            for name in assignments_before_wrapper(lines, index):
                if name not in forwarded:
                    stranded.append(
                        f"{workflow.relative_to(ROOT)}:{index + 1} sets {name}"
                    )

    if not call_sites:
        raise SystemExit(
            f"FAIL: no workflow calls {WRAPPER_NAME}; this guard has gone blind"
        )

    if stranded:
        detail = "\n  ".join(sorted(stranded))
        raise SystemExit(
            "FAIL: these variables are set for the console session but are not in "
            f"the forward=(...) allowlist of {WRAPPER_NAME}, so the command never "
            f"sees them:\n  {detail}"
        )

    print(
        f"PASS: every variable set at {call_sites} console-session call sites "
        "survives the sudo hop"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
