#!/usr/bin/env python3
"""Resolve the per-runner canonical build root for a macOS CI job.

The fleet controller normally exports ``CMUX_CI_CANONICAL_ROOT``.  A reused
owned runner must still have an isolated root when that export is absent, so
the runner identity provides a deterministic fallback before any fixed path is
cleared or cloned.
"""

from __future__ import annotations

import os
import re
import sys
from collections.abc import Mapping

BASE_ROOT = "/private/tmp/cmux-ci"
ROOT_PATTERN = re.compile(r"/private/tmp/cmux-ci(?:-[0-9]{1,2})?\Z")
OWNED_RUNNER_PATTERN = re.compile(r".*-glaeda(?:-([0-9]{1,2}))?\Z")


def resolve(environment: Mapping[str, str]) -> tuple[str, str]:
    """Return the canonical root and the source that selected it."""
    explicit = environment.get("CMUX_CI_CANONICAL_ROOT", "").strip()
    if explicit:
        if not ROOT_PATTERN.fullmatch(explicit):
            raise ValueError(f"unexpected CMUX_CI_CANONICAL_ROOT {explicit!r}")
        return explicit, "controller"

    if not environment.get("CMUX_PRODUCT_RUNNER", "").startswith("glaeda-"):
        return BASE_ROOT, "default"

    runner_name = environment.get("RUNNER_NAME", "").strip()
    match = OWNED_RUNNER_PATTERN.fullmatch(runner_name)
    if match is None:
        raise ValueError(
            "owned runner is missing a canonical root and has no recognized "
            f"slot identity: {runner_name!r}"
        )
    slot = match.group(1)
    return (f"{BASE_ROOT}-{slot}" if slot else BASE_ROOT), "runner-name"


def main() -> int:
    try:
        root, source = resolve(os.environ)
    except ValueError as error:
        print(f"resolve-canonical-root: {error}", file=sys.stderr)
        return 1
    print(f"canonical root: {root} ({source})", file=sys.stderr)
    print(root)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
