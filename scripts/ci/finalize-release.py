#!/usr/bin/env python3
"""Publish, verify or download a staged GitHub release by id, never by tag.

The tags endpoint 404s for drafts. A publish step that looks the release up by
tag therefore creates a second release and can publish it with 0 assets while
the real assets sit on the staged draft (v0.65.2). Callers pass the id that
publish-release-assets.py staged and reported.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import sys
import urllib.error
import urllib.request
from urllib.parse import quote
import os

_spec = importlib.util.spec_from_file_location(
    "publish_release_assets", Path(__file__).with_name("publish-release-assets.py"))
publisher = importlib.util.module_from_spec(_spec)
sys.modules[_spec.name] = publisher  # dataclasses resolve their module by name
_spec.loader.exec_module(publisher)
RequestError = publisher.RequestError


def release(client, release_id: int) -> dict:
    return client.request("GET", f"{client.api_url}/repos/{client.repo}/releases/{release_id}")


def refuse_other_releases(client, tag: str, release_id: int) -> None:
    others = sorted(int(entry["id"]) for entry in client.releases()
                    if entry.get("tag_name") == tag and int(entry["id"]) != release_id)
    if others:
        raise RuntimeError(
            f"Release {release_id} is staged for {tag}, but other releases exist for the same tag "
            f"(ids {', '.join(map(str, others))}). Delete the duplicates, then rerun.")


def check_assets(client, label: str, release_id: int, expected: list[str], exact_count: int | None) -> dict:
    assets = client.assets(release_id)
    missing = [name for name in expected if name not in assets]
    # A long-lived channel release can hold unrelated assets, so only an exact
    # count checks the whole release; otherwise check the expected names.
    checked = assets if exact_count is not None else {name: assets[name] for name in expected if name in assets}
    pending = sorted(name for name, asset in checked.items() if asset.get("state") != "uploaded")
    problems = []
    if missing:
        problems.append(f"missing {', '.join(missing)}")
    if pending:
        problems.append(f"not uploaded {', '.join(pending)}")
    if exact_count is not None and len(assets) != exact_count:
        problems.append(f"{len(assets)} assets, expected {exact_count}")
    if problems:
        raise RuntimeError(f"{label} release {release_id}: " + "; ".join(problems))
    return assets


def check_release(staged: dict, release_id: int, tag: str) -> None:
    if int(staged.get("id", 0)) != release_id or staged.get("tag_name") != tag:
        raise RuntimeError(f"Release {release_id} is not the release for tag {tag}")


def tag_release(client, tag: str) -> dict:
    url = f"{client.api_url}/repos/{client.repo}/releases/tags/{quote(tag, safe='')}"
    # The release is public by now. A 404 here can be read-after-write lag, so
    # retry it a bounded number of times before failing.
    for attempt in range(3):
        try:
            return client.request("GET", url)
        except RequestError as error:
            if error.status != 404 or attempt == 2:
                raise
            print(f"Tag {tag} does not resolve yet (attempt {attempt + 1}/3)", flush=True)
            publisher.backoff(attempt + 1)
    raise AssertionError("unreachable")


def patch(client, release_id: int, fields: dict) -> dict:
    return client.request("PATCH", f"{client.api_url}/repos/{client.repo}/releases/{release_id}",
                          body=json.dumps(fields).encode())


def publish(client, args) -> None:
    staged = release(client, args.release_id)
    check_release(staged, args.release_id, args.tag)
    refuse_other_releases(client, args.tag, args.release_id)
    check_assets(client, "Staged", args.release_id, args.expect_asset, args.expect_count)

    fields: dict = {}
    if args.name is not None:
        fields["name"] = args.name
    if args.target_commitish is not None:
        fields["target_commitish"] = args.target_commitish
    if args.body_file is not None:
        fields["body"] = args.body_file.read_text()
    elif args.generate_notes and staged.get("draft"):
        notes = client.request("POST", f"{client.api_url}/repos/{client.repo}/releases/generate-notes",
                               body=json.dumps({"tag_name": args.tag}).encode())
        fields["body"] = notes["body"]
    if args.prerelease is not None:
        fields["prerelease"] = args.prerelease == "true"
    # GitHub refuses make_latest on a prerelease or a draft, so settle the
    # prerelease flag and the metadata first, then publish.
    if fields:
        patch(client, args.release_id, fields)
    final: dict = {"draft": False}
    if args.make_latest is not None:
        final["make_latest"] = args.make_latest
    patch(client, args.release_id, final)
    print(f"Published release {args.release_id} for {args.tag}", flush=True)

    published = tag_release(client, args.tag)
    if int(published.get("id", 0)) != args.release_id or published.get("draft"):
        raise RuntimeError(
            f"Tag {args.tag} resolves to release {published.get('id')} (draft={published.get('draft')}), "
            f"not the published staged release {args.release_id}")
    if args.prerelease is not None and bool(published.get("prerelease")) != (args.prerelease == "true"):
        raise RuntimeError(f"Release {args.release_id} prerelease flag is {published.get('prerelease')}")
    assets = check_assets(client, "Published", args.release_id, args.expect_asset, args.expect_count)
    print(f"Verified {args.tag}: release {args.release_id} with {len(assets)} assets", flush=True)


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def open_asset(client, url: str):
    """GET an asset; follow GitHub's redirect without sending the token on."""
    request = urllib.request.Request(url, headers={
        "Authorization": f"Bearer {client.token}",
        "Accept": "application/octet-stream",
        "X-GitHub-Api-Version": "2022-11-28",
    })
    try:
        return urllib.request.build_opener(_NoRedirect).open(request, timeout=600)
    except urllib.error.HTTPError as error:
        location = error.headers.get("Location")
        if error.code not in (301, 302, 303, 307, 308) or not location or not location.startswith("https://"):
            raise
    return urllib.request.urlopen(urllib.request.Request(location), timeout=600)


