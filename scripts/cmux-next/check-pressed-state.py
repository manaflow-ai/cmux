#!/usr/bin/env python3
"""Refuse a pressed (mousedown) state that changes anything but the background.

Design rule (Lawrence 2026-11-15): a held button looks like its hover with a
different background fill. Pressing never makes the label bold, never changes
the font, size, scale, padding, offset, opacity of the label or the icon.
The shared looks that own this are:

  * AppKit chrome: `ChromeHover` (CmuxNextDesign), `ChromeHover.State(pressed:)`
    picks `Palette.pressedFill`.
  * SwiftUI on macOS: `CmuxPressFillButtonStyle` / `.buttonStyle(.cmuxPressFill)` (CmuxNextDesign).
  * SwiftUI on iOS: `CmuxMobilePressFillStyle` / `.buttonStyle(.cmuxPressFill)` (CmuxMobileDesign).
  * Web views: `.ui-btn` (webviews/src/ui/controls.css), whose `:active`
    sets `background` only.

What this lint refuses:

  * CSS: a rule whose selector holds `:active` or `[data-press-active]` and
    sets a property other than the background (`background*`, `cursor`,
    `transition*`, custom properties, `outline: none`). `color`, `fill`,
    `stroke` and `opacity` pass only when the same rule also styles `:hover`
    or `:focus-visible`, so the press keeps the hover's ink.
  * Tailwind: an `active:` class other than `active:bg-*` / `active:cursor-*`.
  * Swift: a line that reads a pressed state (`isPressed`, `pressed`,
    `isHighlighted`) and changes the font, weight, scale, frame, padding,
    offset, rotation, image, symbol or line width; or `opacity`/`alphaValue`
    of the label (a line naming a background or fill passes). An
    `if <pressed> {` block is checked line by line too.

A deliberate exception carries `pressed-state: allow <reason>` on the line or
the line above it. Tests, galleries and prototypes are not scanned.

Usage: check-pressed-state.py [ROOT] (default: this checkout). `--self-test` runs the detector against its
own examples. The pre-push gate and cmux-next.yml's "Buttons change only their fill when pressed" run it.
"""

from __future__ import annotations

import os
import re
import sys
from dataclasses import dataclass
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent

SCANNED_PREFIXES = (
    "Packages/macOS/CmuxNext/Sources/",
    "cmux-next-ios/",
    "webviews/src/",
    "agent-chat/src/",
)
SKIPPED_PARTS = (
    "/Tests/",
    "/tests/",
    "/test/",
    "/gallery/",
    "/prototypes/",
    "/prototype/",
    "/node_modules/",
    "/generated/",
)
SKIPPED_SUFFIXES = (".test.ts", ".test.tsx", ".gallery.tsx", ".gallery.ts", ".gallery.css", ".stories.tsx")

ALLOW_MARK = "pressed-state: allow"

# ---------------------------------------------------------------- CSS

PRESSED_SELECTOR = re.compile(r":active(?![\w-])|\[data-press-active")
# A toggle that is on (Base UI `data-pressed`, `aria-pressed="true"`): it may take a selected fill and ink,
# never a weight, size or transform, so its label does not grow when it turns on.
TOGGLE_ON_SELECTOR = re.compile(r"\[data-pressed\]|\[aria-pressed=\"?true\"?\]")
HOVER_SELECTOR = re.compile(r":hover(?![\w-])|:focus-visible(?![\w-])")
# What changes a label's weight, size or place. Never on a press or an on toggle, even when hover shares it.
LAYOUT_PROPS = re.compile(
    r"^(font(-weight|-size|-variation-settings|-stretch|-family)?|letter-spacing|line-height|transform|scale|translate|rotate|"
    r"width|height|min-width|min-height|padding(-[\w-]+)?|margin(-[\w-]+)?|inset|top|left|right|bottom|zoom|border(-[\w-]+)?-width)$"
)
NONE_VALUES = {"none", "0", "initial", "unset"}
ALWAYS_OK_PROPS = re.compile(
    r"^(--[\w-]+|background(-color|-image)?|cursor|transition(-[\w-]+)?|-webkit-tap-highlight-color)$"
)
INK_PROPS = {"color", "fill", "stroke", "opacity", "-webkit-text-fill-color"}


@dataclass(frozen=True)
class Finding:
    path: str
    line: int
    what: str

    def render(self) -> str:
        return f"{self.path}:{self.line}: {self.what}"


def _strip_css_comments(text: str) -> str:
    # Keep newlines so line numbers stay right.
    return re.sub(r"/\*.*?\*/", lambda m: re.sub(r"[^\n]", " ", m.group(0)), text, flags=re.S)


