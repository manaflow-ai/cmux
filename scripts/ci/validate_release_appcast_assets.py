#!/usr/bin/env python3
"""Validate that one appcast points at one complete GitHub release artifact."""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from dataclasses import dataclass


class ValidationError(ValueError):
    pass


@dataclass(frozen=True)
class Candidate:
    build: int
    display_version: str
    enclosure_url: str
    enclosure_name: str
    enclosure_length: int


@dataclass(frozen=True)
class PublishedRelease:
    build: int
    display_version: str


def _local_name(name: str) -> str:
    return name.rsplit("}", 1)[-1].rsplit(":", 1)[-1]


def _attribute(element: ET.Element, local_name: str) -> str | None:
    for name, value in element.attrib.items():
        if _local_name(name) == local_name:
            return value
    return None


def _child_text(element: ET.Element, local_name: str) -> str | None:
    for child in element:
        if _local_name(child.tag) == local_name and child.text:
            return child.text.strip()
    return None


def parse_candidate(data: bytes, *, tag: str) -> Candidate:
    try:
        root = ET.fromstring(data)
    except ET.ParseError as error:
        raise ValidationError(f"appcast is not valid XML: {error}") from error

    items = [element for element in root.iter() if _local_name(element.tag) == "item"]
    if len(items) != 1:
        raise ValidationError(f"appcast must contain exactly one full update item (found {len(items)})")

    enclosures = [
        element for element in items[0].iter() if _local_name(element.tag) == "enclosure"
    ]
    if len(enclosures) != 1:
        raise ValidationError(f"appcast item must contain exactly one enclosure (found {len(enclosures)})")

    enclosure = enclosures[0]
    build_text = _attribute(enclosure, "version") or _child_text(items[0], "version") or ""
    display_version = (
        _attribute(enclosure, "shortVersionString")
        or _child_text(items[0], "shortVersionString")
        or ""
    )
    url = enclosure.attrib.get("url", "")
    length_text = enclosure.attrib.get("length", "")
    signature = _attribute(enclosure, "edSignature") or ""

    if not build_text.isdigit() or int(build_text) <= 0:
        raise ValidationError(f"appcast enclosure has invalid Sparkle build '{build_text}'")
    if not display_version:
        raise ValidationError("appcast enclosure is missing sparkle:shortVersionString")
    if re.fullmatch(r"v\d+\.\d+\.\d+", tag) and display_version != tag.removeprefix("v"):
        raise ValidationError(
            f"appcast version {display_version} does not match stable release tag {tag}"
        )
    if not length_text.isdigit() or int(length_text) <= 0:
        raise ValidationError(f"appcast enclosure has invalid length '{length_text}'")
    if not signature:
        raise ValidationError("appcast enclosure is missing sparkle:edSignature")

    parsed = urllib.parse.urlsplit(url)
    decoded_path = urllib.parse.unquote(parsed.path)
    expected_prefix = f"/manaflow-ai/cmux/releases/download/{tag}/"
    if parsed.scheme != "https" or parsed.netloc != "github.com" or not decoded_path.startswith(expected_prefix):
        raise ValidationError(f"appcast enclosure does not target the {tag} GitHub release: {url}")
    enclosure_name = decoded_path.removeprefix(expected_prefix)
    if not enclosure_name or "/" in enclosure_name:
        raise ValidationError(f"appcast enclosure has an invalid release asset name: {url}")

    return Candidate(
        build=int(build_text),
        display_version=display_version,
        enclosure_url=url,
        enclosure_name=enclosure_name,
        enclosure_length=int(length_text),
    )


