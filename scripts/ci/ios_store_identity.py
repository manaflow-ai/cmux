#!/usr/bin/env python3
"""Check that a built cmux-next-ios App Store app ships as plain "cmux".

usage: ios_store_identity.py <CmuxMobileApp.app>

Run it on the AppStore build the App Review gate makes (ios-review-gate.yml,
artifact review-gate-path-appstore-<device>) or any exported IPA's Payload/*.app.

The public App Store app must never say NEXT where a customer can see it: the
home screen name, the names of its extensions, and the permission prompts, in
every language the app carries. This reads the built app (Info.plist of the
app and of each PlugIns/*.appex, and every *.lproj/InfoPlist.strings) and
fails when a name is not "cmux" or any of those texts says NEXT or cmux-next.
It prints one line per checked value and a last summary line.
"""

from __future__ import annotations

import plistlib
import re
import sys
from pathlib import Path

NAME_KEYS = ("CFBundleDisplayName", "CFBundleName", "CFBundleSpokenName")
# "NEXT" as a word in capitals, or the product's internal name in any case.
# "Next" (a button) is fine.
NEXT_WORD = re.compile(r"\bNEXT\b")
INTERNAL_NAME = re.compile(r"cmux[ _-]?next", re.IGNORECASE)


def says_next(text: str) -> bool:
    return bool(NEXT_WORD.search(text) or INTERNAL_NAME.search(text))


def visible(info: dict) -> dict[str, str]:
    out = {}
    for key, value in info.items():
        if not isinstance(value, str):
            continue
        if key in NAME_KEYS or key.endswith("UsageDescription"):
            out[key] = value
    return out


def load(path: Path) -> dict:
    with path.open("rb") as f:
        return plistlib.load(f)


def check_bundle(bundle: Path, problems: list[str], lines: list[str], main: bool) -> None:
    info = load(bundle / "Info.plist")
    label = bundle.name
    display = info.get("CFBundleDisplayName")
    lines.append(f"{label}: CFBundleIdentifier={info.get('CFBundleIdentifier')} CFBundleDisplayName={display}")
    if main and display != "cmux":
        problems.append(f"{label}: CFBundleDisplayName is {display!r}, not 'cmux'")
    for key, value in visible(info).items():
        if says_next(value):
            problems.append(f"{label}: Info.plist {key} says NEXT: {value!r}")
    for strings in sorted(bundle.glob("*.lproj/InfoPlist.strings")):
        try:
            table = load(strings)
        except Exception as exc:  # a text .strings file would not parse as a plist
            problems.append(f"{label}: cannot read {strings.parent.name}/InfoPlist.strings: {exc}")
            continue
        for key, value in table.items():
            if not isinstance(value, str):
                continue
            if main and key == "CFBundleDisplayName" and value != "cmux":
                problems.append(f"{label}: {strings.parent.name} CFBundleDisplayName is {value!r}, not 'cmux'")
            if says_next(value):
                problems.append(f"{label}: {strings.parent.name} {key} says NEXT: {value!r}")
        lines.append(f"{label}: {strings.parent.name}/InfoPlist.strings checked ({len(table)} keys)")


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(__doc__.strip().splitlines()[2], file=sys.stderr)
        return 2
    app = Path(argv[1])
    if not (app / "Info.plist").is_file():
        print(f"error: {app} has no Info.plist", file=sys.stderr)
        return 2
    problems: list[str] = []
    lines: list[str] = []
    check_bundle(app, problems, lines, main=True)
    extensions = sorted((app / "PlugIns").glob("*.appex"))
    for appex in extensions:
        check_bundle(appex, problems, lines, main=False)
    for line in lines:
        print(line)
    for problem in problems:
        print(f"FAIL {problem}")
    if problems:
        print(f"store identity: FAIL ({len(problems)} problems)")
        return 1
    print(f"store identity: OK, shows as \"cmux\", no NEXT in the app or its {len(extensions)} extensions")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
