#!/usr/bin/env python3
"""Regression checks for cmux-browser get selector examples."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmuxError


ROOT = Path(__file__).resolve().parents[1]
COMMANDS = ROOT / "skills/cmux-browser/references/commands.md"


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def main() -> int:
    commands = COMMANDS.read_text(encoding="utf-8")

    _must("`agent-browser get text <ref>` -> `cmux browser <surface> get text <ref-or-selector>`" in commands, "Expected get text mapping to mention selector support")
    _must("cmux browser <surface> get text body" in commands, "Expected get text body example")
    _must("cmux browser <surface> get html body" in commands, "Expected get html body example")
    _must('cmux browser <surface> get value "#email"' in commands, "Expected get value selector example")
    _must('cmux browser <surface> get attr "#email" --attr placeholder' in commands, "Expected get attr selector example")
    _must("cmux browser <surface> get text|html|value|attr|count|box|styles ..." not in commands, "Unexpected bare get example block")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
