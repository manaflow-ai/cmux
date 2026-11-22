#!/usr/bin/env python3
"""Checks the unsigned Computer Use helper a source-built nightly kept, and writes its pin.

    check-cmux-cua-helper-run.py HELPER_DIR RUN_SOURCE OUT_DIR RUN_URL SOURCE_SHA

HELPER_DIR is the run's cmux-cua-helper-unsigned artifact (key.txt and the zip).
RUN_SOURCE is a sparse checkout of the run's commit. Nothing in it runs: it is read
as data, the same files scripts/cmux-cua-helper-key.sh hashes into the input key.
The check:
  - key.txt's fields hash to its input key and the zip matches its sha256;
  - each source field equals that file's sha256 at the run's commit, and the
    patch fields are exactly the series build-cmux-cua.sh declares there;
  - the zip holds one ad-hoc com.cmuxterm.cua app and no provisioning profile.
It writes OUT_DIR/cmux-cua-helper.pin.json and OUT_DIR/pinned_sha. Every value read
out of a file goes through need(), so a file in another shape fails with its name
and what was expected, never a bare AttributeError
(cmux-next-cua-helper-publish.yml runs it).
"""
import hashlib
import json
import plistlib
import re
import sys
import zipfile
from pathlib import Path

RECIPE = "cmux-cua-helper-prebuilt-v1"


class CheckError(Exception):
    pass


def need(pattern, text, what, flags=re.M):
    match = re.search(pattern, text, flags)
    if match is None:
        raise CheckError(f"cannot read {what}")
    return match.group(1)


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def patch_series(build_text):
    """The patch paths build-cmux-cua.sh applies, in order.

    feat-cmux-next declares the series as CMUX_CUA_PATCH_RELATIVE_PATHS=( "a" "b" ),
    which scripts/cmux-cua-helper-key.sh reads with the same rule (one quoted path
    per line up to the closing parenthesis). Older scripts (main) declare one patch as
    CMUX_CUA_PATCH_RELATIVE_PATH="a". Any other shape is an error, never an empty series.
    """
    block = re.search(r"^CMUX_CUA_PATCH_RELATIVE_PATHS=\(\n(.*?)^\)$", build_text, re.M | re.S)
    if block is not None:
        return re.findall(r'^[ \t]*"([^"]+)"[ \t]*$', block.group(1), re.M)
    single = re.search(r'^CMUX_CUA_PATCH_RELATIVE_PATH="([^"]+)"$', build_text, re.M)
    if single is not None:
        return [single.group(1)]
    raise CheckError(
        "cannot read the patch series in scripts/build-cmux-cua.sh "
        "(neither CMUX_CUA_PATCH_RELATIVE_PATHS=( ... ) nor CMUX_CUA_PATCH_RELATIVE_PATH=\"...\")"
    )


def key_lines(text):
    lines = text.splitlines()
    for number, line in enumerate(lines, 1):
        if "=" not in line:
            raise CheckError(f"key.txt line {number} is not NAME=VALUE: {line!r}")
    return lines


