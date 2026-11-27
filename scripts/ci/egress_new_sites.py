#!/usr/bin/env python3
"""Fail when a change adds an outbound site outside the egress gate, whatever the base's own state.

tests/test_egress_gate.py checks the whole tree against tests/egress_ungated.json. On a pull request into
feat-cmux-next it runs only in the "cmux-next CI guard group" job, which a pull request skips unless labeled
full-ci or ready-to-land, and there guards_new_reds.py excuses a step that is red on the base too. So once one
ungated site reached the base, the step was red on every later head and base alike, and each later site merged
as "not new": between 11-24 and 11-26 ten more reached feat-cmux-next that way (acpmux send_trace and
forum_hosted, cmux-git-cache, autocloud, mcp_servers, runnable links, machine state push and others).

This check compares the change with its own base, file by file, from git objects only (under a second): a file
whose count of any ungated form (test_egress_gate.FORMS) is higher on the merge than on the base fails, so a
red base never excuses a new site. A rename compares the new path with the old one. It runs in cmux-next fast
gates (scripts/ci/cmux_next_fast_gates.py), on every pull request into feat-cmux-next.

Run it: python3 scripts/ci/egress_new_sites.py --base BASE_SHA --head MERGE_SHA [--repo DIR]
"""
from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tests"))
from test_egress_gate import COMPILED, GATES, sites_in  # noqa: E402
from test_outbound_hosts import SCAN  # noqa: E402
from test_classic_cloud_routes import in_scope  # noqa: E402


def git(repo: Path, *args: str) -> subprocess.CompletedProcess:
    return subprocess.run(["git", "-C", str(repo), *args], capture_output=True)


def changed(repo: Path, base: str, head: str) -> list[tuple[str | None, str]]:
    """(base path or None, head path) for every file BASE..HEAD adds, changes or renames into."""
    p = git(repo, "diff", "--name-status", "-z", "-M", base, head)
    if p.returncode != 0:
        raise RuntimeError(p.stderr.decode(errors="replace"))
    parts = [x for x in p.stdout.decode().split("\0")]
    out: list[tuple[str | None, str]] = []
    i = 0
    while i < len(parts) and parts[i]:
        status = parts[i]
        if status[0] in "RC":
            out.append((parts[i + 1], parts[i + 2]))
            i += 3
        else:
            path = parts[i + 1]
            if status[0] != "D":
                out.append((path if status[0] != "A" else None, path))
            i += 2
    return out


def scanned(rel: str) -> bool:
    return Path(rel).suffix in COMPILED and in_scope(rel, SCAN) and not rel.startswith(GATES)


def sites_at(repo: Path, rev: str, rel: str | None) -> dict[str, int]:
    if rel is None:
        return {}
    p = git(repo, "show", f"{rev}:{rel}")
    if p.returncode != 0:
        return {}
    return sites_in(p.stdout.decode("utf-8", errors="replace"), rel)


def new_sites(repo: Path, base: str, head: str) -> list[str]:
    out = []
    for old, new in changed(repo, base, head):
        if not scanned(new):
            continue
        before = sites_at(repo, base, old if old is None or scanned(old) else None)
        after = sites_at(repo, head, new)
        for form in sorted(after):
            n, was = after[form], before.get(form, 0)
            if n > was:
                out.append(f"{new}: {n - was} new {form} site(s) outside the egress gate: make the client through "
                           "the gate (cmux_egress in Rust, CmuxEgress in Swift; docs/privacy.md, Egress gate) "
                           "instead of by hand")
    return out


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--base", required=True)
    ap.add_argument("--head", required=True)
    ap.add_argument("--repo", type=Path, default=ROOT)
    args = ap.parse_args(argv)
    found = new_sites(args.repo.resolve(), args.base, args.head)
    for line in found:
        print(f"::error title=egress gate::{line}", flush=True)
    if found:
        print(f"egress gate: {len(found)} new ungated site(s) against base {args.base}")
        return 1
    print("egress gate: no new ungated site")
    return 0


if __name__ == "__main__":
    sys.exit(main())
