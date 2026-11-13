#!/usr/bin/env python3
"""Every button rounds as a tab (Lawrence 2026-11-12: "roundness of all buttons should match roundness of
tabs/workspaces").

The one button corner is the tab's: `Metrics.buttonCornerRadius` in Swift (Chrome's tab corner on the tab
height, the radius sidebar workspace rows share, `Metrics.tabCornerRadius`), and in pages
`var(--ds-radius-control)`, which reads the host's `--cmux-button-radius` (WebTheme, the same value in CSS
px). A button nested in a rounded shape keeps the concentric rule: `Metrics.buttonCornerRadius(nestedIn:inset:)`
in Swift, `calc(var(--ds-radius-control) - <inset>)` in CSS.

Fails on a button's corner that is anything else:
  Swift (Packages/macOS/CmuxNext/Sources): in a button file (its name holds `Button`, or it declares a
          `ButtonStyle`, an `NSButton` subclass or a type named `...Button`), and on any line that rounds a
          value named `button`/`...Button`, a corner radius (`cornerRadius =`/`:`, `RoundedRectangle(cornerRadius:`,
          `xRadius:`, a `...CornerRadius` declaration) that holds a number (a literal, a capsule's `/ 2`) or
          another corner token (`itemCornerRadius`, `controlCornerRadius`, `insetCornerRadius`,
          `surfaceCornerRadius`, `panelCornerRadius`, `chipCornerRadius`, `capsuleRadius`, `Metrics.corners`)
          and not `buttonCornerRadius` or `tabCornerRadius`.
  CSS (webviews/src, *.css): a `border-radius` in a rule whose subject is a button (`button`,
          `[role="button"]`, a class or id ending in `button`/`btn`/`Button`) that does not read
          `--ds-radius-control` or `--cmux-button-radius` (`0`, `inherit` and `unset` pass).
  TSX (webviews/src, *.tsx): a `<button` element whose className has a `rounded-*` other than
          `rounded-control`, `rounded-none` or one reading `--ds-radius-control`.
A shape that is not a button's own corner (a switch track, a menu row's highlight, a concentric child of a
capsule) says why on its line: `// radius-allow: <reason>` (Swift) or `/* radius-allow: <reason> */` (CSS).

  python3 scripts/cmux-next/check-button-radius.py [ROOT]
"""
import os
import re
import sys

SWIFT_ROOT = "Packages/macOS/CmuxNext/Sources"
WEB_ROOT = "webviews/src"
# The token's own definition and the probes that measure radii.
SKIP = {
    "Packages/macOS/CmuxNext/Sources/CmuxNextDesign/Metrics+ButtonCorner.swift",
}

ALLOW_SWIFT = re.compile(r"//\s*radius-allow:\s*\S")
ALLOW_CSS = re.compile(r"/\*\s*radius-allow:\s*\S")

# A button file: its name, or a button type it declares.
BUTTON_TYPE = re.compile(
    r"\b(?:struct|class|enum)\s+\w*Button(?:View|Style|Cell)?\b"
    r"|\b(?:struct|class|enum)\s+\w+\s*:\s*(?:[\w.]+\s*,\s*)*[\w.]*(?:ButtonStyle|Button)\b")
# A line that rounds a button directly, in any file: `button.layer?.cornerRadius = ...`.
BUTTON_RECEIVER = re.compile(r"\b\w*(?:button|Button)\b[\w?.]*\.(?:layer\??\.)?cornerRadius\s*=")
RADIUS_SITE = re.compile(
    r"(?<![\w])cornerRadius\s*[:=]"
    r"|\.cornerRadius\s*=|RoundedRectangle\(cornerRadius:"
    r"|\b[xy]Radius:"
    r"|\b(?:var|let|func)\s+\w*[Cc]ornerRadius\b")
OTHER_TOKEN = re.compile(
    r"\b(?:item|control|inset|surface|panel|chip|highlight|plate)CornerRadius\b|\bcapsuleRadius\b|\bMetrics\.corners\b"
    r"|\b(?:item|highlight)Radius\b")
