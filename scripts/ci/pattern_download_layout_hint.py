#!/usr/bin/env python3
"""Hint at every `actions/download-artifact` step that can flatten a lone match.

With `pattern:` and no `merge-multiple: true`, the action makes one folder per
artifact only when two or more artifacts match; a lone match lands in `path:`
itself, so a consumer that reads `<path>/<artifact-name>/FILE` finds nothing
(docs/handbook/lone-artifact-flattens-its-download.md in cmuxterm-hq).

This never fails a build. It prints one GitHub `::warning` annotation per step
whose block does not say how its consumer copes, so the author reads the
consumer before the singleton case reaches a nightly. A step marks itself
reviewed with a comment in its block:

    # lone-artifact: <why one match is impossible or the consumer reads both layouts>

Usage: pattern_download_layout_hint.py [WORKFLOW_DIR]   (default .github/workflows)
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

MARKER = re.compile(r"#\s*lone-artifact:\s*\S")
STEP_START = re.compile(r"^(\s*)-\s")
USES_DOWNLOAD = re.compile(r"uses:\s*actions/download-artifact@")
PATTERN = re.compile(r"^\s*pattern:\s*\S")
MERGE_TRUE = re.compile(r"^\s*merge-multiple:\s*['\"]?true['\"]?\s*(#.*)?$", re.IGNORECASE)
PAGE = "https://github.com/manaflow-ai/cmuxterm-hq/blob/main/docs/handbook/lone-artifact-flattens-its-download.md"


def _step_blocks(lines: list[str]):
    """Yield (start_index, block_lines) for each YAML list item that is a step."""
    i = 0
    while i < len(lines):
        m = STEP_START.match(lines[i])
        if not m:
            i += 1
            continue
        indent = len(m.group(1))
        j = i + 1
        while j < len(lines):
            line = lines[j]
            if line.strip() and not line.lstrip().startswith("#"):
                cur = len(line) - len(line.lstrip())
                if cur < indent or (cur == indent and STEP_START.match(line)):
                    break
            j += 1
        # Comments directly above the step belong to it too.
        k = i
        while k > 0 and lines[k - 1].lstrip().startswith("#"):
            k -= 1
        yield i, lines[k:j]
        i = j if j > i + 1 else i + 1


def findings(workflow_dir: Path) -> list[tuple[Path, int]]:
    out: list[tuple[Path, int]] = []
    for path in sorted([*workflow_dir.glob("*.yml"), *workflow_dir.glob("*.yaml")]):
        lines = path.read_text(encoding="utf-8").splitlines()
        for start, block in _step_blocks(lines):
            if not any(USES_DOWNLOAD.search(line) for line in block):
                continue
            if not any(PATTERN.match(line) for line in block):
                continue
            if any(MERGE_TRUE.match(line) for line in block):
                continue
            if any(MARKER.search(line) for line in block):
                continue
            out.append((path, start + 1))
    return out


def main(argv: list[str]) -> int:
    workflow_dir = Path(argv[1]) if len(argv) > 1 else Path(".github/workflows")
    found = findings(workflow_dir)
    for path, line in found:
        print(
            f"::warning file={path},line={line},title=A lone matching artifact flattens its download::"
            "This pattern download has no merge-multiple: true, so when exactly one artifact matches its files "
            "land in path: itself, not path:/<artifact-name>/. Make the consumer read both layouts (or download "
            "by exact name into an explicit folder), then add '# lone-artifact: <why>' to the step. " + PAGE
        )
    print(f"pattern_download_layout_hint: {len(found)} unreviewed pattern download(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
