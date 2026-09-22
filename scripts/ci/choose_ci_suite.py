#!/usr/bin/env python3
"""Decide whether a CI run gets the full macOS suite or only compile admission.

The full suite (app-host shards, package tests, the lag build, the Release
build) is what proves a change. Compile admission is the cheap check that a
push still builds. With a merge queue the full suite runs on the commit that
will land, so running it on every push as well spends most Mac time on commits
that never merge.

The answer is "full" unless everything says otherwise: only a pull_request
event, under the compile-only policy, without the opt-in label, gets less.
"""

from __future__ import annotations

import argparse
import json
import sys
from collections.abc import Iterable
from pathlib import Path

COMPILE_ONLY_POLICY = "compile-only"
FULL_SUITE_LABEL = "full-ci"


def wants_full_suite(event_name: str, pull_request_policy: str, labels: Iterable[str] | None) -> bool:
    """`labels` is None when they could not be read, which keeps the full suite."""
    if event_name != "pull_request":
        return True
    if pull_request_policy.strip() != COMPILE_ONLY_POLICY:
        return True
    if labels is None:
        return True
    return FULL_SUITE_LABEL in {label.strip() for label in labels}


def labels_from_event(event_path: str | Path) -> list[str] | None:
    """Read the pull request labels captured in this workflow run's event payload."""
    try:
        with Path(event_path).open(encoding="utf-8") as handle:
            payload = json.load(handle)
    except (OSError, json.JSONDecodeError, TypeError):
        return None

    if not isinstance(payload, dict):
        return None
    pull_request = payload.get("pull_request")
    if not isinstance(pull_request, dict):
        return None
    raw_labels = pull_request.get("labels")
    if not isinstance(raw_labels, list):
        return None

    labels: list[str] = []
    for raw_label in raw_labels:
        if not isinstance(raw_label, dict):
            return None
        name = raw_label.get("name")
        if not isinstance(name, str):
            return None
        labels.append(name)
    return labels


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--event-name", required=True)
    parser.add_argument("--pull-request-policy", default="")
    label_source = parser.add_mutually_exclusive_group()
    label_source.add_argument(
        "--event-path",
        help="GitHub event JSON whose pull request labels are the immutable run snapshot",
    )
    label_source.add_argument("--labels-file", help="one label per line; omit when labels could not be read")
    parser.add_argument("--github-output")
    args = parser.parse_args(argv)

    labels = None
    if args.event_path:
        labels = labels_from_event(args.event_path)
    elif args.labels_file:
        with open(args.labels_file, encoding="utf-8") as handle:
            labels = handle.read().splitlines()

    full = wants_full_suite(args.event_name, args.pull_request_policy, labels)
    line = f"full_suite={'true' if full else 'false'}"
    print(line)
    if args.github_output:
        with open(args.github_output, "a", encoding="utf-8") as handle:
            handle.write(line + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
