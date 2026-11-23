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
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
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


API = "https://api.github.com"
# A refused token: the App's budget or permission, or github.token's shared pool.
REFUSED = {401, 403, 429}
# GitHub's files listing stops at 3,000 entries (30 pages of 100); check() handles a short listing.
MAX_PAGES = 30


class ListingError(RuntimeError):
    pass


def github_message(error: urllib.error.HTTPError) -> str:
    try:
        raw = error.read().decode("utf-8", "replace")
    except Exception:  # noqa: BLE001 - a body that will not read leaves only the status
        raw = ""
    try:
        message = json.loads(raw).get("message")
    except (ValueError, AttributeError):
        message = None
    return str(message or raw.strip())[:300]


def _get(url: str, token: str):
    headers = {
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "cmux-classic-api-guard",
    }
    if token:
        headers["Authorization"] = f"Bearer {token}"
    with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=30) as response:
        return json.load(response)


class Reader:
    """GETs on `token` (the cmux-bot App's own budget when its mint worked); a refused one (401,
    403, 429) is asked once more on `fallback` (github.token), and a 401 keeps the fallback from
    then on. Run 44033322032 failed its first read, the files listing on github.token, with "API
    rate limit exceeded for installation" while the repository pool was spent."""

    def __init__(self, token: str, fallback: str = "") -> None:
        self.token = token or fallback
        self.fallback = fallback if fallback and fallback != self.token else ""

    def get(self, url: str):
        try:
            return _get(url, self.token)
        except urllib.error.HTTPError as error:
            if error.code not in REFUSED or not self.fallback:
                raise ListingError(f"GET {url} failed with HTTP {error.code}: {github_message(error)}") from error
            print(
                f"::notice::GET {url} refused on the read token (HTTP {error.code}: {github_message(error)}); "
                "asking again with the workflow token"
            )
            if error.code == 401:
                self.token, self.fallback = self.fallback, ""
                return self._get_or_fail(url, self.token)
        except urllib.error.URLError as error:
            raise ListingError(f"GET {url} failed: {error.reason}") from error
        return self._get_or_fail(url, self.fallback)

    @staticmethod
    def _get_or_fail(url: str, token: str):
        try:
            return _get(url, token)
        except urllib.error.HTTPError as error:
            raise ListingError(f"GET {url} failed with HTTP {error.code}: {github_message(error)}") from error
        except urllib.error.URLError as error:
            raise ListingError(f"GET {url} failed: {error.reason}") from error


def list_files(reader: Reader, repository: str, number: int) -> tuple[list[str], int]:
    """(changed paths, file records): a rename's old path also counts as changed, not as a record."""
    paths: list[str] = []
    records = 0
    for page in range(1, MAX_PAGES + 1):
        query = urllib.parse.urlencode({"per_page": 100, "page": page})
        batch = reader.get(f"{API}/repos/{repository}/pulls/{number}/files?{query}")
        if not isinstance(batch, list):
            raise ListingError(f"the files listing answered {str(batch)[:200]}")
        for item in batch:
            records += 1
            paths.append(item["filename"])
            if item.get("previous_filename"):
                paths.append(item["previous_filename"])
        if len(batch) < 100:
            break
    return paths, records


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--base", required=True, help="the pull request's base branch")
    parser.add_argument("--body-file", type=Path, required=True)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--paths-file", type=Path, help="changed paths, one per line")
    source.add_argument(
        "--pr", type=int,
        help="list the pull request's files here: GH_TOKEN first, GH_FALLBACK_TOKEN once on a refusal",
    )
    parser.add_argument("--repository", default=os.environ.get("GITHUB_REPOSITORY", ""))
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    parser.add_argument("--expected-files", type=int, default=None, help="the pull request's changed_files")
    parser.add_argument("--listed-records", type=int, default=None, help="file records the listing returned")
    args = parser.parse_args(argv)
    body = args.body_file.read_text() if args.body_file.exists() else ""
    listed_records = args.listed_records
    if args.pr is not None:
        if not args.repository:
            parser.error("--pr needs --repository or GITHUB_REPOSITORY")
        reader = Reader(os.environ.get("GH_TOKEN", ""), os.environ.get("GH_FALLBACK_TOKEN", ""))
        try:
            paths, listed_records = list_files(reader, args.repository, args.pr)
        except ListingError as error:
            print(f"::error::could not list the pull request's changed files: {error}")
            return 1
    else:
        paths = [line.strip() for line in args.paths_file.read_text().splitlines() if line.strip()]
    code, lines = check(load_config(args.config), args.base, body, paths, args.expected_files, listed_records)
    for line in lines:
        print(line)
    return code


if __name__ == "__main__":
    sys.exit(main())
