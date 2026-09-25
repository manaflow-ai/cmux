#!/usr/bin/env python3
"""Guard that every variable prefixed onto a console-session call survives the hop.

`scripts/ci/run-in-console-session.sh` re-enters the console user's Aqua session
through `sudo -n launchctl asuser ... sudo -n -u <user> -E env ...`. The outer
`sudo` has no `-E`, so the environment is reset there and rebuilt from an explicit
`forward=(...)` allowlist. A workflow that prefixes the wrapper with `FOO=1`
and forgets to extend that allowlist fails silently: the variable
never reaches the command, the test it gates stays skipped, and CI still reports
success.

That is not hypothetical. `CMUX_RENDERER_MEMORY_REGRESSION=1` was added to the
renderer-memory step and never reached `run-app-host-xcodebuild.sh`, so the
regression it gates skipped itself on every run.

What this checks, and deliberately what it does not.

The signal is a **command prefix** -- `FOO=1 scripts/ci/run-in-console-session.sh
...` -- on the invocation line itself or on the backslash-continued lines leading
into it. That is an explicit statement that the variable is meant for this
command, so it must survive the hop.

Ambient environment is NOT checked: step-level, job-level and workflow-level
`env:` mappings, and plain `export` in the surrounding `run:` block. Those carry
dozens of names that the wrapped command has no interest in (CI cache URLs, Xcode
selection, shard indices), and the allowlist is deliberately selective. Requiring
all of them to be forwarded produced 60+ false positives on the real workflows
and would have made this guard useless. If a variable is genuinely needed by the
wrapped command, write it as a prefix on the invocation -- which is the existing
convention at every call site that needs one.
"""

from pathlib import Path
import re

import yaml


ROOT = Path(__file__).resolve().parents[1]
CONSOLE_WRAPPER_PATH = ROOT / "scripts/ci/run-in-console-session.sh"
WRAPPER_NAME = "scripts/ci/run-in-console-session.sh"
WORKFLOW_DIR = ROOT / ".github"

# NAME=, screaming snake case, so this does not match YAML keys or step names.
NAME = r"[A-Z][A-Z0-9_]{3,}"
PREFIX_ASSIGNMENT = re.compile(rf"\b({NAME})=")
# GitHub expression syntax, e.g. FOO=${{ vars.BAR }} -- still a real assignment.
COMMENT = re.compile(r"(?<!\$)#.*$")


def forwarded_variables(source: str) -> set[str]:
    """Every name the wrapper copies across the sudo hop."""
    names: set[str] = set()
    base = re.search(r"forward=\((.*?)\)\n", source, re.S)
    if base is None:
        raise SystemExit(f"FAIL: no forward=(...) allowlist in {WRAPPER_NAME}")
    blocks = [base.group(1)]
    # Conditional extensions (e.g. the cleanup test helper) count as forwarded.
    blocks.extend(re.findall(r"forward\+=\((.*?)\)", source, re.S))
    for block in blocks:
        # A name mentioned only in a comment inside the array is not forwarded.
        stripped = "\n".join(COMMENT.sub("", line) for line in block.splitlines())
        names |= set(re.findall(NAME, stripped))
    return names


def _strip(line: str) -> str:
    return COMMENT.sub("", line)


def run_block_names(run_text: str) -> set[str]:
    """Names prefixed onto a wrapper invocation in this `run:` block."""
    names: set[str] = set()
    lines = run_text.splitlines()

    for index, line in enumerate(lines):
        if WRAPPER_NAME not in line:
            continue
        # A single-line invocation carries its prefix before the wrapper path.
        before = _strip(line).split(WRAPPER_NAME)[0]
        names |= set(PREFIX_ASSIGNMENT.findall(before))
        # ...and a wrapped one carries it on the continued lines above.
        cursor = index - 1
        while cursor >= 0 and _strip(lines[cursor]).rstrip().endswith("\\"):
            names |= set(PREFIX_ASSIGNMENT.findall(_strip(lines[cursor])))
            cursor -= 1

    return names


def workflow_call_sites(document, text: str):
    """Yield (prefixed_names, description) per wrapper invocation."""
    if WRAPPER_NAME not in text:
        return
    if not isinstance(document, dict):
        return
    jobs = document.get("jobs")
    if not isinstance(jobs, dict):
        return
    for job_name, job in jobs.items():
        if not isinstance(job, dict):
            continue
        steps = job.get("steps")
        if not isinstance(steps, list):
            continue
        for position, step in enumerate(steps):
            if not isinstance(step, dict):
                continue
            run_text = step.get("run")
            if not isinstance(run_text, str) or WRAPPER_NAME not in run_text:
                continue
            names = run_block_names(run_text)
            label = step.get("name") or f"step {position}"
            yield names, f"{job_name} / {label}"


def main() -> int:
    forwarded = forwarded_variables(
        CONSOLE_WRAPPER_PATH.read_text(encoding="utf-8")
    )

    call_sites = 0
    stranded: list[str] = []
    workflows = sorted(
        path
        for pattern in ("**/*.yml", "**/*.yaml")
        for path in WORKFLOW_DIR.glob(pattern)
    )
    for workflow in workflows:
        text = workflow.read_text(encoding="utf-8")
        if WRAPPER_NAME not in text:
            continue
        try:
            document = yaml.safe_load(text)
        except yaml.YAMLError as error:
            raise SystemExit(f"FAIL: cannot parse {workflow.relative_to(ROOT)}: {error}")
        for names, label in workflow_call_sites(document, text):
            call_sites += 1
            for name in sorted(names - forwarded):
                stranded.append(f"{workflow.relative_to(ROOT)} :: {label} :: {name}")

    if not call_sites:
        raise SystemExit(
            f"FAIL: no workflow step runs {WRAPPER_NAME}; this guard has gone blind"
        )

    if stranded:
        detail = "\n  ".join(stranded)
        raise SystemExit(
            "FAIL: these variables are prefixed onto a console-session call but "
            f"are not in the forward=(...) allowlist of {WRAPPER_NAME}, so the "
            f"command never sees them:\n  {detail}"
        )

    print(
        f"PASS: every variable reaching {call_sites} console-session call sites "
        "survives the sudo hop"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
