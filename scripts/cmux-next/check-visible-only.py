#!/usr/bin/env python3
"""VISIBLE-ONLY ratchet: lists draw only the rows in view.

Leo 2026-11-18: "It's just text. ... we draw the visible area, right? ... there are so many places where I'm pretty
sure we're just drawing the whole list. And we need to be able to guard against that."

A list that makes a view (or a SwiftUI row) for every element, seen or not, costs time in its length on every
change: build, layout and draw. The ast-grep rules scripts/cmux-next/lint/ast-grep-rules/visible-only-*.yml match
the eager shapes in NEXT Swift:
  visible-only-eager-stack-in-scroll      a ForEach in a VStack/HStack (not Lazy*) inside a ScrollView
  visible-only-foreach-unstable-id        ForEach(..., id: \\.offset), or id: \\.self over a data array
  visible-only-subviews-teardown          subviews.forEach { $0.removeFromSuperview() }, and its for-loop form
  visible-only-stack-set-views            NSStackView.setViews(<a computed array>, in: ...)
  visible-only-reload-data                reloadData() with no arguments
  visible-only-sidebar-region-unwindowed  a SidebarRegionView in a file that never sets its itemWindow

Scope: product Swift in Packages/macOS/CmuxNext/Sources, Packages/Shared/*/Sources, Packages/iOS/*/Sources and
cmux-next-ios (not its tests, UI tests, verify or scripts folders). Not the classic app.

Existing hits are listed in scripts/cmux-next/visible-only-baseline.tsv as PATH, RULE and the number of hits in that
file (counts, not lines, so an edit elsewhere in the file does not churn it). A file with more hits of a rule than its
row, or hits and no row, fails. A file with fewer fails too until its row is lowered (as check-no-process-scan.py and
check-swift-type-scale.py do; the pre-push gate reads the push's own lower row, lower_ratchet_baselines), so the
baseline only shrinks.
A hit that is right as written carries `// visible-only: <reason>` on its line or in the comment lines directly above.

It runs through prepush-gate.py (the pre-push hook, the checks job's "Pushed commits add no violations" step, the fast
gates on the merge and the train's car guards), which judges only what a push adds. Its rules and the ratchet are
tested by scripts/cmux-next/tests/check-visible-only.test.sh, which tests/test_cmux_next_prepush_gate.py runs.

The ast-grep binary: $CMUX_AST_GREP (the gate sets it), else the pinned build of scripts/cmux-next/lint-tools.lock in
the lint tools cache, downloaded through prepush-gate.py's ensure_tool when missing.

Usage: scripts/cmux-next/check-visible-only.py [repo-root] [--list] [--summary] [--write-baseline]
  --list            print every hit (path:line: [rule] text) and exit 0.
  --summary         print hits and files per rule, and the top files per rule, and exit 0.
  --write-baseline  rewrite the baseline from the tree (to lower rows, or to seed it; a raise needs review).
"""

from __future__ import annotations

import collections
import importlib.util
import json
import os
import re
import subprocess
import sys
from pathlib import Path

BASELINE = "scripts/cmux-next/visible-only-baseline.tsv"
SGCONFIG = "scripts/cmux-next/lint/sgconfig.yml"
LOCK = "scripts/cmux-next/lint-tools.lock"
RULE_PREFIX = "visible-only-"
# The folders ast-grep walks; in_scope() then keeps product sources only.
ROOTS = ("Packages/macOS/CmuxNext/Sources", "Packages/Shared", "Packages/iOS", "cmux-next-ios")
# Folder names that are never product code (Vendor: code copied in from elsewhere, not ours to window).
SKIP_PARTS = {"Tests", "UITests", "verify", "scripts", "Fixtures", "Vendor", ".build"}
ESCAPE = re.compile(r"//\s*visible-only:\s*\S")
COMMENT_LINE = re.compile(r"^\s*(//|\*|/\*)")
FIX = ("Draw only the visible rows: window it (only rows in viewport + overscan get views; see FileGridView's "
       "diffable collection or SidebarListView.realizeVisibleRows), bound it with a named cap <= 100 rows, or "
       "register the list with the visible-rows contract test (VisibleRowsContract.check, product "
       "CmuxVisibleRowsTesting in Packages/Shared/CmuxVisibleRows). A hit that is right as written carries "
       "`// visible-only: <reason>`.")