def validate_release_assets(
    candidate: Candidate,
    *,
    appcast_data: bytes,
    assets_document: dict[str, object],
    expected_enclosure: str | None,
) -> None:
    raw_assets = assets_document.get("assets")
    if not isinstance(raw_assets, list):
        raise ValidationError("GitHub release asset document has no assets list")

    assets: dict[str, dict[str, object]] = {}
    for raw_asset in raw_assets:
        if isinstance(raw_asset, dict) and isinstance(raw_asset.get("name"), str):
            assets[raw_asset["name"]] = raw_asset

    if "appcast.xml" not in assets:
        raise ValidationError("GitHub release is missing appcast.xml")
    if candidate.enclosure_name not in assets:
        raise ValidationError(
            f"GitHub release is missing appcast enclosure asset {candidate.enclosure_name}"
        )
    if expected_enclosure is not None and candidate.enclosure_name != expected_enclosure:
        raise ValidationError(
            f"appcast enclosure is {candidate.enclosure_name}, expected {expected_enclosure}"
        )

    asset_size = assets[candidate.enclosure_name].get("size")
    if not isinstance(asset_size, int) or asset_size <= 0:
        raise ValidationError(f"GitHub asset {candidate.enclosure_name} has invalid size {asset_size!r}")
    if asset_size != candidate.enclosure_length:
        raise ValidationError(
            f"appcast length {candidate.enclosure_length} does not match GitHub asset size {asset_size}"
        )

    appcast_asset = assets["appcast.xml"]
    appcast_size = appcast_asset.get("size")
    if appcast_size != len(appcast_data):
        raise ValidationError(
            f"local appcast size {len(appcast_data)} does not match GitHub asset size {appcast_size!r}"
        )
    digest = appcast_asset.get("digest")
    expected_digest = f"sha256:{hashlib.sha256(appcast_data).hexdigest()}"
    if digest != expected_digest:
        raise ValidationError(
            f"GitHub appcast digest {digest!r} does not match local appcast digest {expected_digest}"
        )


def validate_local_enclosure(
    candidate: Candidate, *, enclosure_file: pathlib.Path, expected_enclosure: str | None
) -> None:
    if expected_enclosure is not None and candidate.enclosure_name != expected_enclosure:
        raise ValidationError(
            f"appcast enclosure is {candidate.enclosure_name}, expected {expected_enclosure}"
        )
    if enclosure_file.name != candidate.enclosure_name:
        raise ValidationError(
            f"appcast enclosure is {candidate.enclosure_name}, local file is {enclosure_file.name}"
        )
    size = enclosure_file.stat().st_size
    if size != candidate.enclosure_length:
        raise ValidationError(
            f"appcast length {candidate.enclosure_length} does not match local artifact size {size}"
        )


def _cache_busted(url: str, token: str) -> str:
    parsed = urllib.parse.urlsplit(url)
    query = urllib.parse.parse_qsl(parsed.query, keep_blank_values=True)
    query.append(("cmux_verify", token))
    return urllib.parse.urlunsplit(
        (parsed.scheme, parsed.netloc, parsed.path, urllib.parse.urlencode(query), parsed.fragment)
    )


def parse_current_release(data: bytes) -> PublishedRelease:
    try:
        root = ET.fromstring(data)
    except ET.ParseError as error:
        raise ValidationError(f"current appcast is not valid XML: {error}") from error
    items = [element for element in root.iter() if _local_name(element.tag) == "item"]
    if len(items) != 1:
        raise ValidationError(f"current appcast must have one item (found {len(items)})")
    enclosures = [element for element in items[0].iter() if _local_name(element.tag) == "enclosure"]
    if len(enclosures) != 1:
        raise ValidationError(f"current appcast must have one enclosure (found {len(enclosures)})")
    build_text = _attribute(enclosures[0], "version") or _child_text(items[0], "version") or ""
    display_version = (
        _attribute(enclosures[0], "shortVersionString")
        or _child_text(items[0], "shortVersionString")
        or ""
    )
    if not build_text.isdigit() or int(build_text) <= 0:
        raise ValidationError(f"current appcast has invalid Sparkle build '{build_text}'")
    if not display_version:
        raise ValidationError("current appcast is missing sparkle:shortVersionString")
    return PublishedRelease(build=int(build_text), display_version=display_version)


def parse_current_build(data: bytes) -> int:
    return parse_current_release(data).build


