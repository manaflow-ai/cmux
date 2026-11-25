#!/usr/bin/env python3
"""Read the publication markers recorded in a nightly release body."""

from __future__ import annotations

import re
import sys


MARKER = re.compile(
    r"<!--\s*cmux-published-sha:\s*([0-9a-f]{40})\s*-->",
    re.IGNORECASE,
)
PUBLISHED_AT_MARKER = re.compile(
    r"<!--\s*cmux-published-at:\s*(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z)\s*-->",
    re.IGNORECASE,
)


def published_sha(body: str) -> str | None:
    match = MARKER.search(body)
    return match.group(1).lower() if match else None


def published_at(body: str) -> str | None:
    """Return the UTC time at which the immutable publication completed."""
    match = PUBLISHED_AT_MARKER.search(body)
    return match.group(1) if match else None


if __name__ == "__main__":
    body = sys.stdin.read()
    marker = published_at(body) if sys.argv[1:] == ["--published-at"] else published_sha(body)
    if marker:
        print(marker)
