#!/usr/bin/env python3
"""Fails when a cmux NEXT surface shows a material its kind does not allow.

    check-surface-materials.py [ROOT]

Leo, 2026-11-09: "we need to be auditing all of the app, like what is supposed to be native-looking,
what is supposed to be not as native ... it's just a consistency, okay?" The rule is
design/surface-materials.md; the kinds and every native glass file's kind are in
schemas/surface-materials/surface-materials.json.

Rules:
  native-unlisted  a Swift file under Packages/macOS/CmuxNext/Sources builds glass (Glass.make*,
                   GlassPanelView, NSGlassEffectView, NSVisualEffectView, .glassEffect,
                   CardSurfaceView, FindPillView) and the manifest gives it no kind. A new floating
                   surface is web (web-floating): give a native one a kind only with a reason in the PR.
  native-kind      a native file's kind is not a kind, or is a web kind (web-floating, web-content).
  native-material  a native file's material is not one its kind allows: a sidebar card that builds
                   real glass instead of the card veil, a surface that builds both, a kind
                   that allows no glass.
  native-stale     a manifest entry whose file is gone or no longer builds glass.
  web-floating     a floating web surface in the agent pane's code (webviews/src/ui, webviews/src/agent-session):
                   a JSX element whose opening tag carries both `ui-popup` and `ui-glass` (in a string or a
                   multiline cx(...)) and no `data-host-glass=` attribute of its own. In a see-through
                   Chromium pane it reads as a flat box beside the menus on the App's glass. A
                   `host-glass-allow: <reason>` comment inside that opening tag passes; so does a file in
                   web_floating_pending, the backlog, which fails as stale once the file has no unmarked surface.
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

MANIFEST = "schemas/surface-materials/surface-materials.json"
NATIVE_ROOT = "Packages/macOS/CmuxNext/Sources"
WEB_ROOT = "webviews/src"
WEB_SCOPES = ("ui/", "agent-session/")
WEB_KINDS = {"web-floating", "web-content"}

REAL_GLASS = re.compile(
    r"Glass\.make(?:Surface|OverlayPanel|MenuPanel|Panel)\(|GlassPanelView\(|NSGlassEffectView\(|"
    r"NSVisualEffectView\(|\.glassEffect\(|FindPillView\(|OverlaySurfaceView\("
)
CARD_VEIL = re.compile(r"CardSurfaceView\(")
POPUP = re.compile(r"(?<![\w-])ui-popup(?![\w-])")
GLASS = re.compile(r"(?<![\w-])ui-glass(?![\w-])")
HOST_GLASS = re.compile(r"(?<![\w-])data-host-glass=")
TAG_START = re.compile(r"<[A-Za-z][\w.]*")
SKIP_WEB = re.compile(r"(\.gallery\.|\.test\.|/prototypes/|/test/)")


def code_lines(text: str) -> list[str]:
    """The file's lines with whole-line comments blanked, so a comment naming a view does not count."""
    out = []
    for line in text.splitlines():
        stripped = line.lstrip()
        out.append("" if stripped.startswith("//") or stripped.startswith("*") else line)
    return out


def opening_tags(text: str):
    """Each JSX opening tag: (offset, its text), from `<Name` to the `>` that ends it outside braces and strings."""
    for match in TAG_START.finditer(text):
        depth = 0
        quote = ""
        index = match.end()
        while index < len(text):
            char = text[index]
            if not quote and text.startswith("//", index):
                end = text.find("\n", index)
                index = len(text) if end < 0 else end
                continue
            if not quote and text.startswith("/*", index):
                end = text.find("*/", index + 2)
                index = len(text) if end < 0 else end + 2
                continue
            if quote:
                if char == "\\":
                    index += 1
                elif char == quote:
                    quote = ""
            elif char in "\"'`":
                quote = char
            elif char == "{":
                depth += 1
            elif char == "}":
                depth -= 1
            elif char == ">" and depth == 0:
                yield match.start(), text[match.start() : index + 1]
                break
            elif char == "<" and depth == 0:
                break  # a comparison or a stray `<`, not a tag
            index += 1


CONST = re.compile(r"\bconst\s+(\w+)\s*=([^;]*);", re.S)


