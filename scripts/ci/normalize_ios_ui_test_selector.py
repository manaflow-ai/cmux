#!/usr/bin/env python3
"""Normalize an iOS UI test filter into xcodebuild's target/class/method form."""

from __future__ import annotations

import re
import sys


TEST_TARGET = "cmuxUITests"
IDENTIFIER = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


def normalize(selector: str) -> str:
    selector = selector.strip()
    components = selector.split("/")
    if (
        not selector
        or len(components) > 3
        or any(not IDENTIFIER.fullmatch(component) for component in components)
    ):
        raise ValueError(f"invalid iOS UI test selector: {selector!r}")

    if len(components) == 1:
        return f"{TEST_TARGET}/{selector}"

    if len(components) == 2:
        first, second = components
        # target/class is already complete. The previously documented
        # cmuxUITests/testMethod form instead names the cmuxUITests class and
        # one method, so it still needs the target prefix.
        if first == TEST_TARGET and not second.startswith("test"):
            return selector
        return f"{TEST_TARGET}/{selector}"

    if components[0] != TEST_TARGET:
        raise ValueError(
            f"invalid iOS UI test target {components[0]!r}; expected {TEST_TARGET!r}"
        )
    return selector


def main() -> int:
    if len(sys.argv) != 2:
        print(
            "usage: normalize_ios_ui_test_selector.py <class-or-selector>",
            file=sys.stderr,
        )
        return 2

    try:
        print(normalize(sys.argv[1]))
    except ValueError as error:
        print(f"::error::{error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
