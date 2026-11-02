#!/usr/bin/env python3
"""Warn when a pull request changes cmux Cloud backend code here instead of in manaflow-ai/cmux-platform.

    pr_cloud_backend_check.py --body-file BODY --status-file STATUS [--map .github/cloud-backend-paths.json]

New cloud backend code (control plane, provider drivers, metering and billing, the hand-off server,
entitlements, the NEXT Worker) goes to the private repository manaflow-ai/cmux-platform, through PRs that
follow its stack (Effect `HttpApi`, its committed openapi.json). Backend code already here moves there one
PR-sized move at a time: it lands in cmux-platform first, and a follow-up deletes the copy here. The client,
the CLI, the GUI and the protocol stay in cmux. On 2026-10-31 Leo found dozens of open backend PRs in cmux:
"WHY DO WE HAVE SO MANY PRS IN CMUX INSTEAD OF CMUX-PLATFORM!?"

.github/cloud-backend-paths.json lists the backend paths (a file, or everything under a directory) and the
paths under them that stay here. STATUS is `git diff --name-status --no-renames` output. A PR that adds a file
under a backend path gets a warning that names cmux-platform; one that only changes or deletes files there gets
a softer one. Either is cleared when the description has a line starting `cmux-platform:` that says why the
change belongs here (a fix to code that has not moved yet, the deleting half of a move) or links the
cmux-platform PR. It only warns: it always exits 0 (2 on bad input).
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

DEFAULT_MAP = ".github/cloud-backend-paths.json"
PLATFORM = "manaflow-ai/cmux-platform"
ANSWER = re.compile(r"^[ \t]*(?:[-*][ \t]*)?\**cmux-platform[ \t]*(?::\**|\**:)[ \t]*\S", re.IGNORECASE | re.MULTILINE)


def load_map(path: Path) -> tuple[list[str], list[str]]:
    data = json.loads(path.read_text())
    if not isinstance(data, dict):
        raise ValueError(f"{path}: the map must be a JSON object")
    backend, stays = data.get("backend"), data.get("stays", [])
    for key, value in (("backend", backend), ("stays", stays)):
        if not isinstance(value, list) or not all(isinstance(p, str) and p.strip() for p in value):
            raise ValueError(f"{path}: `{key}` must be a list of non-empty path strings")
    return backend, stays


def norm(p: str) -> str:
    p = p.strip()
    while p.startswith("./"):
        p = p[2:]
    return p.rstrip("/")


def under(owned: str, path: str) -> bool:
    owned = norm(owned)
    return bool(owned) and (path == owned or path.startswith(owned + "/"))


def parse_status(text: str) -> list[tuple[str, str]]:
    """(status letter, path) per line of `git diff --name-status --no-renames`."""
    out = []
    for line in text.splitlines():
        parts = line.split("\t")
        if len(parts) >= 2 and parts[0]:
            out.append((parts[0][0].upper(), norm(parts[-1])))
    return out


def answered(body: str) -> bool:
    return ANSWER.search(body or "") is not None


def check(backend: list[str], stays: list[str], status: list[tuple[str, str]], body: str) -> list[str]:
    """The warnings for this PR (empty when it changes no backend path or its description answers)."""
    def is_backend(p: str) -> bool:
        return any(under(b, p) for b in backend) and not any(under(s, p) for s in stays)

    added = sorted({p for s, p in status if s == "A" and is_backend(p)})
    changed = sorted({p for s, p in status if s != "A" and is_backend(p)})
    if not (added or changed) or answered(body):
        return []

    def shown(paths: list[str]) -> str:
        return ", ".join(paths[:4]) + (f" and {len(paths) - 4} more" if len(paths) > 4 else "")

    how = (f"Add a line to the description starting `cmux-platform:` with the {PLATFORM} PR, or why this "
           "belongs here (a fix to code that has not moved yet, or the deleting half of a move).")
    if added:
        return [f"This PR adds cloud backend code to cmux ({shown(added)}). New cloud backend code (control plane, "
                f"provider drivers, billing, entitlements, the hand-off server, the NEXT Worker) goes to {PLATFORM} "
                f"(Effect HttpApi, its committed openapi.json); the client, CLI, GUI and protocol stay here. {how}"]
    return [f"This PR changes cloud backend code in cmux ({shown(changed)}). That code is moving to {PLATFORM} "
            f"one PR-sized move at a time; a new feature goes there, not here. {how}"]


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--body-file", required=True)
    p.add_argument("--status-file", required=True, help="git diff --name-status --no-renames output")
    p.add_argument("--map", default=DEFAULT_MAP)
    a = p.parse_args(argv)
    try:
        backend, stays = load_map(Path(a.map))
        body = Path(a.body_file).read_text()
        status = parse_status(Path(a.status_file).read_text())
    except (OSError, ValueError) as err:
        print(f"::error::pr_cloud_backend_check: {err}")
        return 2
    warnings = check(backend, stays, status, body)
    for w in warnings:
        print(f"::warning title=Cloud backend belongs in cmux-platform::{w}")
    if not warnings:
        print("This PR adds no cloud backend code to cmux (or its description says why it belongs here).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
