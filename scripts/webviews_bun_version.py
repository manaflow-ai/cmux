#!/usr/bin/env python3
"""The one reader of the bun version webviews/package.json pins.

Prints the version of the devEngines.packageManager entry named "bun" (an
object, or an array of objects as npm's devEngines allows) and exits 0. Exits 1
with one line on stderr when there is no such entry or its version is not an
exact major.minor.patch. Other engines (devEngines.runtime, an npm entry listed
before bun) never count.

Every script that needs the pin calls this instead of parsing package.json
itself, so none can read another version: the pre-commit hook (from its trusted
copy, before any bun exists), check-webviews-bun-version.sh, private-bun.sh,
build-web-bundles.sh, ensure-web-bundles.sh, web-bundle-key.py and the CI steps.
It needs only Python's standard library, never bun.

Usage: webviews_bun_version.py [PACKAGE_JSON]   (default: webviews/package.json
next to this script's scripts/ folder)
"""
import json
import os
import re
import sys

EXACT = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+")


def _shown(value):
    """A pin as printable text: anything outside a version's characters becomes '?'."""
    return re.sub(r"[^A-Za-z0-9._/-]", "?", str(value))[:80]


def bun_version(package_json):
    """The exact bun version package_json pins; ValueError (one line) otherwise."""
    name = os.path.join(os.path.basename(os.path.dirname(package_json)), os.path.basename(package_json))
    try:
        with open(package_json, encoding="utf-8") as handle:
            package = json.load(handle)
    except (OSError, ValueError) as error:
        raise ValueError(f"cannot read {name}: {error.__class__.__name__}") from None
    engines = package.get("devEngines") if isinstance(package, dict) else None
    managers = engines.get("packageManager") if isinstance(engines, dict) else None
    if isinstance(managers, dict):
        managers = [managers]
    if not isinstance(managers, list):
        managers = []
    buns = [entry for entry in managers if isinstance(entry, dict) and entry.get("name") == "bun"]
    if not buns:
        raise ValueError(f"{name} declares no bun in devEngines.packageManager")
    if len(buns) > 1:
        raise ValueError(f"{name} declares bun more than once in devEngines.packageManager")
    pin = buns[0].get("version")
    if not isinstance(pin, str) or not EXACT.fullmatch(pin):
        raise ValueError(f"{name} pins bun '{_shown(pin)}', not an exact major.minor.patch version")
    return pin


def main(argv):
    if len(argv) > 2 or (len(argv) == 2 and argv[1] in ("-h", "--help")):
        sys.stderr.write(__doc__.split("Usage: ", 1)[1])
        return 2
    default = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "webviews", "package.json")
    try:
        print(bun_version(argv[1] if len(argv) == 2 else default))
    except ValueError as error:
        sys.stderr.write(f"{error}\n")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
