#!/usr/bin/env python3
"""Bound the ``pr-media`` branch without breaking live evidence.

The branch stores screenshots and GIFs used by pull-request comments. CI
media is grouped below ``<pr>/<sha8>/<tour>/`` while manually uploaded media
is kept directly below ``<pr>/``. Closed pull requests retain their media for
``RETAIN_DAYS``. Open pull requests retain the current head, media referenced
by the pull request, and the most recently uploaded revision groups.

The planner is deliberately fail-safe: an unknown pull request, incomplete
comment pagination, or unavailable history keeps the complete pull-request
root. Applying a plan rewrites the branch to one commit and uses a lease, so
an upload racing the rewrite wins and the next run retries.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import urllib.parse

BRANCH = "pr-media"
PRUNE_SUBJECT = "PR media, pruned"
RETAIN_DAYS = 30
RECENT_REVISIONS = 3
PR_FOLDER = re.compile(r"[1-9][0-9]{0,6}")
SHA8 = re.compile(r"[0-9a-f]{8}")
GRAPHQL_BATCH = 50
DETAILS_GRAPHQL_BATCH = 20
COMMENT_PAGE_SIZE = 100
RETENTION_INDEX = ".cmux-pr-media-retention.json"
KEEP_MARKER = re.compile(r"<!--\s*cmux:pr-media:keep(?:\s+([^>]*?))?\s*-->", re.IGNORECASE)
RAW_MEDIA_URL = re.compile(
    r"https?://(?:"
    r"raw\.githubusercontent\.com/(?P<raw_repo>[^/\s]+)/(?P<raw_name>[^/\s]+)/"
    r"(?:refs/heads/)?pr-media/|"
    r"github\.com/(?P<web_repo>[^/\s]+/[^/\s]+)/raw/(?:refs/heads/)?pr-media/"
    r")(?P<path>[^\s<>\"')]+)", re.IGNORECASE,
)


def git(*args: str, cwd: Path, input: str | None = None, env: dict[str, str] | None = None) -> str:
    command_env = {**os.environ, **env} if env else None
    return subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True,
                          text=True, input=input, env=command_env).stdout


def _graphql(repository: str, fields: str) -> dict:
    owner, name = repository.split("/", 1)
    query = f'query {{ repository(owner: "{owner}", name: "{name}") {{ {fields} }} }}'
    done = subprocess.run(["gh", "api", "graphql", "-f", f"query={query}"],
                          capture_output=True, text=True)
    try:
        payload = json.loads(done.stdout or "{}")
    except json.JSONDecodeError as error:
        raise RuntimeError(f"GraphQL returned invalid JSON: {done.stderr.strip()[:300]}") from error
    data = payload.get("data") or {}
    if not data and done.returncode != 0:
        raise RuntimeError(f"GraphQL failed: {done.stderr.strip()[:300]}")
    return data.get("repository") or {}


def pull_states(repository: str, numbers: list[int]) -> dict[int, dict]:
    """Return pull-request state and closure time through batched GraphQL."""
    found: dict[int, dict] = {}
    for start in range(0, len(numbers), GRAPHQL_BATCH):
        batch = numbers[start:start + GRAPHQL_BATCH]
        fields = " ".join(f"p{n}: pullRequest(number: {n}) {{ state closedAt }}" for n in batch)
        for key, value in _graphql(repository, fields).items():
            if isinstance(value, dict):
                found[int(key[1:])] = value
    return found


def pull_details(repository: str, numbers: list[int]) -> dict[int, dict]:
    """Read bounded state, head, body, and comment metadata for each PR."""
    found: dict[int, dict] = {}
    for start in range(0, len(numbers), DETAILS_GRAPHQL_BATCH):
        batch = numbers[start:start + DETAILS_GRAPHQL_BATCH]
        fields = " ".join(
            f"p{n}: pullRequest(number: {n}) {{ state closedAt headRefOid body "
            f"comments(first: {COMMENT_PAGE_SIZE}) {{ nodes {{ body }} pageInfo {{ hasNextPage }} }} }}"
            for n in batch
        )
        for key, value in _graphql(repository, fields).items():
            if not isinstance(value, dict):
                continue
            connection = value.get("comments")
            if not isinstance(connection, dict):
                value["commentsComplete"] = False
                value["commentBodies"] = []
            else:
                page = connection.get("pageInfo") or {}
                value["commentsComplete"] = page.get("hasNextPage") is False and \
                    isinstance(connection.get("nodes"), list)
                value["commentBodies"] = [
                    node.get("body") or "" for node in connection.get("nodes") or []
                    if isinstance(node, dict)
                ]
            found[int(key[1:])] = value
    return found


def plan(entries: list[str], states: dict[int, dict], now: dt.datetime,
         touched: frozenset[str] = frozenset(), retain_days: int = RETAIN_DAYS) -> tuple[list[str], list[str]]:
    """Legacy top-level plan used by callers and closed-PR tests."""
    keep, drop = [], []
    cutoff = now - dt.timedelta(days=retain_days)
    for entry in entries:
        if not PR_FOLDER.fullmatch(entry) or entry in touched:
            keep.append(entry)
            continue
        state = states.get(int(entry))
        closed = (state or {}).get("closedAt")
        if state and state.get("state") != "OPEN" and closed and \
                dt.datetime.fromisoformat(closed.replace("Z", "+00:00")) < cutoff:
            drop.append(entry)
        else:
            keep.append(entry)
    return keep, drop


def revision_group(path: str) -> str | None:
    parts = path.split("/")
    if len(parts) >= 3 and PR_FOLDER.fullmatch(parts[0]) and SHA8.fullmatch(parts[1]):
        return f"{parts[0]}/{parts[1]}"
    return None


def normalize_media_path(path: str) -> str:
    """Normalize a branch path from Markdown, including cache-busting suffixes."""
    path = urllib.parse.unquote(path).rstrip(".,;:")
    path = path.split("?", 1)[0].split("#", 1)[0]
    return path.lstrip("/")


def protected_media(repository: str, number: int, info: dict, available: set[str]) -> tuple[frozenset[str], bool]:
    """Return referenced paths and whether an explicit whole-root keep exists."""
    bodies = [info.get("body") or "", *(info.get("commentBodies") or [])]
    protected: set[str] = set()
    keep_root = False
    for body in bodies:
        for match in RAW_MEDIA_URL.finditer(body):
            raw_repo = match.group("raw_repo")
            web_repo = match.group("web_repo")
            if (raw_repo and f"{raw_repo}/{match.group('raw_name')}" != repository) or \
                    (web_repo and web_repo != repository):
                continue
            path = normalize_media_path(match.group("path"))
            if path in available:
                protected.add(path)
        for marker in KEEP_MARKER.finditer(body):
            value = normalize_media_path(marker.group(1) or "")
            if not value or value.casefold() in {"all", "root"}:
                keep_root = True
            elif value.startswith(f"{number}/") and value in available:
                protected.add(value)
    return frozenset(protected), keep_root


def plan_media(repository: str, entries: list[str], details: dict[int, dict], now: dt.datetime,
               recent_groups: dict[str, int] | None, retain_days: int = RETAIN_DAYS,
               recent_revisions: int = RECENT_REVISIONS) -> tuple[list[str], list[str]]:
    """Bound open-PR revision groups while retaining protected paths."""
    available = set(entries)
    roots: dict[str, list[str]] = {}
    for path in entries:
        roots.setdefault(path.split("/", 1)[0], []).append(path)
    cutoff = int((now - dt.timedelta(days=retain_days)).timestamp())
    referenced = set()
    for number, info in details.items():
        if info.get("state") == "OPEN" or not info.get("closedAt") or \
                dt.datetime.fromisoformat(info["closedAt"].replace("Z", "+00:00")).timestamp() >= cutoff:
            referenced.update(protected_media(repository, number, info, available)[0])
    keep: list[str] = []
    drop: list[str] = []
    for root, paths in roots.items():
        if not PR_FOLDER.fullmatch(root):
            keep.extend(paths)
            continue
        info = details.get(int(root))
        if not info or info.get("state") not in {"OPEN", "CLOSED", "MERGED"} or \
                not info.get("commentsComplete", False):
            keep.extend(paths)
            continue
        closed = info.get("closedAt")
        protected, keep_root = protected_media(repository, int(root), info, available)
        protected = protected | referenced
        if keep_root or recent_groups is None:
            keep.extend(paths)
            continue
        if info.get("state") != "OPEN":
            if not closed or dt.datetime.fromisoformat(closed.replace("Z", "+00:00")).timestamp() >= cutoff or \
                    recent_groups.get(root, 0) >= cutoff:
                keep.extend(paths)
            else:
                for path in paths:
                    (keep if path in protected else drop).append(path)
            continue
        groups: dict[str, list[str]] = {}
        flat: list[str] = []
        for path in paths:
            group = revision_group(path)
            if group:
                groups.setdefault(group, []).append(path)
            else:
                flat.append(path)
        selected: set[str] = set()
        selected.update(group for group in groups if any(path in protected for path in groups[group]))
        # Legacy squashes predate the timestamp index. Their unaged revision
        # groups remain protected until a new upload supplies reliable age.
        selected.update(group for group in groups if group not in recent_groups)
        head = info.get("headRefOid")
        if isinstance(head, str) and SHA8.fullmatch(head[:8]) and f"{root}/{head[:8]}" in groups:
            selected.add(f"{root}/{head[:8]}")
        candidates = [(timestamp, group) for group, timestamp in recent_groups.items()
                      if group in groups and group not in selected and timestamp >= cutoff]
        candidates.sort(reverse=True)
        selected.update(group for _timestamp, group in candidates[:max(0, recent_revisions)])
        # If no current head or referenced revision exists, retain the latest
        # available evidence even after its recent window has expired.
        if groups and not selected:
            selected.add(max(groups, key=lambda group: recent_groups.get(group, 0)))
        keep.extend(flat)
        for group, group_paths in groups.items():
            (keep if group in selected else drop).extend(group_paths)
    return keep, drop


def recent_revision_groups(checkout: Path, tip: str, now: dt.datetime,
                           retain_days: int = RETAIN_DAYS) -> dict[str, int] | None:
    """Read recent revision-group upload times; shallow history is unsafe."""
    if git("rev-parse", "--is-shallow-repository", cwd=checkout).strip() == "true":
        return None
    raw = git("log", "--invert-grep", f"--grep=^{PRUNE_SUBJECT}",
              "--name-only", "--format=__CMUX_COMMIT__%ct", "-z", tip, cwd=checkout)
    latest: dict[str, int] = {}
    try:
        saved = json.loads(git("show", f"{tip}:{RETENTION_INDEX}", cwd=checkout))
        if not isinstance(saved, dict) or any(not isinstance(k, str) or type(v) is not int for k, v in saved.items()):
            return None
        latest.update(saved)
    except subprocess.CalledProcessError:
        pass  # The first run predates the index; upload history is complete.
    except (ValueError, TypeError):
        return None
    timestamp: int | None = None
    for record in raw.split("\0"):
        record = record.strip("\n")
        if not record:
            continue
        if record.startswith("__CMUX_COMMIT__"):
            try:
                timestamp = int(record.removeprefix("__CMUX_COMMIT__"))
            except ValueError:
                timestamp = None
            continue
        if timestamp is not None:
            root = record.split("/", 1)[0]
            if PR_FOLDER.fullmatch(root):
                latest[root] = max(timestamp, latest.get(root, 0))
            group = revision_group(record)
            if group:
                latest[group] = max(timestamp, latest.get(group, 0))
    return latest


def write_tree(checkout: Path, records: list[str]) -> str:
    """Write a tree from existing ls-tree records without reading blobs."""
    with tempfile.NamedTemporaryFile(prefix="cmux-pr-media-index-", delete=False) as handle:
        index = Path(handle.name)
    index.unlink()
    env = {"GIT_INDEX_FILE": str(index)}
    try:
        git("read-tree", "--empty", cwd=checkout, env=env)
        git("update-index", "--add", "-z", "--index-info", cwd=checkout,
            input="\0".join(records) + "\0", env=env)
        return git("write-tree", cwd=checkout, env=env).strip()
    finally:
        index.unlink(missing_ok=True)


def prune(repository: str, checkout: Path, apply: bool, now: dt.datetime) -> int:
    refspec = f"+refs/heads/{BRANCH}:refs/remotes/origin/{BRANCH}"
    git("fetch", "--no-tags", "origin", refspec, cwd=checkout)
    if git("rev-parse", "--is-shallow-repository", cwd=checkout).strip() == "true":
        git("fetch", "--no-tags", "--unshallow", "origin", refspec, cwd=checkout)
    tip = git("rev-parse", f"refs/remotes/origin/{BRANCH}", cwd=checkout).strip()
    listing = [record for record in git("ls-tree", "-r", "-z", tip, cwd=checkout).split("\0") if record]
    entries = {record.split("\t", 1)[1]: record for record in listing if "\t" in record}
    numbers = sorted({int(path.split("/", 1)[0]) for path in entries
                      if PR_FOLDER.fullmatch(path.split("/", 1)[0])})
    details = pull_details(repository, numbers)
    recent = recent_revision_groups(checkout, tip, now)
    keep, drop = plan_media(repository, list(entries), details, now, recent)
    protected = sorted({path for number, info in details.items()
                        for path in protected_media(repository, number, info, set(entries))[0]})
    roots_dropped = sorted({path.split("/", 1)[0] for path in drop})
    print(f"{BRANCH} at {tip[:12]}: {len(entries)} files; keeping {len(keep)}, "
          f"dropping {len(drop)} ({len(roots_dropped)} roots): {' '.join(roots_dropped) or 'none'}",
          flush=True)
    print(f"Protected referenced/explicit paths ({len(protected)}): " +
          (" ".join(protected) or "none"), flush=True)
    commits = int(git("rev-list", "--count", tip, cwd=checkout).strip())
    if (not drop and commits <= 1) or not keep:
        return 0
    if not apply:
        print("Dry run; pass --apply to rewrite the branch.", flush=True)
        return 0
    records = [entries[path] for path in keep if path != RETENTION_INDEX]
    if recent is not None:
        kept_roots = {path.split("/", 1)[0] for path in keep}
        kept_groups = {revision_group(path) for path in keep}
        timestamps = {key: value for key, value in recent.items() if key in kept_roots or key in kept_groups}
        blob = git("hash-object", "-w", "--stdin", cwd=checkout, input=json.dumps(timestamps, sort_keys=True) + "\n").strip()
        records.append(f"100644 blob {blob}\t{RETENTION_INDEX}")
    else:
        records.extend(entries[path] for path in keep if path == RETENTION_INDEX)
    tree = write_tree(checkout, records)
    message = (f"{PRUNE_SUBJECT} {now:%Y-%m-%d}\n\nKept {len(keep)} files; dropped "
               f"{len(drop)} unreferenced media files from open/closed PR roots.\n")
    commit = git("commit-tree", tree, "-m", message, cwd=checkout).strip()
    try:
        git("push", f"--force-with-lease=refs/heads/{BRANCH}:{tip}", "origin",
            f"{commit}:refs/heads/{BRANCH}", cwd=checkout)
    except subprocess.CalledProcessError as error:
        if "stale info" in error.stderr:
            print("::notice::An upload landed on pr-media meanwhile; the next run prunes it.", flush=True)
            return 0
        print(error.stderr, file=sys.stderr, flush=True)
        raise
    print(f"{BRANCH} is now {commit[:12]}, one commit.", flush=True)
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--apply", action="store_true", help="rewrite and push the branch")
    parser.add_argument("--checkout", type=Path, default=Path.cwd())
    args = parser.parse_args(argv)
    return prune(os.environ["REPOSITORY"], args.checkout, args.apply, dt.datetime.now(dt.timezone.utc))


if __name__ == "__main__":
    sys.exit(main())
