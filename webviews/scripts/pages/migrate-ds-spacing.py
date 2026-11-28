#!/usr/bin/env python3
"""Migrate nominal Instrument spacing literals to fixed design tokens.

Only padding, margin and gap declarations are eligible. The fixed aliases preserve the
literal geometry when page-density overrides the scalable --ds-space-* family.
"""
from __future__ import annotations

import argparse
import json
import re
from decimal import Decimal
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SOURCE = ROOT / "webviews/src"
SKIP = {"pages/shared/desktop.css", "pages/shared/pageDensity.css"}
PROPERTIES = re.compile(
    r"^(?:(?:padding|margin)(?:-(?:top|right|bottom|left|block(?:-(?:start|end))?|inline(?:-(?:start|end))?))?|"
    r"gap|row-gap|column-gap)$"
)
NUMBER = re.compile(r"(?<![\w.#-])(?P<sign>-?)(?P<number>(?:\d+(?:\.\d+)?|\.\d+))px\b")


def spacing_tokens() -> dict[Decimal, str]:
    scale = json.loads((ROOT / "schemas/design-scale/design-scale.json").read_text())
    spacing = scale["spacing"]
    tokens = {Decimal(str(step["px"])): str(step["name"]) for step in spacing["steps"]}
    tokens.update({Decimal(str(px)): str(px) for px in spacing["layout"]})
    return tokens


TOKENS = spacing_tokens()


def mask(text: str) -> str:
    out = list(text)
    i = 0
    while i < len(text):
        if text.startswith("/*", i):
            end = text.find("*/", i + 2)
            end = len(text) - 2 if end < 0 else end
            for index in range(i, end + 2):
                if out[index] != "\n":
                    out[index] = " "
            i = end + 2
        elif text[i] in "'\"":
            quote = text[i]
            end = i + 1
            while end < len(text):
                if text[end] == "\\":
                    end = min(end + 2, len(text))
                    continue
                if text[end] == quote:
                    end += 1
                    break
                end += 1
            for index in range(i, end):
                if out[index] != "\n":
                    out[index] = " "
            i = end
        else:
            i += 1
    return "".join(out)


def var_depths(value: str) -> list[int]:
    depths = [0] * len(value)
    stack: list[int] = []
    i = 0
    while i < len(value):
        if value.startswith("var(", i):
            stack.append(1)
            i += 4
            continue
        if stack and value[i] == "(":
            stack[-1] += 1
        elif stack and value[i] == ")":
            stack[-1] -= 1
            if stack[-1] == 0:
                stack.pop()
        if stack:
            depths[i] = len(stack)
        i += 1
    return depths


def rewrite_value(value: str, masked: str) -> tuple[str, int]:
    depths = var_depths(masked)
    edits = []
    for match in NUMBER.finditer(masked):
        number = Decimal(match.group("number"))
        # The ratchet keys an off-scale shorthand by its complete value, including fallbacks.
        if number and number not in TOKENS:
            return value, 0
        if depths[match.start()] or not number:
            continue
        token = f"var(--ds-space-fixed-{TOKENS[number]})"
        edits.append((match.start(), match.end(), f"calc(-1 * {token})" if match.group("sign") else token))
    for start, end, replacement in reversed(edits):
        value = value[:start] + replacement + value[end:]
    return value, len(edits)


def migrate(path: Path, write: bool) -> int:
    relative = path.relative_to(SOURCE).as_posix()
    if relative in SKIP or "generated" in path.parts:
        return 0
    original = path.read_text()
    masked = mask(original)
    declaration = re.compile(r"(?m)(?:^|[;{])\s*(?P<prop>[A-Za-z][\w-]*)\s*:\s*(?P<value>[^;{}]*)")
    edits = []
    for match in declaration.finditer(masked):
        if not PROPERTIES.fullmatch(match.group("prop")):
            continue
        start, end = match.span("value")
        replacement, count = rewrite_value(original[start:end], masked[start:end])
        if count:
            edits.append((start, end, replacement))
    if write:
        for start, end, replacement in reversed(edits):
            original = original[:start] + replacement + original[end:]
        if edits:
            path.write_text(original)
    return len(edits)


def main() -> int:
    parser = argparse.ArgumentParser()
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--write", action="store_true", help="rewrite files in place")
    mode.add_argument("--check", action="store_true", help="report pending rewrites without changing files")
    args = parser.parse_args()
    files = sorted(SOURCE.rglob("*.css"))
    total = sum(migrate(path, args.write) for path in files)
    print(f"spacing declarations requiring migration: {total}")
    return 1 if total and not args.write else 0


if __name__ == "__main__":
    raise SystemExit(main())
