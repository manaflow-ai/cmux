#!/usr/bin/env python3
"""The names a DEV build of cmux NEXT gives its own state: its control socket, its app daemon
session and its acpmux home.

The restore journey (restore-journey.py, restore-journey-slot.sh) drives a capture slot's app
through these names.

  build_names.py socket APP_PATH    print the control socket of the app at APP_PATH
"""
import os, plistlib, re, sys


def tag_slug(raw):
    slug = re.sub(r"[^a-z0-9]+", "-", (raw or "").lower()).strip("-")
    return slug or None


def names(bundle_id, bundled_tag, user_home):
    """{"socket", "session", "acpmux_home"} of a DEV build with `bundle_id` that ships the tag
    `bundled_tag` (its Info.plist `LSEnvironment` `CMUX_TAG`, or None)."""
    tag = tag_slug(bundled_tag) or tag_slug(bundle_id.removeprefix("com.cmuxterm.app.debug"))
    return {
        "socket": f"/tmp/cmux-debug-{tag}.sock",
        "session": f"cmux-app-{tag}",
        "acpmux_home": os.path.join(user_home, ".acpmux", "builds", "com.cmuxterm.app.debug." + (tag or "").replace("-", ".")),
    }


def bundled_tag(app_path):
    """The tag the app at `app_path` ships: `LSEnvironment` `CMUX_TAG`, else its `cmux DEV <tag>.app` name."""
    try:
        with open(os.path.join(app_path, "Contents", "Info.plist"), "rb") as f:
            info = plistlib.load(f)
    except (OSError, plistlib.InvalidFileException):
        info = {}
    tag = (info.get("LSEnvironment") or {}).get("CMUX_TAG")
    if not tag:
        name = os.path.basename(app_path.rstrip("/")).removesuffix(".app")
        tag = name[len("cmux DEV "):] if name.startswith("cmux DEV ") else None
    return info.get("CFBundleIdentifier"), tag


def of_app(app_path, user_home=None):
    bundle_id, tag = bundled_tag(app_path)
    return names(bundle_id or "", tag, user_home or os.path.expanduser("~"))


if __name__ == "__main__":
    if len(sys.argv) != 3 or sys.argv[1] != "socket":
        sys.exit("usage: build_names.py socket APP_PATH")
    print(of_app(sys.argv[2])["socket"])
