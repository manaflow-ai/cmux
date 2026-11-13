#!/usr/bin/env python3
"""Prepare a commit's cmux-tui prefix from its published tree, with no build.

A cmux-tui artifacts run whose tree key another run owns builds nothing
(tree-owner-wait defers to that owner), and a run whose tree key is already
published skips its build. Neither used to write cmux-tui/<sha>/manifest.json,
so the commit answered 404: 14 of the 17 first-parent feat-cmux-next commits
from ed8510c8 to f8a39fdd had none (2026-11-13). This script prepares that
prefix from the bytes the tree's publishing commit already published: the
tree key covers every cmux-tui input, so those bytes are this commit's build.

It writes nothing unless every object it names answers 200 now: the tree's
completion.json and source.json, the publishing commit's manifest, and every
binary that manifest lists, each with the SHA-256 the manifest names. A
deferring run whose owner has not finished therefore writes no manifest that
points at missing objects; the owner re-runs it once the tree is published
(scripts/ci/cmux_tui_tree_handoff.py --published), and that attempt adopts.

The manifest is this commit's own: commit and sourceCommit are <sha>, and the
calling run attests it (installers verify the attestation against the commit
they expect, so only a run of <sha> can write it). adoptedFrom names the
publishing commit and tree key.

usage: adopt_cmux_tui_commit.py --sha SHA --tree-key KEY --out DIR
           --commit-time ISO --run-url URL [--source-repository URL]
exit 0: DIR holds manifest.json, source-manifest.json and every binary
exit 1: not published yet (a 404); DIR is left empty
exit 3: a read failure or bytes that do not match; DIR is left empty
"""
from __future__ import annotations

import argparse
import hashlib
import http.client
import json
import os
import re
import shutil
import sys
import tempfile
from datetime import datetime
from pathlib import Path
from typing import Callable
from urllib.error import URLError
from urllib.request import Request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import deadline_http  # noqa: E402

BASE = "https://files.cmux.com/cmux-tui"
HEX40 = re.compile(r"[0-9a-f]{40}")
HEX64 = re.compile(r"[0-9a-f]{64}")
BINARY_NAME = re.compile(r"cmux-tui-[A-Za-z0-9._-]+")
# A whole read, a 100 MB binary included (the publisher's took about a second each from a runner).
READ_SECONDS = 300

Fetch = Callable[[str], bytes]


class NotPublished(Exception):
    """An object the manifest needs answers 404: the tree is not published yet."""


class AdoptError(Exception):
    """A read failed, or published bytes do not match what names them."""


def fetch_url(url: str) -> bytes:
    # deadline_http sends a User-Agent of its own: files.cmux.com answers urllib's default with 403.
    try:
        status, body, _ = deadline_http.request(Request(url, headers={"Cache-Control": "no-cache"}), READ_SECONDS)
    except (URLError, http.client.HTTPException, OSError) as error:
        raise AdoptError(f"could not read {url}: {error}") from error
    if status == 404:
        raise NotPublished(f"{url} answers 404")
    if status != 200:
        raise AdoptError(f"could not read {url}: HTTP {status}")
    return body


def _json(url: str, fetch: Fetch) -> dict:
    try:
        value = json.loads(fetch(url))
    except json.JSONDecodeError as error:
        raise AdoptError(f"{url} is not JSON: {error}") from error
    if not isinstance(value, dict):
        raise AdoptError(f"{url} is not a JSON object")
    return value


