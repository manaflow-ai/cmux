#!/usr/bin/env python3
"""Print a stable digest of the inputs that can change the shipped NIGHTLY app bundle.

Computed from git objects only (`git ls-tree -r`, `git cat-file`): no checkout scan, no
GitHub API. Two commits with the same digest ship the same app inputs, so a build signed for
one is reusable for the other. This is a shadow measure: nothing consumes it to skip work yet.

Rule: a path is an input unless it is on the deny-list below. When unsure, keep it in (a
false "changed" only costs a build; a false "same" ships a stale app).

CI paths are the exception, kept narrow: `.github/` and `scripts/ci/` only count when
nightly.yml (transitively) names them, plus `scripts/ci/nightly-steps/` as a whole.

Usage:
  app_input_digest.py [--ref REV]            print the digest of REV (default HEAD)
  app_input_digest.py --replay N [--ref REV] over the last N first-parent commits, print
                                             commits, distinct digests, and the share whose
                                             digest equals its parent's ("no build needed");
                                             the newest commit's CI closure is applied to every commit
"""

from __future__ import annotations

import argparse
import functools
import hashlib
import re
import subprocess
import sys

SCHEMA = "cmux-app-input-digest/v1"
WORKFLOW = ".github/workflows/nightly.yml"
ALWAYS_PREFIXES = ("scripts/ci/nightly-steps/", ".github/actions/")

# Trees that never reach the app bundle: documentation, tests-only trees, the website and
# workers, the iOS-only tree, agent tooling, and git hooks. Note cmux-tui/, webviews/,
# Packages/, ghostty*/ and cmux-next-ios/ are NOT here: the bundle embeds their builds.
DENY_PREFIXES = (
    "docs/", "design/", "plans/", "tests/", "tests_v2/", "web/", "workers/", "ios/",
    "homebrew-cmux/", "evals/", "experiments/", "agent-chat/", "scripts/git-hooks/",
    ".claude/", ".agents/", ".codex/", ".greptile/", ".lane-notes/", ".asc/",
    "capture-scratch/", "daemon/remote/",
)
DENY_FILES = frozenset({
    "CHANGELOG.md", "CLA.md", "CODE_OF_CONDUCT.md", "CONTRIBUTING.md", "SECURITY.md",
    "STYLE.md", "DESIGN.md", "CLAUDE.md", "AGENTS.md", "THIRD_PARTY_LICENSES.md",
    ".coderabbit.yaml", ".gitattributes", ".vercelignore", ".git-pr-body.md", ".gitkeep",
    "vercel.json",
})
DENY_NAMES = frozenset({"CLAUDE.md", "AGENTS.md"})

REF_RE = re.compile(rb"(?:\.github|scripts)/[A-Za-z0-9_./-]+")
BARE_RE = re.compile(rb"[A-Za-z0-9_-]+\.(?:py|sh)")


def git(*args: str, text: bool = True) -> str | bytes:
    out = subprocess.run(["git", *args], check=True, stdout=subprocess.PIPE).stdout
    return out.decode("utf-8", "replace") if text else out


def tree_entries(rev: str) -> dict[str, tuple[str, str, str]]:
    """path -> (mode, kind, oid) for every blob/gitlink in the commit."""
    raw = git("-c", "core.quotepath=off", "ls-tree", "-r", "-z", rev, text=False)
    entries = {}
    for rec in raw.split(b"\0"):
        if not rec:
            continue
        meta, path = rec.split(b"\t", 1)
        mode, kind, oid = meta.decode().split()
        entries[path.decode("utf-8", "replace")] = (mode, kind, oid)
    return entries


def denied(path: str) -> bool:
    if path in DENY_FILES or path.rsplit("/", 1)[-1] in DENY_NAMES:
        return True
    if path.startswith(DENY_PREFIXES):
        return True
    if path.startswith("README") and path.endswith(".md"):
        return True
    # Skill and release-note prose is not bundled except where it is named above.
    if path.startswith("skills/") and path.endswith(".md") and not path.startswith("skills/cmux-computer-use/"):
        return True
    return False


_BATCH: subprocess.Popen | None = None


