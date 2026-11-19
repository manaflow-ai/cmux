"""Read ast-grep's --json=stream matches on stdin; drop those an escape comment covers; print the report.

A rule's `metadata.escape` (a regex) is the escape its original detector honors: the match is dropped
when its first line, or a comment line of the contiguous block directly above it, has the escape. That
is the originals' rule (check-concurrency.sh `allowed`, lint-connection-lifetimes.py `escaped`), and a
tree rule cannot ask which line a sibling comment sits on.

Usage: python3 -I filter.py REPORT_TXT REPORT_JSON < matches.jsonl   (prints the finding count last)
"""
import collections
import json
import re
import sys

COMMENT = re.compile(r"^\s*(//|/\*|\*|#\[|@)")
lines_of = {}


def escaped(path, line, escape):
    if path not in lines_of:
        try:
            with open(path, encoding="utf-8", errors="replace") as f:
                lines_of[path] = f.read().split("\n")
        except OSError:
            lines_of[path] = []
    lines = lines_of[path]
    if line < len(lines) and escape.search(lines[line]):
        return True
    j = line - 1
    while j >= 0 and COMMENT.match(lines[j]):
        if escape.search(lines[j]):
            return True
        j -= 1
    return False


kept = []
for raw in sys.stdin:
    if not raw.strip():
        continue
    m = json.loads(raw)
    escape = (m.get("metadata") or {}).get("escape")
    line = m["range"]["start"]["line"]
    if escape and escaped(m["file"], line, re.compile(escape)):
        continue
    kept.append(m)
kept.sort(key=lambda m: (m["ruleId"], m["file"], m["range"]["start"]["line"]))
with open(sys.argv[2], "w", encoding="utf-8") as f:
    json.dump(kept, f, indent=1)
counts = collections.Counter(m["ruleId"] for m in kept)
with open(sys.argv[1], "w", encoding="utf-8") as f:
    f.write(f"ast-grep findings: {len(kept)}\n\n== by rule\n")
    for rule, n in sorted(counts.items(), key=lambda kv: -kv[1]):
        f.write(f"{n:6d} {rule}\n")
    current = None
    for m in kept:
        if m["ruleId"] != current:
            current = m["ruleId"]
            f.write(f"\n== {current}: {m['message']}\n   note: {m.get('note') or ''}\n")
        first = m["lines"].split("\n", 1)[0].strip()
        f.write(f"{m['file']}:{m['range']['start']['line'] + 1}: {first[:160]}\n")
print(len(kept))
