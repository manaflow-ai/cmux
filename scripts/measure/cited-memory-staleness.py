#!/usr/bin/env python3
"""How many `path:line` citations in a memory folder point at code that is no longer there:
the measurement behind RFD 0158 §13 (cited memory, harness magic `citedMemory`).

Reads every `.md` under MEMDIR, finds each `dir/file.ext:LINE` citation, and checks it against the
tracked files (`git ls-files`) of each ROOT, by the rules `cmux-tui/crates/acpmux/src/
cited_memory.rs` uses: the path as written, else the only file ending in it, else the only file
with its name. Each citation is `ok`, `lineGone` (the file ends before the line), `fileGone` (no
file in the roots is it; an upper bound, since a memory may cite a repo not passed as a ROOT), or
`unknown` (more than one file could be it). Prints the counts, the docs with at least one stale
citation, and a few samples of each stale kind.

On a lane VM, 2026-11-27 (~/.cache/agent-memory/hq against cmux, cmuxterm-hq, leo-workspace):
2,649 citations in 267 docs; 2,115 ok (376 by file name only), 34 lineGone, 316 fileGone, 184
unknown; 99 docs hold a stale citation.

Read-only. Run on any host with a memory folder and checkouts:
  python3 -I scripts/measure/cited-memory-staleness.py ~/.cache/agent-memory/hq \
      ~/path/to/cmux ~/path/to/cmuxterm-hq [--json OUT]
"""

import argparse
import collections
import json
import os
import re
import subprocess

EXTS = "rs|py|ts|tsx|js|mjs|swift|sh|toml|yml|yaml"
CITE = re.compile(
    r"(?<![A-Za-z0-9_./-])((?:\./)?[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)+\.(?:" + EXTS + r")):(\d+)"
)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("memdir")
    ap.add_argument("roots", nargs="+")
    ap.add_argument("--json")
    args = ap.parse_args()

    by_suffix = collections.defaultdict(list)
    for root in args.roots:
        out = subprocess.run(
            ["git", "-C", root, "ls-files", "-z"], capture_output=True, check=True, timeout=60
        ).stdout.decode("utf-8", "replace")
        for f in filter(None, out.split("\0")):
            parts = f.split("/")
            for i in range(len(parts)):
                by_suffix["/".join(parts[i:])].append((root, f))

    lengths = {}

    def lines(root, rel):
        key = (root, rel)
        if key not in lengths:
            try:
                with open(os.path.join(root, rel), "rb") as fh:
                    data = fh.read()
                n = data.count(b"\n")
                lengths[key] = 0 if not data else n if data.endswith(b"\n") else n + 1
            except OSError:
                lengths[key] = None
        return lengths[key]

    def resolve(path):
        name = path.rsplit("/", 1)[-1]
        for key in (path, name):
            hits = by_suffix.get(key, [])
            if len(hits) == 1:
                return hits[0]
            exact = [h for h in hits if h[1] == path]
            if len(exact) == 1:
                return exact[0]
            if hits:
                return "unknown"
        return None

    counts = collections.Counter()
    docs = set()
    stale_docs = set()
    samples = collections.defaultdict(list)
    for dirpath, _, names in os.walk(args.memdir):
        for n in names:
            if not n.endswith(".md"):
                continue
            p = os.path.join(dirpath, n)
            try:
                with open(p, encoding="utf-8", errors="replace") as fh:
                    text = fh.read()
            except OSError:
                continue
            for m in CITE.finditer(text):
                path, line = m.group(1), int(m.group(2))
                path = path[2:] if path.startswith("./") else path
                if line == 0 or ".." in path.split("/"):
                    continue
                docs.add(p)
                counts["citations"] += 1
                hit = resolve(path)
                if hit == "unknown":
                    verdict = "unknown"
                elif hit is None:
                    verdict = "fileGone"
                else:
                    if hit[1] != path and not hit[1].endswith("/" + path):
                        counts["byNameOnly"] += 1
                    n_lines = lines(*hit)
                    verdict = "unknown" if n_lines is None else "ok" if n_lines >= line else "lineGone"
                counts[verdict] += 1
                if verdict in ("fileGone", "lineGone"):
                    stale_docs.add(p)
                    if len(samples[verdict]) < 8:
                        samples[verdict].append(f"{os.path.relpath(p, args.memdir)}: {path}:{line}")

    result = {
        "counts": dict(counts),
        "docsWithCitations": len(docs),
        "docsWithAStaleCitation": len(stale_docs),
        "samples": samples,
    }
    print(json.dumps(result, indent=2))
    if args.json:
        with open(args.json, "w") as fh:
            json.dump(result, fh, indent=2)


if __name__ == "__main__":
    main()
