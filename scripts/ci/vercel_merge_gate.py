#!/usr/bin/env python3
"""Decide whether the external Vercel status is relevant to a pull request."""

from __future__ import annotations

import argparse
import sys
from collections.abc import Iterable

WEB_PREFIXES = ("admin/", "board-ui/", "dashboard/", "web/")
WEB_FILES = frozenset({
    ".vercelignore", "package.json", "bun.lock", "package-lock.json",
    "pnpm-lock.yaml", "yarn.lock", "vercel.json",
})


def requires_vercel(repo: str, paths: Iterable[str]) -> bool:
    """Keep Vercel advisory for non-web changes, required for web changes."""
    paths = list(paths)
    if not paths:
        return True
    return any(path in WEB_FILES or path.startswith(WEB_PREFIXES) for path in paths)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("repo")
    args = parser.parse_args()
    raise SystemExit(0 if requires_vercel(args.repo, (line.strip() for line in sys.stdin)) else 1)
