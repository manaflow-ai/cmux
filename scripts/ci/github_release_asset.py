#!/usr/bin/env python3
"""The api.github.com URL of a github.com release download, read with a token: github_release_asset.py [--size] URL.

The NIGHTLY Macs get 403 from GitHub on anonymous requests, release downloads included
(https://github.com/OWNER/REPO/releases/download/TAG/NAME: the pinned gh, our Zig package mirror, the
previous DMG); authenticated ones succeed. github.com's download path ignores a token, so an authenticated
download goes through the API: GET /repos/OWNER/REPO/releases/assets/ID with Accept: application/octet-stream
(scripts/ci/github-release-download.sh). This prints that asset URL (with --size, the asset's size in bytes, what
a HEAD of the download would say), or exits 1 (no token, not a release
download, no such asset, an API error): the caller then downloads URL as before.

The token: GH_DOWNLOAD_TOKEN, else GH_TOKEN, else GITHUB_TOKEN. A release's asset names and URLs are read once
per job into RELEASE_ASSET_CACHE (default $RUNNER_TEMP/github-release-assets), so the 40 packages of a Zig
seed cost one or two API calls, not 40. Tests: tests/test_nightly_release_downloads.py.
"""
from __future__ import annotations

import json
import os
import re
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import deadline_http  # noqa: E402

DOWNLOAD = re.compile(r"^https://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/releases/download/([^/?#]+)/([^/?#]+)$")
SECONDS = 20


def token() -> str:
    for name in ("GH_DOWNLOAD_TOKEN", "GH_TOKEN", "GITHUB_TOKEN"):
        if os.environ.get(name):
            return os.environ[name]
    return ""


def api_base() -> str:
    return os.environ.get("GITHUB_API_URL", "https://api.github.com").rstrip("/")


def get_json(url: str, secret: str):
    req = urllib.request.Request(url, headers={"Accept": "application/vnd.github+json"})
    req.add_unredirected_header("Authorization", f"Bearer {secret}")
    status, body, _ = deadline_http.request(req, SECONDS, max_bytes=32 << 20)
    if status != 200:
        raise RuntimeError(f"{url}: HTTP {status}")
    return json.loads(body)


def release_assets(owner: str, repo: str, tag: str, secret: str) -> dict[str, dict]:
    base = f"{api_base()}/repos/{owner}/{repo}/releases"
    release = get_json(f"{base}/tags/{urllib.parse.quote(tag, safe='')}", secret)
    def entry(asset: dict) -> dict:
        return {"url": asset["url"], "size": asset.get("size")}

    assets = {a["name"]: entry(a) for a in release.get("assets") or []}
    # The release object lists only the first assets; page through the rest.
    page = 1
    while True:
        batch = get_json(f"{base}/{int(release['id'])}/assets?per_page=100&page={page}", secret)
        assets.update({a["name"]: entry(a) for a in batch})
        if len(batch) < 100:
            return assets
        page += 1


def cache_dir() -> Path:
    default = Path(os.environ.get("RUNNER_TEMP") or tempfile.gettempdir()) / "github-release-assets"
    return Path(os.environ.get("RELEASE_ASSET_CACHE") or default)


def resolve(url: str) -> dict | None:
    match = DOWNLOAD.match(url)
    secret = token()
    if not match or not secret:
        return None
    owner, repo, tag, name = match.groups()
    name = urllib.parse.unquote(name)
    folder = cache_dir()
    path = folder / f"{owner}--{repo}--{urllib.parse.quote(urllib.parse.unquote(tag), safe='')}.json"
    try:
        assets = json.loads(path.read_text())
    except (OSError, ValueError):
        assets = None
    if not isinstance(assets, dict) or name not in assets:
        assets = release_assets(owner, repo, urllib.parse.unquote(tag), secret)
        folder.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile("w", dir=folder, delete=False, suffix=".tmp") as out:
            json.dump(assets, out)
        os.replace(out.name, path)
    asset = assets.get(name)
    prefix = f"{api_base()}/repos/{owner}/{repo}/releases/assets/"
    ok = isinstance(asset, dict) and isinstance(asset.get("url"), str) and asset["url"].startswith(prefix)
    return asset if ok else None


def main(argv: list[str]) -> int:
    size = argv[1:2] == ["--size"]
    args = argv[2:] if size else argv[1:]
    if len(args) != 1:
        print("usage: github_release_asset.py [--size] URL", file=sys.stderr)
        return 2
    try:
        asset = resolve(args[0])
    except (OSError, ValueError, KeyError, TypeError, RuntimeError, urllib.error.URLError,
            deadline_http.RequestTimeout) as error:
        print(f"github_release_asset: {args[0]}: {error}", file=sys.stderr)
        return 1
    if not asset:
        return 1
    if size:
        if not isinstance(asset.get("size"), int):
            return 1
        print(asset["size"])
    else:
        print(asset["url"])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