def check(helper, src, out, run_url, source_sha):
    lines = key_lines((helper / "key.txt").read_text())
    if len(lines) < 4:
        raise CheckError("key.txt has no fields")
    head = dict(line.split("=", 1) for line in lines[:3])
    fields = lines[3:]
    for name in ("input_key", "asset", "sha256"):
        if name not in head:
            raise CheckError(f"key.txt has no {name}")
    key, asset, digest = head["input_key"], head["asset"], head["sha256"]
    if not re.fullmatch(r"cmux-computer-use-unsigned-macos-[a-z0-9_-]+\.zip", asset):
        raise CheckError(f"unexpected asset name {asset!r}")
    if sha(helper / asset) != digest:
        raise CheckError("the zip does not match key.txt")
    if hashlib.sha256("".join(f + "\n" for f in fields).encode()).hexdigest() != key:
        raise CheckError("fields do not hash to the key")
    f = dict(line.split("=", 1) for line in fields)
    if f.get("recipe") != RECIPE:
        raise CheckError(f"recipe {f.get('recipe')!r}, expected {RECIPE}")

    build_path = src / "scripts/build-cmux-cua.sh"
    build = build_path.read_text()
    pinned = need(r'^CMUX_CUA_PINNED_SHA="([0-9a-f]{40})"$', build, "CMUX_CUA_PINNED_SHA in scripts/build-cmux-cua.sh")
    icon = src / "Resources/ComputerUseHelperIcon.icns"
    checks = {
        "cmux_cua_pinned_sha": pinned,
        "build_script": sha(build_path),
        "apply_patch": sha(src / "scripts/apply-cmux-cua-patch.sh"),
        "strip_rpaths": sha(src / "scripts/strip-cmux-cua-rpaths.sh"),
        "icon": sha(icon) if icon.exists() else "none",
        "rust_toolchain": need(
            r'^channel = "(.*)"$', (src / "cmux-tui/rust-toolchain.toml").read_text(), "channel in cmux-tui/rust-toolchain.toml"
        ),
    }
    for rel in patch_series(build):
        path = src / rel
        if not path.is_file():
            raise CheckError(f"build-cmux-cua.sh lists {rel}, which is not in the run's commit")
        checks[f"patch:{rel}"] = sha(path)
    recorded = {k for k in f if k.startswith("patch:")}
    declared = {k for k in checks if k.startswith("patch:")}
    if recorded != declared:
        raise CheckError(f"another patch series: the run recorded {sorted(recorded)}, its commit declares {sorted(declared)}")
    for name, want in checks.items():
        if f.get(name) != want:
            raise CheckError(f"{name}: the run recorded {f.get(name)!r}, its commit has {want!r}")
    for name in ("archs", "xcode", "macos_sdk"):
        if not f.get(name):
            raise CheckError(f"key.txt has no {name}")

    with zipfile.ZipFile(helper / asset) as z:
        names = z.namelist()
        if not names or not all(n.startswith("cmux Computer Use.app/") for n in names):
            raise CheckError("the zip holds more than the helper app")
        if any(n.endswith("embedded.provisionprofile") for n in names):
            raise CheckError("the helper carries a provisioning profile")
        if "cmux Computer Use.app/Contents/MacOS/cmux-cua" not in names:
            raise CheckError("the helper has no Contents/MacOS/cmux-cua")
        info = plistlib.loads(z.read("cmux Computer Use.app/Contents/Info.plist"))
        if info.get("CFBundleIdentifier") != "com.cmuxterm.cua":
            raise CheckError(f"bundle id {info.get('CFBundleIdentifier')!r}")

    pin = {
        "asset": asset, "arch": f["archs"], "sha256": digest, "r2_bucket": "cmux-cef",
        "r2_key": f"cmux-cua-helper/{digest}/{asset}", "input_key": key, "bundle_id": "com.cmuxterm.cua",
        "signing": "adhoc (the nightly signs it)", "cmux_cua_pinned_sha": pinned,
        "xcode": f["xcode"], "macos_sdk": f["macos_sdk"], "built_by": run_url, "source_commit": source_sha,
    }
    out.mkdir(parents=True, exist_ok=True)
    (out / "cmux-cua-helper.pin.json").write_text(json.dumps(pin, indent=2) + "\n")
    (out / "pinned_sha").write_text(pinned)
    return pin


def main(argv):
    if len(argv) != 6:
        print(__doc__.strip().splitlines()[2].strip(), file=sys.stderr)
        return 2
    try:
        check(Path(argv[1]), Path(argv[2]), Path(argv[3]), argv[4], argv[5])
    except (CheckError, OSError, KeyError, zipfile.BadZipFile, plistlib.InvalidFileException) as error:
        print(f"::error::{error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
