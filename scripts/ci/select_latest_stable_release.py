#!/usr/bin/env python3
"""Select the highest unambiguous stable cmux release from tag names."""

import re
import sys


STABLE_TAG = re.compile(
    r"^v(?P<major>0|[1-9][0-9]*)\.(?P<minor>0|[1-9][0-9]*)\.(?P<patch>0|[1-9][0-9]*)"
    r"(?:\+(?P<build>[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$"
)


def select_latest(tags):
    versions = {}
    for raw_tag in tags:
        tag = raw_tag.strip()
        match = STABLE_TAG.fullmatch(tag)
        if not match:
            continue
        core = tuple(int(match.group(name)) for name in ("major", "minor", "patch"))
        versions.setdefault(core, []).append(tag)

    duplicates = {core: tags for core, tags in versions.items() if len(tags) > 1}
    if duplicates:
        details = "; ".join(
            f"{core}: {', '.join(tags)}" for core, tags in sorted(duplicates.items())
        )
        raise ValueError(f"duplicate stable SemVer precedence ({details})")

    if not versions:
        return ""
    return versions[max(versions)][0]


def main():
    try:
        latest = select_latest(sys.stdin)
    except ValueError as error:
        print(f"Refusing R2 stable upload: {error}", file=sys.stderr)
        return 1
    print(latest)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
