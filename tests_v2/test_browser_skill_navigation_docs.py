#!/usr/bin/env python3
"""Regression checks for cmux-browser navigation guidance."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmuxError


ROOT = Path(__file__).resolve().parents[1]
SKILL = ROOT / "skills/cmux-browser/SKILL.md"
FORM_TEMPLATE = ROOT / "skills/cmux-browser/templates/form-automation.sh"
AUTH_TEMPLATE = ROOT / "skills/cmux-browser/templates/authenticated-session.sh"


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def _must_ordered(text: str, parts: list[str], msg: str) -> None:
    start = 0
    for part in parts:
        idx = text.find(part, start)
        if idx < 0:
            raise cmuxError(msg)
        start = idx + len(part)


def main() -> int:
    skill = SKILL.read_text(encoding="utf-8")
    form_template = FORM_TEMPLATE.read_text(encoding="utf-8")
    auth_template = AUTH_TEMPLATE.read_text(encoding="utf-8")

    _must("Verify navigation with `get url` before waiting or snapshotting." in skill, "Expected core workflow to require get url verification")
    _must("If `get url` is empty or `about:blank`, navigate first instead of waiting on load state." in skill, "Expected blank-page guidance in stable agent loop")
    _must("cmux --json browser open https://example.com" in skill, "Expected safe browser open example with --json before browser")
    _must("cmux browser open https://example.com --json" not in skill, "Unexpected trailing --json browser open example")
    _must_ordered(
        skill,
        [
            "cmux browser surface:7 get url",
            "cmux browser surface:7 wait --load-state complete --timeout-ms 15000",
            "cmux browser surface:7 snapshot --interactive",
        ],
        "Expected get url -> wait -> snapshot ordering in skill examples",
    )
    _must_ordered(
        form_template,
        [
            'cmux browser "$SURFACE" goto "$URL"',
            'cmux browser "$SURFACE" get url',
            'cmux browser "$SURFACE" wait --load-state complete --timeout-ms 15000',
        ],
        "Expected form template to verify navigation before waiting",
    )
    _must_ordered(
        auth_template,
        [
            'cmux browser "$SURFACE" goto "$DASHBOARD_URL"',
            'cmux browser "$SURFACE" get url',
            'cmux browser "$SURFACE" wait --load-state complete --timeout-ms 15000',
        ],
        "Expected authenticated-session template to verify navigation before waiting",
    )

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