NUMBER = re.compile(r"(?<![\w.])\d+(?:\.\d+)?(?![\w.])")
# A button radius token declared anywhere (`OmnibarStyle.buttonCornerRadius`).
BUTTON_DECL = re.compile(r"\b(?:var|let|func)\s+\w*[Bb]utton\w*Radius\b")
DECLARATION = re.compile(r"(?:var|let|func)\s+\w+(?:\([^)]*\))?\s*(?::\s*[\w.?]+)?\s*")
# The token, or a button token declared from it (`chipButtonCornerRadius`; BUTTON_DECL checks each declaration).
BUTTON_TOKEN = re.compile(r"\b(?:\w*[bB]uttonCornerRadius|tabCornerRadius)\b")
# A parameter or property typed as a radius (`cornerRadius: CGFloat`) holds no value of its own.
TYPED = re.compile(r"\b\w*[cC]ornerRadius\s*:\s*(?:CGFloat|Double|Float)\b")
STRING = re.compile(r'"(?:\\.|[^"\\])*"')


def swift_findings(rel, text):
    is_button_file = "Button" in os.path.basename(rel) or bool(BUTTON_TYPE.search(text))
    out = []
    for number, raw in enumerate(text.splitlines(), 1):
        code = raw.split("//", 1)[0]
        if not code.strip() or ALLOW_SWIFT.search(raw):
            continue
        if not (is_button_file and RADIUS_SITE.search(code)) and not BUTTON_RECEIVER.search(code) \
                and not BUTTON_DECL.search(code):
            continue
        site = BUTTON_DECL.search(code) or RADIUS_SITE.search(code) or BUTTON_RECEIVER.search(code)
        value = STRING.sub('""', code[site.start():])
        if TYPED.match(value):
            continue
        declared = DECLARATION.match(value)
        if declared:
            # `static var buttonCornerRadius: CGFloat { 8 }` names the token; its body is what it rounds by.
            value = value[declared.end():]
        if BUTTON_TOKEN.search(value):
            continue
        # A bare radius passed along (`= cornerRadius`, `cornerRadius: radius`) is judged where it is made.
        literal = [m.group() for m in NUMBER.finditer(value) if m.group() != "0"]
        if literal or OTHER_TOKEN.search(value):
            out.append((number, raw.strip()))
    return out


CSS_COMMENT = re.compile(r"/\*.*?\*/", re.S)
# A segment of a segmented control (`.segment`, `.cu-segment-button`) is a button too.
BUTTON_SUBJECT = re.compile(r'(?:^|[\s>+~(,])button\b|\[role=["\']?button|[#.][\w-]*(?:button|btn|Button)(?![\w-])'
                            r'|\.segment(?![\w-])')
RADIUS_DECL = re.compile(r"(?<![\w-])border(?:-(?:top|bottom|start|end)-(?:left|right|start|end))?-radius\s*:\s*([^;}]*)")
CSS_PASS = re.compile(r"--ds-radius-control\b|--cmux-button-radius\b")
CSS_KEYWORD = re.compile(r"^\s*(?:0|0px|inherit|unset|initial)\s*(?:!important)?\s*$")


def subject_is_button(selector):
    for part in selector.split(","):
        # The subject is the last compound selector: `.x-button svg` rounds the svg, not the button.
        compound = re.split(r"\s*[\s>+~]\s*", part.strip())[-1] if part.strip() else ""
        compound = re.sub(r"::?[\w-]+(\([^)]*\))?", "", compound)
        if BUTTON_SUBJECT.search(" " + compound):
            return True
    return False


def css_findings(text):
    out = []
    # Keep the allow comments' positions: mark the lines that carry one, then drop comments.
    allowed = {text.count("\n", 0, m.start()) + 1 for m in ALLOW_CSS.finditer(text)}
    bare = CSS_COMMENT.sub(lambda m: re.sub(r"[^\n]", " ", m.group()), text)
    stack = []
    start = 0
    for index, char in enumerate(bare):
        if char == "{":
            selector = bare[start:index].strip().split(";")[-1].strip()
            parent = stack[-1] if stack else ""
            if "&" in selector:
                selector = ",".join(selector.replace("&", p.strip() or "") for p in (parent.split(",") or [""]))
            elif parent and not selector.startswith("@") and not parent.startswith("@"):
                selector = ",".join(f"{p.strip()} {s.strip()}" for p in parent.split(",") for s in selector.split(","))
            elif parent.startswith("@") and stack[:-1]:
                selector = selector
            stack.append(selector)
            start = index + 1
        elif char == "}":
            body = bare[start:index]
            if stack:
                check_body(stack[-1], body, start, bare, allowed, out)
                stack.pop()
            start = index + 1
        elif char == ";" and stack:
            pass
    return out


