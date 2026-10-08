#!/usr/bin/env bash
# Fails when a CmuxNext module reads a chrome color outside its theme scope
# (plans/cmux-next/data-model.md 6, stage 5 themes).
#
# Rooms, workspaces and terminals can each have their own theme, so a color
# is only right when it is resolved for the view that draws it. Rules, for
# every Swift file under Sources/ except CmuxNextDesign (which implements the
# scopes) and app-scope UI that belongs to no window (listed below):
#   1. Every `Palette.<token>` read sits lexically inside a
#      `performWithTheme { ... }` or `<scope>.perform { ... }` closure, or
#      inside a function or computed property whose declaration line (or the
#      comment line above it) carries the marker `theme-scoped` (a helper its
#      callers only call inside such a closure).
#   2. No `performAsCurrentDrawingAppearance` (it resolves the app theme);
#      use `performWithTheme`.
#   3. No `ThemeStore.shared.tokens` or `ThemeStore.shared.input` and no
#      `ThemeStore.shared.adopt(`: read `themeTokens` / `themeScope`, adopt
#      with `ThemeScope.adopt` or `NSWindow.adoptThemeScope(of:)`.
# Usage: scripts/cmux-next/check-theme-scope.sh [package-root]
set -euo pipefail
root="${1:-$(git rev-parse --show-toplevel)/Packages/macOS/CmuxNext}"
exec python3 - "$root" <<'PY'
import os, re, sys

root = sys.argv[1]
sources = os.path.join(root, "Sources")

# UI outside every room: the app theme (Ghostty config) is its scope.
APP_SCOPE = (
    "CmuxNextDesign/",
    "CmuxNextOnboarding/",
    "CmuxNextUpdater/",
    "/Demo/",
    "CmuxNextBrowser/Engine/MockBrowserEngine.swift",
    # Feeds ThemeStore from the Ghostty config and resolves room,
    # workspace and terminal specs against it.
    "CmuxNextApp/ThemeBridge.swift",
    "CmuxNextApp/Themes/",
    "CmuxNextApp/Onboarding/",
)

WRAPPERS = re.compile(r"(performWithTheme|\.perform)\s*(\([^)]*\))?\s*\{")
MARKER = "theme-scoped"


def strip(text):
    """Blanks comments and string literals, keeping offsets and newlines."""
    out = list(text)
    i, n = 0, len(text)
    def blank(a, b):
        for k in range(a, b):
            if out[k] != "\n":
                out[k] = " "
    while i < n:
        if text.startswith("//", i):
            j = text.find("\n", i)
            j = n if j < 0 else j
            blank(i, j); i = j
        elif text.startswith("/*", i):
            j = text.find("*/", i + 2)
            j = n if j < 0 else j + 2
            blank(i, j); i = j
        elif text.startswith('"""', i):
            j = text.find('"""', i + 3)
            j = n if j < 0 else j + 3
            blank(i, j); i = j
        elif text[i] == '"':
            j = i + 1
            while j < n and text[j] != '"' and text[j] != "\n":
                j += 2 if text[j] == "\\" else 1
            blank(i, min(j + 1, n)); i = j + 1
        else:
            i += 1
    return "".join(out)


def matching(code, open_index):
    depth = 0
    for k in range(open_index, len(code)):
        c = code[k]
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return k
    return len(code)


def scoped_ranges(text, code):
    ranges = []
    for m in WRAPPERS.finditer(code):
        start = m.end() - 1
        ranges.append((start, matching(code, start)))
    lines = text.split("\n")
    offsets = [0]
    for line in lines:
        offsets.append(offsets[-1] + len(line) + 1)
    for index, line in enumerate(lines):
        if MARKER not in line:
            continue
        # The marked declaration: this line, or the next code line.
        target = index
        while target < len(lines) and "{" not in code[offsets[target]:offsets[target + 1]]:
            target += 1
        if target >= len(lines):
            continue
        brace = code.find("{", offsets[target])
        ranges.append((brace, matching(code, brace)))
    return ranges


problems = []
for directory, _, files in os.walk(sources):
    for name in files:
        if not name.endswith(".swift"):
            continue
        path = os.path.join(directory, name)
        rel = os.path.relpath(path, sources)
        if any(part in "/" + rel for part in APP_SCOPE):
            continue
        text = open(path, encoding="utf-8").read()
        code = strip(text)
        ranges = scoped_ranges(text, code)
        def line_of(offset):
            return code.count("\n", 0, offset) + 1
        for m in re.finditer(r"\bPalette\.[a-zA-Z]+", code):
            if not any(a < m.start() < b for a, b in ranges):
                problems.append(f"{rel}:{line_of(m.start())}: {m.group(0)} outside performWithTheme (rule 1)")
        for m in re.finditer(r"performAsCurrentDrawingAppearance", code):
            problems.append(f"{rel}:{line_of(m.start())}: performAsCurrentDrawingAppearance resolves the app theme; use performWithTheme (rule 2)")
        for m in re.finditer(r"ThemeStore\.shared\.(tokens|input|adopt\()", code):
            problems.append(f"{rel}:{line_of(m.start())}: ThemeStore.shared.{m.group(1)} is the app theme; use the view's theme scope (rule 3)")

for problem in sorted(problems):
    print(problem)
if problems:
    print(f"{len(problems)} unscoped color read(s); see scripts/cmux-next/check-theme-scope.sh")
    sys.exit(1)
PY
