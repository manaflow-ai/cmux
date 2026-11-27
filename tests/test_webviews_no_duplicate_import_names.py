#!/usr/bin/env python3
"""No webviews import statement names the same binding twice.

Two PRs that each add the same name to one `import { ... }` list both pass CI
alone, and then the merged base fails to bundle: "Identifier 'layoutGeometry'
has already been declared". This happened twice on 2026-11-26 in
VirtualTranscript.tsx (fixed by #59145, then again after #48219 and #57269
merged), and the second time it stopped the nightly web bundle build.

This test reads every .ts/.tsx file under webviews/src. It fails when a file's
import statements bind one local name twice, in one statement or across two
(`import { a } from "./m"` and `import { a } from "./n"` fail the bundle the
same way). cmux-next guards / static-checks runs it, so the car guards run it on
every merge-queue car that touches webviews/src, where two such PRs first meet.
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


def duplicates(text):
    found = []
    seen = set()
    for match in IMPORT.finditer(text):
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
