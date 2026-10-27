#!/usr/bin/env python3
# Vendored from manaflow-ai/cmuxterm-hq tools/agent-guards/polling_scan.py; keep the two copies in sync.
# Change the judge there first, then copy it here unchanged below this header.
"""Fail on polling loops checked into a repo's scripts and workflows.

The rulebook bans polling loops (`until ...; do sleep`, `while true`, `gh pr checks --watch`,
loops that wait on a file): waits go through one `glaeda-gh wait run|pr ... --sha`. The
block-gh-polling hook refuses them in agent commands; this scanner runs the same judge
(block_polling.py) over files, so a loop can't come back through a script or a workflow.

Scanned: shell scripts (*.sh, *.bash, *.zsh, or a shell shebang) and the `run:` blocks of
GitHub workflow and action YAML. Words in quotes, heredoc bodies and comments are data, as in
the hook.

A loop that must stay (a CI job with no glaeda-gh, waiting on a GitHub API event under a
deadline) needs an allowlist entry with a reason:

    {"path": "scripts/x.sh", "match": "until gh run view \"$id\" --json status; do",
     "reason": "why this loop is bounded and has no glaeda-gh"}

`match` is the loop's first line, stripped. An entry that matches nothing, or has no reason,
fails the scan too, so the list can't rot.

    polling_scan.py [--root DIR] [--allowlist FILE] [PATH ...]

--allowlist defaults to DIR/.github/polling-allowlist.json when that exists. With no PATH it scans
the files git tracks under --root. Exit 0 clean, 1 on a violation.
"""

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import block_polling  # noqa: E402

DEFAULT_ALLOWLIST = ".github/polling-allowlist.json"
SHELL_EXT = {".sh", ".bash", ".zsh", ".ksh"}
SHEBANG = re.compile(r"^#!\s*\S*?(?:/env\s+(?:-\S+\s+)*)?\S*\b(?:ba|z|da|k)?sh\b")
RUN_KEY = re.compile(r"^(\s*)(?:-\s+)?(run):\s*(.*?)\s*$")
SHELL_KEY = re.compile(r"^\s*(?:-\s+)?shell:\s*(\S+)")
EXPR = re.compile(r"\$\{\{.*?\}\}")


def is_workflow(rel):
    parts = rel.split("/")
    name = parts[-1]
    if not name.endswith((".yml", ".yaml")):
        return False
    return (".github" in parts and "workflows" in parts) or name in ("action.yml", "action.yaml")


def is_shell(path, rel):
    if Path(rel).suffix in SHELL_EXT:
        return True
    if Path(rel).suffix:
        return False
    try:
        with open(path, "rb") as f:
            first = f.readline(200)
    except OSError:
        return False
    return bool(SHEBANG.match(first.decode("utf-8", "replace")))


def run_blocks(text):
    """(start line, shell text) for every `run:` in workflow YAML that a POSIX shell runs."""
    lines = text.split("\n")
    out = []
    i = 0
    while i < len(lines):
        m = RUN_KEY.match(lines[i])
        if not m:
            i += 1
            continue
        key_col = lines[i].index("run:")
        value = m.group(3)
        if shell_of(lines, i, key_col) not in (None, "bash", "sh", "zsh"):
            i += 1
            continue
        if value[:1] in ("|", ">"):
            body, j = [], i + 1
            while j < len(lines) and (not lines[j].strip() or indent(lines[j]) > key_col):
                body.append(lines[j])
                j += 1
            cut = min((indent(b) for b in body if b.strip()), default=0)
            out.append((i + 2, "\n".join(b[cut:] for b in body)))
            i = j
            continue
        j = i + 1
        while j < len(lines) and lines[j].strip() and indent(lines[j]) > key_col:
            j += 1  # a plain or quoted scalar continued on more-indented lines (YAML folds them with spaces)
        if j > i + 1:
            value = " ".join([value] + [line.strip() for line in lines[i + 1:j]])
        if value[:1] in ("'", '"') and value[-1:] == value[:1]:
            value = value[1:-1]
        out.append((i + 1, value))
        i = j
    return [(n, EXPR.sub("GH_EXPR", t)) for n, t in out]


