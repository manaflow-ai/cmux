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
  primitive or fails here. A computed class is checked branch by branch: each arm of a ternary, and
  both sides of a `cond && "x"`, is a class list of its own, so
  `className={ok ? "acpmux-send acpmux-pill" : "acpmux-send"}` fails on its second arm.

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
JSX_CONTROLS = set(CONTROLS) - {"acpmux-pill"}
# A transcript row is `<article className="acpmux-row acpmux-plan">` (App.tsx): a plain element, not
# the Plan control. Only an intrinsic element that is not a button (and has no button role) is exempt.
ROW_HOSTS_NOT_CONTROLS = re.compile(r"^[a-z][\w-]*$")


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


def skip_string(text, index):
    """The index just past the string literal that opens at text[index] (', " or `)."""
    quote, index = text[index], index + 1
    while index < len(text) and text[index] != quote:
        if text[index] == "\\":
            index += 1
        elif quote == "`" and text.startswith("${", index):
            index = skip_group(text, index + 1)
            continue
        index += 1
    return index + 1


def skip_group(text, index):
    """The index just past the bracket group that opens at text[index]."""
    closing = {"(": ")", "[": "]", "{": "}"}
    stack = [closing[text[index]]]
    index += 1
    while index < len(text) and stack:
        char = text[index]
        if char in "'\"`":
            index = skip_string(text, index)
            continue
        if char in closing:
            stack.append(closing[char])
        elif char == stack[-1]:
            stack.pop()
        index += 1
    return index


def top_level(text):
    """(index, char) for each character of text outside strings and bracket groups."""
    index = 0
    while index < len(text):
        char = text[index]
        if char in "'\"`":
            index = skip_string(text, index)
        elif char in "([{":
            index = skip_group(text, index)
        else:
            yield index, char
            index += 1


def ternary(expr):
    """(then, otherwise) of a top-level `cond ? then : otherwise`, or None."""
    question, depth = None, 0
    for index, char in top_level(expr):
        following = expr[index + 1:index + 2]
        if char == "?" and question is None and following not in "?." and expr[index - 1:index] != "?":
            question = index
        elif char == "?" and question is not None and following not in "?." and expr[index - 1:index] != "?":
            depth += 1
        elif char == ":" and question is not None:
            if depth == 0:
                return expr[question + 1:index], expr[index + 1:]
            depth -= 1
    return None


def split_operator(expr, operator):
    """expr split on a top-level `&&` or `||`."""
    parts, start = [], 0
    for index, char in top_level(expr):
        if expr.startswith(operator, index) and index >= start:
            parts.append(expr[start:index])
            start = index + len(operator)
    return parts + [expr[start:]]


def product(left, right):
    return [a | b for a in left for b in right]


def branches(expr):
    """Every class list a className expression can produce, as sets of names (an over-approximation
    inside one branch: every literal of a call or array counts)."""
    expr = expr.strip()
    arms = ternary(expr)
    if arms:
        return branches(arms[0]) + branches(arms[1])
    alternatives = split_operator(expr, "||")
    if len(alternatives) > 1:
        return [names for part in alternatives for names in branches(part)]
    conjuncts = split_operator(expr, "&&")
    if len(conjuncts) > 1:
        # `cond && "x"` is "x" or nothing: the condition never names a class.
        return [set()] + branches(conjuncts[-1])
    found, index = [set()], 0
    while index < len(expr):
        char = expr[index]
        if char in "'\"":
            end = skip_string(expr, index)
            found = product(found, [set(re.findall(r"[\w-]+", expr[index + 1:end - 1]))])
            index = end
        elif char == "`":
            end = skip_string(expr, index)
            body, static, cursor = expr[index + 1:end - 1], "", 0
            parts = [set()]
            while cursor < len(body):
                if body.startswith("${", cursor):
                    close = skip_group(body, cursor + 1)
                    parts = product(parts, branches(body[cursor + 2:close - 1]))
                    cursor = close
                else:
                    static += body[cursor]
                    cursor += 1
            found = product(found, product(parts, [set(re.findall(r"[\w-]+", static))]))
            index = end
        elif char in "([{":
            end = skip_group(expr, index)
            for element in split_top_level_commas(expr[index + 1:end - 1]):
                found = product(found, branches(element))
            index = end
        else:
            index += 1
    return found


def split_top_level_commas(text):
    parts, start = [], 0
    for index, char in top_level(text):
        if char == ",":
            parts.append(text[start:index])
            start = index + 1
    return parts + [text[start:]]


def class_attributes(text):
    """(offset, expression) of each className: a quoted value as its literal, a braced one as its code."""
    for match in re.finditer(r"className=", text):
        start = match.end()
        if start < len(text) and text[start] in "'\"":
            yield match.start(), text[start:skip_string(text, start)]
        elif start < len(text) and text[start] == "{":
            yield match.start(), text[start + 1:skip_group(text, start) - 1]


def owning_tag(text, offset):
    """The JSX element a className at `offset` belongs to, and its attributes before the className:
    the last `<Name` opened before it."""
    opened = None
    for match in re.finditer(r"<([A-Za-z][\w.-]*)", text[:offset]):
        opened = match
    return (opened.group(1), text[opened.end():offset]) if opened else ("", "")


def transcript_row(names, tag, attributes):
    """The one non-control form of a control's class: a transcript row (acpmux-row acpmux-plan)
    drawn by a plain, non-button element."""
    return (
        "acpmux-row" in names
        and names & JSX_CONTROLS == {"acpmux-plan"}
        and ROW_HOSTS_NOT_CONTROLS.match(tag) is not None
        and tag != "button"
        and not re.search(r"\brole=[\"'{]*button", attributes)
    )


def jsx_failures(path, relative):
    failures = []
    with open(path, encoding="utf-8") as handle:
        text = handle.read()
    for offset, expression in class_attributes(text):
        tag, attributes = owning_tag(text, offset)
        for names in branches(expression):
            if names & JSX_CONTROLS and "acpmux-pill" not in names and not transcript_row(names, tag, attributes):
                line = text.count("\n", 0, offset) + 1
                failures.append("%s:%d: %s is a composer control without the pill primitive in one of its class branches (%s); add acpmux-pill (acpmux-pill-icon for a square)"
                                % (relative, line, ", ".join(sorted(names & JSX_CONTROLS)), " ".join(sorted(names))[:120]))
                break
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
