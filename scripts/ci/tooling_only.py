"""Whether a pull request changes only CI and tooling files (ci-min-per-pr-140).

A tooling-only change is one whose every changed path is under .github/, scripts/, tests/, tests_v2/, ci/,
tools/ or docs/, or is a Markdown file. On such a change the full-ci label no longer forces the Rust build jobs
the path routers place (scripts/ci/affected_jobs.py route and gate, scripts/ci/fast_tier_cargo_route.py): they
route by their inputs instead, so a job still runs when the change edits its own workflow, a script or action it
runs, or a file its crates read. Over the last 50 merged cmux pull requests, ci-tools pull requests labeled full-ci
spent about 360 runner-min on fast-tier-cargo and the acpmux jobs whose inputs they never touched
(/tmp/ci140/unchanged.md, 2026-11-26).

An empty or unreadable change list is not tooling-only: the label keeps forcing every job (fail open).
"""
from __future__ import annotations

PREFIXES = (".github/", "scripts/", "tests/", "tests_v2/", "ci/", "tools/", "docs/")


def tooling_only(changed: list[str] | None) -> bool:
    """True when CHANGED is non-empty and every path is a CI or tooling file (PREFIXES, or *.md)."""
    if not changed:
        return False
    return all(path.startswith(PREFIXES) or path.endswith(".md") for path in changed)
