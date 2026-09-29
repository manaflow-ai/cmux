#!/usr/bin/env python3
"""Keep Sparkle from offering a build to a macOS it cannot run on.

cmux-next requires macOS 26 while the legacy app ran on macOS 14. Sparkle
filters appcast items by `sparkle:minimumSystemVersion`, which
generate_appcast copies from the bundle's `LSMinimumSystemVersion`. If either
link is missing, macOS 14/15 users would download an update that cannot
launch. This tool makes both links explicit and fail closed:

  floor <app>
      Print the bundle's LSMinimumSystemVersion. Fails when it is missing or
      lower than the deployment target (`minos`) of the main executable.

  enforce <appcast> --archive <dmg-name> --minimum <version>
      The item(s) whose enclosure is <dmg-name> must carry
      `<sparkle:minimumSystemVersion>` equal to <version>. A missing element
      is inserted; a different value is an error.

  append-legacy <appcast> --item-file <xml> --floor <version>
      Append a pinned legacy `<item>` (minimumSystemVersion below <floor>)
      so macOS versions under the floor are offered that build instead of
      nothing. Skipped when an item with the same sparkle:version exists.

The EdDSA signatures cover the archives, not the feed XML, so editing the
feed does not invalidate them (the release scripts already rewrite it).
"""

from __future__ import annotations

import argparse
import plistlib
import re
import subprocess
import sys
import urllib.parse
from pathlib import Path

ITEM_RE = re.compile(r"<item>.*?</item>", re.S)
MIN_RE = re.compile(r"<sparkle:minimumSystemVersion>\s*([^<]*?)\s*</sparkle:minimumSystemVersion>")
VERSION_RE = re.compile(r"<sparkle:version>\s*([^<]*?)\s*</sparkle:version>")
DELTAS_RE = re.compile(r"<sparkle:deltas>.*?</sparkle:deltas>", re.S)


class FloorError(Exception):
    pass


def parse_version(text: str) -> tuple[int, int, int]:
    parts = text.strip().split(".")
    if not 1 <= len(parts) <= 3 or not all(p.isdigit() for p in parts):
        raise FloorError(f"not a macOS version: {text!r}")
    numbers = [int(p) for p in parts] + [0] * (3 - len(parts))
    return numbers[0], numbers[1], numbers[2]


def executable_minos(executable: Path) -> list[str]:
    """Deployment targets of every slice (LC_BUILD_VERSION minos)."""
    output = subprocess.run(["otool", "-l", str(executable)], check=True, capture_output=True, text=True).stdout
    found: list[str] = []
    in_build_version = False
    for line in output.splitlines():
        stripped = line.strip()
        if stripped.startswith("cmd "):
            in_build_version = stripped == "cmd LC_BUILD_VERSION"
        elif in_build_version and stripped.startswith("minos "):
            found.append(stripped.split()[1])
            in_build_version = False
    return found


def floor(app: Path, minos_reader=executable_minos) -> str:
    info_path = app / "Contents" / "Info.plist"
    with info_path.open("rb") as handle:
        info = plistlib.load(handle)
    declared = info.get("LSMinimumSystemVersion")
    if not isinstance(declared, str) or not declared.strip():
        raise FloorError(f"{info_path} has no LSMinimumSystemVersion; Sparkle would offer this build to every macOS")
    declared = declared.strip()
    executable_name = info.get("CFBundleExecutable")
    if executable_name:
        executable = app / "Contents" / "MacOS" / executable_name
        if executable.exists():
            for minos in minos_reader(executable):
                if parse_version(declared) < parse_version(minos):
                    raise FloorError(
                        f"LSMinimumSystemVersion {declared} is below the executable's deployment target {minos}; "
                        "older macOS would be offered a build that cannot launch"
                    )
    parse_version(declared)
    return declared


def items_for_archive(xml: str, archive: str) -> list[re.Match[str]]:
    names = {archive, urllib.parse.quote(archive)}
    matches = []
    for match in ITEM_RE.finditer(xml):
        # Only the full-archive enclosure counts; delta enclosures name other files.
        body = DELTAS_RE.sub("", match.group(0))
        if any(re.search(r'<enclosure[^>]*url="[^"]*/' + re.escape(name) + r'"', body) for name in names):
            matches.append(match)
    return matches


def enforce(xml: str, archive: str, minimum: str) -> str:
    want = parse_version(minimum)
    matches = items_for_archive(xml, archive)
    if not matches:
        raise FloorError(f"no appcast item has an enclosure for {archive}")
    for match in reversed(matches):
        item = match.group(0)
        found = MIN_RE.search(DELTAS_RE.sub("", item))
        if found:
            if parse_version(found.group(1)) != want:
                raise FloorError(
                    f"item for {archive} has sparkle:minimumSystemVersion {found.group(1)}, expected {minimum}"
                )
            continue
        anchor = re.search(r"\n(\s*)<enclosure", item)
        indent = anchor.group(1) if anchor else "            "
        insert_at = anchor.start() if anchor else item.index("<enclosure")
        element = f"\n{indent}<sparkle:minimumSystemVersion>{minimum}</sparkle:minimumSystemVersion>"
        patched = item[:insert_at] + element + item[insert_at:]
        xml = xml[: match.start()] + patched + xml[match.end() :]
    return xml


def append_legacy(xml: str, item_xml: str, floor_version: str) -> str:
    item_match = ITEM_RE.search(item_xml)
    if not item_match:
        raise FloorError("legacy item file has no <item>")
    item = item_match.group(0)
    legacy_min = MIN_RE.search(item)
    if not legacy_min:
        raise FloorError("legacy item has no sparkle:minimumSystemVersion")
    if parse_version(legacy_min.group(1)) >= parse_version(floor_version):
        raise FloorError(f"legacy item requires macOS {legacy_min.group(1)}, not below the floor {floor_version}")
    version = VERSION_RE.search(item)
    if not version:
        raise FloorError("legacy item has no sparkle:version")
    existing = {m.group(1) for m in VERSION_RE.finditer(xml)}
    if version.group(1) in existing:
        return xml
    close = xml.rfind("</channel>")
    if close < 0:
        raise FloorError("appcast has no </channel>")
    item = DELTAS_RE.sub("", item)
    return xml[:close] + "    " + item.strip() + "\n    " + xml[close:]


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    p_floor = sub.add_parser("floor")
    p_floor.add_argument("app", type=Path)
    p_enforce = sub.add_parser("enforce")
    p_enforce.add_argument("appcast", type=Path)
    p_enforce.add_argument("--archive", required=True)
    p_enforce.add_argument("--minimum", required=True)
    p_legacy = sub.add_parser("append-legacy")
    p_legacy.add_argument("appcast", type=Path)
    p_legacy.add_argument("--item-file", required=True, type=Path)
    p_legacy.add_argument("--floor", required=True)
    args = parser.parse_args(argv)
    try:
        if args.command == "floor":
            print(floor(args.app))
        elif args.command == "enforce":
            args.appcast.write_text(enforce(args.appcast.read_text(encoding="utf-8"), args.archive, args.minimum), encoding="utf-8")
            print(f"appcast item for {args.archive} requires macOS {args.minimum}")
        else:
            xml = args.appcast.read_text(encoding="utf-8")
            patched = append_legacy(xml, args.item_file.read_text(encoding="utf-8"), args.floor)
            args.appcast.write_text(patched, encoding="utf-8")
            print("appended legacy item" if patched != xml else "legacy item already present")
    except FloorError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
