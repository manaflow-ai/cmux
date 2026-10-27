#!/usr/bin/env python3
"""Retired pull-request merge-tree publisher.

Creating a real branch at an untrusted pull-request merge commit turns that
commit's workflow files into a push event. The old publisher therefore let
pull-request code request OIDC tokens and enter the artifact-publication path.
Keep this executable refusal so stale callers fail closed and explain the
replacement architecture instead of silently recreating the unsafe ref.
"""

from __future__ import annotations

import sys


def main(argv: list[str]) -> int:
    if len(argv) != 3 or not argv[1].isdigit() or len(argv[2]) != 40:
        print("usage: publish_pr_merge_tree.py PR_NUMBER HEAD_SHA", file=sys.stderr)
        return 2
    print(
        "::error title=cmux-tui merge tree publisher disabled::"
        "refusing to turn an untrusted merge commit into a push event; "
        "build it without credentials and publish its artifact from trusted default-branch controls"
    )
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
