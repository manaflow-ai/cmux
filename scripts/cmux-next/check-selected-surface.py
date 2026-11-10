#!/usr/bin/env python3
"""The selected state is the foreground (design/selected-is-foreground.md).

    check-selected-surface.py [ROOT]

Leo, 2026-11-10: "The selected tab should be white as well. Right now, the selected tab gets this
highlight, and it's gray. But it's like, bro, that doesn't make sense because it looks like it's
backgrounded against the foreground." A selected tab, row, segment or nav item is part of the
foreground, so it is drawn in the content's own surface: one token, never a colour picked per
component. The selected state used to be styled by hand in each component, which is how the gray
pill spread. This check fails a selected style on any other colour:

- web: a CSS rule whose selector is a selected state (`[aria-selected]`, `[aria-current]`,
  `[data-selected]`, `[data-active]`, `[data-checked]`, `.is-selected`, `.is-active`, `.is-current`)
  and that paints a background must take `--ds-color-selected` or `--cmux-selected-surface`;
- native: a line of the NEXT app that paints `Palette.selectionFill` for a selected or active item
  must take `Palette.selectedSurface` or `Palette.selectedFolderSurface` instead.

A rule or line that is not a foreground selection (a list's cursor inside content, a drop target,
the opt-out gray pill) says why with a `selected-surface-allow: <reason>` comment on it or the line
above. `schemas/selected-surface/pending.json` lists today's offenders, a backlog that only shrinks:
a new offender fails, and so does a listed one that is fixed (remove it from the list).

Rules, in findings: [web-selected], [native-selected], [stale-pending].
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ALLOW = "selected-surface-allow:"
WEB_ROOT = "webviews/src"
NATIVE_ROOT = "Packages/macOS/CmuxNext/Sources"
PENDING = "schemas/selected-surface/pending.json"

SELECTED_SELECTOR = re.compile(
    r"\[aria-selected(?:=\"?true\"?)?\]|\[aria-current\b[^\]]*\]|\[data-selected\b[^\]]*\]"
    r"|\[data-active\b[^\]]*\]|\[data-checked\b[^\]]*\]|\.is-(?:selected|active|current)\b"
)
NEGATION = re.compile(r":not\((?:[^()]|\([^()]*\))*\)")
SELECTED_TOKENS = ("--ds-color-selected", "--cmux-selected-surface")
NO_FILL = {"transparent", "none", "inherit", "initial", "unset", "revert"}
BACKGROUND = re.compile(r"(?:^|;)\s*background(?:-color)?\s*:\s*([^;]+)", re.I)
COMMENT = re.compile(r"/\*.*?\*/", re.S)
# The innermost `selector { body }` blocks: an @media's own braces hold blocks, so only leaves match.
RULE = re.compile(r"([^{}]*)\{([^{}]*)\}")

NATIVE_STATE = re.compile(r"\b(?:isSelected|isActive|isCurrent|selectedID|isPaletteSelected|fillsSelection|\.selected\b)")
NATIVE_GRAY = "Palette.selectionFill"


def web_findings(root: Path) -> list[tuple[str, str, int]]:
    """(path, selector, line) of each selected rule that paints a background off the token."""
    found: list[tuple[str, str, int]] = []
    base = root / WEB_ROOT
    if not base.is_dir():
        return found
    for path in sorted(base.rglob("*.css")):
        rel = path.relative_to(root).as_posix()
        if "/gallery/" in rel or rel.endswith(".gallery.css") or "/node_modules/" in rel:
            continue
        text = path.read_text(encoding="utf-8", errors="replace")
        # Keep the comments' allow reasons: a rule is allowed when the comment right before it says so.
        for match in RULE.finditer(text):
            raw_selector, body = match.group(1), match.group(2)
            lead = raw_selector
            selector = COMMENT.sub("", raw_selector).strip()
            if not selector or selector.startswith("@"):
                continue
            if not any(SELECTED_SELECTOR.search(NEGATION.sub("", part)) for part in selector.split(",")):
                continue
            clean_body = COMMENT.sub("", body)
            values = [m.group(1).strip() for m in BACKGROUND.finditer(clean_body)]
            if not values:
                continue
            if all(v.split()[0].lower() in NO_FILL or any(t in v for t in SELECTED_TOKENS) for v in values):
                continue
            # A comment between the previous rule and this one, or in its body, may allow it.
            if ALLOW in lead or ALLOW in body:
                continue
            line = text.count("\n", 0, match.start() + len(raw_selector) - len(raw_selector.lstrip())) + 1
            found.append((rel, " ".join(selector.split()), line))
    return found


def native_findings(root: Path) -> list[tuple[str, str, int]]:
    """(path, line text, line) of each line that paints the gray selection for a selected item."""
    found: list[tuple[str, str, int]] = []
    base = root / NATIVE_ROOT
    if not base.is_dir():
        return found
    for path in sorted(base.rglob("*.swift")):
        rel = path.relative_to(root).as_posix()
        if "/Playground/" in rel or "/Debug" in rel.rsplit("/", 1)[-1]:
            continue
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
        for index, line in enumerate(lines):
            code = line.split("//", 1)[0]
            if NATIVE_GRAY not in code or not NATIVE_STATE.search(code):
                continue
            if ALLOW in line or (index > 0 and ALLOW in lines[index - 1]):
                continue
            found.append((rel, " ".join(code.split()), index + 1))
    return found


def main(argv: list[str]) -> int:
    root = Path(argv[1] if len(argv) > 1 else ".").resolve()
    # The pre-push gate judges a tree of the changed files only: the list then comes from this script's
    # own checkout, and a listed file the tree does not hold is not judged stale.
    pending_path = root / PENDING
    if not pending_path.is_file():
        pending_path = Path(__file__).resolve().parents[2] / PENDING
    pending = json.loads(pending_path.read_text()) if pending_path.is_file() else {}
    pending_web = {(p, s) for p, sels in pending.get("web", {}).items() for s in sels}
    pending_native = {(p, s) for p, lines in pending.get("native", {}).items() for s in lines}
    errors: list[str] = []

    web = web_findings(root)
    seen_web = set()
    for rel, selector, line in web:
        seen_web.add((rel, selector))
        if (rel, selector) not in pending_web:
            errors.append(f"{rel}:{line}: [web-selected] `{selector}` paints a selected item off the content surface: "
                          f"use var(--ds-color-selected), or say why with /* {ALLOW} <reason> */")
    native = native_findings(root)
    seen_native = set()
    for rel, code, line in native:
        seen_native.add((rel, code))
        if (rel, code) not in pending_native:
            errors.append(f"{rel}:{line}: [native-selected] a selected item paints {NATIVE_GRAY}: use "
                          f"Palette.selectedSurface (a row) or Palette.selectedFolderSurface (a folder tab), "
                          f"or say why with // {ALLOW} <reason>")
    for rel, selector in sorted(pending_web - seen_web):
        if not (root / rel).is_file():
            continue
        errors.append(f"{PENDING}: [stale-pending] web {rel} `{selector}` is fixed or gone: remove it from the list")
    for rel, code in sorted(pending_native - seen_native):
        if not (root / rel).is_file():
            continue
        errors.append(f"{PENDING}: [stale-pending] native {rel} `{code}` is fixed or gone: remove it from the list")

    if errors:
        print("\n".join(errors))
        print(f"check-selected-surface: {len(errors)} finding(s). Rule: design/selected-is-foreground.md")
        return 1
    print(f"check-selected-surface: every selected style is the content surface "
          f"({len(pending_web) + len(pending_native)} pending in {PENDING})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
