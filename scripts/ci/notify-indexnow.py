#!/usr/bin/env python3
"""Submit the deployed sitemap directly using IndexNow's public ownership key.

Read the existing web/app/lib/indexnow.ts configuration as JSON on stdin.
No CRON_SECRET or independently synchronized GitHub credential is involved.
"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone
import json
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
            entries.append((url, date))
    if not entries:
        return []
    # Match the web notifier's content-relative window, including delayed
    # deployments. Reading the public sitemap excludes unshipped main changes.
    earliest = max(date for _, date in entries) - timedelta(hours=lookback_hours)
    return list(dict.fromkeys(url for url, date in entries if date >= earliest))


def run(config: dict) -> dict:
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
    urls = select_urls(sitemap, lookback)
    if not urls:
        return {"submitted": 0, "status": 0}
    if len(urls) > 10_000:
        raise ValueError("IndexNow accepts at most 10,000 URLs per request")
    payload = {"host": "cmux.com", "key": key, "keyLocation": key_location, "urlList": urls}
    status, _ = request(endpoint, data=json.dumps(payload).encode("utf-8"))
    return {"submitted": len(urls), "status": status}


if __name__ == "__main__":
    try:
        print(json.dumps(run(json.load(sys.stdin))))
    except (ValueError, KeyError, OSError) as error:
        print(f"IndexNow notification failed: {error}", file=sys.stderr)
        sys.exit(1)
