#!/usr/bin/env python3
"""Refuse a pull request into main that changes classic's auto-deployed API without a reason.

Classic cmux.com and its API deploy on their own (Vercel) when a commit lands on main. `scripts/ci/classic-auto-deploy.json` lists those deploys and the paths each guards. A
pull request into main that changes a guarded path fails unless its description has a line
`Classic API change: <reason>`. Into feat-cmux-next the same change is a warning only:
feat-cmux-next does not reach main today, so it deploys nothing classic, but the warning keeps
the change visible if the branches are ever merged.

New NEXT Cloud backend code belongs in manaflow-ai/cmux-platform, not in classic's paths.

Leo, 2026-11-04: "apparently the api if we change it it'll auto deploy so we wanna make extra
sure we dont change it for clasisc".
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_CONFIG = ROOT / "scripts" / "ci" / "classic-auto-deploy.json"
REASON_LINE = re.compile(r"^[ \t]*Classic API change:[ \t]*(\S.*)$", re.MULTILINE)
PLACEHOLDER = re.compile(r"^<[^>]*>$")


def glob_regex(pattern: str) -> re.Pattern[str]:
    """`**` crosses directories, `*` and `?` stay within one path segment."""
    out = []
    i = 0
    while i < len(pattern):
        if pattern.startswith("**/", i):
            out.append("(?:.*/)?")
            i += 3
        elif pattern.startswith("**", i):
            out.append(".*")
            i += 2
        elif pattern[i] == "*":
            out.append("[^/]*")
            i += 1
        elif pattern[i] == "?":
            out.append("[^/]")
            i += 1
        else:
            out.append(re.escape(pattern[i]))
            i += 1
    return re.compile("^" + "".join(out) + "$")


def load_config(path: Path) -> dict:
    return json.loads(path.read_text())


def guarded_hits(config: dict, paths: list[str]) -> dict[str, list[str]]:
    """Map each guarded deploy id to the changed paths it covers."""
    hits: dict[str, list[str]] = {}
    for deploy in config["deploys"]:
        if not deploy.get("guarded"):
            continue
        include = [glob_regex(p) for p in deploy["paths"]]
        exclude = [glob_regex(p) for p in deploy.get("exclude", [])]
        for path in paths:
            if any(r.match(path) for r in include) and not any(r.match(path) for r in exclude):
                hits.setdefault(deploy["id"], []).append(path)
    return hits


def reason(body: str) -> str | None:
    for match in REASON_LINE.finditer(body or ""):
        text = match.group(1).strip()
        if text and not PLACEHOLDER.match(text):
            return text
    return None


def check(
    config: dict,
    base: str,
    body: str,
    paths: list[str],
    expected_files: int | None = None,
    listed_records: int | None = None,
) -> tuple[int, list[str]]:
    """Return (exit code, annotation lines).

    `expected_files` is the pull request's changed-file count. GitHub's files listing stops at
    3,000 entries, so a shorter listing than that count may hide a guarded path: into main that
    fails unless the description gives a reason. `listed_records` is how many file records the
    listing returned; a rename adds its old path to `paths`, so `paths` alone overcounts."""
    hits = guarded_hits(config, paths)
    listed = listed_records if listed_records is not None else len(set(paths))
    if expected_files is not None and listed < expected_files and not reason(body):
        message = (
            f"The changed-file listing has {listed} paths but the pull request changes {expected_files} files; "
            "a guarded classic path may be past the listing's end."
        )
        if base == "main":
            return 1, [f"::error::{message} Add a line `Classic API change: <reason>`, or split the pull request."]
        if not hits:
            return 0, [f"::warning::{message}"]
    if not hits:
        return 0, ["::notice::No classic auto-deployed API path changed."]
    lines = []
    for deploy_id, changed in sorted(hits.items()):
        target = next(d["target"] for d in config["deploys"] if d["id"] == deploy_id)
        shown = ", ".join(changed[:10]) + (f" and {len(changed) - 10} more" if len(changed) > 10 else "")
        lines.append(f"{deploy_id} ({target}): {shown}")
    why = reason(body)
    if why:
        return 0, [f"::notice::Classic API change accepted ({why}): {line}" for line in lines]
    if base == "main":
        out = [f"::error::Changes classic's auto-deployed API on merge to main: {line}" for line in lines]
        out.append(
            "::error::Add a line `Classic API change: <reason>` to the description if classic needs this; "
            "new NEXT Cloud backend code goes to manaflow-ai/cmux-platform instead "
            "(scripts/ci/classic-auto-deploy.json lists the paths)."
        )
        return 1, out
    out = [
        f"::warning::Changes a path classic auto-deploys from main (not deployed from {base}): {line}"
        for line in lines
    ]
    return 0, out


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--base", required=True, help="the pull request's base branch")
    parser.add_argument("--body-file", type=Path, required=True)
    parser.add_argument("--paths-file", type=Path, required=True, help="changed paths, one per line")
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    parser.add_argument("--expected-files", type=int, default=None, help="the pull request's changed_files")
    parser.add_argument("--listed-records", type=int, default=None, help="file records the listing returned")
    args = parser.parse_args(argv)
    body = args.body_file.read_text() if args.body_file.exists() else ""
    paths = [line.strip() for line in args.paths_file.read_text().splitlines() if line.strip()]
    code, lines = check(load_config(args.config), args.base, body, paths, args.expected_files, args.listed_records)
    for line in lines:
        print(line)
    return code


if __name__ == "__main__":
    sys.exit(main())
