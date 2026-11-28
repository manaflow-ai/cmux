#!/usr/bin/env python3
"""Fail when a workflow step runs a repository script before its job checks the repository out.

Incident now:base-red:more:cmux-next-check-steps-reds (general/1114): the Mac fallback job in cmux-next.yml
ran `bash scripts/ci/cmux-next-steps/generated-files-linux.sh fallback` as its first step, before
actions/checkout. It passed only while the self-hosted runner's reused workspace still held an earlier
checkout; on a fresh workspace it exited 127 (No such file or directory) and turned feat-cmux-next red.

A hit is a step, before the job's first `actions/checkout`, that executes a repository path:
  - a run: line that invokes `scripts/`, `tools/`, `tests/` or `.github/` through bash/sh/zsh/python/
    python3/node/bun/ruby/perl/source/`.`, or directly (`./scripts/x.sh`, `scripts/x.sh`);
  - `uses: ./...` (a local action).
Mentions are not hits: comments, `gh api` path strings, `git archive SHA scripts/ci` arguments.
A job with no checkout step is skipped (it never reads the tree, or it seeds it some other way).

Usage: check_pre_checkout_scripts.py [WORKFLOW_DIR_OR_FILE ...]   (default: .github/workflows)
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

import yaml

REPO_PATH = r"(?:\./)?(?:scripts|tools|tests|\.github)/[\w./-]+"
INTERPRETER = r"(?:bash|sh|zsh|python3?|node|bun|ruby|perl|source|\.)(?:\s+-[\w-]+)*"
# At a command position: line start, or after ; && || | ( `{` `then` `do` `exec` `time` `env VAR=..`.
COMMAND_START = r"(?:^|[;&|(]\s*|\b(?:then|do|else|exec|time|if|!)\s+)"
INVOKE = re.compile(COMMAND_START + r"\s*(?:\w+=\S*\s+)*(?:" + INTERPRETER + r"\s+)?(?P<path>" + REPO_PATH + r")")


class _Loader(getattr(yaml, "CSafeLoader", yaml.SafeLoader)):
    """`on:` stays the string key `on` (YAML 1.1 would read it as True)."""


_Loader.add_constructor("tag:yaml.org,2002:bool", lambda loader, node: loader.construct_scalar(node))


def invoked_paths(run: str) -> list[str]:
    hits = []
    for raw in run.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        line = re.sub(r"\s#.*$", "", line)
        line = re.sub(r'"[^"]*"|\'[^\']*\'', '""', line)  # quoted text is data, not a command
        hits.extend(m.group("path") for m in INVOKE.finditer(line))
    return hits


def is_checkout(step: dict) -> bool:
    return str(step.get("uses", "")).split("@")[0] == "actions/checkout"


def job_hits(steps: list) -> list[tuple[int, str, str]]:
    steps = [s for s in steps if isinstance(s, dict)]
    first = next((i for i, s in enumerate(steps) if is_checkout(s)), None)
    if first is None:
        return []
    hits = []
    for i, step in enumerate(steps[:first]):
        name = str(step.get("name") or step.get("uses") or f"step {i}")
        uses = str(step.get("uses", ""))
        if uses.startswith("./"):
            hits.append((i, name, uses))
        for path in invoked_paths(str(step.get("run", ""))):
            hits.append((i, name, path))
    return hits


def check_file(path: Path) -> list[str]:
    doc = yaml.load(path.read_text(), Loader=_Loader) or {}
    out = []
    for job, body in (doc.get("jobs") or {}).items():
        if not isinstance(body, dict):
            continue
        for i, name, target in job_hits(body.get("steps") or []):
            out.append(f"{path}: job {job} step {i} ({name}) runs {target} before the job's actions/checkout")
    return out


def main(argv: list[str]) -> int:
    targets = [Path(a) for a in argv] or [Path(".github/workflows")]
    files = []
    for t in targets:
        files += sorted(p for p in t.glob("*.y*ml")) if t.is_dir() else [t]
    found = [hit for f in files for hit in check_file(f)]
    for hit in found:
        print(f"::error::{hit}")
    if found:
        print("A step that runs a repository script before checkout works only on a reused self-hosted workspace; "
              "on a fresh one it exits 127. Move the step after the job's checkout.", file=sys.stderr)
        return 1
    print(f"check_pre_checkout_scripts: {len(files)} workflow(s), no script runs before checkout")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
