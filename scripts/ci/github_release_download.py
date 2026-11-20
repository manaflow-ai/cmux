"""Fetch a GitHub release download, through the release-assets API when the download itself fails.

2026-11-08: every GitHub release download answered 503 or 504 for hours while the API served the same files, so
every PR's fast gates went red fetching ast-grep (prepush-gate.py's ensure_tool) and every merge was held on an
unread FFI pin (base_red_excuse.py). The API serves the same bytes another way; each caller still judges what it
gets (a pinned sha256, a pinned SOURCE_SHA and checksum). A token (GH_TOKEN, else GITHUB_TOKEN) goes only to
api.github.com and never on to the asset's signed storage redirect.

Lives in scripts/ci because merge_hold runs base_red_excuse.py from `git archive ... scripts/ci` alone; the
pre-push hook's copy of prepush-gate.py loads the copy install-git-hooks.sh puts beside it.
"""
from __future__ import annotations

import json
import os
import re
import shutil
import sys
import urllib.error
import urllib.request
from pathlib import Path

# Loaded by path (base_red_excuse.py, and the pre-push gate from the hook folder, where install-git-hooks.sh and
# refresh_checks.py put deadline_http.py beside it), so its own folder may not be on sys.path.
sys.path.insert(0, str(Path(__file__).resolve().parent))
import deadline_http  # noqa: E402

# TIMEOUT stays the stall bound of each wait (urlopen's timeout before), and one fetch ends as a whole within
# FETCH_SECONDS. Nothing bounded the whole fetch before, and no caller has an overall budget; 15 minutes is far
# past any pinned lint tool or FFI pin file that is moving (tens of MB at most) and ends one that trickles.
FETCH_SECONDS = 15 * 60
GITHUB_RELEASE_DOWNLOAD = re.compile(r"https://github\.com/([^/]+)/([^/]+)/releases/download/([^/]+)/([^/]+)")


class NoAsset(LookupError):
    """The release exists but has no asset of that name: as unpublished as a 404."""


def fetch(url: str, out: Path, accept: str | None = None, timeout: float = 120) -> None:
    request = urllib.request.Request(url)
    if accept:
        request.add_header("Accept", accept)
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if token and url.startswith("https://api.github.com/"):
        # Unredirected: the asset's redirect goes to a signed storage URL, which must not get the token.
        request.add_unredirected_header("Authorization", f"Bearer {token}")
    with deadline_http.stream(request, FETCH_SECONDS, stall=timeout, raise_errors=True) as response, \
            open(out, "wb") as sink:
        shutil.copyfileobj(response, sink)


def download(url: str, out: Path, timeout: float = 120, log=lambda message: print(message, file=sys.stderr)) -> None:
    """The file at URL, into OUT. A GitHub release download that fails, other than with a 404 (GitHub's answer that
    it is not there), is fetched once more through the release-assets API. Raises the failure (an OSError: URLError
    and HTTPError are OSErrors) of the path that answered last, or NoAsset."""
    try:
        fetch(url, out, timeout=timeout)
        return
    except OSError as error:
        match = GITHUB_RELEASE_DOWNLOAD.fullmatch(url)
        if not match or (isinstance(error, urllib.error.HTTPError) and error.code == 404):
            raise
        log(f"{url} failed ({error}); fetching it through the release-assets API")
    owner, repo, tag, name = match.groups()
    listing = out.with_name(out.name + ".release.json")
    fetch(f"https://api.github.com/repos/{owner}/{repo}/releases/tags/{tag}", listing, "application/vnd.github+json",
          timeout)
    try:
        assets = json.loads(listing.read_text(encoding="utf-8")).get("assets") or []
    finally:
        listing.unlink(missing_ok=True)
    asset = next((a for a in assets if a.get("name") == name), None)
    if asset is None:
        raise NoAsset(f"release {owner}/{repo} {tag} has no asset {name}")
    fetch(asset["url"], out, "application/octet-stream", timeout)
