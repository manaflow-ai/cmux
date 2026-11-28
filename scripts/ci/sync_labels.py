#!/usr/bin/env python3
"""Make the repository's labels match `.github/labels.json`.

Creates labels that are missing and updates color or description drift. It
never deletes: this repository carries a pile of CI plumbing labels that are
not in the manifest and must survive a sync.

    python3 scripts/ci/sync_labels.py --dry-run
    python3 scripts/ci/sync_labels.py            # needs a token with issues:write

Prints one line per label with what it did, so a workflow log shows the diff.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
MANIFEST = ROOT / ".github" / "labels.json"
API = "https://api.github.com"


def request(method: str, url: str, token: str, payload: dict[str, Any] | None = None) -> Any:
    body = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(url, data=body, method=method)
    req.add_header("Accept", "application/vnd.github+json")
    req.add_header("Authorization", f"Bearer {token}")
    req.add_header("X-GitHub-Api-Version", "2022-11-28")
    if body is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=30) as response:
            text = response.read().decode()
            return json.loads(text) if text else None
    except urllib.error.HTTPError as error:
        detail = error.read().decode(errors="replace")
        raise SystemExit(f"{method} {url} failed: {error.code} {detail}") from error


def load_manifest(path: Path) -> list[dict[str, str]]:
    data = json.loads(path.read_text())
    labels = data.get("labels")
    if not isinstance(labels, list) or not labels:
        raise SystemExit(f"{path}: expected a non-empty 'labels' array")
    seen: set[str] = set()
    for entry in labels:
        name = entry.get("name")
        color = entry.get("color", "")
        description = entry.get("description", "")
        if not name:
            raise SystemExit(f"{path}: every label needs a name")
        if name in seen:
            raise SystemExit(f"{path}: duplicate label {name!r}")
        seen.add(name)
        if len(color) != 6 or any(character not in "0123456789abcdefABCDEF" for character in color):
            raise SystemExit(f"{path}: {name!r} needs a six-digit hex color, got {color!r}")
        if len(description) > 100:
            raise SystemExit(f"{path}: {name!r} description is {len(description)} chars; GitHub allows 100")
    return labels


def fetch_existing(repo: str, token: str) -> dict[str, dict[str, Any]]:
    """Existing labels, keyed by lowercased name.

    GitHub label names are case-insensitively unique: creating `area: cloud`
    when `Area: Cloud` exists is a 422, not a second label. Keying on the exact
    name would take the create path and fail the sync on the first such label,
    leaving every later label in the manifest unsynced. Lowercased keys find it
    instead, and the update path renames it to the manifest spelling.
    """
    existing: dict[str, dict[str, Any]] = {}
    page = 1
    while True:
        batch = request("GET", f"{API}/repos/{repo}/labels?per_page=100&page={page}", token)
        if not batch:
            break
        for label in batch:
            existing[str(label["name"]).lower()] = label
        if len(batch) < 100:
            break
        page += 1
    return existing


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, default=MANIFEST)
    parser.add_argument("--repo", default=os.environ.get("GH_REPO", "manaflow-ai/cmux"))
    parser.add_argument("--dry-run", action="store_true", help="validate and print the plan only")
    args = parser.parse_args(argv)

    labels = load_manifest(args.manifest)
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN") or ""
    if args.dry_run and not token:
        # Validation still works with no credentials, so a fork's CI can run it.
        print(f"{args.manifest}: {len(labels)} labels valid (no token, so no comparison)")
        return 0
    if not token:
        raise SystemExit("set GH_TOKEN or GITHUB_TOKEN to sync labels")

    existing = fetch_existing(args.repo, token)
    created = updated = unchanged = 0
    for entry in labels:
        name = str(entry["name"])
        color = str(entry["color"]).lower()
        description = str(entry.get("description", ""))
        current = existing.get(name.lower())
        if current is None:
            print(f"create  {name}")
            created += 1
            if not args.dry_run:
                request(
                    "POST",
                    f"{API}/repos/{args.repo}/labels",
                    token,
                    {"name": name, "color": color, "description": description},
                )
            continue
        drift = []
        if str(current.get("name", "")) != name:
            drift.append(f"name {current.get('name')} -> {name}")
        if str(current.get("color", "")).lower() != color:
            drift.append(f"color {current.get('color')} -> {color}")
        if str(current.get("description") or "") != description:
            drift.append("description")
        if not drift:
            unchanged += 1
            continue
        print(f"update  {name}  ({', '.join(drift)})")
        updated += 1
        if not args.dry_run:
            request(
                "PATCH",
                f"{API}/repos/{args.repo}/labels/{urllib.parse.quote(str(current['name']))}",
                token,
                {"new_name": name, "color": color, "description": description},
            )

    verb = "would be" if args.dry_run else "were"
    print(f"{created} created, {updated} updated, {unchanged} already matching ({verb} applied)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