def _split_top_level(text: str, sep: str) -> list[str]:
    out, depth, cur = [], 0, []
    for ch in text:
        if ch in "([":
            depth += 1
        elif ch in ")]":
            depth -= 1
        if ch == sep and depth == 0:
            out.append("".join(cur))
            cur = []
        else:
            cur.append(ch)
    out.append("".join(cur))
    return out


def check_css(path: str, raw: str) -> list[Finding]:
    text = _strip_css_comments(raw)
    raw_lines = raw.splitlines()
    findings: list[Finding] = []
    # A stack of (selector, start index of the block body).
    stack: list[tuple[str, int]] = []
    seg_start = 0
    i = 0
    while i < len(text):
        ch = text[i]
        if ch == "{":
            head = text[seg_start:i]
            # The selector is what follows the last declaration end in this segment.
            selector = re.split(r";", head)[-1].strip()
            stack.append((selector, i + 1))
            seg_start = i + 1
        elif ch == "}":
            if stack:
                selector, body_start = stack.pop()
                _check_css_rule(path, text, raw_lines, selector, body_start, i, findings)
            seg_start = i + 1
        i += 1
    return findings


def _strip_not(selector: str) -> str:
    """The selector without the arguments of `:not(...)`: `:not(:active)` is not a pressed state."""
    out, i = [], 0
    while i < len(selector):
        if selector.startswith(":not(", i):
            depth, j = 0, i + 4
            while j < len(selector):
                if selector[j] == "(":
                    depth += 1
                elif selector[j] == ")":
                    depth -= 1
                    if depth == 0:
                        break
                j += 1
            i = j + 1
            continue
        out.append(selector[i])
        i += 1
    return "".join(out)


def _check_css_rule(path, text, raw_lines, selector, body_start, body_end, findings):
    if selector.startswith("@"):
        return
    selectors = [_strip_not(s) for s in _split_top_level(selector, ",")]
    pressed = any(PRESSED_SELECTOR.search(s) for s in selectors)
    # An on toggle counts only when the rule styles the toggle itself: not a `::before` mark, not a child.
    toggle_on = any(
        TOGGLE_ON_SELECTOR.search(s.strip().split()[-1]) and "::" not in s.strip().split()[-1] for s in selectors if s.strip()
    )
    if not pressed and not toggle_on:
        return
    shares_hover = any(HOVER_SELECTOR.search(s) for s in selectors)
    body = text[body_start:body_end]
    # Only this block's own declarations: blank out nested blocks.
    flat, depth = [], 0
    for ch in body:
        if ch == "{":
            depth += 1
        if depth == 0:
            flat.append(ch)
        else:
            flat.append("\n" if ch == "\n" else " ")
        if ch == "}":
            depth -= 1
    flat_body = "".join(flat)
    offset = body_start
    for decl in re.finditer(r"([-\w]+)\s*:\s*([^;}]*)", flat_body):
        prop = decl.group(1).strip().lower()
        value = decl.group(2).strip().lower()
        value = value.replace("!important", "").strip()
        if ALWAYS_OK_PROPS.match(prop):
            continue
        layout = bool(LAYOUT_PROPS.match(prop))
        if not layout and value in NONE_VALUES:
            continue  # Taking an edge, ring or shadow away keeps the hover's look.
        if not pressed and not layout:
            continue  # An on toggle may take its selected fill and ink.
        if not layout and shares_hover:
            continue  # The press keeps the hover's look; this rule styles both.
        line = text.count("\n", 0, offset + decl.start()) + 1
        if _allowed(raw_lines, line):
            continue
        state = "pressed" if pressed else "on toggle"
        findings.append(Finding(path, line, f"{state} `{selector.strip()[:80]}` sets `{prop}`; a press or an on toggle changes the background only"))


# ---------------------------------------------------------------- Tailwind

TAILWIND_ACTIVE = re.compile(r"""(?:(?<=[\s"'`{])|^)active:(!?[a-z\[][\w\-\[\]/.%#()!]*)""")
TAILWIND_OK = re.compile(r"^!?(bg-|cursor-)")


def check_tailwind(path: str, raw: str) -> list[Finding]:
    findings = []
    lines = raw.splitlines()
    for n, line in enumerate(lines, 1):
        for m in TAILWIND_ACTIVE.finditer(line):
            cls = m.group(1)
            if TAILWIND_OK.match(cls) or _allowed(lines, n):
                continue
            findings.append(Finding(path, n, f"`active:{cls}`; a press changes the background only (`active:bg-*`)"))
    return findings


# ---------------------------------------------------------------- Swift

