#!/usr/bin/env python3
"""Fail when a workflow job's `runs-on` can resolve to a GitHub-hosted label in manaflow-ai.

Leo, 2026-11-21 00:14Z: "the ci must flow." GitHub-hosted runners (ubuntu-*, macos-*, windows-*) start
nothing for manaflow-ai, so a job whose runs-on can pick one sits queued forever: at 01:20Z 280 cmux
runs had waited 13-15 h on `ubuntu-24.04`. A job takes an owned label instead: the persistent pool
(`cmux-fleet-linux-x64`, cmuxterm-hq runner_pool.py POOL_LABELS), a one-job JIT label
(`cmux-gcp-*-jit-x64`), a `glaeda-*` Mac, or `fromJSON(vars.RUNNER_POOLS).<key>`.

A hit is a hosted literal a same-repository run can reach:
  - a plain label, or a string literal inside `${{ }}` outside a fork-only branch
    (`github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04'` never evaluates here);
  - a hosted label inside a string literal's JSON list, as in the CI_TRUSTED_RUNNER selector
    `contains(fromJSON('["ubuntu-24.04", ...]'), vars.CI_TRUSTED_RUNNER) && vars.CI_TRUSTED_RUNNER`:
    the list admits the variable's value, so a hosted entry lets the variable route there.
A comparison operand (`vars.X == 'ubuntu-24.04'`) picks nothing and is not a hit.

The fork-branch parsing, runs-on forms and matrix expansion are check_runs_on_pools.py's.

Usage: check_no_hosted_runs_on.py [WORKFLOW_DIR_OR_FILE ...]   (default: .github/workflows)
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import check_runs_on_pools as pools  # noqa: E402

HOSTED = re.compile(r"^(?:ubuntu-(?:latest|slim|\d{2}\.\d{2}(?:-arm)?)|macos-(?:latest|\d+(?:-[a-z0-9]+)*)"
                    r"|windows-(?:latest|\d{4}(?:-arm)?|11-arm))$")

# (workflow file name, job id) -> why it may still reach a hosted label. Keep it empty but for reasons
# outside this repository's control.
EXCEPTIONS: dict[tuple[str, str], str] = {
    # .github/language-boundaries.toml: a PR that changes this workflow fails unless Leo labels it (the boundaries
    # are his call), so its CI_TRUSTED_RUNNER list drops ubuntu-24.04 only in a PR he approves.
    ("language-boundaries.yml", "language-boundaries"): "language-boundaries.yml is Leo's to change",
}


def _list_entries(value: str) -> list[str]:
    if not value.startswith("["):
        return []
    try:
        parsed = json.loads(value)
    except ValueError:
        return []
    return [v for v in parsed if isinstance(v, str)] if isinstance(parsed, list) else []


def hosted_labels(text: str) -> list[str]:
    """Hosted labels one runs-on value can resolve to outside a fork-only branch."""
    found: list[str] = []
    at = 0
    outside = []
    for m in pools.EXPRESSION.finditer(text):
        outside.append(text[at:m.start()])
        at = m.end()
        body = m.group(1)
        for s in pools.STRING.finditer(body):
            value = s.group()[1:-1].replace("''", "'")
            candidates = [value] if HOSTED.match(value) else [v for v in _list_entries(value) if HOSTED.match(v)]
            if not candidates or pools.literal_is_fork_only(body, s.start()):
                continue
            if HOSTED.match(value) and pools.is_comparison_operand(body, s.start(), s.end()):
                continue
            found += [c for c in candidates if c not in found]
    outside.append(text[at:])
    for chunk in outside:
        found += [w for w in re.split(r"[\s,\[\]\"']+", chunk.split("#", 1)[0]) if HOSTED.match(w) and w not in found]
    return found


def job_hits(job: dict) -> list[str]:
    import workflow_jobs  # noqa: PLC0415  (tests/ on sys.path via check_runs_on_pools)

    hits: list[str] = []
    for item in workflow_jobs.runs_on_items(job):
        if not isinstance(item, str):
            continue
        for cell in workflow_jobs.expand_matrix(job, item.strip()) or [item]:
            hits += [label for label in hosted_labels(cell) if label not in hits]
    return hits


def hits(files: list[Path]) -> list[tuple[str, str, list[str]]]:
    import yaml  # noqa: PLC0415

    found = []
    for path in files:
        doc = yaml.load(path.read_text(encoding="utf-8"), Loader=yaml.BaseLoader) or {}
        jobs = doc.get("jobs") if isinstance(doc, dict) else None
        for job_id, job in (jobs or {}).items():
            if not isinstance(job, dict) or (path.name, job_id) in EXCEPTIONS:
                continue
            labels = job_hits(job)
            if labels:
                found.append((path.name, job_id, labels))
    return found


def main(argv: list[str]) -> int:
    found = hits(pools.workflow_files(argv))
    for name, job_id, labels in found:
        print(f"{name} {job_id}: runs-on can resolve to GitHub-hosted {', '.join(labels)}, which never starts in "
              "manaflow-ai. Fix: an owned label (cmux-fleet-linux-x64, a cmux-gcp-*-jit-x64 label, a glaeda-* Mac, "
              "or fromJSON(vars.RUNNER_POOLS).<key>); keep hosted labels only behind "
              "`github.repository_owner != 'manaflow-ai' &&`")
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
