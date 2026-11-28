#!/usr/bin/env python3
"""Shared helpers for static regression tests."""

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path


def repo_root() -> Path:
    git = shutil.which("git")
    if git is None:
        return Path(__file__).resolve().parents[1]
    try:
        result = subprocess.run(
            [git, "rev-parse", "--show-toplevel"],
            capture_output=True,
            text=True,
            check=False,
            timeout=2,
        )
    except (subprocess.TimeoutExpired, OSError):
        return Path(__file__).resolve().parents[1]
    if result.returncode == 0:
        return Path(result.stdout.strip())
    return Path(__file__).resolve().parents[1]


def extract_block(source: str, signature: str) -> str:
    # Targeted helper for this regression suite: assumes braces in the matched
    # block are structural (not inside strings/comments/character literals).
    start = source.find(signature)
    if start < 0:
        raise ValueError(f"Missing signature: {signature}")

    brace_start = source.find("{", start)
    if brace_start < 0:
        raise ValueError(f"Missing opening brace for: {signature}")

    depth = 0
    for idx in range(brace_start, len(source)):
        char = source[idx]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return source[brace_start : idx + 1]

    raise ValueError(f"Unbalanced braces for: {signature}")
