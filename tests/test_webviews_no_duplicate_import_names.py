#!/usr/bin/env python3
"""No webviews file imports the same binding twice.

Two PRs that each add the same name to one `import { ... }` list both pass CI
alone, and then the merged base fails to bundle: "Identifier 'layoutGeometry'
has already been declared". This happened twice on 2026-11-26 in
VirtualTranscript.tsx (fixed by #59145, then again after #48219 and #57269
merged), and the second time it stopped the nightly web bundle build.

This test reads every .ts/.tsx file under webviews/src. It fails when a file's
import statements bind one local name twice, in one statement or across two
(`import { a } from "./m"` and `import { a } from "./n"` fail the bundle the
same way). cmux-next guards / static-checks runs it on each feat-cmux-next push,
and the car guards run it (scripts/ci/focused-tests-extra.json, lane linux-guard)
on every car that touches webviews/src, where two such PRs first meet.
"""

import os
import re
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "webviews", "src")
IMPORT = re.compile(r"^import\s+(?:type\s+)?([^;'\"]*?)\s+from\s+['\"][^'\"]+['\"]", re.M | re.S)


def local_names(clause):
    names = []
    brace = re.search(r"\{(.*)\}", clause, re.S)
    if brace:
        body = re.sub(r"//[^\n]*|/\*.*?\*/", "", brace.group(1), flags=re.S)
        for part in body.split(","):
            part = part.strip()
            if not part:
                continue
            part = re.sub(r"^type\s+", "", part)
            names.append(part.split(" as ")[-1].strip())
        clause = clause[: brace.start()] + clause[brace.end():]
    for part in clause.split(","):
        part = part.strip()
        if part.startswith("* as "):
            names.append(part[5:].strip())
        elif re.fullmatch(r"[A-Za-z_$][\w$]*", part):
            names.append(part)
    return names


def quoted_spans(text):
    """Where template literals and block comments sit, so an import written inside a fixture
    string (workedTurn.ts holds two test files as template text) is not read as the file's own."""
    spans = []
    stack = []  # "tpl" for template text, an int for the brace depth of code inside ${ ... }
    start = 0
    i, n = 0, len(text)
    while i < n:
        ch = text[i]
        if stack and stack[-1] == "tpl":
            if ch == "\\":
                i += 2
                continue
            if ch == "`":
                stack.pop()
                if not stack:
                    spans.append((start, i + 1))
            elif text.startswith("${", i):
                stack.append(0)
                i += 2
                continue
            i += 1
            continue
        if text.startswith("//", i):
            j = text.find("\n", i)
            i = n if j < 0 else j
            continue
        if text.startswith("/*", i):
            j = text.find("*/", i + 2)
            j = n if j < 0 else j + 2
            if not stack:
                spans.append((i, j))
            i = j
            continue
        if ch in "'\"":
            j = i + 1
            while j < n and text[j] not in (ch, "\n"):
                j += 2 if text[j] == "\\" else 1
            i = j + 1
            continue
        if ch == "`":
            if not stack:
                start = i
            stack.append("tpl")
        elif ch == "{" and stack:
            stack[-1] += 1
        elif ch == "}" and stack:
            if stack[-1] == 0:
                stack.pop()
            else:
                stack[-1] -= 1
        i += 1
    if stack:
        spans.append((start, n))
    return spans


def duplicates(text):
    found = []
    seen = set()
    spans = quoted_spans(text)
    for match in IMPORT.finditer(text):
        if any(a <= match.start() < b for a, b in spans):
            continue
        for name in local_names(match.group(1)):
            if name in seen:
                found.append(name)
            seen.add(name)
    return found


def main():
    assert duplicates("import {\n  a,\n  type B,\n  a,\n} from './m';\n") == ["a"]
    assert duplicates("import { a, b as a } from './m';") == ["a"]
    assert duplicates("import { a, b } from './m';\nimport { a as c } from './n';") == []
    assert duplicates("import D, { d } from './m';") == []
    assert duplicates("import { a } from './m';\nimport type { a } from './n';") == ["a"]
    fixture = "import { a } from './m';\nconst f = `\nimport { a } from './n';\n${`\nimport { a } from './o';\n`}`;\n"
    assert duplicates(fixture) == []
    assert duplicates("import { a } from './m';\n/*\nimport { a } from './n';\n*/\n") == []

    bad = []
    for dirpath, dirnames, filenames in os.walk(ROOT):
        dirnames[:] = [d for d in dirnames if d != "node_modules"]
        for name in filenames:
            if not name.endswith((".ts", ".tsx")):
                continue
            path = os.path.join(dirpath, name)
            with open(path, encoding="utf-8") as handle:
                dups = duplicates(handle.read())
            if dups:
                bad.append(f"{os.path.relpath(path, ROOT)}: {', '.join(sorted(set(dups)))}")
    if bad:
        print("a file's imports bind these names twice:\n  " + "\n  ".join(bad))
        return 1
    print("ok: no file under webviews/src imports one name twice")
    return 0


if __name__ == "__main__":
    sys.exit(main())