SWIFT_PRESSED = re.compile(r"\b(isPressed|pressed|isHighlighted|wasPressed)\b")
SWIFT_FORBIDDEN = re.compile(
    r"\.scaleEffect\(|\.fontWeight\(|\.bold\(|\.font\(|\bfont\s*=|boldSystemFont|\bweight:|\.offset\(|"
    r"rotationEffect|\btransform\b|\.frame\(|\.padding\(|imageScale|symbolVariant|\bimage\s*=|\.image\(|"
    r"\blineWidth\s*=|\.brightness\(|\bsetAffineTransform|\.scale\b|CGAffineTransform|CATransform3D"
)
SWIFT_DIMMING = re.compile(r"\.opacity\(|\balphaValue\s*=")
SWIFT_FILL_WORDS = re.compile(r"background|fill|Fill|plate|Plate|wash|Wash", re.I)
# SwiftUI's own plain, borderless and link styles dim the label while it is held.
SWIFT_DIMMING_STYLE = re.compile(r"\.buttonStyle\(\s*\.(plain|borderless|link)\s*\)|\b(Plain|Borderless|Link)ButtonStyle\(\)")
SWIFT_IF_PRESSED_BLOCK = re.compile(r"^\s*(\}\s*else\s+)?if\b.*\b(isPressed|pressed|isHighlighted)\b.*\{\s*$")


def _swift_line_problem(line: str, context: str = "") -> str | None:
    """`context` is the two lines above: an opacity on a fill drawn there (`.fill(x)` then
    `.opacity(pressed ? 1 : 0)`) shows a background, not a dimmed label."""
    code = line.split("//", 1)[0]
    m = SWIFT_FORBIDDEN.search(code)
    if m:
        return m.group(0).strip(".( =")
    m = SWIFT_DIMMING.search(code)
    if m and not SWIFT_FILL_WORDS.search(code) and not SWIFT_FILL_WORDS.search(context):
        return m.group(0).strip(".( =")
    return None


def check_swift(path: str, raw: str) -> list[Finding]:
    findings = []
    lines = raw.splitlines()
    n = 0
    while n < len(lines):
        line = lines[n]
        code = line.split("//", 1)[0]
        style = SWIFT_DIMMING_STYLE.search(code)
        if style and not _allowed(lines, n + 1):
            findings.append(Finding(path, n + 1, f"`{style.group(0)}` dims the label while held; use `.buttonStyle(.cmuxPressFill)`"))
        if SWIFT_PRESSED.search(code):
            problem = _swift_line_problem(line, "\n".join(l.split("//", 1)[0] for l in lines[max(0, n - 2):n]))
            if problem and not _allowed(lines, n + 1):
                findings.append(Finding(path, n + 1, f"pressed state changes `{problem}`; a press changes the background only"))
            if SWIFT_IF_PRESSED_BLOCK.match(code):
                depth = code.count("{") - code.count("}")
                k = n + 1
                while k < len(lines) and depth > 0:
                    inner = lines[k]
                    inner_code = inner.split("//", 1)[0]
                    depth += inner_code.count("{") - inner_code.count("}")
                    problem = _swift_line_problem(inner)
                    if problem and not _allowed(lines, k + 1) and not _allowed(lines, n + 1):
                        findings.append(Finding(path, k + 1, f"pressed branch changes `{problem}`; a press changes the background only"))
                    k += 1
        n += 1
    return findings


# ---------------------------------------------------------------- driver


def _allowed(lines: list[str], line_no: int) -> bool:
    here = lines[line_no - 1] if 0 < line_no <= len(lines) else ""
    above = lines[line_no - 2] if line_no >= 2 else ""
    return ALLOW_MARK in here or ALLOW_MARK in above


def scanned(path: str) -> bool:
    if not path.startswith(SCANNED_PREFIXES):
        return False
    if any(part in "/" + path for part in SKIPPED_PARTS) or path.endswith(SKIPPED_SUFFIXES):
        return False
    return path.endswith((".swift", ".css", ".tsx", ".ts", ".jsx"))


def check_file(path: str, raw: str) -> list[Finding]:
    if path.endswith(".swift"):
        return check_swift(path, raw)
    if path.endswith(".css"):
        return check_css(path, raw)
    return check_tailwind(path, raw)


def source_files(root: Path) -> list[str]:
    """The scanned files under `root`, repo-relative: a checkout, or the gate's tree of a push's files."""
    out = []
    for prefix in SCANNED_PREFIXES:
        base = root / prefix
        if not base.is_dir():
            continue
        for dirpath, dirnames, filenames in os.walk(base):
            dirnames[:] = [d for d in dirnames if d not in ("node_modules", ".build", "dist", "DerivedData")]
            for name in filenames:
                rel = os.path.relpath(os.path.join(dirpath, name), root).replace(os.sep, "/")
                if scanned(rel):
                    out.append(rel)
    return sorted(out)


