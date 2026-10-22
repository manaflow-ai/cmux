#!/usr/bin/env python3
"""Fail a composer control that sizes itself (Leo 2026-10-22, ask-d4eed794c9, on Lawrence's notes of
"weird padding" on the mode and model pills and the + button's "left/top/bottom padding": "did we have
a generalized solulu to the weird pills?").

Every control of the shared composer (+, the mode, the model button, Options, Plan, the mic, the
dictation finish key, Codex's bolt, ↵, Stop, Send and the context ring) is one primitive, `.acpmux-pill`
(`.acpmux-pill-icon` for a square), whose height, padding, square size, corner and gap come only from
the --acpmux-pill-* tokens in webviews/src/agent-session/acpmux/composerLocation.css. This check fails:

- a stylesheet rule under webviews/src/agent-session/acpmux whose subject is a composer control and
  that sets its own padding, height, corner radius or gap, or a width or min-width with a length
  (`auto`, `0`, `100%` and `max-content` are layout, not size). A rule may still set a --acpmux-pill-*
  token to resize a whole row or one control's family (a narrow row, the classic New Tab mode square);
- a JSX element whose class names a composer control without `acpmux-pill`, so a new control gets the
  primitive or fails here.

Run from anywhere:

    python3 scripts/cmux-next/check-composer-pills.py [ROOT]
"""
import os, re, sys

FOLDER = "webviews/src/agent-session/acpmux"
# The primitive itself: the only rules that set a pill's geometry.
PRIMITIVE = {".acpmux-pill", ".acpmux-pill.acpmux-pill-icon"}
CONTROLS = (
    "acpmux-pill", "acpmux-picker-button", "acpmux-access-trigger", "acpmux-plan", "acpmux-mic",
    "acpmux-dictation-finish", "acpmux-fast", "acpmux-send", "acpmux-context-ring",
)
CONTROL = re.compile(r"\.(?:" + "|".join(re.escape(name) for name in CONTROLS) + r")(?![\w-])")
SIZE = re.compile(r"^(?:padding(?:-[a-z-]+)?|height|min-height|block-size|min-block-size|border(?:-[a-z]+)*-radius|gap|column-gap|row-gap)$")
WIDTH = re.compile(r"^(?:width|min-width|inline-size|min-inline-size)$")
LAYOUT_WIDTH = re.compile(r"^(?:auto|0|0px|100%|max-content|min-content|fit-content|inherit|initial|unset)$")
# A transcript row is `acpmux-row acpmux-plan` (App.tsx): only a button is the Plan control.
CLASS_ATTR = re.compile(r"className=(?:\"([^\"]*)\"|\{`([^`]*)`\}|\{([^{}]*)\})")
JSX_CONTROLS = set(CONTROLS) - {"acpmux-pill", "acpmux-access-trigger"}


def rules(css):
    """Each innermost rule as (selector, body, line): @media and @container blocks are looked into."""
    plain = re.sub(r"/\*.*?\*/", lambda match: re.sub(r"[^\n]", " ", match.group()), css, flags=re.S)
    stack, start, found = [], 0, []
    for match in re.finditer(r"[{}]", plain):
        if match.group() == "{":
            stack.append((plain[start:match.start()].split(";")[-1].split("}")[-1].strip(), match.end()))
        elif stack:
            selector, opened = stack.pop()
            body = plain[opened:match.start()]
            if "{" not in body and not selector.startswith("@"):
                found.append((selector, body, plain.count("\n", 0, opened) + 1))
        start = match.end()
    return found


def split_top(text, separators):
    parts, depth, current = [], 0, ""
    for char in text:
        depth += char == "("
        depth -= char == ")"
        if depth == 0 and char in separators:
            parts.append(current)
            current = ""
        else:
            current += char
    return parts + [current]


def subject(selector):
    """The compound a selector styles: its last one, after the last combinator outside parentheses."""
    return split_top(re.sub(r"\s*([>~+])\s*", r" ", selector.strip()), " ")[-1]


def css_failures(path, relative):
    failures = []
    with open(path, encoding="utf-8") as handle:
        text = handle.read()
    for selector, body, line in rules(text):
        controls = [part.strip() for part in split_top(selector, ",") if CONTROL.search(subject(part))]
        if not controls or all(" ".join(part.split()) in PRIMITIVE for part in controls):
            continue
        for declaration in body.split(";"):
            name, _, value = declaration.partition(":")
            name, value = name.strip().lower(), value.strip()
            if not name or name.startswith("--"):
                continue
            if SIZE.match(name) or (WIDTH.match(name) and not LAYOUT_WIDTH.match(value)):
                failures.append("%s:%d: %s sets its own %s: %s; take it from the --acpmux-pill-* tokens (composerLocation.css .acpmux-pill)"
                                % (relative, line, ", ".join(controls)[:120], name, value))
    return failures


def jsx_failures(path, relative):
    failures = []
    with open(path, encoding="utf-8") as handle:
        text = handle.read()
    for match in CLASS_ATTR.finditer(text):
        value = next(group for group in match.groups() if group is not None)
        names = set(re.findall(r"[\w-]+", value))
        if names & JSX_CONTROLS and "acpmux-pill" not in names and not ("acpmux-plan" in names and "acpmux-row" in names):
            line = text.count("\n", 0, match.start()) + 1
            failures.append("%s:%d: %s is a composer control without the pill primitive; add acpmux-pill (acpmux-pill-icon for a square)"
                            % (relative, line, ", ".join(sorted(names & JSX_CONTROLS))))
    return failures


def main():
    args = [arg for arg in sys.argv[1:] if not arg.startswith("--")]
    root = os.path.abspath(args[0] if args else os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
    base = os.path.join(root, FOLDER)
    failures, sheets, views = [], 0, 0
    for folder, _, files in os.walk(base):
        for name in sorted(files):
            path = os.path.join(folder, name)
            relative = os.path.relpath(path, root)
            if ".gallery." in name or ".test." in name:
                continue
            if name.endswith(".css"):
                sheets += 1
                failures += css_failures(path, relative)
            elif name.endswith(".tsx"):
                views += 1
                failures += jsx_failures(path, relative)
    if failures:
        print("\n".join(failures))
        print("%d composer pill violation(s)" % len(failures))
        sys.exit(1)
    print("composer pills: %d stylesheet(s) and %d view(s) on the --acpmux-pill-* tokens" % (sheets, views))


if __name__ == "__main__":
    main()
