#!/usr/bin/env python3
"""Filter GetTargetBuildSettings JSON to security-relevant entries.

Usage:
    filter_build_settings.py <saved-file> [--show-overrides] [--unhardened-only] [--regex REGEX]
"""

import argparse
import json
import re
from pathlib import Path

CATALOG_PATH = (
    Path(__file__).resolve().parent.parent
    / "references"
    / "settings-and-entitlements-catalog.md"
)

# Settings the script needs that aren't documented in the catalog as security
# settings but are required to interpret results (target type, SDK, etc.).
EXTRA_NAMES = ("CODE_SIGN_ENTITLEMENTS", "PRODUCT_TYPE", "SDKROOT", "SUPPORTED_PLATFORMS")

# Tokens inside backticks that look like build-setting macro names.
_NAME_RX = re.compile(r"`([A-Z][A-Z0-9_]{2,})`")

HARDENED_VALUES = {"YES", "YES_AGGRESSIVE", "YES_ERROR"}


def _load_catalog_names(path: Path) -> list[str]:
    text = path.read_text()
    names = set(_NAME_RX.findall(text))
    names.update(EXTRA_NAMES)
    # Longest-first so prefix-like names don't get shadowed in alternation.
    return sorted(names, key=lambda n: (-len(n), n))


def _default_regex() -> str:
    return "|".join(re.escape(n) for n in _load_catalog_names(CATALOG_PATH))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("saved_file", help="Path to the saved GetTargetBuildSettings JSON")
    parser.add_argument("--regex", default=None,
                        help="Override the catalog-derived default regex")
    parser.add_argument("--show-overrides", action="store_true",
                        help="Annotate target-level overrides with [target-override]")
    parser.add_argument("--unhardened-only", action="store_true",
                        help="Only show settings whose evaluatedValue is not YES/YES_AGGRESSIVE/YES_ERROR")
    args = parser.parse_args()

    rx = re.compile(args.regex if args.regex else _default_regex())
    with open(args.saved_file) as f:
        data = json.load(f)

    for s in data["buildSettings"]:
        name = s["macroName"]
        val = s.get("evaluatedValue", "")
        if not rx.search(name):
            continue
        if args.unhardened_only and val in HARDENED_VALUES:
            continue
        flag = "  [target-override]" if args.show_overrides and "targetValue" in s else ""
        print(f"{name}={val}{flag}")


if __name__ == "__main__":
    main()
