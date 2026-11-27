#!/usr/bin/env python3
"""Resolve shipped phone/Mac sources, not merely green compilation runs.

Publication jobs append a receipt with 'record'; CI reads a trusted registry with
'resolve'. N counts releases before source deduplication: repeated releases retain
their IDs but build the source only once. 'host' means a shipped Mac source paired
with the PR phone; 'dial' means a shipped phone source paired with the PR Mac.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

DEFAULT_REGISTRY = Path(__file__).with_name("mobile_pair_shipped_window.json")
SHA = re.compile(r"[0-9a-f]{40}")
EVIDENCE = {"ios": "testflight-processed", "mac": "nightly-feed-published"}


def timestamp(value):
    if not isinstance(value, str):
        raise ValueError("published_at must be an ISO 8601 timestamp")
    result = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if result.tzinfo is None:
        raise ValueError("published_at must include a timezone")
    return result.astimezone(timezone.utc)


def validate_entry(entry):
    if not isinstance(entry, dict) or entry.get("platform") not in EVIDENCE:
        raise ValueError("publication needs platform ios or mac")
    if not isinstance(entry.get("sha"), str) or not SHA.fullmatch(entry["sha"]):
        raise ValueError("publication needs a full source SHA")
    if not isinstance(entry.get("release_id"), str) or not entry["release_id"].strip():
        raise ValueError("publication needs a release ID")
    timestamp(entry.get("published_at"))
    proof = entry.get("evidence", {})
    if not isinstance(proof, dict) or proof.get("kind") != EVIDENCE[entry["platform"]]:
        raise ValueError("compilation/upload-only is not publication evidence")
    url = proof.get("url", "")
    if not isinstance(url, str) or not url.startswith("https://"):
        raise ValueError("publication evidence needs an HTTPS receipt URL")
    return entry


def validate_registry(registry):
    if not isinstance(registry, dict) or registry.get("schema_version") != 1:
        raise ValueError("unsupported shipped-window registry schema")
    releases = registry.get("releases")
    if not isinstance(releases, list):
        raise ValueError("registry needs a releases list")
    seen = set()
    for entry in releases:
        validate_entry(entry)
        key = (entry["platform"], entry["release_id"])
        if key in seen:
            raise ValueError("duplicate platform/release ID in registry")
        seen.add(key)
    return registry


def record(registry, entry):
    """Idempotent publication hook; an existing release can never change source."""
    validate_registry(registry)
    validate_entry(entry)
    key = (entry["platform"], entry["release_id"])
    for previous in registry["releases"]:
        if (previous["platform"], previous["release_id"]) == key:
            if previous["sha"] != entry["sha"]:
                raise ValueError("published release ID cannot change source SHA")
            return registry
    return {**registry, "releases": registry["releases"] + [entry]}


def resolve(registry, count=3):
    validate_registry(registry)
    if count < 1:
        raise ValueError("count must be positive")
    rows = []
    selected = []
    for platform, role in (("ios", "dial"), ("mac", "host")):
        releases = sorted(
            (r for r in registry["releases"] if r["platform"] == platform),
            key=lambda r: (timestamp(r["published_at"]), r["release_id"]),
            reverse=True,
        )[:count]
        if len(releases) != count:
            raise ValueError(f"{platform}: need {count} published releases, found {len(releases)}")
        selected.extend(releases)
        by_sha = {}
        for release in releases:
            row = by_sha.setdefault(release["sha"], {
                "role": role, "sha": release["sha"], "release_ids": [],
            })
            row["release_ids"].append(release["release_id"])
        rows.extend(by_sha.values())
    identity = {"count": count, "include": rows}
    fingerprint = hashlib.sha256(
        json.dumps(identity, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()
    return {"include": rows, "fingerprint": fingerprint, "releases": selected}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    for name in ("resolve", "record"):
        command = sub.add_parser(name)
        command.add_argument("--registry", type=Path, default=DEFAULT_REGISTRY)
        if name == "resolve":
            command.add_argument("--count", type=int, default=3)
            command.add_argument("--github-output", type=Path)
        else:
            command.add_argument("--receipt", type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        registry = json.loads(args.registry.read_text())
        if args.command == "record":
            result = record(registry, json.loads(args.receipt.read_text()))
            args.registry.write_text(json.dumps(result, indent=2) + "\n")
        else:
            result = resolve(registry, args.count)
            if args.github_output:
                with args.github_output.open("a") as output:
                    output.write("matrix=" + json.dumps({"include": result["include"]}, separators=(",", ":")) + "\n")
                    output.write("fingerprint=" + result["fingerprint"] + "\n")
        print(json.dumps(result, sort_keys=True))
    except (OSError, ValueError, TypeError) as error:
        parser.exit(1, f"shipped-window: {error}\n")


if __name__ == "__main__":
    main()