def self_test() -> int:
    bad = {
        "a.css": ".b:active { font-weight: 600; }",
        "b.css": ".b:active { transform: scale(0.97); background: red }",
        "c.css": ".b { &:active { padding: 2px } }",
        "d.css": ".b:active { color: red }",
        "e.css": ".b[data-press-active] { font-size: 13px }",
        "f.tsx": 'const c = "px-2 active:scale-95 hover:bg-x";',
        "g.tsx": "<b className={`active:font-semibold`} />",
        "h.swift": "label.scaleEffect(configuration.isPressed ? 0.98 : 1)",
        "i.swift": "            .fontWeight(configuration.isPressed ? .semibold : .regular)",
        "j.swift": "if isPressed {\n    title.font = .boldSystemFont(ofSize: 12)\n}",
        "k.swift": ".opacity(configuration.isPressed ? 0.7 : 1)",
        "l.swift": "layer.transform = isPressed ? CATransform3DMakeScale(0.96, 0.96, 1) : CATransform3DIdentity",
        "m.css": ".b:hover, .b:active { font-weight: 600 }",
        "n.css": ".seg [data-pressed] { font-weight: var(--weight-emphasis) }",
        "o.css": '.chip[aria-pressed="true"] { font-weight: 600 }',
        "p.swift": ".buttonStyle(.plain)",
    }
    good = {
        "a.css": ".b:active:not(:disabled) { background: var(--p); cursor: default }",
        "b.css": ".b:hover, .b:active { color: red; background: x }",
        "c.css": ".b:is(:hover, :active) { color: red }",
        "d.css": "/* .b:active { font-weight: 600 } */ .c { font-weight: 600 }",
        "e.css": ".b:active { outline: none; --ds-x: 1px; transition: background 0s }",
        "f.css": ".b:active { font-weight: 600 } /* pressed-state: allow drag handle */",
        "g.tsx": 'const c = "active:bg-pressed active:cursor-default"; const o = { active: true };',
        "h.swift": ".background(configuration.isPressed ? p.selection : p.hover, in: shape)",
        "i.swift": "let fill = isPressed ? Palette.pressedFill : nil",
        "j.swift": "if isPressed {\n    fill = Palette.pressedFill\n}",
        "k.swift": "// pressed-state: allow key cap travel\n.offset(y: configuration.isPressed ? 1 : 0)",
        "l.swift": ".background(Color.x.opacity(configuration.isPressed ? 1 : 0))",
        "l2.swift": "    .background {\n        theme.colors.fillSelected.color\n            .opacity(configuration.isPressed ? 1 : 0)",
        "m.swift": "let isPressed = false // .font(.bold)",
        "n.css": ".b:not(:hover, :active) { box-shadow: 0 0 1px red; font-weight: 600 }",
        "o.css": ".b:is(:active, [aria-expanded=true]) { background: x; box-shadow: none }",
        "p.css": ".b:is(:hover, :active) { box-shadow: inset 0 0 0 1px red; color: x }",
        "q.css": '.b[aria-pressed="true"] { background: x; color: y }',
        "r.swift": ".buttonStyle(.cmuxPressFill)",
    }
    failures = []
    for name, src in bad.items():
        if not check_file(name, src):
            failures.append(f"missed: {name}: {src!r}")
    for name, src in good.items():
        found = check_file(name, src)
        if found:
            failures.append(f"false positive: {name}: {[f.render() for f in found]}")
    for f in failures:
        print(f, file=sys.stderr)
    print(f"self-test: {len(bad) + len(good) - len(failures)}/{len(bad) + len(good)} passed")
    return 1 if failures else 0


def main(argv: list[str]) -> int:
    if "--self-test" in argv:
        return self_test()
    args = [a for a in argv if not a.startswith("--")]
    root = Path(args[0]).resolve() if args else REPO_ROOT
    paths = source_files(root)
    findings: list[Finding] = []
    for path in paths:
        try:
            raw = (root / path).read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            continue
        findings.extend(check_file(path, raw))
    github = "--github" in argv or os.environ.get("GITHUB_ACTIONS") == "true"
    for f in findings:
        print(f"::error file={f.path},line={f.line}::{f.what}" if github else f.render())
    if findings:
        print(
            f"\n{len(findings)} pressed-state change(s) other than the background. A held button keeps its hover look "
            "and changes only its fill: use ChromeHover / CmuxPressFillButtonStyle / CmuxMobilePressFillStyle / "
            ".ui-btn. A deliberate exception carries `pressed-state: allow <reason>`. See design/pressed-state.md.",
            file=sys.stderr,
        )
        return 1
    print(f"pressed-state: ok ({len(paths)} files)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