def refuse(why: str) -> None:
    """No verdict: exit 2, which the pre-push gate reads as a check that did not judge (never as a pass)."""
    print(f"check-visible-only: {why}", file=sys.stderr)
    sys.exit(2)


def in_scope(rel: str) -> bool:
    if not rel.endswith(".swift"):
        return False
    parts = rel.split("/")
    if any(p in SKIP_PARTS or p.endswith("Tests") for p in parts[:-1]):
        return False
    if rel.startswith("Packages/macOS/CmuxNext/Sources/") or rel.startswith("cmux-next-ios/"):
        return True
    # Packages/Shared/<pkg>/Sources/... and Packages/iOS/<pkg>/Sources/...
    return len(parts) > 3 and parts[0] == "Packages" and parts[1] in ("Shared", "iOS") and parts[3] == "Sources"


def ast_grep_binary(root: Path) -> str:
    if os.environ.get("CMUX_AST_GREP"):
        return os.environ["CMUX_AST_GREP"]
    # The pinned build, downloaded and sha256-checked once by the gate's own code (never an unpinned `sg` on PATH:
    # on Linux that name is often newgrp).
    here = Path(__file__).resolve().parent
    gate = here / "prepush-gate.py"
    lock = root / LOCK if (root / LOCK).is_file() else here / "lint-tools.lock"
    sys.path.insert(0, str(here))
    spec = importlib.util.spec_from_file_location("prepush_gate_for_visible_only", gate)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return str(module.ensure_tool(lock, "ast-grep"))


def escaped(lines: list[str], index: int) -> bool:
    if not 0 <= index < len(lines):
        return False
    if ESCAPE.search(lines[index]):
        return True
    j = index - 1
    while j >= 0 and COMMENT_LINE.match(lines[j]):
        if ESCAPE.search(lines[j]):
            return True
        j -= 1
    return False


def scan(root: Path) -> dict[tuple[str, str], list[tuple[int, str]]]:
    """{(path, rule): [(line, text)]} of every unescaped hit in scope."""
    present = [r for r in ROOTS if (root / r).is_dir()]
    if not present:
        return {}
    config = root / SGCONFIG
    if not config.is_file():
        config = Path(__file__).resolve().parent / "lint" / "sgconfig.yml"
    result = subprocess.run([ast_grep_binary(root), "scan", "-c", str(config), "--filter", f"^{RULE_PREFIX}",
                             "--json=compact", *present],
                            cwd=root, capture_output=True, text=True, stdin=subprocess.DEVNULL)
    # Every visible-only rule is severity warning, so a verdict exits 0; anything else is a config error or a crash.
    if result.returncode != 0 or not result.stdout.strip():
        refuse(f"ast-grep failed: exit {result.returncode}: {result.stderr.strip()[-300:] or 'no output'}")
    try:
        matches = json.loads(result.stdout)
    except json.JSONDecodeError:
        refuse(f"ast-grep printed no JSON: {result.stdout.strip()[:200]}")
    if not isinstance(matches, list) or not all(isinstance(m, dict) for m in matches):
        refuse(f"ast-grep printed {type(matches).__name__}, not a list of matches")
    hits: dict[tuple[str, str], list[tuple[int, str]]] = collections.defaultdict(list)
    texts: dict[str, list[str]] = {}
    # One hit per matched node: two eager calls on one line are two hits (a key of line and text counted them once,
    # so the second slipped under the file's row). A node ast-grep reports twice keeps one.
    seen: set[tuple[str, str, int, int]] = set()
    for m in matches:
        rel, rule, index = m["file"].replace(os.sep, "/"), m["ruleId"], m["range"]["start"]["line"]
        if rel.startswith("./"):
            rel = rel[2:]
        if not rule.startswith(RULE_PREFIX) or not in_scope(rel):
            continue
        if rel not in texts:
            texts[rel] = (root / rel).read_text(encoding="utf-8", errors="replace").split("\n")
        if escaped(texts[rel], index):
            continue
        node = (rel, rule, m["range"]["byteOffset"]["start"], m["range"]["byteOffset"]["end"])
        if node in seen:
            continue
        seen.add(node)
        line = texts[rel][index].strip() if index < len(texts[rel]) else ""
        hits[(rel, rule)].append((index + 1, line))
    return {key: sorted(found) for key, found in hits.items()}