def unmarked_surfaces(text: str) -> list[int]:
    """The 1-based lines of the floating glass elements with no host glass of their own and no allowance. A class
    held in a const of the same file (`const popupClassName = cx("ui-popup ui-glass ...")`) counts as the tag's."""
    floating_names = [m.group(1) for m in CONST.finditer(text) if POPUP.search(m.group(2)) and GLASS.search(m.group(2))]
    lines = []
    for offset, tag in opening_tags(text):
        named = any(re.search(r"\b" + name + r"\b", tag) for name in floating_names)
        floating = (POPUP.search(tag) and GLASS.search(tag)) or named
        if floating and not HOST_GLASS.search(tag) and "host-glass-allow:" not in tag:
            lines.append(text.count("\n", 0, offset) + 1)
    return lines


def native_materials(text: str) -> set[str]:
    body = "\n".join(code_lines(text))
    found = set()
    if REAL_GLASS.search(body):
        found.add("real-glass")
    if CARD_VEIL.search(body):
        found.add("card-veil")
    return found


def check(root: Path) -> list[str]:
    errors: list[str] = []
    manifest_path = root / MANIFEST
    try:
        manifest = json.loads(manifest_path.read_text())
    except (OSError, ValueError) as error:
        return [f"{MANIFEST}: unreadable ({error})"]
    kinds: dict = manifest.get("kinds", {})
    native: dict = manifest.get("native", {})
    pending: dict = manifest.get("web_floating_pending", {})

    sources = root / NATIVE_ROOT
    seen: dict[str, set[str]] = {}
    if sources.is_dir():
        for path in sorted(sources.rglob("*.swift")):
            materials = native_materials(path.read_text(errors="replace"))
            if materials:
                seen[path.relative_to(sources).as_posix()] = materials

    for rel, materials in seen.items():
        kind = native.get(rel)
        if kind is None:
            errors.append(
                f"{NATIVE_ROOT}/{rel}: [native-unlisted] builds {', '.join(sorted(materials))} with no kind in {MANIFEST}."
                " A new floating surface is web (web-floating, shared web); a native one needs a kind and a reason"
                " (design/surface-materials.md)."
            )
            continue
        spec = kinds.get(kind)
        if spec is None or kind in WEB_KINDS:
            errors.append(f"{NATIVE_ROOT}/{rel}: [native-kind] kind '{kind}' is not a native kind")
            continue
        allowed = set(spec.get("materials", []))
        wrong = materials - allowed
        if wrong:
            errors.append(
                f"{NATIVE_ROOT}/{rel}: [native-material] a {kind} surface shows {', '.join(sorted(wrong))};"
                f" its kind allows {', '.join(sorted(allowed))} (design/surface-materials.md)"
            )
    for rel in sorted(set(native) - set(seen)):
        errors.append(f"{MANIFEST}: [native-stale] {rel} is gone or builds no glass: remove its entry")

    web = root / WEB_ROOT
    unmarked: set[str] = set()
    if web.is_dir():
        for path in sorted(web.rglob("*.tsx")):
            rel = path.relative_to(web).as_posix()
            if not rel.startswith(WEB_SCOPES) or SKIP_WEB.search("/" + rel):
                continue
            for line in unmarked_surfaces(path.read_text(errors="replace")):
                unmarked.add(rel)
                if rel not in pending:
                    errors.append(
                        f"{WEB_ROOT}/{rel}:{line}: [web-floating] a floating ui-glass surface without data-host-glass:"
                        " in the agent pane it reads flat beside menus on the App's glass. Mark it"
                        ' data-host-glass="menu|popover|chip" (ui/glass/hostGlass.ts) or say why: host-glass-allow: <reason>'
                    )
    for rel in sorted(set(pending) - unmarked):
        errors.append(f"{MANIFEST}: [web-floating] {rel} is marked now: remove it from web_floating_pending")
    return errors


def main() -> int:
    root = Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
    errors = check(root)
    for error in errors:
        print(error)
    if errors:
        print(f"check-surface-materials: {len(errors)} finding(s). Rule: design/surface-materials.md")
        return 1
    print("check-surface-materials: every surface shows a material its kind allows")
    return 0


if __name__ == "__main__":
    sys.exit(main())
