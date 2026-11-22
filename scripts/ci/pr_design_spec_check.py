#!/usr/bin/env python3
"""Warn when a pull request changes a UI surface without citing the surface's design spec.

    pr_design_spec_check.py --body-file BODY --paths-file PATHS [--map .github/design-surfaces.json]

.github/design-surfaces.json maps each UI surface (model-picker, composer, ...) to its source paths and its
design spec (leo-workspace design/<surface>.md, one spec per surface). A pull request that changes one of a
surface's paths (a file, or anything under a directory) should cite that surface's spec in its description,
by its file name (`model-picker.md`, `design/model-picker.md`) or a link to it, or change the spec when the
spec lives in this repository. The spec records the designs already settled and the ones replaced, so a change
cannot quietly undo one: on 2026-10-28 #26071 made the model picker's left rail the default over the harness
tabs across the top, and nobody noticed the earlier design was gone until Leo did.

It only warns: a `::warning` annotation per surface and a short summary, and it always exits 0 (2 on bad
input). A mapped path that no longer exists in the checkout is warned about too, so the map follows moves.

A surface may name a `checklist` (the spec section every PR on it passes, one numbered rule per item with
Leo's words, e.g. `design/model-picker.md#checklist`). Every PR that changes the surface gets a notice naming
it, cited or not, so a lane patching one corner reads the whole list (Leo 2026-10-31: "WHY IS THE MODEL
PICKER ALWAYS ALWAYS FUCKING SHIT", after many lanes patched the picker piecemeal).

The map is read twice: the base branch's (--map) and the pull request's (--pr-map). Their surfaces are joined,
path by path, so a PR that drops or empties the map, or removes a surface's paths, is still judged by the
base's map; a PR that moves a surface's files and maps the new paths is judged on both.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

DEFAULT_MAP = ".github/design-surfaces.json"


def load_map(path: Path) -> dict[str, dict]:
    data = json.loads(path.read_text())
    surfaces = data.get("surfaces")
    if not isinstance(surfaces, dict):
        raise ValueError(f"{path}: no `surfaces` object")
    for name, s in surfaces.items():
        if not isinstance(s, dict) or not isinstance(s.get("spec"), str) or not isinstance(s.get("paths"), list):
            raise ValueError(f"{path}: surface {name!r} needs a `spec` string and a `paths` list")
        if not all(isinstance(p, str) for p in s["paths"]):
            raise ValueError(f"{path}: surface {name!r} has a path that is not a string")
    return surfaces


def join_maps(*maps: dict[str, dict] | None) -> dict[str, dict]:
    """The surfaces of every map, joined: a surface's paths from all of them, its spec from the first."""
    out: dict[str, dict] = {}
    for m in maps:
        for name, s in (m or {}).items():
            have = out.setdefault(name, {"spec": s["spec"], "paths": []})
            if isinstance(s.get("checklist"), str):
                have.setdefault("checklist", s["checklist"])
            have["paths"] += [p for p in s["paths"] if p not in have["paths"]]
    return out


def norm(p: str) -> str:
    p = p.strip()
    while p.startswith("./"):
        p = p[2:]
    return p.rstrip("/")


def owns(owned: str, path: str) -> bool:
    owned = norm(owned)
    return bool(owned) and (path == owned or path.startswith(owned + "/"))


def spec_file(spec: str) -> str:
    """The spec's repository path: `leo-workspace design/model-picker.md` -> `design/model-picker.md`."""
    return spec.split()[-1] if spec.split() else spec


def cites(body: str, spec: str) -> bool:
    """The description names the spec: its file name (model-picker.md) or its design/ path, in any form."""
    name = Path(spec_file(spec)).name
    return bool(name) and re.search(r"(?<![\w-])" + re.escape(name) + r"(?![\w-])", body or "", re.IGNORECASE) is not None


def checklists(surfaces: dict[str, dict], paths: list[str]) -> list[str]:
    """A notice per changed surface that names a checklist: the rules every PR on it passes."""
    changed = [norm(p) for p in paths if norm(p)]
    out = []
    for name, s in sorted(surfaces.items()):
        checklist = s.get("checklist")
        if isinstance(checklist, str) and any(owns(o, p) for p in changed for o in s["paths"]):
            out.append(f"This PR changes the {name} surface: it must pass every item of {checklist} "
                       f"({s['spec']}). Say in the description which items it touches.")
    return out


def check(surfaces: dict[str, dict], paths: list[str], body: str,
          tree: set[str] | None = None) -> tuple[list[str], list[str]]:
    """(warnings for surfaces changed without their spec cited, warnings for mapped paths that are gone)."""
    changed = [norm(p) for p in paths if norm(p)]
    uncited, gone = [], []
    for name, s in sorted(surfaces.items()):
        mine = sorted({p for p in changed if any(owns(o, p) for o in s["paths"])})
        spec = s["spec"]
        if mine and not cites(body, spec) and spec_file(spec) not in changed:
            shown = ", ".join(mine[:4]) + (f" and {len(mine) - 4} more" if len(mine) > 4 else "")
            uncited.append(f"This PR changes the {name} surface ({shown}) but its description does not cite the "
                           f"surface's design spec, {spec}. Read it, say in the description how this change fits it "
                           f"(cite `{Path(spec_file(spec)).name}`), and update the spec when the design changes.")
        if tree is not None:
            for o in s["paths"]:
                if not any(owns(o, t) for t in tree):
                    gone.append(f"{DEFAULT_MAP}: the {name} surface maps {o}, which no longer exists; update the map.")
    return uncited, gone


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--body-file", required=True)
    p.add_argument("--paths-file", required=True)
    p.add_argument("--map", default=DEFAULT_MAP, help="the base branch's map")
    p.add_argument("--pr-map", help="the pull request's map, joined with --map; missing or unreadable is ignored")
    p.add_argument("--tree-file", help="the PR's file list (git ls-tree -r --name-only): mapped paths are checked against it")
    a = p.parse_args(argv)
    try:
        base = load_map(Path(a.map))
        body = Path(a.body_file).read_text()
        paths = Path(a.paths_file).read_text().splitlines()
        tree = {norm(t) for t in Path(a.tree_file).read_text().splitlines() if norm(t)} if a.tree_file else None
    except (OSError, ValueError) as err:
        print(f"::error::pr_design_spec_check: {err}")
        return 2
    theirs = None
    if a.pr_map:
        try:
            theirs = load_map(Path(a.pr_map))
        except (OSError, ValueError) as err:
            print(f"::warning title=Design spec::this PR's {DEFAULT_MAP} is missing or unreadable ({err}); "
                  "using the base branch's map")
    joined = join_maps(base, theirs)
    uncited, _ = check(joined, paths, body)
    for note in checklists(joined, paths):
        print(f"::notice title=Design checklist::{note}")
    _, gone = check(theirs or base, [], body, tree=tree)
    for w in uncited + gone:
        print(f"::warning title=Design spec::{w}")
    if not uncited and not gone:
        print("Every UI surface this PR changes cites its design spec (or none is changed).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
