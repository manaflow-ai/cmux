#!/usr/bin/env python3
"""Make every item of a Sparkle appcast require one hardware architecture.

Usage: appcast_hardware_requirements.py APPCAST ARCH

Sparkle offers an item that carries <sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>
only to Apple silicon. nightly-next is arm64 only, so an Intel Mac that reads its feed keeps its
last build instead of being offered an arm64 one. Existing requirements are replaced, so a second
pass (the delta republish regenerates the feed) changes nothing.
"""
import re
import sys

ARCHES = {"arm64", "x86_64"}


def main(argv: list[str]) -> int:
    if len(argv) != 2 or argv[1] not in ARCHES:
        print(f"usage: appcast_hardware_requirements.py APPCAST {{{'|'.join(sorted(ARCHES))}}}", file=sys.stderr)
        return 2
    path, arch = argv
    xml = open(path, encoding="utf-8").read()
    xml = re.sub(r"\s*<sparkle:hardwareRequirements>[^<]*</sparkle:hardwareRequirements>", "", xml)
    xml, count = re.subn(r"<item>", f"<item>\n            <sparkle:hardwareRequirements>{arch}</sparkle:hardwareRequirements>", xml)
    if count == 0:
        print("appcast has no items to mark", file=sys.stderr)
        return 1
    open(path, "w", encoding="utf-8").write(xml)
    print(f"Marked {count} appcast item(s) with sparkle:hardwareRequirements {arch}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
