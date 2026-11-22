#!/usr/bin/env python3
"""Submit the deployed sitemap directly using IndexNow's public ownership key.

Read the existing web/app/lib/indexnow.ts configuration as JSON on stdin.
No CRON_SECRET or independently synchronized GitHub credential is involved.

The workflow runs on a schedule, so with --state PATH this keeps the
(url, lastmod) pairs it last submitted and submits only pairs not in that file.
A page is sent again only when its lastmod changes, not on every run.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timedelta, timezone
import json
from pathlib import Path
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

ORIGIN = "https://cmux.com"
NAMESPACE = "{http://www.sitemaps.org/schemas/sitemap/0.9}"


def request(url: str, *, data: bytes | None = None) -> tuple[int, bytes]:
    headers = {"Content-Type": "application/json; charset=utf-8"} if data else {}
    req = urllib.request.Request(url, data=data, headers=headers)
    for attempt in range(3):
        try:
            with urllib.request.urlopen(req, timeout=30) as response:
                return response.status, response.read()
        except urllib.error.HTTPError as error:
            if error.code not in (408, 429) and error.code < 500:
                raise
            if attempt == 2:
                raise
        except (urllib.error.URLError, TimeoutError, ConnectionError):
            if attempt == 2:
                raise
        time.sleep(2 ** attempt)
    raise AssertionError("unreachable")


def select_urls(xml: bytes, lookback_hours: int, now: datetime | None = None) -> list[str]:
    return list(dict.fromkeys(url for url, _ in select_entries(xml, lookback_hours, now)))


def select_entries(xml: bytes, lookback_hours: int, now: datetime | None = None) -> list[tuple[str, str]]:
    """The (url, lastmod) pairs in the lookback window, in sitemap order, deduplicated."""
    try:
        root = ET.fromstring(xml)
    except ET.ParseError as error:
        raise ValueError("Invalid deployed sitemap XML") from error
    if root.tag != NAMESPACE + "urlset":
        raise ValueError("Expected a deployed sitemap urlset")
    now = now or datetime.now(timezone.utc)
    entries = []
    for element in root.findall(NAMESPACE + "url"):
        url = element.findtext(NAMESPACE + "loc", "").strip()
        parsed = urllib.parse.urlsplit(url)
        if parsed.scheme != "https" or parsed.netloc != "cmux.com":
            raise ValueError(f"Sitemap URL does not belong to {ORIGIN}: {url}")
        modified = element.findtext(NAMESPACE + "lastmod", "").strip()
        try:
            date = datetime.fromisoformat(modified.replace("Z", "+00:00"))
        except ValueError:
            continue
        if date.tzinfo is None:
            date = date.replace(tzinfo=timezone.utc)
        if date <= now:
            entries.append((url, date, modified))
    if not entries:
        return []
    # Match the web notifier's content-relative window, including delayed
    # deployments. Reading the public sitemap excludes unshipped main changes.
    earliest = max(date for _, date, _ in entries) - timedelta(hours=lookback_hours)
    return list(dict.fromkeys((url, modified) for url, date, modified in entries if date >= earliest))


def submit_batches(config: dict, urls: list[str]) -> dict:
    endpoint = config["endpoint"]
    key = config["key"]
    key_location = f"{ORIGIN}/{key}.txt"
    batch_count = (len(urls) + 9_999) // 10_000
    submitted = 0
    statuses: list[int] = []
    for index in range(batch_count):
        batch = urls[index * 10_000 : (index + 1) * 10_000]
        payload = {"host": "cmux.com", "key": key, "keyLocation": key_location, "urlList": batch}
        try:
            status, _ = request(endpoint, data=json.dumps(payload).encode("utf-8"))
        except Exception as error:
            raise RuntimeError(
                f"IndexNow batch {index + 1}/{batch_count} failed after {submitted} URLs: {error}"
            ) from error
        submitted += len(batch)
        statuses.append(status)
    return {"submitted": submitted, "batches": batch_count, "status": statuses[-1] if statuses else 0}


def load_state(path: Path | None) -> set[tuple[str, str]]:
    if path is None or not path.exists():
        return set()
    try:
        pairs = json.loads(path.read_text())["submitted"]
        return {(str(url), str(modified)) for url, modified in pairs}
    except (ValueError, KeyError, TypeError) as error:
        # A damaged marker costs one resubmission of the window, never a failure.
        print(f"Ignoring unreadable IndexNow state {path}: {error}", file=sys.stderr)
        return set()


def save_state(path: Path, entries: list[tuple[str, str]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({"submitted": [list(entry) for entry in entries]}, indent=0) + "\n")


def run(config: dict, state_path: Path | None = None) -> dict:
    key = config["key"]
    if not isinstance(key, str) or not re.fullmatch(r"[a-zA-Z0-9-]{8,128}", key):
        raise ValueError("Invalid IndexNow public key")
    endpoint = config["endpoint"]
    if endpoint != "https://api.indexnow.org/indexnow":
        raise ValueError("Unexpected IndexNow endpoint")
    lookback = config["lookbackHours"]
    if not isinstance(lookback, int) or lookback <= 0:
        raise ValueError("lookbackHours must be a positive integer")
    key_location = f"{ORIGIN}/{key}.txt"
    _, deployed_key = request(key_location)
    if deployed_key.decode("utf-8").strip() != key:
        raise ValueError("Deployed IndexNow key does not match the configured public key")
    _, sitemap = request(f"{ORIGIN}/sitemap.xml")
    entries = select_entries(sitemap, lookback)
    already = load_state(state_path)
    urls = list(dict.fromkeys(url for url, modified in entries if (url, modified) not in already))
    result = submit_batches(config, urls) if urls else {"submitted": 0, "status": 0}
    # Written only after every batch succeeded, and only the current window, so
    # the marker stays as small as the window and a failed run retries next time.
    if state_path is not None and set(entries) != already:
        save_state(state_path, entries)
        result["stateChanged"] = True
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state", type=Path, help="JSON file of the (url, lastmod) pairs already submitted")
    args = parser.parse_args()
    try:
        print(json.dumps(run(json.load(sys.stdin), args.state)))
    except (ValueError, KeyError, OSError) as error:
        print(f"IndexNow notification failed: {error}", file=sys.stderr)
        sys.exit(1)
