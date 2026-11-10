#!/usr/bin/env python3
"""Check the iOS App Store listing URLs before App Review sees them.

Reads every support, marketing and privacy URL in
ios/fastlane/metadata/<locale>/*_url.txt and ios/AppStoreReview/metadata/**/*.json
and fails when:

- a URL is not under https://cmux.com/;
- a support URL is the bare home page (App Review rejected https://cmux.com as
  a support URL), or redirects to it;
- a URL does not answer 200 after redirects (15 s timeout, two tries; a
  network error counts as a failure).

Exit 0 when every URL passes, 1 when any fails (each failure is printed), 2 on
a usage or read error.
"""

from __future__ import annotations

import argparse
import json
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Iterable


REPO_ROOT = Path(__file__).resolve().parents[2]
FASTLANE_METADATA = REPO_ROOT / "ios/fastlane/metadata"
REVIEW_METADATA = REPO_ROOT / "ios/AppStoreReview/metadata"

ALLOWED_HOST = "cmux.com"
FETCH_TIMEOUT_SECONDS = 15
FETCH_TRIES = 2
RETRY_DELAY_SECONDS = 2

# fastlane deliver file name -> kind
FASTLANE_URL_FILES = {
    "support_url.txt": "support",
    "marketing_url.txt": "marketing",
    "privacy_url.txt": "privacy",
}
# asc metadata JSON key -> kind
REVIEW_URL_KEYS = {
    "supportUrl": "support",
    "marketingUrl": "marketing",
    "privacyPolicyUrl": "privacy",
    "privacyChoicesUrl": "privacy",
}

# (url) -> (HTTP status after redirects, final URL)
Fetch = Callable[[str], "tuple[int, str]"]


@dataclass(frozen=True)
class ListingUrl:
    source: str  # repo-relative path, plus the JSON key for review metadata
    kind: str  # support | marketing | privacy
    url: str


def _rel(path: Path, root: Path) -> str:
    try:
        return str(path.relative_to(root))
    except ValueError:
        return str(path)


def collect_urls(
    fastlane_dir: Path = FASTLANE_METADATA,
    review_dir: Path = REVIEW_METADATA,
    root: Path = REPO_ROOT,
) -> tuple[list[ListingUrl], list[str]]:
    """Return every listing URL and the problems found while reading them."""
    urls: list[ListingUrl] = []
    problems: list[str] = []

    if fastlane_dir.is_dir():
        for locale_dir in sorted(p for p in fastlane_dir.iterdir() if p.is_dir()):
            if locale_dir.name in {"review_information", "default"}:
                continue
            has_support = False
            for name, kind in FASTLANE_URL_FILES.items():
                path = locale_dir / name
                if not path.is_file():
                    continue
                value = path.read_text(encoding="utf-8").strip()
                if not value:
                    continue
                has_support = has_support or kind == "support"
                urls.append(ListingUrl(_rel(path, root), kind, value))
            if not has_support:
                problems.append(
                    f"{_rel(locale_dir, root)}: no support_url.txt; App Store Connect requires a support URL"
                )

    if review_dir.is_dir():
        for path in sorted(review_dir.rglob("*.json")):
            try:
                body = json.loads(path.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError) as exc:
                problems.append(f"{_rel(path, root)}: unreadable JSON: {exc}")
                continue
            if not isinstance(body, dict):
                continue
            for key, kind in REVIEW_URL_KEYS.items():
                value = body.get(key)
                if isinstance(value, str) and value.strip():
                    urls.append(ListingUrl(f"{_rel(path, root)} {key}", kind, value.strip()))

    return urls, problems


def is_home_page(url: str) -> bool:
    parts = urllib.parse.urlsplit(url)
    return (
        parts.scheme == "https"
        and (parts.hostname or "").lower() == ALLOWED_HOST
        and parts.path in {"", "/"}
        and not parts.query
        and not parts.fragment
    )