def fetch_current_release(url: str, *, attempts: int, delay: float) -> PublishedRelease | None:
    for attempt in range(1, attempts + 1):
        request = urllib.request.Request(
            _cache_busted(url, f"current-{time.time_ns()}-{attempt}"),
            headers={"Cache-Control": "no-cache", "User-Agent": "cmux-release-validator"},
        )
        try:
            with urllib.request.urlopen(request, timeout=20) as response:
                return parse_current_release(response.read())
        except (OSError, urllib.error.URLError, ValidationError):
            if attempt < attempts:
                time.sleep(delay)
    return None


def validate_publication_order(
    candidate: Candidate,
    current_release: PublishedRelease | None,
    *,
    allow_missing_current_feed: bool,
) -> None:
    if current_release is None:
        if not allow_missing_current_feed:
            raise ValidationError(
                "current feed is missing or invalid; normal publication fails closed "
                "(use explicit appcast repair)"
            )
        return
    if candidate.build < current_release.build:
        raise ValidationError(
            f"candidate Sparkle build {candidate.build} would roll back current build "
            f"{current_release.build}"
        )
    if (
        candidate.build == current_release.build
        and candidate.display_version != current_release.display_version
    ):
        raise ValidationError(
            f"candidate {candidate.display_version} reuses Sparkle build {candidate.build} "
            f"from current release {current_release.display_version}"
        )


def verify_enclosure(candidate: Candidate, *, attempts: int, delay: float) -> None:
    last_error = "unknown error"
    for attempt in range(1, attempts + 1):
        request = urllib.request.Request(
            _cache_busted(candidate.enclosure_url, f"asset-{time.time_ns()}-{attempt}"),
            headers={"Cache-Control": "no-cache", "User-Agent": "cmux-release-validator"},
            method="HEAD",
        )
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                length_text = response.headers.get("Content-Length")
                if length_text is not None and int(length_text) != candidate.enclosure_length:
                    raise ValidationError(
                        f"public enclosure length {length_text} does not match appcast length "
                        f"{candidate.enclosure_length}"
                    )
                return
        except (OSError, ValueError, urllib.error.URLError, ValidationError) as error:
            last_error = str(error)
            if attempt < attempts:
                time.sleep(delay)
    raise ValidationError(f"public enclosure never became readable: {last_error}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--appcast", required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--assets-json")
    parser.add_argument("--enclosure-file")
    parser.add_argument("--expected-enclosure")
    parser.add_argument("--current-feed-url")
    parser.add_argument(
        "--allow-missing-current-feed",
        action="store_true",
        help="Allow an unreadable current feed only for an explicit repair operation",
    )
    parser.add_argument("--verify-enclosure", action="store_true")
    parser.add_argument("--attempts", type=int, default=10)
    parser.add_argument("--delay", type=float, default=2.0)
    args = parser.parse_args()

    try:
        appcast_data = pathlib.Path(args.appcast).read_bytes()
        candidate = parse_candidate(appcast_data, tag=args.tag)
        if not args.assets_json and not args.enclosure_file:
            raise ValidationError("provide --assets-json or --enclosure-file")
        if args.assets_json:
            assets_document = json.loads(pathlib.Path(args.assets_json).read_text(encoding="utf-8"))
            validate_release_assets(
                candidate,
                appcast_data=appcast_data,
                assets_document=assets_document,
                expected_enclosure=args.expected_enclosure,
            )
        if args.enclosure_file:
            validate_local_enclosure(
                candidate,
                enclosure_file=pathlib.Path(args.enclosure_file),
                expected_enclosure=args.expected_enclosure,
            )
        if args.current_feed_url:
            current_release = fetch_current_release(
                args.current_feed_url, attempts=args.attempts, delay=args.delay
            )
            validate_publication_order(
                candidate,
                current_release,
                allow_missing_current_feed=args.allow_missing_current_feed,
            )
            if current_release is None:
                print(
                    f"WARNING: current feed is missing or invalid; allowing explicit build {candidate.build} repair",
                    file=sys.stderr,
                )
        if args.verify_enclosure:
            verify_enclosure(candidate, attempts=args.attempts, delay=args.delay)
    except (OSError, json.JSONDecodeError, ValidationError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1

    print(
        f"PASS: {args.tag} appcast build {candidate.build} points to complete asset "
        f"{candidate.enclosure_name}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
