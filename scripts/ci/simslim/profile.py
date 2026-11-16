#!/usr/bin/env python3
"""Print fleet.json with CMUX_SIM_KEEP merged in, as one simslim --profile JSON.

Usage: profile.py FLEET_JSON "photos,search,com.apple.assetsd"

A word with a dot is a launchd label and goes to "keep"; any other word is a
category ID (`simslim profiles`) and goes to "except". simslim itself rejects
an unknown category or an unmanaged label when it applies the profile, so a
typo fails the run at `simslim on` instead of slimming something else.
"""
import json
import re
import sys

CATEGORY = re.compile(r"^[a-z][a-z-]{1,31}$")
LABEL = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{2,127}$")


def merge(profile, keep):
    out = dict(profile)
    out["except"] = list(profile.get("except", []))
    out["keep"] = list(profile.get("keep", []))
    words = [w.strip() for w in keep.split(",") if w.strip()]
    for word in words:
        if "." in word:
            if not LABEL.match(word):
                raise ValueError(f"not a launchd label: {word!r}")
            dest = out["keep"]
        else:
            if not CATEGORY.match(word):
                raise ValueError(f"not a simslim category: {word!r}")
            dest = out["except"]
        if word not in dest:
            dest.append(word)
    if words:
        out["name"] = profile.get("name", "cmux-fleet") + "+keep"
    return out


def main(argv):
    if len(argv) != 3:
        print(__doc__.strip().splitlines()[2], file=sys.stderr)
        return 2
    with open(argv[1]) as f:
        profile = json.load(f)
    try:
        merged = merge(profile, argv[2])
    except ValueError as err:
        print(f"profile.py: {err}", file=sys.stderr)
        return 2
    json.dump(merged, sys.stdout, indent=2)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
