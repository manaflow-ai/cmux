#!/usr/bin/env python3
"""The NIGHTLY's signed Screen Sharing helper per helper source key: what `cmux app try` swaps in.

    screen_sharing_helper_release.py key-plan KEY        is KEY's signed helper published? (needed=true|false)
    screen_sharing_helper_release.py stub-app DIR        DIR/cmux NIGHTLY.app: an Info.plist to bundle into
    screen_sharing_helper_release.py check HELPER --team T
                                                         HELPER is the NIGHTLY's helper, signed by T, its
                                                         designated requirement the Developer ID form
    screen_sharing_helper_release.py record --zip Z --helper H --team T --key K --commit C --out F
                                                         F, the record of Z (the zipped, signed helper H)
    screen_sharing_helper_release.py verify-record F [--key K] [--zip Z]
                                                         F is a sound record (of KEY; of the bytes Z)
    screen_sharing_helper_release.py objects F ZIP       the R2 object keys and local files to upload, in order

Why: the NIGHTLY runs screen sharing only from Contents/Library/<app name> Helper.app (the app and
the daemon never fall back to `bin/cmux rd serve` once a helper is bundled), so a commit that changes the
cmux-rd host is read back live only with its own helper. cmux-tui-team-signed.yml builds that helper
(build-screen-sharing-helper.sh, keyed by the source of cmux-rd-host's crates), signs it as the NIGHTLY
signs its helper (sign-cmux-bundle.sh step 2: hardened runtime, a timestamp, no entitlements, the
release-next Developer ID identity), and publishes it here:

    cmux-tui/screen-sharing-helper/KEY/SHA256/cmux-screen-sharing-helper-aarch64-apple-darwin.zip  write-once
    cmux-tui/screen-sharing-helper/KEY/helper.json   written last, once: the zip's sha256, size, bundle id,
                                                     team and designated requirement

The Mac live update file of a commit (cmux-machine-channel.py --purpose mac-live) copies KEY's zip to
cmux-tui/COMMIT/ and names it under the top-level key `screen_sharing_helper`, which every older CLI
ignores (cmux-tui/crates/cmux-tui/src/cli/app/try_cmd/helper.rs).

One identity, the one cmux#47409's release guard (scripts/ci/check-screen-share-identity.sh) pins: the
bundle id com.cmuxterm.app.nightly.screen-sharing and Developer ID team 7WLXT3NR37, so the Screen Recording
and Accessibility grants carry over. Its designated requirement is compared byte for byte with the form
codesign prints for the NIGHTLY's own helper (REQUIREMENT below, the same string as helper.rs's
developer_id_requirement): never a cdhash. CMUX_CODESIGN_TOOL stands in for codesign in tests.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import plistlib
import re
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path

BASE = os.environ.get("CMUX_SCREEN_HELPER_FILES_BASE") or "https://files.cmux.com"
PREFIX = "cmux-tui/screen-sharing-helper"
ZIP = "cmux-screen-sharing-helper-aarch64-apple-darwin.zip"
RECORD = "helper.json"
APP_ID = "com.cmuxterm.app.nightly"
APP_NAME = "cmux NIGHTLY"
# check-screen-share-identity.sh pinned_helper_id and SHIPPED_TEAM (cmux#47409): change them there and
# here in the same PR, or not at all: a change re-asks every NIGHTLY user for Screen Recording.
BUNDLE_ID = f"{APP_ID}.screen-sharing"
TEAM = "7WLXT3NR37"
# The bundle bundle-screen-sharing-helper.sh makes (SUFFIX, "<app name> Helper.app", since 5167d1f0). A commit
# from before the rename builds LEGACY_HELPER_NAME, and a zip published then holds it; check takes either, as
# `cmux app try` (try_cmd/helper.rs SUFFIX and LEGACY_SUFFIX) and the app read either.
HELPER_NAME = f"{APP_NAME} Helper.app"
LEGACY_HELPER_NAME = f"{APP_NAME} Screen Sharing.app"
HELPER_NAMES = (HELPER_NAME, LEGACY_HELPER_NAME)
EXECUTABLE = "cmux-screen-sharing"
SCHEMA = 1
ZIP_MAX_BYTES = 128 * 1024 * 1024
HEX40 = re.compile(r"[0-9a-f]{40}")
HEX64 = re.compile(r"[0-9a-f]{64}")
KEY = re.compile(r"[0-9a-f]{16}")
TEAM_ID = re.compile(r"[A-Z0-9]{10}")


def requirement(bundle_id: str, team: str) -> str:
    """The designated requirement codesign prints for a Developer ID signed bundle BUNDLE_ID of TEAM."""
    return (f'identifier "{bundle_id}" and anchor apple generic and '
            "certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and "
            "certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and "
            f'certificate leaf[subject.OU] = "{team}"')


class Refused(Exception):
    pass


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def key_plan(args) -> int:
    if not KEY.fullmatch(args.key):
        raise Refused(f"{args.key!r} is not a helper source key")
    url = f"{BASE}/{PREFIX}/{args.key}/{RECORD}"
    try:
        # files.cmux.com answers urllib's default User-Agent with 403, which read as "needed" on every run.
        request = urllib.request.Request(f"{url}?plan=1", headers={"User-Agent": "cmux-ci screen_sharing_helper_release"})
        with urllib.request.urlopen(request, timeout=30):
            needed = False
    except urllib.error.HTTPError as error:
        if error.code not in (403, 404):
            raise
        needed = True
    print(f"helper_needed={'true' if needed else 'false'}")
    return 0


def stub_app(args) -> int:
    """An app bundle bundle-screen-sharing-helper.sh --app names the helper from: the NIGHTLY's id and name."""
    app = Path(args.dir) / f"{APP_NAME}.app"
    (app / "Contents").mkdir(parents=True, exist_ok=False)
    with open(app / "Contents/Info.plist", "wb") as f:
        plistlib.dump({"CFBundleIdentifier": APP_ID, "CFBundleName": APP_NAME, "CFBundleVersion": "1",
                       "LSMinimumSystemVersion": "14.0"}, f)
    print(app)
    return 0


