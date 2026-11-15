#!/usr/bin/env python3
"""Every actions/upload-artifact step sets retention-days, so no artifact falls back to the 90-day default.

The org's Actions artifact storage quota filled again on 2026-11-14 ("Artifact storage quota has been
hit"); main still carried 25 upload steps with no retention-days. A step in .github/workflows/*.yml or in a
composite action (.github/actions/**/action.yml, any depth) fails when its `with:` has no retention-days (an
expression counts as set). That covers actions/upload-artifact and actions/upload-artifact/merge, which
writes a new artifact too. Pick the shortest period the step needs: 1 for a same-run handoff, 3 for logs and
screenshots, more only when a later run or a person reads it. Handbook:
docs/handbook/artifact-quota-fills-on-the-unguarded-branch.md in cmuxterm-hq.

A guard that reads nothing passes for the wrong reason, so it fails when it finds no workflow file or no
upload step at all (a moved directory or a changed `uses:` spelling would otherwise turn it off silently).
"""
from __future__ import annotations

import re
import shutil
import sys
import tempfile
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]

# actions/upload-artifact@<ref> and actions/upload-artifact/merge@<ref>; not download-artifact.
UPLOAD = re.compile(r"^actions/upload-artifact(/merge)?@")


def steps_of(doc):
    if not isinstance(doc, dict):
        return
    for job in (doc.get("jobs") or {}).values():
        for step in (job or {}).get("steps") or []:
            yield step
    for step in ((doc.get("runs") or {}).get("steps")) or []:
        yield step


def files_under(root: Path) -> list[Path]:
    return sorted((root / ".github/workflows").glob("*.y*ml")) + sorted((root / ".github/actions").rglob("action.y*ml"))


def scan(root: Path) -> tuple[list[Path], int, list[str]]:
    """(files read, upload steps found, steps with no retention-days)."""
    files = files_under(root)
    steps, out = 0, []
    for f in files:
        doc = yaml.safe_load(f.read_text())
        for step in steps_of(doc):
            if not isinstance(step, dict) or not UPLOAD.match(str(step.get("uses", ""))):
                continue
            steps += 1
            if "retention-days" not in (step.get("with") or {}):
                out.append(f"{f.relative_to(root)}: {step.get('name') or (step.get('with') or {}).get('name')}")
    return files, steps, out


def problems(root: Path) -> list[str]:
    files, steps, bad = scan(root)
    if not files:
        return [f"no workflow or action file under {root}/.github: the guard read nothing"]
    if not steps:
        return [f"no actions/upload-artifact step in {len(files)} files: the guard matched nothing"]
    return [f"upload-artifact without retention-days: {b}" for b in bad]


def self_check() -> None:
    """The guard's own cases, on a throwaway tree: merge steps, nested actions, and the empty scans."""
    made: list[Path] = []

    def tree(files: dict[str, str]) -> Path:
        root = Path(tempfile.mkdtemp(prefix="upload-retention-"))
        made.append(root)
        for rel, text in files.items():
            (root / rel).parent.mkdir(parents=True, exist_ok=True)
            (root / rel).write_text(text)
        return root

    wf = "jobs:\n  a:\n    steps:\n      - uses: {uses}\n        with: {{{with_}}}\n"
    merge = tree({".github/workflows/m.yml": wf.format(uses="actions/upload-artifact/merge@v4", with_="name: x")})
    assert problems(merge) == ["upload-artifact without retention-days: .github/workflows/m.yml: x"], problems(merge)
    nested = tree({".github/workflows/ok.yml": wf.format(uses="actions/upload-artifact@v7", with_="retention-days: 1"),
                   ".github/actions/a/b/action.yml":
                       "runs:\n  using: composite\n  steps:\n      - uses: actions/upload-artifact@v7\n"
                       "        with: {name: deep}\n"})
    assert problems(nested) == ["upload-artifact without retention-days: .github/actions/a/b/action.yml: deep"], \
        problems(nested)
    assert problems(tree({}))[0].startswith("no workflow or action file"), problems(tree({}))
    none = tree({".github/workflows/d.yml": wf.format(uses="actions/download-artifact@v7", with_="name: x")})
    assert problems(none)[0].startswith("no actions/upload-artifact step"), problems(none)
    capped = tree({".github/workflows/c.yml": wf.format(uses="actions/upload-artifact/merge@v4",
                                                        with_="retention-days: '${{ inputs.days }}'")})
    assert problems(capped) == [], problems(capped)
    for root in made:
        shutil.rmtree(root, ignore_errors=True)


if __name__ == "__main__":
    self_check()
    files, steps, _ = scan(ROOT)
    bad = problems(ROOT)
    for b in bad:
        print(b)
    if bad:
        print("add `retention-days: N` (shortest the step needs; see the docstring)")
    else:
        print(f"ok: {steps} upload steps in {len(files)} files set retention-days")
    sys.exit(1 if bad else 0)
