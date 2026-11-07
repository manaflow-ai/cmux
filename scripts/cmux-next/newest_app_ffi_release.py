#!/usr/bin/env python3
"""The newest published app FFI release on the base: the one app-ffi-release.yml's re-pin pins.

    python3 scripts/cmux-next/newest_app_ffi_release.py [--tip REF] [--manifest PATH] [--remote NAME]

Prints `SOURCE_SHA CHECKSUM` for the newest commit on TIP (default HEAD) that is newer than the release
Packages/macOS/CmuxNext/Package.swift pins now and has a published cmux-app-ffi-<sha> release: its tag exists,
its SOURCE_SHA names that commit, and its SHA256SUMS carries the archive's checksum. Latest wins: a newer FFI
commit whose release is not published yet (its build was cancelled by a newer push, or is still running, so
SOURCE_SHA or SHA256SUMS is a 404) is skipped, never waited for. The base's FFI sources may be ahead of the
release it picks; merge_hold's classifier (scripts/ci/base_red_excuse.py) accepts such a pin once the app
compiles against it. When nothing newer is published it prints the current pin, so the re-pin is a no-op.

Reads tags with `git ls-remote` and release files anonymously from the release downloads: no API quota.
Exits 1 when a release file cannot be read for any reason but a 404, or when the manifest pins nothing.
"""
from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MANIFEST = ROOT / "Packages/macOS/CmuxNext/Package.swift"
ASSET = "CCmuxAppFFI.xcframework.zip"
TAG = re.compile(r"refs/tags/cmux-app-ffi-([0-9a-f]{40})$")
PIN = re.compile(r"releases/download/cmux-app-ffi-([0-9a-f]{40})/CCmuxAppFFI\.xcframework\.zip")
CHECKSUM = re.compile(r'name:\s*"CCmuxAppFFI".*?checksum:\s*"([0-9a-f]{64})"', re.S)
SUMS_LINE = re.compile(r"^([0-9a-f]{64})  " + re.escape(ASSET) + r"$", re.M)
TRIES = 40  # published releases looked at, newest first, before giving up on newer ones
FETCH_SECONDS = 60


class Unpublished(Exception):
    """A release file is a 404: the release is not (fully) published."""


def fetch(url: str) -> str:
    """URL's text. Unpublished on a 404; three tries on anything else, then the error."""
    for attempt in range(3):
        try:
            with urllib.request.urlopen(url, timeout=FETCH_SECONDS) as answer:  # noqa: S310 (release downloads)
                return answer.read(1 << 16).decode("utf-8")
        except urllib.error.HTTPError as error:
            if error.code == 404:
                raise Unpublished(url) from error
            if attempt == 2:
                raise
        except FileNotFoundError as error:  # a file:// download base (tests) has no such file
            raise Unpublished(url) from error
        except urllib.error.URLError as error:
            if isinstance(error.reason, FileNotFoundError):
                raise Unpublished(url) from error
            if attempt == 2:
                raise
        time.sleep(3 * (attempt + 1))
    raise AssertionError("unreachable")


def git(*args: str) -> str:
    return subprocess.run(["git", *args], check=True, capture_output=True, text=True).stdout


def published_tags(remote: str) -> set[str]:
    """The source shas of every cmux-app-ffi-<sha> tag on REMOTE (a release's tag; peeled entries skipped)."""
    out = git("ls-remote", "--tags", remote, "refs/tags/cmux-app-ffi-*")
    return {found[1] for line in out.splitlines() if (found := TAG.search(line.split("\t")[-1]))}


def newer_commits(tip: str, current: str) -> list[str]:
    """Commits on TIP not on CURRENT (the pinned source), newest first (topological: never an ancestor first)."""
    known = subprocess.run(["git", "cat-file", "-e", f"{current}^{{commit}}"], capture_output=True).returncode == 0
    if not known:
        print(f"note: the pinned source {current} is not in this checkout; reading all of {tip}", file=sys.stderr)
    return git("rev-list", "--topo-order", tip, *([f"^{current}"] if known else [])).split()


def release(base_url: str, sha: str) -> str:
    """The checksum of release cmux-app-ffi-SHA, read from its SOURCE_SHA and SHA256SUMS. Unpublished on a 404 or a
    release whose files do not name SHA and one archive checksum."""
    where = f"{base_url}/cmux-app-ffi-{sha}"
    sums = fetch(f"{where}/SHA256SUMS")
    source = fetch(f"{where}/SOURCE_SHA").strip()
    if source != sha:
        raise Unpublished(f"{where}/SOURCE_SHA names {source[:40]!r}, not {sha}")
    found = SUMS_LINE.findall(sums)
    if len(found) != 1:
        raise Unpublished(f"{where}/SHA256SUMS carries no one checksum for {ASSET}")
    return found[0]


def newest(tip: str, manifest: Path, remote: str, base_url: str, log=sys.stderr) -> tuple[str, str]:
    text = manifest.read_text(encoding="utf-8")
    pin, checksum = PIN.search(text), CHECKSUM.search(text)
    if not pin or not checksum:
        raise SystemExit(f"error: no cmux-app-ffi pin (url and checksum) in {manifest}")
    tags = published_tags(remote)
    tried = 0
    for sha in newer_commits(tip, pin[1]):
        if sha not in tags:
            continue
        try:
            found = release(base_url, sha)
        except Unpublished as why:
            print(f"skipped cmux-app-ffi-{sha}: not published ({why})", file=log)
            tried += 1
            if tried >= TRIES:
                break
            continue
        print(f"newest published app FFI release on {tip}: cmux-app-ffi-{sha}", file=log)
        return sha, found
    print(f"nothing newer than cmux-app-ffi-{pin[1]} is published", file=log)
    return pin[1], checksum[1]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--tip", default="HEAD")
    parser.add_argument("--manifest", type=Path, default=MANIFEST)
    parser.add_argument("--remote", default="origin")
    args = parser.parse_args(argv)
    repo = os.environ.get("GITHUB_REPOSITORY") or "manaflow-ai/cmux"
    base_url = os.environ.get("CMUX_APP_FFI_RELEASE_DOWNLOAD") or f"https://github.com/{repo}/releases/download"
    try:
        sha, checksum = newest(args.tip, args.manifest, args.remote, base_url)
    except (OSError, subprocess.CalledProcessError, urllib.error.URLError) as error:
        print(f"error: could not read the published app FFI releases: {error}", file=sys.stderr)
        return 1
    print(sha, checksum)
    return 0


if __name__ == "__main__":
    sys.exit(main())
