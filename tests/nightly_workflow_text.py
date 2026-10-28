"""nightly.yml with its moved step scripts put back inline, for workflow tests.

To stay under GitHub's workflow file size limit, some nightly.yml steps run
`bash scripts/ci/nightly-steps/<step>.sh` (or the same path under
.publish-tooling/) instead of an inline `run: |` block. Tests that read the
workflow's text or YAML read this expansion, so they keep checking those
steps' commands in place.
"""
from __future__ import annotations

from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
NIGHTLY_YML = ROOT / ".github/workflows/nightly.yml"
STEP_CALL = re.compile(
    r"^(?P<indent> *)run: bash (?:\.publish-tooling/)?(?P<path>scripts/ci/nightly-steps/[A-Za-z0-9_.-]+\.sh)[ \t]*$",
    re.MULTILINE,
)


def step_body(path: str) -> str:
    """A moved step's script without its shebang and leading comment header."""
    lines = (ROOT / path).read_text().splitlines()
    while lines and lines[0].startswith("#"):
        lines.pop(0)
    return "\n".join(lines)


def expand(text: str) -> str:
    def inline(match: re.Match[str]) -> str:
        indent = match.group("indent")
        body = "\n".join(f"{indent}  {line}" if line else "" for line in step_body(match.group("path")).split("\n"))
        return f"{indent}run: |\n{body}"

    return STEP_CALL.sub(inline, text)


def nightly_text() -> str:
    return expand(NIGHTLY_YML.read_text(encoding="utf-8"))


if __name__ == "__main__":
    print(nightly_text(), end="")
