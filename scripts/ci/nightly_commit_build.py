#!/usr/bin/env python3
"""Per-commit cmux NIGHTLY builds of feat-cmux-next tips (cmux-next-dev-daily.yml, nightly-commit jobs).

Leo: "if i wait for the nightly then i might as well just update to the thing". Each DEV tip source run
can also give a cmux NIGHTLY-identity app (com.cmuxterm.app.nightly), signed and notarized, published
write-once to nightly-next/commits/<sha40>/ on the bucket behind https://files-next.cmux.com/nightly-next/.
`cmux app try` reads build.json there and updates.switch_build installs the DMG. No feed, appcast,
release or rolling DMG changes: the nightly feed never names these builds.

  nightly_commit_build.py identity PLIST BUILD FEED_URL PUBLIC_KEY VERSION
      Rewrites a cmux NEXT DEV Info.plist to cmux NIGHTLY, as nightly.yml's prepare_variant writes the
      nightly-next track and scripts/ci/nightly-next-legacy-identity.sh (feat-cmux-next) re-identifies
      a cmux NEXT build: name, bundle id, the auth URL scheme, no CMUX_AUTH_CALLBACK_SCHEME override,
      the nightly feed and its key, the build and the marketing version. CMUXCommit stays.
  nightly_commit_build.py marketing-version PLIST BUILD
      <V>-nightly.<build> (nightly_version.py next-base's line), V the DEV app's version less its suffix.
  nightly_commit_build.py icns APPICONSET OUT
      AppIcon-Nightly.icns from the source commit's Assets.xcassets/AppIcon-Nightly.appiconset (PNG elements,
      iconutil's types): the DEV compile builds only AppIcon.
  nightly_commit_build.py entitlements IN OUT
      cmux.nightly.entitlements less the Cloud tunnel keys, which feat-cmux-next's copy (the one the
      nightly signs with) no longer has: cmux-next ships no tunnel.
  nightly_commit_build.py profile PROFILE_PLIST
      Refuses a decoded profile that is not the NIGHTLY Developer ID profile for com.cmuxterm.app.nightly.
  nightly_commit_build.py channel APP
      The Info.plist and icon checks of scripts/verify-app-bundle-channel-metadata.sh APP nightly, on
      Linux (the Mac job runs that script and codesign on the result).
  nightly_commit_build.py newest-handoff RUNS_JSON
      The newest source run id among this workflow's publish runs (a workflow runs API page).
  nightly_commit_build.py index --commit SHA --build N --dmg DMG --source-run ID --out build.json
      Writes build.json: compact, sorted keys.
  nightly_commit_build.py sign ENV_NAME FILE OUT
      Writes OUT = {"edSignature", "length"} over FILE's bytes, the format ArchiveSignature reads,
      with the base64 Sparkle private key in the variable ENV_NAME (never argv).
  nightly_commit_build.py check DIR --public-key KEY [--commit SHA]
      Verifies a commit folder: build.json's fields, the DMG's length and sha256, both signatures.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import importlib.util
import json
import os
import plistlib
import re
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location("tip_appcast_linux", HERE / "tip_appcast_linux.py")
tip_appcast_linux = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(tip_appcast_linux)

DEV_BUNDLE_ID = "com.cmuxterm.app.debug.next"
DEV_NAME = "cmux NEXT DEV"
NIGHTLY_BUNDLE_ID = "com.cmuxterm.app.nightly"
NIGHTLY_NAME = "cmux NIGHTLY"
NIGHTLY_SCHEME = "cmux-nightly"
NIGHTLY_ICON = "AppIcon-Nightly"
TEAM_ID = "7WLXT3NR37"
APP_ID = f"{TEAM_ID}.{NIGHTLY_BUNDLE_ID}"
# reconcile-entitlements-with-profile.py TUNNEL_FEATURE_KEYS.
TUNNEL_KEYS = ("com.apple.developer.networking.networkextension", "com.apple.developer.system-extension.install",
               "com.apple.security.application-groups")
PURPOSE = "cmux-nightly-commit-build"
DMG_NAME = re.compile(r"^cmux-nightly-commit-macos-arm64-([0-9]+)\.dmg$")
TITLE = re.compile(r"^cmux NEXT DEV daily · publish ([0-9]+)$")
SHA = re.compile(r"^[0-9a-f]{40}$")
KEY = re.compile(r"^[A-Za-z0-9+/]{43}=$")


def fail(message: str) -> None:
    sys.exit(f"error: {message}")


def dmg_name(build: str) -> str:
    return f"cmux-nightly-commit-macos-arm64-{build}.dmg"


def edit_plist(path: str, edit) -> None:
    data = Path(path).read_bytes()
    fmt = plistlib.FMT_BINARY if data.startswith(b"bplist00") else plistlib.FMT_XML
    plist = plistlib.loads(data)
    edit(plist)
    Path(path).write_bytes(plistlib.dumps(plist, fmt=fmt, sort_keys=False))


def identity(path: str, build: str, feed: str, key: str, version: str) -> None:
    if not build.isdigit():
        fail(f"build {build!r} is not a number")
    if not KEY.match(key):
        fail(f"{key!r} is not a base64 Ed25519 public key")
    if not feed.startswith("https://files-next.cmux.com/nightly-next/") or "/tip/" in feed or "/commits/" in feed:
        fail(f"{feed} is not the nightly-next feed")
    if not re.fullmatch(r"[0-9]+(\.[0-9]+)*-nightly\.[0-9]+", version) or not version.endswith(f".{build}"):
        fail(f"marketing version {version!r} is not <V>-nightly.{build}")

    def edit(plist: dict) -> None:
        if plist.get("CFBundleIdentifier") != DEV_BUNDLE_ID or plist.get("CFBundleName") != DEV_NAME:
            fail(f"input is not {DEV_NAME} ({plist.get('CFBundleIdentifier')}, {plist.get('CFBundleName')})")
        if not SHA.match(str(plist.get("CMUXCommit", ""))):
            fail("input has no full CMUXCommit")
        types = plist.get("CFBundleURLTypes")
        if not isinstance(types, list) or len(types) < 2 or not str(types[1].get("CFBundleURLName", "")).endswith(".auth"):
            fail("CFBundleURLTypes[1] is not the auth URL type")
        schemes = types[1].get("CFBundleURLSchemes")
        if not isinstance(schemes, list) or not schemes:
            fail("the auth URL type has no scheme")
        schemes[0] = NIGHTLY_SCHEME
        # The nightly compiles with the project's PRODUCT_BUNDLE_IDENTIFIER (com.cmuxterm.app), so its URL
        # type names are com.cmuxterm.app.<kind>, and a non-dev id claims http/https at Default rank
        # (check-cmux-scheme-compile.sh CMUX_WEB_URL_HANDLER_RANK; the DEV id takes Alternate).
        for entry in types:
            name = str(entry.get("CFBundleURLName", ""))
            if name.startswith(DEV_BUNDLE_ID + "."):
                entry["CFBundleURLName"] = "com.cmuxterm.app." + name[len(DEV_BUNDLE_ID) + 1:]
            if {"http", "https"} & set(entry.get("CFBundleURLSchemes") or []) and "LSHandlerRank" in entry:
                entry["LSHandlerRank"] = "Default"
        plist["CFBundleName"] = NIGHTLY_NAME
        plist["CFBundleDisplayName"] = NIGHTLY_NAME
        plist["CFBundleIdentifier"] = NIGHTLY_BUNDLE_ID
        # cmux NIGHTLY signs in through cmux-nightly (CloudConfiguration.defaultScheme).
        environment = plist.get("LSEnvironment")
        if isinstance(environment, dict):
            environment.pop("CMUX_AUTH_CALLBACK_SCHEME", None)
            if not environment:
                plist.pop("LSEnvironment")
        for entry, value in (("SUPublicEDKey", key), ("SUFeedURL", feed)):
            plist.pop(entry, None)
            plist[entry] = value
        plist["CFBundleShortVersionString"] = version
        plist["CFBundleVersion"] = build
        plist["CFBundleIconFile"] = NIGHTLY_ICON
        plist["CFBundleIconName"] = NIGHTLY_ICON
    edit_plist(path, edit)


def marketing_version(cargo_toml: str, build: str) -> str:
    """<V>-nightly.<build>, nightly.yml's line: V is `nightly_version.py next-base`, the [workspace.package]
    version of the source commit's cmux-tui/Cargo.toml, MAJOR.MINOR.PATCH (the DEV compile keeps the
    project's MARKETING_VERSION instead)."""
    import tomllib

    try:
        base = tomllib.loads(Path(cargo_toml).read_text(encoding="utf-8"))["workspace"]["package"]["version"]
    except (OSError, ValueError, KeyError, TypeError) as error:
        fail(f"{cargo_toml} has no [workspace.package] version ({error})")
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", str(base)) or not build.isdigit():
        fail(f"{cargo_toml}'s version {base!r} is not MAJOR.MINOR.PATCH, or build {build!r} is not a number")
    return f"{base}-nightly.{build}"


