#!/usr/bin/env python3
"""Stamp the cmux NEXT nightly identity into a prepared app's Info.plist.

    nightly_next_identity.py PLIST

The edits nightly.yml build-sign-notarize-nightly's "Inject nightly identities
and metadata" makes with PlistBuddy for the nightly-next track (not the notary
probe), as plistlib edits that keep the plist's format, for a job without
PlistBuddy. Each Delete + Add moves the entry to the end, as PlistBuddy does.

Env (as in that step): CHANNEL_APP_NAME, CHANNEL_BUNDLE_ID, CHANNEL_URL_SCHEME,
FEED_URL, SPARKLE_PUBLIC_KEY, NIGHTLY_MARKETING_VERSION, NIGHTLY_BUILD,
SHORT_SHA. Fails like that step when the second URL type is not the auth type
or a required entry is missing.
"""

from __future__ import annotations

import os
import plistlib
import sys


def fail(message: str) -> None:
    sys.exit(f"error: {message}")


def env(name: str) -> str:
    value = os.environ.get(name, "")
    if not value:
        fail(f"{name} is empty")
    return value


def stamp(plist: dict) -> None:
    name, bundle_id, scheme = env("CHANNEL_APP_NAME"), env("CHANNEL_BUNDLE_ID"), env("CHANNEL_URL_SCHEME")
    # PlistBuddy's Set fails on an entry that does not exist.
    for key in ("CFBundleName", "CFBundleDisplayName", "CFBundleIdentifier", "CFBundleShortVersionString", "CFBundleVersion"):
        if key not in plist:
            fail(f"Info.plist has no {key}")
    plist["CFBundleName"] = name
    plist["CFBundleDisplayName"] = name
    plist["CFBundleIdentifier"] = bundle_id
    try:
        url_type = plist["CFBundleURLTypes"][1]
        url_type_name = url_type["CFBundleURLName"]
        schemes = url_type["CFBundleURLSchemes"]
        schemes[0]
    except (KeyError, IndexError, TypeError):
        fail("Info.plist has no second URL type with a scheme")
    if not str(url_type_name).endswith(".auth"):
        fail(f"Expected CFBundleURLTypes[1] to be the auth URL type, found: {url_type_name}")
    schemes[0] = scheme
    # A tagged nightly bundle id defaults to the stable `cmux` sign-in
    # callback; cmux NEXT signs in through its own scheme.
    # Add :LSEnvironment dict only when it is missing; PlistBuddy's later Add
    # fails when an existing LSEnvironment is not a dictionary.
    environment = plist.setdefault("LSEnvironment", {})
    if not isinstance(environment, dict):
        fail("Info.plist has an LSEnvironment that is not a dictionary")
    environment.pop("CMUX_AUTH_CALLBACK_SCHEME", None)
    environment["CMUX_AUTH_CALLBACK_SCHEME"] = scheme
    for key, value in (("SUPublicEDKey", env("SPARKLE_PUBLIC_KEY")), ("SUFeedURL", env("FEED_URL"))):
        plist.pop(key, None)
        plist[key] = value
    plist["CFBundleShortVersionString"] = env("NIGHTLY_MARKETING_VERSION")
    plist["CFBundleVersion"] = env("NIGHTLY_BUILD")
    plist.pop("CMUXCommit", None)
    plist["CMUXCommit"] = env("SHORT_SHA")


def main(argv: list[str]) -> int:
    if len(argv) != 1:
        sys.exit(__doc__)
    path = argv[0]
    with open(path, "rb") as handle:
        data = handle.read()
    fmt = plistlib.FMT_BINARY if data.startswith(b"bplist00") else plistlib.FMT_XML
    plist = plistlib.loads(data)
    stamp(plist)
    with open(path, "wb") as handle:
        plistlib.dump(plist, handle, fmt=fmt, sort_keys=False)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
