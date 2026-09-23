"""Shared parser for the deliberately small Python test execution registry."""

from __future__ import annotations

import ast
from pathlib import Path
from typing import Optional


def load_registry(path: Path) -> list[dict[str, object]]:
    return parse_registry(path.read_text(encoding="utf-8"), str(path))


def parse_registry(text: str, label: str) -> list[dict[str, object]]:
    """Parse registry text. `label` names the source in error messages.

    The validator reads the base branch's registry through `git show`, which
    has no path on disk, so parsing is separate from reading.
    """
    version: object = None
    tests: list[dict[str, object]] = []
    current: Optional[dict[str, object]] = None
    path = label

    for line_number, raw_line in enumerate(text.splitlines(), start=1):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if line == "[[test]]":
            current = {}
            tests.append(current)
            continue

        key, separator, raw_value = line.partition("=")
        if not separator:
            raise ValueError(f"{path}:{line_number}: expected key = value")
        key = key.strip()
        try:
            value = ast.literal_eval(raw_value.strip())
        except (SyntaxError, ValueError) as error:
            raise ValueError(f"{path}:{line_number}: invalid literal: {error}") from error

        if current is None:
            if key != "version":
                raise ValueError(f"{path}:{line_number}: unsupported top-level key {key!r}")
            if version is not None:
                raise ValueError(f"{path}:{line_number}: duplicate version")
            version = value
            continue

        if key in current:
            raise ValueError(f"{path}:{line_number}: duplicate field {key!r}")
        current[key] = value

    if version != 1:
        raise ValueError(f"{path}: unsupported version {version!r}")
    if not tests:
        raise ValueError(f"{path}: expected [[test]] entries")
    return tests