def designated(helper: Path) -> str:
    tool = os.environ.get("CMUX_CODESIGN_TOOL") or "/usr/bin/codesign"
    done = subprocess.run([tool, "-d", "-r-", str(helper)], capture_output=True, text=True)
    if done.returncode != 0:
        raise Refused(f"codesign -d -r- {helper}: {(done.stderr or done.stdout).strip()}")
    for line in (done.stdout + "\n" + done.stderr).splitlines():
        if line.strip().startswith("designated =>"):
            return line.strip()[len("designated =>"):].strip()
    raise Refused(f"{helper} has no designated requirement")


def check_helper(helper: Path, team: str) -> str:
    """HELPER's designated requirement, once HELPER is the NIGHTLY's helper signed by TEAM."""
    if helper.name not in HELPER_NAMES:
        raise Refused(f"{helper.name} is not {HELPER_NAME} (or, built before the rename, {LEGACY_HELPER_NAME})")
    if not (helper / "Contents/MacOS" / EXECUTABLE).is_file():
        raise Refused(f"{helper} has no Contents/MacOS/{EXECUTABLE}")
    with open(helper / "Contents/Info.plist", "rb") as f:
        bundle_id = plistlib.load(f).get("CFBundleIdentifier")
    if bundle_id != BUNDLE_ID:
        raise Refused(f"{helper.name} is {bundle_id}, not {BUNDLE_ID} (pinned by check-screen-share-identity.sh)")
    if team != TEAM:
        raise Refused(f"signed by team {team!r}, not the NIGHTLY's {TEAM}")
    got = designated(helper)
    want = requirement(BUNDLE_ID, team)
    if "cdhash" in got or got != want:
        raise Refused(f"{helper.name}'s designated requirement is\n  {got}\nnot, byte for byte,\n  {want}")
    return got


