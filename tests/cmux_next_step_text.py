"""A cmux-next.yml step's commands, read from its script when the step runs one.

To keep cmux-next.yml under GitHub's workflow file size limit (tests/test_ci_workflow_file_size.py), some steps
run `bash -e scripts/ci/cmux-next-steps/<step>.sh` instead of an inline `run: |` block; their env: stays in the
workflow. Tests that check a step's commands read them through step_run.
"""
from __future__ import annotations

from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
# A step with `working-directory:` calls its script relative to that directory (`../../../scripts/...`).
STEP_CALL = re.compile(r"^bash -e (?:\.\./)*(scripts/ci/cmux-next-steps/[A-Za-z0-9_.-]+\.sh)$")


def step_body(path: str) -> str:
    """A moved step's script without its shebang and leading comment header."""
    lines = (ROOT / path).read_text().splitlines(keepends=True)
    while lines and lines[0].startswith("#"):
        lines.pop(0)
    return "".join(lines)


def step_run(step: dict) -> str:
    """STEP's `run:` text, or its script's body when the step runs a moved script."""
    run = str(step.get("run") or "")
    call = STEP_CALL.match(run.strip())
    return step_body(call.group(1)) if call else run


STEP_CALL_LINE = re.compile(r"^( *)run: bash -e (?:\.\./)*(scripts/ci/cmux-next-steps/[A-Za-z0-9_.-]+\.sh)$", re.MULTILINE)


def inline_steps(text: str) -> str:
    """Workflow TEXT with each moved step's script put back as the `run: |` block it was."""
    def inline(match: re.Match) -> str:
        indent = match.group(1) + "  "
        body = "".join(indent + line if line.strip() else line
                       for line in step_body(match.group(2)).splitlines(keepends=True))
        return f"{match.group(1)}run: |\n{body.rstrip(chr(10))}"
    return STEP_CALL_LINE.sub(inline, text)
