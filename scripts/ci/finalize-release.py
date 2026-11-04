#!/usr/bin/env python3
"""Publish, verify or download a staged GitHub release by id, never by tag.

The tags endpoint 404s for drafts. A publish step that looks the release up by
tag therefore creates a second release and can publish it with 0 assets while
the real assets sit on the staged draft (v0.65.2). Callers pass the id that
publish-release-assets.py staged and reported.

`adopt` repairs a tag that is already in that state (v0.65.2, v0.65.2.2, both
tagged from a checkout whose release workflow still published by tag): it
deletes the published duplicate (empty, or holding copies of only some draft
assets; a duplicate holding every draft asset is refused), moves the tag onto
the staged draft and publishes the draft through `publish`.
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


def refuse_other_releases(client, tag: str, release_id: int, deleted: frozenset = frozenset()) -> None:
    # `deleted` holds releases adopt just removed: the list can still show them
    # for a moment, and failing then would leave the tag with no release.
    others = sorted(int(entry["id"]) for entry in client.releases()
                    if entry.get("tag_name") == tag and int(entry["id"]) not in {release_id, *deleted})
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


def publish(client, args, deleted: frozenset = frozenset()) -> None:
    staged = release(client, args.release_id)
    check_release(staged, args.release_id, args.tag)
    refuse_other_releases(client, args.tag, args.release_id, deleted)
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


def adopt(client, args) -> None:
    staged = release(client, args.release_id)
    # Once the publish-by-tag release claimed the tag, GitHub shows the staged
    # draft as untagged-<hash>; only its name still says which tag it is for.
    current = staged.get("tag_name") or ""
    owned = current == args.tag or (current.startswith("untagged-") and staged.get("name") == args.tag)
    if int(staged.get("id", 0)) != args.release_id or not staged.get("draft") or not owned:
        hint = ""
        if current == args.tag and not staged.get("draft"):
            # A failed check after the draft went public leaves nothing to adopt.
            hint = "; it is already published, so finish it with `publish`"
        raise RuntimeError(f"Release {args.release_id} is not a staged draft for tag {args.tag}{hint}")
    prerelease = staged.get("prerelease") if args.prerelease is None else args.prerelease == "true"
    if prerelease and args.make_latest == "true":
        raise RuntimeError("Cannot make a prerelease latest; use --prerelease false or --make-latest false")
    staged_assets = check_assets(client, "Staged", args.release_id, args.expect_asset, args.expect_count)
    others = [entry for entry in client.releases()
              if entry.get("tag_name") == args.tag and int(entry["id"]) != args.release_id]
    # Only a published release with nothing of its own is the publish-by-tag
    # duplicate: empty, or holding only byte-identical copies of draft assets
    # (a hand repair of the download links). A draft or a release with any
    # other asset may be someone's real release, so leave it.
    def copy_of_staged(asset: dict) -> bool:
        source = staged_assets.get(asset.get("name"))
        return bool(source and asset.get("digest") and asset.get("digest") == source.get("digest")
                    and asset.get("size") == source.get("size"))

    held = {int(entry["id"]): client.assets(int(entry["id"])) for entry in others}
    keep = sorted(int(entry["id"]) for entry in others
                  if entry.get("draft") or not all(map(copy_of_staged, held[int(entry["id"])].values())))
    if keep:
        raise RuntimeError(
            f"Refusing to adopt release {args.release_id}: releases {', '.join(map(str, keep))} for "
            f"{args.tag} are drafts or have assets that are not copies of the draft's. "
            f"Resolve them by hand.")
    # A release that already serves every draft asset needs no repair, and
    # deleting it would take working downloads offline; drop the draft instead.
    complete = sorted(release_id for release_id, assets in held.items() if set(staged_assets) <= set(assets))
    if complete:
        raise RuntimeError(
            f"Release {', '.join(map(str, complete))} for {args.tag} already holds every asset of draft "
            f"{args.release_id}; nothing to adopt. Delete the draft instead.")
    empty = sorted(held)
    # Without a notes flag the draft keeps the deleted release's notes. A body
    # file is read now, so a bad path fails before anything is deleted.
    carried = {}
    if args.body_file is not None:
        carried["body"] = args.body_file.read_text()
        args = argparse.Namespace(**{**vars(args), "body_file": None, "generate_notes": False})
    elif not args.generate_notes:
        bodies = [entry.get("body") for entry in sorted(others, key=lambda entry: int(entry["id"]))
                  if entry.get("body")]
        if bodies:
            carried["body"] = bodies[0]
    print(f"Adopting draft {args.release_id} for {args.tag}; replacing published duplicates: "
          f"{', '.join(map(str, empty)) or 'none'}"
          f"{'; carrying their notes' if carried else ''}", flush=True)
    if args.dry_run:
        return
    # Generate and persist notes before deleting even a partially served release.
    if args.generate_notes:
        notes = client.request("POST", f"{client.api_url}/repos/{client.repo}/releases/generate-notes",
                               body=json.dumps({"tag_name": args.tag}).encode())
        carried["body"] = notes["body"]
        args = argparse.Namespace(**{**vars(args), "generate_notes": False})
    # Notes go onto the draft before anything is deleted, so a failure cannot lose them.
    if carried:
        patch(client, args.release_id, carried)
    for release_id in empty:
        try:
            client.request("DELETE", f"{client.api_url}/repos/{client.repo}/releases/{release_id}")
        except RequestError as error:
            if error.status != 404:
                raise
        # A 404 can also mean the request was refused; confirm the release is gone
        # before publish stops counting it as a duplicate.
        try:
            release(client, release_id)
        except RequestError as error:
            if error.status != 404:
                raise
        else:
            raise RuntimeError(f"Release {release_id} for {args.tag} still exists after DELETE")
        print(f"Deleted duplicate release {release_id} for {args.tag}", flush=True)
    if current != args.tag:
        patch(client, args.release_id, {"tag_name": args.tag})
    publish(client, args, frozenset(empty))


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
    for name in ("publish", "download", "adopt"):
        command = sub.add_parser(name)
        command.add_argument("--repo", required=True)
        command.add_argument("--tag", required=True)
        command.add_argument("--release-id", type=int, required=True)
    for pub in (sub.choices["publish"], sub.choices["adopt"]):
        pub.add_argument("--expect-asset", action="append", default=[])
        pub.add_argument("--expect-count", type=int)
        pub.add_argument("--name")
        pub.add_argument("--target-commitish")
        pub.add_argument("--body-file", type=Path)
        pub.add_argument("--generate-notes", action="store_true")
        pub.add_argument("--prerelease", choices=("true", "false"))
        pub.add_argument("--make-latest", choices=("true", "false"))
    sub.choices["adopt"].add_argument("--dry-run", action="store_true")
    dl = sub.choices["download"]
    dl.add_argument("--asset", action="append", required=True)
    dl.add_argument("--dest", type=Path, required=True)
    args = parser.parse_args()
    if args.command in ("publish", "adopt") and not args.expect_asset and args.expect_count is None:
        parser.error(f"{args.command} needs --expect-asset or --expect-count")
    # Publishing without make_latest lets GitHub make the release latest, so a
    # repair of an older tag would move releases/latest back onto it.
    if args.command == "adopt" and args.make_latest is None:
        parser.error("adopt needs --make-latest true or false")
    # GH_APP_TOKEN first when the step passes one, GH_TOKEN as its fallback.
    client = publisher.client_from_env(args.repo)
    {"publish": publish, "download": download, "adopt": adopt}[args.command](client, args)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (RuntimeError, ValueError, OSError, RequestError) as error:
        print(f"::error::Release finalization failed: {error}", file=sys.stderr)
        sys.exit(1)