def read_blob(oid: str) -> bytes | None:
    """Blob bytes through one long-lived `git cat-file --batch` (None if missing or big)."""
    global _BATCH
    if _BATCH is None:
        _BATCH = subprocess.Popen(["git", "cat-file", "--batch"], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    try:
        _BATCH.stdin.write(oid.encode() + b"\n")
        _BATCH.stdin.flush()
        header = _BATCH.stdout.readline().split()
    except BrokenPipeError:
        header = []
    if len(header) < 3:
        _BATCH = None  # a missing object (partial clone) ends the batch process; start a new one next time
        return None
    size = int(header[2])
    data = _BATCH.stdout.read(size)
    _BATCH.stdout.read(1)
    return data if size <= 2_000_000 else None


@functools.lru_cache(maxsize=None)
def blob_refs(oid: str) -> tuple[frozenset[str], frozenset[str]]:
    """(paths named, bare script basenames named) by one blob; empty for big or binary blobs."""
    data = read_blob(oid)
    if data is None or b"\0" in data[:4096]:
        return frozenset(), frozenset()
    paths = frozenset(m.decode().rstrip(".") for m in REF_RE.findall(data))
    bare = frozenset(m.decode() for m in BARE_RE.findall(data))
    return paths, bare


def ci_closure(entries: dict[str, tuple[str, str, str]]) -> set[str]:
    """CI-side files nightly.yml reaches: named paths, directory prefixes, sibling scripts."""
    ci_files = [p for p in entries if p.startswith((".github/", "scripts/ci/"))]
    by_base: dict[str, list[str]] = {}
    for p in ci_files:
        if p.startswith("scripts/ci/"):
            by_base.setdefault(p.rsplit("/", 1)[-1], []).append(p)
    included: set[str] = {p for p in ci_files if p.startswith(ALWAYS_PREFIXES)}
    if WORKFLOW in entries:
        included.add(WORKFLOW)
    queue = list(included)
    scanned: set[str] = set()
    while queue:
        path = queue.pop()
        if path in scanned:
            continue
        scanned.add(path)
        entry = entries.get(path)
        if not entry or entry[1] != "blob":
            continue
        paths, bare = blob_refs(entry[2])
        found: set[str] = set()
        for ref in paths:
            if ref in entries:
                found.add(ref)
            else:
                pre = ref.rstrip("/") + "/"
                found.update(p for p in ci_files if p.startswith(pre))
        for name in bare:
            found.update(by_base.get(name, ()))
        for f in found:
            if f.startswith((".github/", "scripts/ci/")) and f not in included:
                included.add(f)
                queue.append(f)
    return included


def digest_for(rev: str, fixed_ci: set[str] | None = None) -> str:
    """fixed_ci: replay passes the newest commit's CI closure, so an old commit's workflow and scripts need
    not be readable (a partial clone lacks old blobs); always-in prefixes are still taken from its own tree."""
    entries = tree_entries(rev)
    if fixed_ci is None:
        ci = ci_closure(entries)
    else:
        ci = {p for p in entries if p in fixed_ci or p.startswith(ALWAYS_PREFIXES)}
    h = hashlib.sha256(SCHEMA.encode() + b"\n")
    lines = []
    for path, (mode, kind, oid) in entries.items():
        if kind not in ("blob", "commit"):
            continue
        if path.startswith((".github/", "scripts/ci/")):
            if path not in ci:
                continue
        elif denied(path):
            continue
        lines.append(f"{mode} {kind} {oid}\t{path}")
    for line in sorted(lines):
        h.update(line.encode("utf-8") + b"\n")
    return h.hexdigest()


def replay(ref: str, n: int) -> int:
    # n+1 so the oldest counted commit has a parent to compare with.
    revs = git("rev-list", "--first-parent", f"--max-count={n + 1}", ref).split()
    ci = ci_closure(tree_entries(revs[0]))
    digests = [digest_for(r, ci) for r in revs]
    commits = len(revs) - 1 if len(revs) > 1 else len(revs)
    same = sum(1 for i in range(commits) if i + 1 < len(revs) and digests[i] == digests[i + 1])
    print(f"ref: {ref}")
    print(f"commits: {commits}")
    print(f"distinct_digests: {len(set(digests[:commits]))}")
    print(f"same_as_parent: {same}")
    print(f"no_build_needed_rate: {same / commits:.4f}" if commits else "no_build_needed_rate: n/a")
    return 0


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--ref", default="HEAD")
    ap.add_argument("--replay", type=int, metavar="N")
    args = ap.parse_args(argv)
    if args.replay:
        return replay(args.ref, args.replay)
    print(digest_for(args.ref))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