def indent(line):
    return len(line) - len(line.lstrip(" "))


def shell_of(lines, i, key_col):
    """The `shell:` of the step holding the run key at lines[i], or None."""
    dash = key_col - 2
    begin = i
    while begin >= 0 and not (indent(lines[begin]) == dash and lines[begin].lstrip().startswith("- ")):
        if lines[begin].strip() and indent(lines[begin]) < key_col and begin != i:
            break
        begin -= 1
    end = i + 1
    while end < len(lines) and (not lines[end].strip() or indent(lines[end]) >= key_col):
        end += 1
    for j in range(max(begin, 0), end):
        line = lines[j]
        m = SHELL_KEY.match(line)
        if m and (indent(line) == key_col or (indent(line) == dash and line.lstrip().startswith("- "))):
            return m.group(1).split("{")[0].strip("'\"")
    return None


def scan_text(rel, text):
    """[(line, loop's first line, message)] for one file."""
    pieces = run_blocks(text) if is_workflow(rel) else [(1, text)]
    file_lines = text.split("\n")
    found = []
    for start, shell in pieces:
        try:
            violations = block_polling.find_violations(shell)
        except Exception as e:  # a parser fault is a scanner bug, not a pass
            found.append((start, "", "scanner could not parse this shell: %r" % e))
            continue
        for line, msg in violations:
            n = start + (line or 1) - 1
            first = file_lines[n - 1].strip() if 0 < n <= len(file_lines) else ""
            found.append((n, first, msg))
    return found


def tracked(root):
    out = subprocess.run(["git", "-C", str(root), "ls-files", "-z"], check=True, capture_output=True).stdout
    return [p for p in out.decode().split("\0") if p]


def load_allowlist(path):
    if not path:
        return [], []
    data = json.loads(Path(path).read_text())
    entries = data.get("entries", data) if isinstance(data, dict) else data
    errors = []
    for e in entries:
        if not (isinstance(e, dict) and e.get("path") and e.get("match")):
            errors.append("allowlist entry needs path and match: %r" % (e,))
        elif len(str(e.get("reason", "")).strip()) < 20:
            errors.append("allowlist entry for %s needs a reason (why the loop must stay): %r" % (e["path"], e["match"]))
    return entries, errors


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--root", default=".")
    ap.add_argument("--allowlist")
    ap.add_argument("paths", nargs="*")
    args = ap.parse_args(argv)
    root = Path(args.root).resolve()
    rels = [os.path.relpath(Path(p).resolve(), root) for p in args.paths] if args.paths else tracked(root)
    allowlist = args.allowlist
    if allowlist is None and (root / DEFAULT_ALLOWLIST).is_file():
        allowlist = root / DEFAULT_ALLOWLIST
    entries, errors = load_allowlist(allowlist)
    used = set()
    violations = []
    scanned = 0
    for rel in sorted(rels):
        path = root / rel
        if not path.is_file() or not (is_workflow(rel) or is_shell(path, rel)):
            continue
        scanned += 1
        text = path.read_text(encoding="utf-8", errors="replace")
        for n, first, msg in scan_text(rel, text):
            hit = next((k for k, e in enumerate(entries) if e.get("path") == rel and e.get("match") == first), None)
            if hit is not None:
                used.add(hit)
                continue
            violations.append((rel, n, first, msg))
    for k, e in enumerate(entries):
        if k not in used and isinstance(e, dict) and e.get("path"):
            errors.append("allowlist entry matches no loop (remove it): %s: %s" % (e.get("path"), e.get("match")))
    for rel, n, first, msg in violations:
        short = msg.split(". ")[0].replace("Blocked: ", "")
        print("::error file=%s,line=%d::polling loop: %s" % (rel, n, short))
        print("%s:%d: %s\n    %s\n" % (rel, n, first, msg))
    for err in errors:
        print("::error::%s" % err)
    print("polling scan: %d files, %d violations, %d allowlisted, %d allowlist errors"
          % (scanned, len(violations), len(used), len(errors)))
    return 1 if violations or errors else 0


if __name__ == "__main__":
    sys.exit(main())