# iconutil's element types for a macOS appiconset: (point size, scale) -> OSType.
ICNS_TYPES = {(16, 1): b"icp4", (16, 2): b"ic11", (32, 1): b"icp5", (32, 2): b"ic12", (128, 1): b"ic07",
              (128, 2): b"ic13", (256, 1): b"ic08", (256, 2): b"ic14", (512, 1): b"ic09", (512, 2): b"ic10"}


def icns(iconset: str, out: str) -> None:
    """AppIcon-Nightly.icns from the source commit's appiconset, as actool writes it when the nightly compiles
    with ASSETCATALOG_COMPILER_APPICON_NAME=AppIcon-Nightly (the DEV compile names AppIcon): PNG elements."""
    root = Path(iconset)
    images = json.loads((root / "Contents.json").read_text(encoding="utf-8")).get("images") or []
    chunks = []
    for image in images:
        if image.get("idiom") != "mac" or not image.get("filename"):
            continue
        size = int(str(image.get("size", "0x0")).split("x")[0].split(".")[0])
        scale = int(str(image.get("scale", "1x")).rstrip("x"))
        kind = ICNS_TYPES.get((size, scale))
        name = Path(image["filename"]).name
        data = (root / name).read_bytes()
        if kind is None or not data.startswith(b"\x89PNG\r\n\x1a\n"):
            fail(f"{name} ({size}pt @{scale}x) is not a macOS icon PNG")
        chunks.append(kind + (len(data) + 8).to_bytes(4, "big") + data)
    if len(chunks) != len(ICNS_TYPES):
        fail(f"{iconset} has {len(chunks)} of the {len(ICNS_TYPES)} macOS icon sizes")
    body = b"".join(chunks)
    Path(out).write_bytes(b"icns" + (len(body) + 8).to_bytes(4, "big") + body)


