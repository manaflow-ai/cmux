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
    try:
        with open(path, "rb") as f:
            first = f.readline(200)
    except OSError:
        return False
    return bool(SHEBANG.match(first.decode("utf-8", "replace")))


# Shells whose run: text is not shell. Anything else (bash, sh, a path, `/usr/bin/env bash {0}`, an expression,
# an unknown) is scanned: a wrong guess here could only let a loop through.
NOT_SHELL = {"python", "python3", "pwsh", "powershell", "cmd", "node", "ruby", "perl", "deno", "bun"}


def base_name(word):
    return word.rsplit("/", 1)[-1]


def is_posix_shell(shell):
    """False only for a shell that is clearly not POSIX (python, pwsh, ...), with its path and options."""
    words = str(shell or "").strip("'\"").split()
    if words and base_name(words[0]) == "env":
        words = words[1:]
        if any(w.startswith("-") or "=" in w for w in words):
            return True  # env with options or assignments: which word runs is not certain, so scan it
    words = [w for w in words if not w.startswith("-")]
    return not words or base_name(words[0]) not in NOT_SHELL


def load_yaml():
    try:
        import yaml
    except ImportError:  # fail closed: a workflow nobody parsed is not a clean workflow
        sys.exit("polling_scan: PyYAML is required to read workflows (pip install pyyaml)")
    return yaml


def run_blocks(text):
    """(start line, shell text) for every step `run:` in workflow or action YAML that a POSIX shell runs,
    read with a real YAML parser (any spelling: quoted keys, flow mappings, folded scalars, any indent).
    A step is skipped only when its own `shell:` is clearly not POSIX; `defaults:` never skips one."""
    yaml = load_yaml()
    try:
        root = yaml.compose(text, Loader=yaml.SafeLoader)
    except yaml.YAMLError as e:
        raise ValueError("not valid YAML: %s" % e)
    out = []

    def walk(node):
        if isinstance(node, yaml.MappingNode):
            keys = {k.value: v for k, v in node.value if isinstance(k, yaml.ScalarNode)}
            run = keys.get("run")
            shell = keys.get("shell")
            if isinstance(run, yaml.ScalarNode) and not (isinstance(shell, yaml.ScalarNode)
                                                        and not is_posix_shell(shell.value)):
                block = run.style in ("|", ">")
                out.append((run.start_mark.line + (2 if block else 1), run.value))
            for _, v in node.value:
                walk(v)
        elif isinstance(node, yaml.SequenceNode):
            for v in node.value:
                walk(v)

    if root is not None:
        walk(root)
    return [(n, EXPR.sub("GH_EXPR", t)) for n, t in out]


def scan_text(rel, text):
    """[(line, loop's first line, message)] for one file."""
    try:
        pieces = run_blocks(text) if is_workflow(rel) else [(1, text)]
    except ValueError as e:  # a workflow that does not parse is reported, never passed
        return [(1, "", "scanner could not read this workflow: %s" % e)]
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
