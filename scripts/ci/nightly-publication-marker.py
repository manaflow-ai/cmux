#!/usr/bin/env python3
"""Read the exact source SHA recorded in a nightly release body."""

from __future__ import annotations

import re
import sys


MARKER = re.compile(
    r"<!--\s*cmux-published-sha:\s*([0-9a-f]{40})\s*-->",
    re.IGNORECASE,
)


def published_sha(body: str) -> str | None:
    match = MARKER.search(body)
    return match.group(1).lower() if match else None


if __name__ == "__main__":
    marker = published_sha(sys.stdin.read())
    if marker:
        print(marker)