def entitlements(source: str, out: str) -> None:
    plist = plistlib.loads(Path(source).read_bytes())
    for key in TUNNEL_KEYS:
        plist.pop(key, None)
    if plist.get("com.apple.application-identifier") != APP_ID or plist.get("keychain-access-groups") != [APP_ID]:
        fail(f"{source} is not the {APP_ID} entitlements")
    Path(out).write_bytes(plistlib.dumps(plist))


def profile(path: str) -> None:
    plist = plistlib.loads(Path(path).read_bytes())
    granted = plist.get("Entitlements", {})
    if granted.get("com.apple.application-identifier") != APP_ID:
        fail(f"the NIGHTLY profile targets {granted.get('com.apple.application-identifier')}, not {APP_ID}")
    if plist.get("ProvisionsAllDevices") is not True:
        fail("the NIGHTLY profile is not a Developer ID profile")


def channel(app: str) -> None:
    plist = plistlib.loads((Path(app) / "Contents/Info.plist").read_bytes())
    want = {"CFBundleName": NIGHTLY_NAME, "CFBundleDisplayName": NIGHTLY_NAME, "CFBundleIdentifier": NIGHTLY_BUNDLE_ID,
            "CFBundleIconFile": NIGHTLY_ICON, "CFBundleIconName": NIGHTLY_ICON}
    for key, value in want.items():
        if plist.get(key) != value:
            fail(f"{key} expected {value!r}, found {plist.get(key)!r}")
    icon = Path(app) / f"Contents/Resources/{NIGHTLY_ICON}.icns"
    if not icon.is_file() or icon.stat().st_size == 0:
        fail(f"expected icon file missing or empty at {icon}")
    if (Path(app) / "Icon\r").exists():
        fail("app bundle contains a Finder custom icon file")
    print(f"verified nightly app bundle metadata: {app}")