def open_asset_with_fallback(client, url: str):
    """open_asset with the client's token; a refused App token is tried once more with the fallback."""
    for switched in (False, True):
        used = client.token
        try:
            return open_asset(client, url)
        except urllib.error.HTTPError as error:
            if not switched and client._fall_back(used, error.code, error):
                continue
            raise


def download(client, args) -> None:
    staged = release(client, args.release_id)
    check_release(staged, args.release_id, args.tag)
    refuse_other_releases(client, args.tag, args.release_id)
    assets = check_assets(client, "Staged", args.release_id, args.asset, None)
    args.dest.mkdir(parents=True, exist_ok=True)
    for name in args.asset:
        remote = assets[name]
        target = args.dest / name
        digest = hashlib.sha256()
        try:
            with open_asset_with_fallback(client, remote["url"]) as response, target.open("wb") as out:
                for chunk in iter(lambda: response.read(1024 * 1024), b""):
                    digest.update(chunk)
                    out.write(chunk)
        except (OSError, urllib.error.URLError) as error:
            raise RuntimeError(f"Could not download {name} from release {args.release_id}: {error}") from error
        if target.stat().st_size != remote.get("size"):
            raise RuntimeError(f"Downloaded {name} has the wrong size")
        if remote.get("digest") and remote["digest"] != "sha256:" + digest.hexdigest():
            raise RuntimeError(f"Downloaded {name} does not match its release digest")
        print(f"Downloaded {name} from release {args.release_id}", flush=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    for name in ("publish", "download"):
        command = sub.add_parser(name)
        command.add_argument("--repo", required=True)
        command.add_argument("--tag", required=True)
        command.add_argument("--release-id", type=int, required=True)
    pub = sub.choices["publish"]
    pub.add_argument("--expect-asset", action="append", default=[])
    pub.add_argument("--expect-count", type=int)
    pub.add_argument("--name")
    pub.add_argument("--target-commitish")
    pub.add_argument("--body-file", type=Path)
    pub.add_argument("--generate-notes", action="store_true")
    pub.add_argument("--prerelease", choices=("true", "false"))
    pub.add_argument("--make-latest", choices=("true", "false"))
    dl = sub.choices["download"]
    dl.add_argument("--asset", action="append", required=True)
    dl.add_argument("--dest", type=Path, required=True)
    args = parser.parse_args()
    if args.command == "publish" and not args.expect_asset and args.expect_count is None:
        parser.error("publish needs --expect-asset or --expect-count")
    # GH_APP_TOKEN first when the step passes one, GH_TOKEN as its fallback.
    client = publisher.client_from_env(args.repo)
    (publish if args.command == "publish" else download)(client, args)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (RuntimeError, ValueError, OSError, RequestError) as error:
        print(f"::error::Release finalization failed: {error}", file=sys.stderr)
        sys.exit(1)
