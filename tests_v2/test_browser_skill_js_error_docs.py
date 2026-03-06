#!/usr/bin/env python3
"""Regression checks for cmux-browser js_error troubleshooting docs."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmuxError


ROOT = Path(__file__).resolve().parents[1]
SKILL = ROOT / "skills/cmux-browser/SKILL.md"


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def main() -> int:
    skill = SKILL.read_text(encoding="utf-8")

    _must("## Troubleshooting" in skill, "Expected Troubleshooting section in cmux-browser skill")
    _must("### `js_error` on `snapshot --interactive` or `eval`" in skill, "Expected js_error troubleshooting heading")
    _must("cmux browser surface:7 get url" in skill, "Expected get url recovery step")
    _must("cmux browser surface:7 get text body" in skill, "Expected get text body recovery step")
    _must("cmux browser surface:7 get html body" in skill, "Expected get html body recovery step")
    _must("when `snapshot --interactive` or `eval` returns `js_error`" in skill, "Expected js_error fallback guidance")
    _must("navigate to a simpler intermediate page" in skill, "Expected simpler-page fallback guidance")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
