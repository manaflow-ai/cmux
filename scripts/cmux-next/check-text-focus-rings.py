#!/usr/bin/env python3
"""Text fields never draw their own focus ring (cx-ncc.57).

A text field (a text input, a textarea, a contenteditable prompt) is :focus-visible on every
focus, the mouse included, and its box is a plain rectangle inside the rounded control that owns
it (the composer, the New Tab box, a picker's search row). A ring on the field draws a square
inside that control. The shared rule in webviews/src/pages/shared/desktop.css leaves text entry
out of the focus ring; the caret and the owning control's own rounded state (`:focus-within` on
the box, or the field's own border) show focus. This check refuses a new ring on a text field:

  css  a rule whose `:focus` / `:focus-visible` compound names a text field (input, textarea,
       contenteditable, ProseMirror, or a class or id with field / input / search / prompt in
       its name; buttons, checkboxes, radios, ranges, switches excluded) and
       sets a visible `outline` (or outline-width / outline-style / outline-color).
       A universal focus ring (`:focus-visible { outline: ... }`, the shared rule) must name
       `input`, `textarea` and `contenteditable` in its `:not(...)` list, and open menus
       and popovers (`[role="menu"]`, `.ui-popup`), which take focus on open.
  tsx  a Tailwind `focus:` / `focus-visible:` outline or ring utility on an <input> or <textarea>
       (`outline-none` / `ring-0` are fine).

  swift CmuxNext sources: a SwiftUI TextField / SecureField whose modifier chain (the next 8
       lines) has no `.focusEffectDisabled()`, and an AppKit NSTextField / NSSearchField /
       NSSecureTextField / NSTokenField / NSComboBox built in a file that never sets
       `focusRingType = .none` (labels excluded), or a label made selectable (`isSelectable = true`)
       without it. AppKit's and SwiftUI's ring is a system-blue
       rectangle around the field.

A deliberate exception carries `text-focus-allow: <reason>` in a comment on the rule (CSS) or on
the element's line (TSX, Swift). Exits 1 with one line per hit; 0 when clean.

  python3 scripts/cmux-next/check-text-focus-rings.py [--root DIR]
"""
import argparse
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
TREE = "webviews/src"

FOCUS = re.compile(r":focus(?:-visible)?(?![-\w])")
TEXT_COMPOUND = re.compile(
    r"(?:^|[\s>+~(,])(?:input|textarea)(?![-\w])|contenteditable|ProseMirror|role=\"?(?:textbox|searchbox)"
    r"|[.#][-\w]*(?:field|input|search|prompt)[-\w]*",
    re.I,
)
NOT_TEXT = re.compile(
    r"checkbox|radio|range|switch|toggle|slider|swatch|color|file\b|type=\"?(?:button|submit|reset|image)"
    r"|button|btn|chip|clear|cancel|icon",
    re.I,
)
VISIBLE_OUTLINE = re.compile(r"outline\s*:\s*(?!\s*(?:(?:none|0)(?:px)?\s*)+(?:!important)?\s*$)([^;]+)", re.I)
OUTLINE_PART = re.compile(r"outline-(?:width|style|color)\s*:\s*(?!\s*(?:none|0)(?:px)?\s*(?:!important)?\s*$)[^;]+", re.I)
ALLOW = "text-focus-allow:"
# A compound that is only the focus pseudo-class (plus :not/:is filters): `:focus-visible`,
# `*:focus`, `:focus-visible:not(...)`, `.page :focus-visible`.
UNIVERSAL = re.compile(r"^\*?:focus")

TSX_FIELD = re.compile(r"<(?:input|textarea)\b[^>]*?className=(?:\"([^\"]*)\"|\{`([^`]*)`\})", re.S)
TSX_RING = re.compile(
    r"(?<![-\w])(?:focus|focus-visible):(?:outline(?!-none)(?:-[-\w\[\]./%]+)?|ring(?!-0\b|-offset|-transparent)(?:-[-\w\[\]./%]+)?)(?![-\w])"
)


def split_list(selector: str) -> list[str]:
    """Split a selector list on its top-level commas (not the ones inside :not(...) or :is(...))."""
    parts, depth, start = [], 0, 0
    for index, char in enumerate(selector):
        if char in "([":
            depth += 1
        elif char in ")]":
            depth -= 1
        elif char == "," and depth == 0:
            parts.append(selector[start:index])
            start = index + 1
    parts.append(selector[start:])
    return parts