def check_body(selector, body, offset, bare, allowed, out):
    if selector.startswith("@") or not subject_is_button(selector):
        return
    # Only this rule's own declarations: a nested rule's body is judged with its own selector.
    depth, own = 0, []
    for char in body:
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
        own.append(char if depth == 0 else " ")
    own = "".join(own)
    for match in RADIUS_DECL.finditer(own):
        value = match.group(1)
        line = bare.count("\n", 0, offset + match.start()) + 1
        if line in allowed or CSS_PASS.search(value) or CSS_KEYWORD.match(value):
            continue
        out.append((line, f"{selector.strip()[:80]} {{ border-radius: {value.strip()} }}"))


TSX_BUTTON = re.compile(r"<button\b[^>]*?className=(?:\"([^\"]*)\"|\{`([^`]*)`\}|\{\"([^\"]*)\"\})", re.S)
ROUNDED = re.compile(r"(?<![\w-])rounded(?:-[a-z]{1,2})?(?:-[\w.]+|-\[[^\]]+\])?(?![\w-])")
TSX_PASS = re.compile(r"^rounded-(?:control|none|\[var\(--ds-radius-control\)\]|\[calc\(var\(--ds-radius-control\).*\])$")


def tsx_findings(text):
    out = []
    for match in TSX_BUTTON.finditer(text):
        classes = next(group for group in match.groups() if group is not None)
        for rounded in ROUNDED.finditer(classes):
            token = rounded.group()
            if TSX_PASS.match(token):
                continue
            line = text.count("\n", 0, match.start()) + 1
            if ALLOW_CSS.search(text.splitlines()[line - 1]) or "radius-allow:" in text.splitlines()[line - 1]:
                continue
            out.append((line, f"<button className=... {token}>"))
    return out


def walk(root, base, suffixes):
    top = os.path.join(root, base)
    for directory, dirs, files in os.walk(top):
        # Galleries and prototypes are dev surfaces that compare looks; they draw what they compare.
        dirs[:] = [d for d in dirs if d not in ("node_modules", "dist", "build", "__tests__", "test", "tests",
                                                 "gallery", "prototypes", "prototype")]
        for name in files:
            if name.endswith(suffixes) and ".test." not in name and ".spec." not in name and ".gallery" not in name:
                path = os.path.join(directory, name)
                yield os.path.relpath(path, root).replace(os.sep, "/"), path


def main(argv):
    root = os.path.abspath(argv[1] if len(argv) > 1 else os.path.join(os.path.dirname(__file__), "..", ".."))
    findings = []
    for rel, path in walk(root, SWIFT_ROOT, (".swift",)):
        if rel in SKIP:
            continue
        with open(path, encoding="utf-8", errors="replace") as handle:
            findings += [(rel, n, what) for n, what in swift_findings(rel, handle.read())]
    for rel, path in walk(root, WEB_ROOT, (".css", ".tsx")):
        with open(path, encoding="utf-8", errors="replace") as handle:
            text = handle.read()
        found = css_findings(text) if rel.endswith(".css") else tsx_findings(text)
        findings += [(rel, n, what) for n, what in found]
    if findings:
        for rel, number, what in findings:
            print(f"{rel}:{number}: a button's corner off the tab's: {what}")
        print(f"check-button-radius: {len(findings)} button corner(s) off the one token. Use Metrics.buttonCornerRadius "
              "(nested: Metrics.buttonCornerRadius(nestedIn:inset:)) in Swift and var(--ds-radius-control) in pages, "
              "or say why on the line (radius-allow: <reason>).", file=sys.stderr)
        return 1
    print("check-button-radius: ok (every button rounds as a tab)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
