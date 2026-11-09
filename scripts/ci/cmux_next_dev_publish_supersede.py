#!/usr/bin/env python3
"""Cancel cmux NEXT DEV publish runs that a newer one supersedes before their Mac jobs start (stub)."""

from __future__ import annotations

import sys
from collections.abc import Callable, Mapping, Sequence
from typing import Any


def cancel_superseded(api: Any, repo: str, run_id: int, source_run_id: int,
                      log: Callable[[str], None] = print) -> list[int]:
    """Not implemented yet: cancels nothing."""
    return []


def main(argv: Sequence[str] | None = None, env: Mapping[str, str] | None = None, api: Any = None) -> int:
    return 0


if __name__ == "__main__":
    sys.exit(main())