def read_baseline(root: Path) -> dict[tuple[str, str], int]:
    rows: dict[tuple[str, str], int] = {}
    path = root / BASELINE
    if not path.is_file():
        return rows
    for raw in path.read_text(encoding="utf-8").splitlines():
        if not raw or raw.startswith("#"):
            continue
        parts = raw.split("\t")
        if len(parts) != 3 or not parts[2].isdigit() or not parts[1].startswith(RULE_PREFIX):
            print(f"check-visible-only: bad baseline row: {raw!r}", file=sys.stderr)
            sys.exit(2)
        rows[(parts[0], parts[1])] = int(parts[2])
    return rows


BASELINE_HEADER = ("# path\trule\thits (scripts/cmux-next/check-visible-only.py; the count only goes down: draw only "
                   "the visible rows, then lower the row or delete it)\n")


def write_baseline(root: Path, hits: dict[tuple[str, str], list[tuple[int, str]]]) -> None:
    rows = "".join(f"{p}\t{r}\t{len(found)}\n" for (p, r), found in sorted(hits.items()))
    (root / BASELINE).write_text(BASELINE_HEADER + rows, encoding="utf-8")


def summary(hits: dict[tuple[str, str], list[tuple[int, str]]]) -> str:
    by_rule: dict[str, list[tuple[int, str]]] = collections.defaultdict(list)
    for (path, rule), found in hits.items():
        by_rule[rule].append((len(found), path))
    out = []
    for rule in sorted(by_rule):
        files = sorted(by_rule[rule], key=lambda x: (-x[0], x[1]))
        out.append(f"{rule}: {sum(n for n, _ in files)} hits in {len(files)} files")
        out += [f"  {n}  {p}" for n, p in files[:5]]
    total = sum(len(f) for f in hits.values())
    out.append(f"total: {total} hits in {len({p for p, _ in hits})} files")
    return "\n".join(out)


def main(argv: list[str]) -> int:
    args = [a for a in argv if not a.startswith("--")]
    root = Path(args[0] if args else os.getcwd()).resolve()
    hits = scan(root)
    if "--list" in argv:
        for (path, rule), found in sorted(hits.items()):
            for number, line in found:
                print(f"{path}:{number}: [{rule}] {line}")
        return 0
    if "--summary" in argv:
        print(summary(hits))
        return 0
    if "--write-baseline" in argv:
        write_baseline(root, hits)
        print(f"check-visible-only: wrote {BASELINE} ({sum(len(f) for f in hits.values())} hits)")
        return 0
    baseline = read_baseline(root)
    status = 0
    for (path, rule), found in sorted(hits.items()):
        allowed = baseline.get((path, rule), 0)
        if len(found) > allowed:
            status = 1
            print(f"check-visible-only: {path} has {len(found)} [{rule}] hit(s), baseline {allowed}: a list that "
                  f"draws every row, seen or not. {FIX}", file=sys.stderr)
            for number, line in found:
                print(f"  {path}:{number}: [{rule}] {line}", file=sys.stderr)
    for (path, rule), allowed in sorted(baseline.items()):
        count = len(hits.get((path, rule), []))
        if count < allowed:
            status = 1
            print(f"check-visible-only: {path} now has {count} [{rule}] hit(s), baseline {allowed}: lower the "
                  f"baseline, its row in {BASELINE} to {count}" + (" (delete the row)" if count == 0 else "")
                  + " (or run check-visible-only.py --write-baseline).", file=sys.stderr)
    if status == 0:
        print(f"check-visible-only: ok ({sum(len(v) for v in hits.values())} baselined hit(s) in "
              f"{len({p for p, _ in hits})} file(s))")
    return status


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