def focus_compound(selector: str) -> str:
    """The compound selector that carries :focus: from the last top-level combinator before it to
    the end of that compound (parentheses, as in :not(a, b c), never split it)."""
    match = FOCUS.search(selector)
    if not match:
        return selector.strip()
    depth, begin = 0, 0
    for index, char in enumerate(selector[: match.start()]):
        if char in "([":
            depth += 1
        elif char in ")]":
            depth -= 1
        elif depth == 0 and char in " >+~":
            begin = index + 1
    depth, finish = 0, len(selector)
    for index in range(match.start(), len(selector)):
        char = selector[index]
        if char in "([":
            depth += 1
        elif char in ")]":
            depth -= 1
        elif depth == 0 and char in " >+~":
            finish = index
            break
    return selector[begin:finish].strip()


def strip_not(compound: str) -> str:
    """The compound without its :not(...) and :where(...) arguments (they exclude, never select)."""
    out, index = [], 0
    while index < len(compound):
        match = re.compile(r":(?:not|where)\(").match(compound, index)
        if not match:
            out.append(compound[index])
            index += 1
            continue
        depth, index = 1, match.end()
        while index < len(compound) and depth:
            depth += {"(": 1, ")": -1}.get(compound[index], 0)
            index += 1
    return "".join(out)


def css_hits(path: str, text: str):
    # Keep comments' positions so an allow note on the rule is found.
    for match in re.finditer(r"([^{}]+)\{([^{}]*)\}", text):
        selector_raw, body = match.group(1), match.group(2)
        if ALLOW in selector_raw or ALLOW in body:
            continue
        selector = re.sub(r"/\*.*?\*/", "", selector_raw, flags=re.S).strip()
        if not FOCUS.search(selector):
            continue
        clean = re.sub(r"/\*.*?\*/", "", body, flags=re.S)
        declarations = [d.strip() for d in clean.split(";")]
        ring = [d for d in declarations if VISIBLE_OUTLINE.fullmatch(d) or OUTLINE_PART.fullmatch(d)]
        if not ring:
            continue
        for part in split_list(selector):
            if not FOCUS.search(part) or re.search(r":focus-within", focus_compound(part)):
                continue
            # A ring drawn by an ancestor or a pseudo-element (`.dot:has(input:focus-visible)::before`)
            # is not on the field.
            if re.search(r":has\([^)]*:focus", part) or "::" in part.split(":focus")[-1]:
                continue
            compound = focus_compound(part)
            if UNIVERSAL.match(compound):
                # A ring for every focused element (desktop.css's shared rule): it must leave text
                # entry out, or every text field draws a square inside its box.
                if not all(name in compound for name in ("input", "textarea", "contenteditable")):
                    line = text.count("\n", 0, match.start(2)) + 1
                    yield line, part.strip(), ring[0] + " on every element, text fields included"
                # An open menu or popover takes focus so its keys work; a ring drew a square
                # around the whole menu (Leo 2026-10-11). A list that takes Tab focus keeps it.
                elif not all(name in compound for name in ('[role="menu"]', ".ui-popup")):
                    line = text.count("\n", 0, match.start(2)) + 1
                    yield line, part.strip(), ring[0] + " on every element, open menus included"
                continue
            selecting = strip_not(compound)
            if TEXT_COMPOUND.search(" " + selecting) and not NOT_TEXT.search(selecting):
                line = text.count("\n", 0, match.start(2)) + 1
                yield line, part.strip(), ring[0]


def tsx_hits(text: str):
    for match in TSX_FIELD.finditer(text):
        classes = match.group(1) or match.group(2) or ""
        ring = TSX_RING.search(classes)
        if not ring:
            continue
        line_start = text.rfind("\n", 0, match.start()) + 1
        line_end = text.find("\n", match.end())
        if ALLOW in text[line_start : line_end if line_end != -1 else len(text)]:
            continue
        yield text.count("\n", 0, match.start()) + 1, ring.group(0)


SWIFT_TREE = "Packages/macOS/CmuxNext/Sources"
SWIFTUI_FIELD = re.compile(r"(?<![\w.])(?:TextField|SecureField)\s*\(")
APPKIT_FIELD = re.compile(
    r"(?<![\w.])(?:NSTextField|NSSearchField|NSSecureTextField|NSTokenField|NSComboBox)\s*\("
    r"(?!\s*(?:labelWithString|wrappingLabelWithString|labelWithAttributedString)\b)"
)

SELECTABLE = re.compile(r"(?<![\w.])(\w+)\.isSelectable\s*=\s*true\b")


