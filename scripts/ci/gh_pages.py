#!/usr/bin/env python3
"""Read a paginated GitHub list one bounded page per `gh api` call, never `gh api --paginate`.

`gh api --paginate` is one invocation that makes any number of requests. The gh quota wrapper on our
hosts can't charge it and refuses it, and a refused read left the merge gate unable to read freezes,
so every merge stopped (cmux#26647). This module asks for `per_page=100&page=N`, one call each, stops
at the first short page, and raises PageCapError past MAX_PAGES. A list cut short is an error, never
a complete answer.

    gh_pages.py ENDPOINT [--slurp] [--field NAME] [--max-pages N]

prints the items as one JSON array. --slurp prints the raw pages instead, in the shape a slurped
paginating call printed. --field NAME prints that field of each item, one per line, skipping empty ones.
It exits 2 when the list is past the cap and 1 when gh fails.
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from typing import Any, Callable

PER_PAGE = 100
# 30 pages of 100 is 3000 items: the most changed files GitHub's files API lists, and more check
# runs, jobs, comments or workflows than any list we read has.
MAX_PAGES = 30

Fetch = Callable[[str], Any]


class PageCapError(ValueError):
    """The list is longer than the page cap; what was read is not the whole list."""


def page_url(endpoint: str, page: int) -> str:
    """The endpoint with its own per_page/page dropped and ours added."""
    path, _, query = endpoint.partition("?")
    kept = [part for part in query.split("&") if part and not re.match(r"(per_page|page)=", part)]
    return f"{path}?{'&'.join([*kept, f'per_page={PER_PAGE}', f'page={page}'])}"


def page_items(page: Any) -> list:
    """A page's items: the page itself for a plain list, or the one list field of a wrapped
    response ({"total_count": N, "check_runs": [...]}, say)."""
    if isinstance(page, list):
        return page
    if isinstance(page, dict):
        lists = [value for value in page.values() if isinstance(value, list)]
        if len(lists) == 1:
            return lists[0]
    raise TypeError(f"a page of a GitHub list is neither a list nor an object with one list field: {str(page)[:200]}")


def pages(fetch: Fetch, endpoint: str, max_pages: int = MAX_PAGES) -> list:
    """Every raw page of the list, fetched one `fetch(url)` call each (fetch returns parsed JSON)."""
    out = []
    for number in range(1, max_pages + 1):
        page = fetch(page_url(endpoint, number))
        out.append(page)
        if len(page_items(page)) < PER_PAGE:
            return out
    raise PageCapError(f"{endpoint} has more than {max_pages} pages of {PER_PAGE}; "
                       "refusing to read a list cut short as complete")


def items(fetch: Fetch, endpoint: str, max_pages: int = MAX_PAGES) -> list:
    """Every item of the list, in order."""
    return [item for page in pages(fetch, endpoint, max_pages) for item in page_items(page)]


def gh_json(url: str) -> Any:
    """One `gh api` GET, parsed. Raises CalledProcessError when gh fails."""
    return json.loads(subprocess.run(["gh", "api", url], check=True, capture_output=True, text=True).stdout)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("endpoint")
    parser.add_argument("--slurp", action="store_true", help="print the raw pages, not the items")
    parser.add_argument("--field", help="print this field of each item, one per line")
    parser.add_argument("--max-pages", type=int, default=MAX_PAGES)
    args = parser.parse_args(argv)
    try:
        read = pages(gh_json, args.endpoint, args.max_pages)
    except PageCapError as error:
        print(f"gh_pages: {error}", file=sys.stderr)
        return 2
    except (subprocess.CalledProcessError, ValueError, TypeError) as error:
        print(f"gh_pages: {args.endpoint}: {getattr(error, 'stderr', '') or error}".strip(), file=sys.stderr)
        return 1
    if args.slurp:
        print(json.dumps(read))
    elif args.field:
        for item in (i for page in read for i in page_items(page)):
            value = item.get(args.field) if isinstance(item, dict) else None
            if value:
                print(value)
    else:
        print(json.dumps([i for page in read for i in page_items(page)]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
