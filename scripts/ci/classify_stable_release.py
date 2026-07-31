#!/usr/bin/env python3
"""Classify whether a stable tag is the highest semantic version."""

import argparse
import json
import pathlib
import re


STABLE_TAG = re.compile(r"^v(\d+)\.(\d+)\.(\d+)$")


def parse_version(tag: str) -> tuple[int, int, int] | None:
    match = STABLE_TAG.fullmatch(tag)
    return tuple(map(int, match.groups())) if match else None


def classify(candidate: str, releases: list[dict[str, object]]) -> dict[str, str]:
    candidate_version = parse_version(candidate)
    if candidate_version is None:
        raise ValueError(f"candidate is not an exact stable tag: {candidate}")

    tags = {candidate: candidate_version}
    for release in releases:
        tag = release.get("tagName")
        if isinstance(tag, str) and (version := parse_version(tag)) is not None:
            tags[tag] = version

    latest_tag = max(tags, key=tags.__getitem__)
    is_latest = latest_tag == candidate
    return {
        "latest_tag": latest_tag,
        "is_latest": str(is_latest).lower(),
        "make_latest": str(is_latest).lower(),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--candidate", required=True)
    parser.add_argument("--releases-json", required=True)
    parser.add_argument("--github-output")
    args = parser.parse_args()

    releases = json.loads(pathlib.Path(args.releases_json).read_text(encoding="utf-8"))
    result = classify(args.candidate, releases)
    if args.github_output:
        with pathlib.Path(args.github_output).open("a", encoding="utf-8") as output:
            for key, value in result.items():
                output.write(f"{key}={value}\n")
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
