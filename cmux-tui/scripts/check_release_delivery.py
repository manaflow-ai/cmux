#!/usr/bin/env python3
"""Check registry delivery independently of the TUI build/publisher dependency chain."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import sys
import urllib.error
import urllib.request


TAG_PREFIX = "refs/tags/cmux-tui-v"
PLATFORMS = (
    "macosx_11_0_arm64",
    "macosx_10_12_x86_64",
    "manylinux_2_17_aarch64.manylinux2014_aarch64",
    "manylinux_2_17_x86_64.manylinux2014_x86_64",
    "musllinux_1_2_aarch64",
    "musllinux_1_2_x86_64",
)


def version_tuple(value: str) -> tuple[int, ...]:
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", value):
        raise ValueError(f"expected stable X.Y.Z version, got {value!r}")
    return tuple(map(int, value.split(".")))


def newest_stable_tag(refs: list[dict]) -> dict:
    stable = [
        ref for ref in refs
        if re.fullmatch(re.escape(TAG_PREFIX) + r"[0-9]+\.[0-9]+\.[0-9]+", ref["ref"])
    ]
    if not stable:
        raise ValueError("no stable cmux-tui release tags found")
    return max(stable, key=lambda ref: version_tuple(ref["ref"][len(TAG_PREFIX):]))


def wheel_names(version: str) -> set[str]:
    return {f"cmux-{version}-py3-none-{platform}.whl" for platform in PLATFORMS}


def assess_delivery(
    version: str,
    tagged_at: dt.datetime,
    pypi: dict,
    npm: dict,
    now: dt.datetime,
    grace_seconds: int,
) -> dict:
    problems = []
    for name, published in (("PyPI", pypi["info"]["version"]), ("npm", npm["version"])):
        if version_tuple(published) < version_tuple(version):
            problems.append(f"{name} latest is {published}; expected at least {version}")
    available = {
        wheel["filename"] for wheel in pypi.get("releases", {}).get(version, [])
        if not wheel.get("yanked", False)
    }
    missing = wheel_names(version) - available
    if missing:
        problems.append("missing PyPI wheels: " + ", ".join(sorted(missing)))
    age = (now - tagged_at).total_seconds()
    status = "complete" if not problems else "pending" if age < grace_seconds else "failed"
    return {"version": version, "status": status, "problems": problems}


# A refused token: the App's budget or permission, or github.token's shared pool.
REFUSED = {401, 403, 429}


class FetchError(RuntimeError):
    pass


def github_message(error: urllib.error.HTTPError) -> str:
    try:
        raw = error.read().decode("utf-8", "replace")
    except Exception:  # noqa: BLE001 - a body that will not read leaves only the status
        raw = ""
    try:
        message = json.loads(raw).get("message")
    except (ValueError, AttributeError):
        message = None
    return str(message or raw.strip())[:300]


def _get(url: str, token: str):
    headers = {"User-Agent": "cmux-tui-release-delivery/1", "Accept": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    request = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def fetch_json(url: str, token: str = "", fallback_token: str = ""):
    """GET url as JSON. A refused token is tried once more as fallback_token (github.token); a
    failure names GitHub's own message ("API rate limit exceeded for installation", run 43989417033
    showed only "HTTP Error 403: Forbidden")."""
    try:
        return _get(url, token)
    except urllib.error.HTTPError as error:
        if error.code not in REFUSED or not fallback_token or fallback_token == token:
            raise FetchError(f"GET {url} failed with HTTP {error.code}: {github_message(error)}") from error
        print(
            f"GET {url} refused on the read token (HTTP {error.code}: {github_message(error)}); "
            "asking again with the workflow token",
            file=sys.stderr,
        )
    try:
        return _get(url, fallback_token)
    except urllib.error.HTTPError as error:
        raise FetchError(f"GET {url} failed with HTTP {error.code}: {github_message(error)}") from error


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--grace-seconds", type=int, default=7200)
    args = parser.parse_args()
    if args.grace_seconds < 0:
        parser.error("--grace-seconds must be nonnegative")
    repository = "manaflow-ai/cmux"
    api = f"https://api.github.com/repos/{repository}"
    token = os.environ.get("GH_TOKEN", "")
    fallback = os.environ.get("GH_FALLBACK_TOKEN", "")
    try:
        return check(api, repository, token, fallback, args.grace_seconds)
    except FetchError as error:
        print(f"check_release_delivery: {error}", file=sys.stderr)
        return 1


def check(api: str, repository: str, token: str, fallback: str, grace_seconds: int) -> int:
    refs = fetch_json(f"{api}/git/matching-refs/tags/cmux-tui-v", token, fallback)
    tag = newest_stable_tag(refs)
    version = tag["ref"][len(TAG_PREFIX):]
    obj = tag["object"]
    if obj["type"] == "tag":
        annotation = fetch_json(f"{api}/git/tags/{obj['sha']}", token, fallback)
        tagged_at = annotation["tagger"]["date"]
    else:
        commit = fetch_json(f"{api}/commits/{obj['sha']}", token, fallback)
        tagged_at = commit["commit"]["committer"]["date"]
    result = assess_delivery(
        version,
        dt.datetime.fromisoformat(tagged_at.replace("Z", "+00:00")),
        fetch_json("https://pypi.org/pypi/cmux/json"),
        fetch_json("https://registry.npmjs.org/cmux/latest"),
        dt.datetime.now(dt.timezone.utc),
        grace_seconds,
    )
    print(json.dumps(result, indent=2))
    if result["status"] == "complete":
        return 0
    print(
        "Inspect publisher failures or pending environment approvals at "
        f"https://github.com/{repository}/actions/workflows/tui-publish-pypi.yml and "
        f"https://github.com/{repository}/actions/workflows/tui-publish-npm.yml. "
        "A successful artifact build is not a delivered release."
    )
    return 1 if result["status"] == "failed" else 0


if __name__ == "__main__":
    raise SystemExit(main())
