#!/usr/bin/env python3
"""Every page of a GitHub list endpoint, one `gh api` call per page.

The agent hosts' gh-quota shim refuses `gh api --paginate`: one invocation makes
any number of requests, so it cannot be charged before it runs. gh-merge-green
read a pull request's files, check runs and statuses that way, so on every host
with the shim those reads were refused: some fell back to GraphQL, and the
cmux-next paths and Vercel gates refused the merge outright. This pages them
with main_fix_evidence's reader, which asks for each page in its own call.

usage: gh_pages.py ROUTE           the pages, as one JSON array (what --paginate --slurp printed)
       gh_pages.py ROUTE FIELD     each item's FIELD, one per line, items without it skipped
                                   (what --paginate -q '.[].FIELD // empty' printed)

Exits 1, printing nothing, when a page cannot be read or the list runs past
main_fix_evidence.MAX_PAGES: the caller's fallback or refusal takes over.
"""
from __future__ import annotations

import importlib.util
import json
import sys
from pathlib import Path

_spec = importlib.util.spec_from_file_location("main_fix_evidence", Path(__file__).with_name("main_fix_evidence.py"))
_evidence = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_evidence)


def main(argv: list[str]) -> int:
    if len(argv) not in (1, 2):
        print(__doc__.split("\n\n")[2], file=sys.stderr)
        return 2
    try:
        pages = _evidence.GitHub().json(argv[0], paginate=True)
    except (_evidence.Refused, ValueError) as error:
        print(f"gh_pages: {error}", file=sys.stderr)
        return 1
    if len(argv) == 1:
        print(json.dumps(pages))
        return 0
    lines = []
    for page in pages:
        if not isinstance(page, list):
            print(f"gh_pages: {argv[0]} is not a list of items, so it has no {argv[1]} per item", file=sys.stderr)
            return 1
        lines.extend(str(item[argv[1]]) for item in page
                     if isinstance(item, dict) and item.get(argv[1]) is not None)
    if lines:
        print("\n".join(lines))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