def check(args) -> int:
    print(check_helper(Path(args.helper), args.team))
    return 0


def record(args) -> int:
    if not KEY.fullmatch(args.key) or not HEX40.fullmatch(args.commit):
        raise Refused("--key is a 16-hex helper source key and --commit a 40-hex sha")
    got = check_helper(Path(args.helper), args.team)
    zip_path = Path(args.zip)
    value = {"schema": SCHEMA, "key": args.key, "commit": args.commit, "zip": ZIP,
             "sha256": sha256_file(zip_path), "size": zip_path.stat().st_size,
             "bundle_id": BUNDLE_ID, "team": args.team, "designated_requirement": got}
    verify_value(value, args.key, zip_path)
    Path(args.out).write_text(json.dumps(value, sort_keys=True, indent=1) + "\n")
    return 0


def verify_value(value: dict, key: str | None = None, zip_path: Path | None = None) -> dict:
    """VALUE, a helper record, when every field is sound (KEY's; of the bytes at ZIP_PATH)."""
    if not isinstance(value, dict) or value.get("schema") != SCHEMA:
        raise Refused("not a schema 1 helper record")
    if not KEY.fullmatch(str(value.get("key"))) or (key is not None and value.get("key") != key):
        raise Refused(f"the record is of key {value.get('key')!r}, not {key}")
    if value.get("zip") != ZIP or not HEX64.fullmatch(str(value.get("sha256"))):
        raise Refused("the record does not name the helper zip and its sha256")
    size = value.get("size")
    if not isinstance(size, int) or not 0 < size <= ZIP_MAX_BYTES:
        raise Refused(f"size {size!r} is out of range")
    if value.get("bundle_id") != BUNDLE_ID or value.get("team") != TEAM:
        raise Refused(f"the record is {value.get('bundle_id')} of team {value.get('team')}, not {BUNDLE_ID} of {TEAM}")
    if value.get("designated_requirement") != requirement(BUNDLE_ID, TEAM):
        raise Refused("the record's designated requirement is not the NIGHTLY helper's, byte for byte")
    if zip_path is not None:
        if zip_path.stat().st_size != size or sha256_file(zip_path) != value["sha256"]:
            raise Refused(f"{zip_path} is not the zip the record names")
    return value


def verify_record(args) -> int:
    verify_value(json.loads(Path(args.record).read_text()), args.key, Path(args.zip) if args.zip else None)
    return 0


def objects(args) -> int:
    value = verify_value(json.loads(Path(args.record).read_text()), zip_path=Path(args.zip))
    print(f"{PREFIX}/{value['key']}/{value['sha256']}/{ZIP} {args.zip}")
    print(f"{PREFIX}/{value['key']}/{RECORD} {args.record}")
    return 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[1] if __doc__ else None)
    sub = parser.add_subparsers(dest="command", required=True)
    one = sub.add_parser("key-plan")
    one.add_argument("key")
    one.set_defaults(run=key_plan)
    one = sub.add_parser("stub-app")
    one.add_argument("dir")
    one.set_defaults(run=stub_app)
    one = sub.add_parser("check")
    one.add_argument("helper")
    one.add_argument("--team", required=True)
    one.set_defaults(run=check)
    one = sub.add_parser("record")
    for name in ("--zip", "--helper", "--team", "--key", "--commit", "--out"):
        one.add_argument(name, required=True)
    one.set_defaults(run=record)
    one = sub.add_parser("verify-record")
    one.add_argument("record")
    one.add_argument("--key")
    one.add_argument("--zip")
    one.set_defaults(run=verify_record)
    one = sub.add_parser("objects")
    one.add_argument("record")
    one.add_argument("zip")
    one.set_defaults(run=objects)
    args = parser.parse_args(argv)
    try:
        return args.run(args)
    except Refused as error:
        print(f"screen_sharing_helper_release: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