def swift_hits(text: str):
    """SwiftUI fields without .focusEffectDisabled() in their own modifier chain (up to 8 lines, never
    past the next field), and AppKit editable fields whose bound name never gets
    `<name>.focusRingType = .none` in the file."""
    lines = text.split("\n")
    for index, line in enumerate(lines):
        code = re.sub(r'"(?:[^"\\]|\\.)*"', '""', line.split("//", 1)[0])
        if ALLOW in line:
            continue
        if SWIFTUI_FIELD.search(code) and not re.search(r"\b(?:struct|class|enum|extension)\s+\w*(?:TextField|SecureField)", code):
            chain = [code[SWIFTUI_FIELD.search(code).end() :]]
            for following in lines[index + 1 : index + 9]:
                if SWIFTUI_FIELD.search(following.split("//", 1)[0]):
                    break
                chain.append(following)
            if not re.search(r"\.focusEffectDisabled\(\s*\)", "\n".join(chain)):
                yield index + 1, "a SwiftUI text field without .focusEffectDisabled()"
        match = APPKIT_FIELD.search(code)
        if match:
            bound = re.search(r"(?:let|var)?\s*(\w+)\s*(?::\s*[\w.]+)?\s*=\s*(?:\w+\s*\?\s*)?[\w.]*$", code[: match.start()])
            name = bound.group(1) if bound else None
            if name and re.search(rf"\b{re.escape(name)}\.focusRingType\s*=\s*\.none", text):
                continue
            if name is None and re.search(r"focusRingType\s*=\s*\.none", text):
                continue  # an unbound field (an argument): the file-level setting is the best signal
            yield index + 1, f"an AppKit text field ({name or 'unbound'}) without focusRingType = .none"
        # A selectable label takes the keyboard on a click and draws the same ring (cx-ncc.88);
        # an NSTextView draws none.
        selectable = SELECTABLE.search(code)
        if selectable:
            name = selectable.group(1)
            if re.search(rf"\b{re.escape(name)}\s*(?::\s*NSTextView\b|=\s*NSTextView\s*\()", text):
                continue
            if re.search(rf"\b{re.escape(name)}\.focusRingType\s*=\s*\.none", text):
                continue
            yield index + 1, f"a selectable AppKit label ({name}) without focusRingType = .none"

def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--root", default=REPO)
    args = parser.parse_args()
    tree = os.path.join(args.root, TREE)
    if not os.path.isdir(tree):
        print(f"check-text-focus-rings: no {TREE} under {args.root}", file=sys.stderr)
        return 2
    hits = []
    for directory, dirs, files in os.walk(tree):
        dirs[:] = [d for d in dirs if d not in ("node_modules", "dist", "generated")]
        for name in sorted(files):
            path = os.path.join(directory, name)
            rel = os.path.relpath(path, args.root)
            if name.endswith(".css"):
                if not os.path.isfile(path):
                    continue
                with open(path, encoding="utf-8", errors="replace") as handle:
                    text = handle.read()
                for line, selector, ring in css_hits(path, text):
                    hits.append(f"{rel}:{line}: `{selector}` sets `{ring}` on a focused text field")
            elif name.endswith(".tsx") and ".test." not in name:
                if not os.path.isfile(path):
                    continue
                with open(path, encoding="utf-8", errors="replace") as handle:
                    text = handle.read()
                for line, utility in tsx_hits(text):
                    hits.append(f"{rel}:{line}: `{utility}` on a text field")
    swift_tree = os.path.join(args.root, SWIFT_TREE)
    if not os.path.isdir(swift_tree):
        print(f"check-text-focus-rings: no {SWIFT_TREE} under {args.root}", file=sys.stderr)
        return 2
    for directory, dirs, files in os.walk(swift_tree):
        dirs[:] = [d for d in dirs if d not in (".build", "generated")]
        for name in sorted(files):
            path = os.path.join(directory, name)
            if not name.endswith(".swift") or not os.path.isfile(path):
                continue
            with open(path, encoding="utf-8", errors="replace") as handle:
                text = handle.read()
            for line, what in swift_hits(text):
                hits.append(f"{os.path.relpath(path, args.root)}:{line}: {what}")
    for hit in hits:
        print(hit)
    if hits:
        print(
            f"check-text-focus-rings: {len(hits)} focus ring(s) on text fields. A text field shows focus through"
            " its caret and its owning control's rounded `:focus-within` state, never a ring of its own"
            " (webviews/src/pages/shared/desktop.css). Mark a deliberate exception `text-focus-allow: <reason>`.",
            file=sys.stderr,
        )
        return 1
    print("check-text-focus-rings: no focus ring on a text field")
    return 0


if __name__ == "__main__":
    sys.exit(main())
