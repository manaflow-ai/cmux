#!/usr/bin/env python3
"""Webviews test selection for a one-line edit to each hub file, and why the always-run floor runs.

Leo (2026-11-22): "> because of rules that always run the full suite or because they edit one shared core file /
well, make better rules and make better architecture". This prints both halves as numbers: how many test files
scripts/ci/webviews_affected.py selects when a PR touches one hub (the architecture half), and the always-run set
it adds to every selection, broken down by cause (the rules half). Read-only: each edit is a throwaway commit
object; the checkout and its index are untouched.

    python3 scripts/measure/webviews-hub-selection.py [FILE ...]   (from the repo root; default: the hubs below)
    cmux-ci test --setup webviews -- python3 scripts/measure/webviews-hub-selection.py
"""

from __future__ import annotations

import collections
import hashlib
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
import webviews_affected as wa  # noqa: E402

HUBS = [
    "webviews/src/agent-session/acpmux/pageHost.ts",
    "webviews/src/agent-session/acpmux/native.ts",
    "webviews/src/agent-session/acpmux/direct.ts",
    "webviews/src/agent-session/acpmux/model.ts",
]
# What makes a test always-run by itself, first match wins (webviews_affected.UNTRACKED and UNTRACKED_OUTSIDE_SRC).
KINDS = [
    ("fs import", r"[\"'](?:node:)?fs(?:/promises)?[\"']"),
    ("vite", r"[\"']vite[\"']"),
    ("playwright", r"[\"']playwright[\"']"),
    ("Bun.file", r"Bun\.file\("),
    ("requireBrowserLane", r"requireBrowserLane"),
    ("spawn or exec", r"child_process|spawnSync|execSync|execFile"),
    ("glob", r"Glob|import\.meta\.glob|globSync"),
]


def git(*args: str, env: dict[str, str] | None = None, stdin: str | None = None) -> str:
    return subprocess.run(["git", *args], cwd=ROOT, check=True, capture_output=True, text=True,
                          env=env, input=stdin).stdout.strip()


def probe(path: str, selector: wa.Selector) -> int:
    """Test files selected for a one-line edit to PATH at HEAD (None from select means every file)."""
    head = git("rev-parse", "HEAD")
    blob = git("hash-object", "-w", "--stdin", stdin=git("show", f"HEAD:{path}") + "\n// probe\n")
    with tempfile.NamedTemporaryFile() as index:
        env = {**os.environ, "GIT_INDEX_FILE": index.name}
        git("read-tree", head, env=env)
        git("update-index", "--cacheinfo", f"100644,{blob},{path}", env=env)
        tree = git("write-tree", env=env)
    commit = git("commit-tree", tree, "-p", head, "-m", "probe")
    picked, _ = selector.select(wa.changed(ROOT, head, commit))
    return len(selector.graph.tests) if picked is None else len(picked)


def main(argv: list[str]) -> int:
    os.chdir(ROOT)
    s = wa.Selector(ROOT)
    total = len(s.graph.tests)
    print(f"HEAD {git('rev-parse', '--short', 'HEAD')}: {total} test files, always-run floor {len(s.always)}")
    for path in argv or HUBS:
        n = probe(path, s)
        print(f"edit {path}: {n} tests ({100 * n // total}%), {n - len(s.always)} above the floor")
    untracked = {f for f, t in s.text.items() if wa.outside_doc(wa.UNTRACKED, t)
                 or (not f.startswith(wa.WEB + "src/") or f in s.graph.tests) and wa.UNTRACKED_OUTSIDE_SRC.search(t)}
    reviewed = {f for f, d in wa.RUNTIME_LOADS.items() if wa.NARROW and f in s.text
                and hashlib.sha256((ROOT / f).read_bytes()).hexdigest() == d}
    bad = untracked - reviewed
    kinds: collections.Counter[str] = collections.Counter()
    via: collections.Counter[str] = collections.Counter()
    for t in s.always:
        if t in bad:
            kinds[next((k for k, p in KINDS if re.search(p, s.text[t])), "computed import or other")] += 1
        else:
            for m in s.closure(t) & bad:
                via[m] += 1
    print(f"always-run, the test itself: {sum(kinds.values())}: " + ", ".join(f"{k} {n}" for k, n in kinds.most_common()))
    print(f"always-run through an import: {len(s.always) - sum(kinds.values())}; top modules:")
    for m, n in via.most_common(8):
        print(f"  {n} {m}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