def adopt(
    sha: str,
    tree_key: str,
    out: Path,
    *,
    commit_time: str,
    run_url: str,
    source_repository: str = "https://github.com/manaflow-ai/cmux",
    fetch: Fetch = fetch_url,
) -> dict:
    """Fill `out` with the commit prefix of `sha` and return its manifest.

    Raises NotPublished or AdoptError, and then `out` holds nothing new."""
    if not HEX40.fullmatch(sha) or not HEX40.fullmatch(tree_key):
        raise ValueError("sha and tree key must be 40 lowercase hex")
    tree = f"{BASE}/tree/{tree_key}"
    # completion.json is the tree's last object: the owner wrote every other one first.
    completion = _json(f"{tree}/completion.json", fetch)
    if completion.get("key") != tree_key:
        raise AdoptError(f"{tree}/completion.json names key {completion.get('key')!r}")
    source = _json(f"{tree}/source.json", fetch)
    publisher = source.get("commit")
    if source.get("key") != tree_key or not isinstance(publisher, str) or not HEX40.fullmatch(publisher):
        raise AdoptError(f"{tree}/source.json does not name key {tree_key} and a publishing commit")
    manifest_url = f"{BASE}/{publisher}/manifest.json"
    raw_manifest = fetch(manifest_url)
    try:
        published = json.loads(raw_manifest)
    except json.JSONDecodeError as error:
        raise AdoptError(f"{manifest_url} is not JSON: {error}") from error
    if not isinstance(published, dict) or published.get("commit") != publisher or published.get("sourceCommit") != publisher:
        raise AdoptError(f"{manifest_url} is not the manifest of {publisher}")
    binaries = published.get("binaries")
    if not isinstance(binaries, dict) or not binaries:
        raise AdoptError(f"{manifest_url} lists no binaries")
    for name, digest in binaries.items():
        if not BINARY_NAME.fullmatch(name) or not isinstance(digest, str) or not HEX64.fullmatch(digest):
            raise AdoptError(f"{manifest_url} has a malformed entry {name!r}")
    # The tree's own copies are the publisher's: a tree whose source.json names
    # other bytes than the publisher's manifest is not this commit's build.
    for name, digest in (source.get("binaries") or {}).items():
        if name in binaries and binaries[name] != digest:
            raise AdoptError(f"{tree}/source.json and {manifest_url} disagree on {name}")

    out.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=out.parent, prefix=f".{out.name}.") as staging_name:
        staging = Path(staging_name)
        for name, digest in sorted(binaries.items()):
            url = f"{BASE}/{publisher}/{name}"
            data = fetch(url)
            actual = hashlib.sha256(data).hexdigest()
            if actual != digest:
                raise AdoptError(f"{url} has SHA-256 {actual}, its manifest names {digest}")
            path = staging / name
            path.write_bytes(data)
            path.chmod(0o755)
        manifest = {
            "commit": sha,
            # As the publish job writes it: the commit time keeps a re-run's upload byte-identical.
            "builtAt": datetime.fromisoformat(commit_time).isoformat(),
            "sourceRepository": source_repository,
            "sourceCommit": sha,
            "attestationUrl": run_url,
            "releaseUrl": None,
            "license": published.get("license", "GPL-3.0-or-later"),
            "runtimeByBinary": published.get("runtimeByBinary", {}),
            "binaries": dict(sorted(binaries.items())),
            "adoptedFrom": {"commit": publisher, "treeKey": tree_key, "manifest": manifest_url},
        }
        (staging / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        # The publisher's manifest bytes, for the caller's attestation check of the source.
        (staging / "source-manifest.json").write_bytes(raw_manifest)
        for path in staging.iterdir():
            shutil.move(str(path), out / path.name)
    return manifest


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--sha", required=True)
    parser.add_argument("--tree-key", required=True)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--commit-time", required=True)
    parser.add_argument("--run-url", required=True)
    parser.add_argument("--source-repository", default="https://github.com/manaflow-ai/cmux")
    args = parser.parse_args(argv)
    try:
        manifest = adopt(args.sha, args.tree_key, args.out, commit_time=args.commit_time,
                         run_url=args.run_url, source_repository=args.source_repository)
    except NotPublished as error:
        print(f"tree {args.tree_key} is not published yet: {error}; nothing written")
        return 1
    except AdoptError as error:
        print(f"::error title=commit manifest not adopted::{error}; nothing written")
        return 3
    print(f"Prepared cmux-tui/{args.sha}/ from tree {args.tree_key} "
          f"(published by {manifest['adoptedFrom']['commit']}): {len(manifest['binaries'])} binaries")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