def newest_handoff(runs_json: str) -> int:
    runs = json.loads(Path(runs_json).read_text(encoding="utf-8")).get("workflow_runs") or []
    ids = [int(match.group(1)) for run in runs
           if (match := TITLE.match(str(run.get("display_title") or run.get("name") or "")))]
    return max(ids, default=0)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def index_bytes(commit: str, build: str, dmg: Path, source_run: str, published_at: int) -> bytes:
    if not SHA.match(commit):
        fail(f"commit {commit!r} is not 40 hex")
    if not build.isdigit() or not source_run.isdigit() or not build.startswith(source_run) or len(build) != len(source_run) + 2:
        fail(f"build {build!r} is not source run {source_run!r} and a two-digit attempt")
    if dmg.name != dmg_name(build):
        fail(f"{dmg.name} is not {dmg_name(build)}")
    record = {"schema": 1, "purpose": PURPOSE, "commit": commit, "build": build, "arch": "arm64", "dmg": dmg.name,
              "length": dmg.stat().st_size, "sha256": sha256(dmg), "source_run": int(source_run),
              "published_at": published_at}
    return json.dumps(record, sort_keys=True, separators=(",", ":")).encode()


def private_key(env_name: str) -> bytes:
    encoded = os.environ.get(env_name, "").strip()
    if not encoded:
        fail(f"{env_name} is empty")
    try:
        return base64.b64decode(encoded + "=" * (-len(encoded) % 4), validate=True)
    except ValueError:
        fail(f"{env_name} is not base64")


def sign(env_name: str, path: str, out: str, public_key: str | None = None) -> None:
    raw = private_key(env_name)
    signature, public = tip_appcast_linux.sign_file(raw, path)
    if len(raw) == 96 and raw[64:] != public:
        fail("the 96-byte Sparkle key's public half does not match its private half")
    if public_key and base64.b64encode(public).decode() != public_key:
        fail(f"{env_name} does not derive {public_key}")
    if not tip_appcast_linux.openssl_verify(public, signature, path):
        fail(f"openssl does not verify the EdDSA signature of {path}")
    record = {"edSignature": base64.b64encode(signature).decode(), "length": os.path.getsize(path)}
    Path(out).write_text(json.dumps(record, sort_keys=True, separators=(",", ":")), encoding="utf-8")


def verify_signature(path: Path, sidecar: Path, public: bytes) -> list[str]:
    try:
        record = json.loads(sidecar.read_text(encoding="utf-8"))
        signature = base64.b64decode(record["edSignature"], validate=True)
    except (OSError, ValueError, KeyError, TypeError) as error:
        return [f"{sidecar.name} is unreadable ({error})"]
    problems = []
    if set(record) != {"edSignature", "length"}:
        problems.append(f"{sidecar.name} has keys {sorted(record)}")
    if record.get("length") != path.stat().st_size:
        problems.append(f"{sidecar.name} says {record.get('length')} bytes, {path.name} has {path.stat().st_size}")
    if not tip_appcast_linux.openssl_verify(public, signature, str(path)):
        problems.append(f"{sidecar.name} does not verify {path.name}")
    return problems