def static_problems(item: ListingUrl) -> list[str]:
    parts = urllib.parse.urlsplit(item.url)
    problems = []
    if (
        parts.scheme != "https"
        or (parts.hostname or "").lower() != ALLOWED_HOST
        or parts.port is not None
        or parts.username is not None
    ):
        problems.append(f"{item.source}: {item.url} is not under https://{ALLOWED_HOST}/")
    elif item.kind == "support" and is_home_page(item.url):
        problems.append(
            f"{item.source}: support URL {item.url} is the home page; "
            f"App Review rejects it, use https://{ALLOWED_HOST}/support"
        )
    return problems


def live_fetch(url: str) -> tuple[int, str]:
    """GET url, following redirects; return (final status, final URL)."""
    request = urllib.request.Request(
        url,
        headers={"User-Agent": "cmux-app-store-url-check/1.0", "Accept": "text/html,*/*"},
        method="GET",
    )
    try:
        with urllib.request.urlopen(request, timeout=FETCH_TIMEOUT_SECONDS) as response:
            response.read(1024)
            return response.status, response.geturl()
    except urllib.error.HTTPError as exc:
        return exc.code, exc.geturl() or url


def fetch_problem(
    item: ListingUrl,
    fetch: Fetch,
    tries: int = FETCH_TRIES,
    sleep: Callable[[float], None] = time.sleep,
) -> str | None:
    last = ""
    for attempt in range(tries):
        if attempt:
            sleep(RETRY_DELAY_SECONDS)
        try:
            status, final_url = fetch(item.url)
        except Exception as exc:  # network errors, TLS, timeouts all fail the URL
            last = f"{type(exc).__name__}: {exc}"
            continue
        if status != 200:
            last = f"HTTP {status}"
            continue
        if item.kind == "support" and is_home_page(final_url):
            return (
                f"{item.source}: support URL {item.url} redirects to the home page "
                f"{final_url}; App Review rejects it"
            )
        if urllib.parse.urlsplit(final_url).hostname != ALLOWED_HOST:
            return f"{item.source}: {item.url} redirects off {ALLOWED_HOST} to {final_url}"
        return None
    return f"{item.source}: {item.url} did not answer 200 after {tries} tries ({last})"


def check(
    urls: Iterable[ListingUrl],
    fetch: Fetch | None,
    sleep: Callable[[float], None] = time.sleep,
) -> list[str]:
    problems: list[str] = []
    to_fetch: dict[str, list[ListingUrl]] = {}
    for item in urls:
        found = static_problems(item)
        problems.extend(found)
        if not found:
            to_fetch.setdefault(item.url, []).append(item)
    if fetch is None:
        return problems
    for url, items in to_fetch.items():
        # Fetch each distinct URL once; a support use of it is the strictest.
        strictest = next((i for i in items if i.kind == "support"), items[0])
        problem = fetch_problem(strictest, fetch, sleep=sleep)
        if problem:
            others = len(items) - 1
            problems.append(problem + (f" (and {others} more file(s) with this URL)" if others else ""))
    return problems


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--no-fetch", action="store_true", help="skip the live 200 check")
    parser.add_argument("--fastlane-dir", type=Path, default=FASTLANE_METADATA)
    parser.add_argument("--review-dir", type=Path, default=REVIEW_METADATA)
    args = parser.parse_args(argv)

    urls, problems = collect_urls(args.fastlane_dir, args.review_dir)
    if not urls:
        print("error: found no App Store listing URLs to check", file=sys.stderr)
        return 2
    problems += check(urls, None if args.no_fetch else live_fetch)
    distinct = len({u.url for u in urls})
    if problems:
        for problem in problems:
            print(f"error: {problem}", file=sys.stderr)
        print(f"{len(problems)} App Store URL problem(s) in {len(urls)} listing URLs", file=sys.stderr)
        return 1
    fetched = "not fetched" if args.no_fetch else "each answered 200"
    print(f"ok: {len(urls)} App Store listing URLs ({distinct} distinct, {fetched})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
