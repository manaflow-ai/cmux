#!/usr/bin/env python3
"""The names a DEV build of cmux NEXT gives its own state: its control socket, its app daemon
session and its acpmux home.

The restore journey (restore-journey.py, restore-journey-slot.sh) drives a capture slot's app
through these names.

  build_names.py socket APP_PATH    print the control socket of the app at APP_PATH: the real one
                                    in ~/.local/state/cmux first, then its /tmp link
"""
import os, plistlib, re, sys


DEV_PREFIX = "com.cmuxterm.app.debug"
# DEV tags whose names a shipped build owns (BuildIdentity.KeptNames.ownedTags).
OWNED_TAGS = {"nightly", "rc", "staging", "cmux-next"}
# Bundle id prefixes other than DEV's (BuildIdentity.kinds); `com.cmuxterm.app.<other>` is DEV.
OTHER_KINDS = ("com.cmuxterm.app.nightly", "com.cmuxterm.app.staging", "com.cmuxterm.app.rc")


def tag_slug(raw):
    """BuildIdentity.tagSlug: lowercase, runs outside [a-z0-9] become one `-`, trimmed."""
    slug = re.sub(r"[^a-z0-9]+", "-", (raw or "").lower()).strip("-")
    return slug or None


def component(raw):
    """BuildIdentity.component: runs outside [A-Za-z0-9._] become one `-`, no leading or trailing `-` or `.`."""
    out = re.sub(r"[^A-Za-z0-9._]+", "-", raw).strip("-.")
    return out or None


def fnv1a32(data):
    h = 0x811C9DC5
    for byte in data.encode():
        h = ((h ^ byte) * 0x01000193) & 0xFFFFFFFF
    return f"{h:08x}"


def names(bundle_id, bundled_tag, user_home):
    """{"socket", "session", "acpmux_home"} of a DEV build with `bundle_id` that ships the tag
    `bundled_tag` (its Info.plist `LSEnvironment` `CMUX_TAG`, or None): the app's own rule
    (CmuxNextCompat BuildIdentity and BuildIdentity+AppNames, schemas/build-identity/vectors.json).
    A build whose id ends in its tag (scripts/reload.sh's `com.cmuxterm.app.debug.<a.b>`) keeps
    `/tmp/cmux-debug-<tag>.sock`; any other (a capture slot's `<id>.capslot<N>` clone shipping
    `<tag>`) gets names of its key."""
    if bundle_id == "com.cmuxterm.app" or bundle_id.startswith(OTHER_KINDS) or not bundle_id.startswith("com.cmuxterm.app"):
        raise ValueError(f"not a DEV build: {bundle_id!r}")
    suffix = None
    if bundle_id.startswith(DEV_PREFIX + "."):
        suffix = bundle_id[len(DEV_PREFIX) + 1:]
    elif bundle_id not in (DEV_PREFIX, "com.cmuxterm.app") and bundle_id.startswith("com.cmuxterm.app."):
        suffix = bundle_id[len("com.cmuxterm.app."):]
    suffix_tag = tag_slug(suffix) if suffix is not None else None
    shipped = tag_slug(bundled_tag)
    name = component(bundle_id)
    key = name if name == bundle_id else f"{name}--{fnv1a32(bundle_id)}"
    if shipped and shipped != suffix_tag:
        key += "--" + shipped
    kept = None
    if bundle_id == DEV_PREFIX:
        kept = shipped if shipped and shipped not in OWNED_TAGS else None
    elif not (shipped and shipped != suffix_tag) and bundle_id.startswith(DEV_PREFIX + "."):
        reload_form = all(re.fullmatch(r"[a-z0-9]+", part) for part in bundle_id[len(DEV_PREFIX) + 1:].split("."))
        if reload_form and suffix_tag and suffix_tag not in OWNED_TAGS:
            kept = suffix_tag
    key_hash = fnv1a32(key)
    return {
        "socket": f"/tmp/cmux-debug-{kept}.sock" if kept else f"/tmp/cmux-debug--{key_hash}.sock",
        "session": f"cmux-app-{kept}" if kept else f"cmux-app--{key_hash}",
        "acpmux_home": os.path.join(user_home, ".acpmux", "builds", key),
    }


def socket_paths(tmp_name, user_home):
    """ControlSocketPath.moved: the socket in `<home>/.local/state/cmux` (when its path fits
    sun_path, 103 bytes), then the `/tmp` name the app keeps as a link to it (since #20508)."""
    moved = os.path.join(user_home, ".local", "state", "cmux", os.path.basename(tmp_name))
    return [moved, tmp_name] if len(moved.encode()) <= 103 else [tmp_name]


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
    print("\n".join(socket_paths(of_app(sys.argv[2])["socket"], os.path.expanduser("~"))))
