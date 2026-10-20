#!/usr/bin/env python3
"""Answer whether a dispatched revision is already contained in main.

The manual E2E lane compiles a dispatcher-chosen revision, so its compilation
cache may only be seeded from code that main already carries. Requiring the
selected revision to equal the workflow SHA expressed that, but no dispatcher
ever satisfies it: they pass the exact revision under test, which is a branch
or pull-request head, so the cache never gained an entry.

Containment is the property that was actually wanted. `compare/main...<sha>`
reports `identical` when the revision is main's tip and `behind` when main has
moved past it; both mean main contains the revision. `ahead` and `diverged`
mean it carries commits main has not taken, which must not seed a shared cache.
"""
from __future__ import annotations

import json
import os
import re
import sys
import urllib.error
import urllib.request

API = "https://api.github.com"
CONTAINED = frozenset({"identical", "behind"})
SHA = re.compile(r"[0-9a-f]{40}")


def compare_status(repository, revision, token, opener=urllib.request.urlopen):
    request = urllib.request.Request(
        f"{API}/repos/{repository}/compare/main...{revision}",
        headers={
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token}",
            "X-GitHub-Api-Version": "2022-11-28",
        },
    )
    with opener(request, timeout=20) as response:
        return json.load(response).get("status")


def contained_in_main(repository, revision, token, compare=compare_status):
    """Return True only when main provably contains this exact revision."""
    if not repository or not token or not SHA.fullmatch(str(revision or "")):
        return False
    try:
        return compare(repository, revision, token) in CONTAINED
    except (urllib.error.URLError, OSError, ValueError, KeyError, TimeoutError):
        # An unreachable API is not evidence of containment; stay read-only.
        return False


def main() -> int:
    contained = contained_in_main(
        os.environ.get("GITHUB_REPOSITORY", ""),
        os.environ.get("TEST_REF", ""),
        os.environ.get("GITHUB_TOKEN", ""),
    )
    print("true" if contained else "false")
    return 0


if __name__ == "__main__":
    sys.exit(main())