def check(folder: str, public_key: str, commit: str | None = None) -> list[str]:
    root = Path(folder)
    index = root / "build.json"
    try:
        public = base64.b64decode(public_key, validate=True)
        record = json.loads(index.read_bytes())
    except (OSError, ValueError) as error:
        return [f"cannot read {index} or the public key ({error})"]
    problems = []
    want = {"schema", "purpose", "commit", "build", "arch", "dmg", "length", "sha256", "source_run", "published_at"}
    if set(record) != want:
        return [f"build.json has keys {sorted(record)}"]
    if index.read_bytes() != json.dumps(record, sort_keys=True, separators=(",", ":")).encode():
        problems.append("build.json is not compact sorted JSON")
    if record["schema"] != 1 or record["purpose"] != PURPOSE or record["arch"] != "arm64":
        problems.append("build.json is not a schema 1 arm64 cmux-nightly-commit-build")
    if not SHA.match(str(record["commit"])) or (commit and record["commit"] != commit):
        problems.append(f"build.json names commit {record['commit']}")
    if (not DMG_NAME.match(str(record["dmg"])) or DMG_NAME.match(record["dmg"]).group(1) != record["build"]
            or not str(record["build"]).startswith(str(record["source_run"]))):
        problems.append(f"build.json's dmg {record['dmg']} and build {record['build']} disagree")
        return problems
    dmg = root / record["dmg"]
    if not dmg.is_file():
        return problems + [f"{record['dmg']} is missing"]
    if record["length"] != dmg.stat().st_size or record["sha256"] != sha256(dmg):
        problems.append(f"{dmg.name} is not the {record['length']} bytes build.json names")
    problems += verify_signature(dmg, root / f"{dmg.name}.signature.json", public)
    problems += verify_signature(index, root / "build.json.signature.json", public)
    return problems


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("identity")
    for name in ("plist", "build", "feed", "key", "version"):
        p.add_argument(name)
    p = sub.add_parser("marketing-version")
    p.add_argument("plist")
    p.add_argument("build")
    p = sub.add_parser("icns")
    p.add_argument("iconset")
    p.add_argument("out")
    p = sub.add_parser("entitlements")
    p.add_argument("source")
    p.add_argument("out")
    sub.add_parser("profile").add_argument("plist")
    sub.add_parser("channel").add_argument("app")
    sub.add_parser("newest-handoff").add_argument("runs_json")
    p = sub.add_parser("index")
    p.add_argument("--commit", required=True)
    p.add_argument("--build", required=True)
    p.add_argument("--dmg", required=True)
    p.add_argument("--source-run", required=True)
    p.add_argument("--published-at", type=int)
    p.add_argument("--out", required=True)
    p = sub.add_parser("sign")
    p.add_argument("env_name")
    p.add_argument("file")
    p.add_argument("out")
    p.add_argument("--public-key")
    p = sub.add_parser("check")
    p.add_argument("folder")
    p.add_argument("--public-key", required=True)
    p.add_argument("--commit")
    args = parser.parse_args(argv)
    if args.command == "identity":
        identity(args.plist, args.build, args.feed, args.key, args.version)
    elif args.command == "marketing-version":
        print(marketing_version(args.plist, args.build))
    elif args.command == "icns":
        icns(args.iconset, args.out)
    elif args.command == "entitlements":
        entitlements(args.source, args.out)
    elif args.command == "profile":
        profile(args.plist)
    elif args.command == "channel":
        channel(args.app)
    elif args.command == "newest-handoff":
        print(newest_handoff(args.runs_json))
    elif args.command == "index":
        published = args.published_at if args.published_at is not None else int(time.time())
        Path(args.out).write_bytes(index_bytes(args.commit, args.build, Path(args.dmg), args.source_run, published))
    elif args.command == "sign":
        sign(args.env_name, args.file, args.out, args.public_key)
    elif args.command == "check":
        problems = check(args.folder, args.public_key, args.commit)
        for problem in problems:
            print(f"error: {problem}", file=sys.stderr)
        if problems:
            return 1
        print(f"{args.folder}: build.json, DMG and both signatures check")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
