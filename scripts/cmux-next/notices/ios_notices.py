#!/usr/bin/env python3
# Copyright 2026 Manaflow, Inc.
# SPDX-License-Identifier: GPL-3.0-or-later
"""Third-party notices of the cmux iOS app: the Settings.bundle Acknowledgements pane.

  ios_notices.py link-set --xcframework DIR [--out FILE]
      (a Mac with Xcode: llvm-dwarfdump) Reads the ios-arm64 slice of the pinned
      GhosttyNextKit.xcframework and writes ios/link-set.json: the pin, the archive
      members, and the owner of every DWARF source path (Zig package, vendored
      Ghostty directory, Zig's lib). Zig code keeps no package-level DWARF, so every
      Zig-source package that Ghostty declares counts as linked (conservative).
  ios_notices.py generate --ghostty-tree DIR [--check]
      Writes ios/cmux/Settings.bundle/Acknowledgements.plist from link-set.json, the
      collected ghostty-next license tree (collect-ghostty-licenses.py, CI only:
      cmux-next-source-archive.yml), hand-written.md sections and Zig's LICENSE.
      --check fails when the committed pane differs.
  ios_notices.py check-repo
      No network, no tree: the link set, the pane and the libintl rule all name
      the CmuxGhosttyKit pin of Package.swift. A new pin stops here until
      link-set and generate run for it.
  ios_notices.py check-app --app cmux.app
      The built app: Settings.bundle has the Acknowledgements pane (en and ja
      strings) and its Acknowledgements.plist equals the committed one; the app
      binaries pass the libintl rule.
  ios_notices.py check-binaries --pin SHA256 PATH...
      The libintl rule on the slices of the pinned xcframework, with the ratchet.

libintl rule (D1): GNU gettext's libintl is LGPL-2.1-or-later and must not be
statically linked into a shipped Apple binary. A binary that contains it fails,
unless its CmuxGhosttyKit pin is listed in ios/lgpl-exceptions.json (pins from
before the ghostty-next i18n-off rebuild). When a listed pin is the current pin
and the slices of its xcframework no longer contain libintl, the entry fails, so
it is removed with that pin. Entries for pins not in use yet are not checked.
GETTEXT_LOG_UNTRANSLATED is a string literal of libintl: it survives `strip`
of a linked binary (symbol names do not).
"""

from __future__ import annotations

import argparse
import hashlib
import json
import plistlib
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
DATA = HERE / "ios"
LINK_SET = DATA / "link-set.json"
EXCEPTIONS = DATA / "lgpl-exceptions.json"
HAND_WRITTEN = HERE / "hand-written.md"
GHOSTTY_KIT = ROOT / "Packages/Shared/CmuxGhosttyKit/Package.swift"
SETTINGS = ROOT / "ios/cmux/Settings.bundle"
PANE = SETTINGS / "Acknowledgements.plist"
TOOLCHAINS = ROOT / "cmux-tui/build-support/notices/toolchains/toolchains.json"
HAND_WRITTEN_SECTIONS = ("Ghostty", "Swift Crypto and Swift ASN.1", "Stack Auth Swift SDK")
LANGUAGES = ("en", "ja")
# Bytes that only GNU gettext's libintl puts into an object or a linked binary.
LIBINTL_MARKERS = (b"libintl_dcigettext", b"GETTEXT_LOG_UNTRANSLATED", b"gettext-runtime/intl")
SLICE = "ios-arm64"
# The z2d MPL-2.0 Executable Form notice (MPL-2.0 3.2(a)) for the iOS app.
Z2D_OFFER = """z2d is licensed under the Mozilla Public License 2.0 (MPL-2.0); its text is above. \
This app contains z2d in Executable Form, unmodified. The Source Code Form of the exact \
version in this app is available at {url} (the archive that Ghostty {revision} fetches) \
and at https://github.com/vancluever/z2d. The Ghostty source that selects it is at \
https://github.com/manaflow-ai/ghostty-next/tree/{revision}."""


class NoticeError(Exception):
    pass


def ghostty_kit_pin(path: Path = GHOSTTY_KIT) -> dict:
    text = path.read_text()
    url = re.search(r'url:\s*"([^"]+GhosttyNextKit\.xcframework\.zip)"', text)
    checksum = re.search(r'checksum:\s*"([0-9a-f]{64})"', text)
    revision = re.search(r"xcframework-([0-9a-f]{40})-", url.group(1)) if url else None
    if not (url and checksum and revision):
        raise NoticeError(f"{path}: no GhosttyNextKit binaryTarget url/checksum")
    return {"url": url.group(1), "sha256": checksum.group(1), "ghostty_revision": revision.group(1)}


# ---------------------------------------------------------------- libintl rule

def contains_libintl(path: Path) -> bool:
    data = path.read_bytes()
    return any(marker in data for marker in LIBINTL_MARKERS)


def libintl_errors(pin_sha256: str, paths: list[Path], exceptions_path: Path = EXCEPTIONS, *, ratchet: bool = False) -> list[str]:
    """The libintl rule for binaries built from CmuxGhosttyKit pin `pin_sha256` (the current pin).

    Binaries with libintl fail unless the pin has an exception. With ratchet=True (the
    pinned xcframework's slices themselves), an excepted pin whose slices are all clean
    fails too, so its entry goes. An app may be clean under an excepted pin (the linker
    drops unused libintl), so check-app runs without the ratchet. Entries for pins that
    are not current are never checked here: they wait for their pin.
    """
    exceptions = json.loads(exceptions_path.read_text())["pins"]
    found = [str(path) for path in paths if contains_libintl(path)]
    excepted = pin_sha256 in exceptions
    if found and not excepted:
        return [
            f"LGPL-2.1 libintl (GNU gettext) is statically linked in {', '.join(found)}; a shipped Apple "
            "binary must not contain it (D1: build GhosttyNextKit with i18n off for Apple targets)"
        ]
    if ratchet and excepted and paths and not found:
        return [
            f"pin {pin_sha256[:12]} is in {exceptions_path.name} but its binaries no longer "
            "contain libintl; remove the exception"
        ]
    if found:
        print(f"warning: libintl present, allowed only for pin {pin_sha256[:12]}: {exceptions[pin_sha256]}", file=sys.stderr)
    return []


# ---------------------------------------------------------------- link set

def attribute(path: str, names: dict[str, str]) -> str | None:
    match = re.search(r"/(?:zig-pkg|zig/p)/([^/]+)/", path)
    if match:
        return "zig-package:" + names.get(match.group(1), match.group(1))
    for kind in ("pkg", "vendor"):
        match = re.search(rf"/ghostty-next/ghostty-next/{kind}/([^/]+)/", path)
        if match:
            return f"vendored:{kind}/{match.group(1)}"
    match = re.search(r"/zig-[0-9.]+/[^/]+/lib/([^/]+)/", path)
    if match:
        return "zig-lib:" + match.group(1)
    return None


def link_set(xcframework: Path, manifest: Path) -> dict:
    archive = xcframework / SLICE / "libghostty-internal.a"
    members = subprocess.run(["ar", "t", str(archive)], check=True, capture_output=True, text=True).stdout.split()
    sources = subprocess.run(
        ["xcrun", "llvm-dwarfdump", "--show-sources", str(archive)], check=True, capture_output=True, text=True
    ).stdout.splitlines()
    tree = json.loads(manifest.read_text())
    names = {key: value["dependency"] for key, value in tree["zig_packages"].items()}
    owners = sorted({owner for line in sources if (owner := attribute(line.strip(), names))})
    zig_versions = sorted({match.group(1) for line in sources if (match := re.search(r"/zig-([0-9]+\.[0-9]+\.[0-9]+)/", line))})
    if len(zig_versions) != 1:
        raise NoticeError(f"expected one Zig version in the DWARF paths, found {zig_versions}")
    return {
        "zig_version": zig_versions[0],
        "schema": 1,
        "slice": SLICE,
        "members": sorted(set(members) - {"__.SYMDEF"}),
        "dwarf_owners": owners,
        "libintl": contains_libintl(archive),
    }


# ---------------------------------------------------------------- pane

def hand_written_section(title: str, text: str) -> str:
    match = re.search(rf"^### {re.escape(title)}\n(.*?)(?=^#{{2,3}} |\Z)|^## {re.escape(title)}\n(.*?)(?=^## |\Z)", text, re.S | re.M)
    if not match:
        raise NoticeError(f"hand-written.md has no section {title!r}")
    return (match.group(1) or match.group(2)).strip()


def _tree_texts(tree: Path, manifest: dict, package_names: set[str]) -> dict[str, list[tuple[str, str]]]:
    hashes = {name: key for key, value in manifest["zig_packages"].items() for name in [value["dependency"]]}
    texts: dict[str, list[tuple[str, str]]] = {}
    for entry in manifest["license_files"]:
        source, package = entry["source"], entry["package"]
        owner = None
        match = re.match(r"zig-pkg/([^/]+)/", source)
        if match:
            owner = next((name for name, key in hashes.items() if key == match.group(1)), None)
        elif package.startswith(("pkg/", "vendor/")):
            owner = package
        elif package in manifest["zig_packages"]:
            owner = manifest["zig_packages"][package]["dependency"]
        elif source.startswith("source-offer:"):
            continue
        elif package == GHOSTTY_OWN and not source.startswith("pkg/afl++"):
            owner = GHOSTTY_OWN
        if owner not in package_names:
            continue
        data = (tree / entry["destination"]).read_bytes()
        if hashlib.sha256(data).hexdigest() != entry["sha256"]:
            raise NoticeError(f"{entry['destination']}: sha256 differs from SOURCE-MANIFEST.json")
        label = source.split("/", 2)[-1] if source.startswith("zig-pkg/") else source.rsplit("/", 1)[-1]
        texts.setdefault(owner, []).append((label, data.decode("utf-8", "replace")))
    return texts


VENDORED_REVIEW = ROOT / "cmux-tui/build-support/notices/ghostty/pinned-licenses/MANIFEST.json"
GHOSTTY_OWN = "ghostty-next"  # Ghostty's own LICENSE, embedded font licenses (src/font/res, vendor/nerd-fonts)


def linked_packages(links: dict, manifest: dict) -> list[str]:
    declared = {value["dependency"] for value in manifest["zig_packages"].values()}
    vendored_in_tree = {entry["package"] for entry in manifest["license_files"] if entry["package"].startswith(("pkg/", "vendor/"))}
    review = json.loads(VENDORED_REVIEW.read_text())["vendored"]
    names = {GHOSTTY_OWN}
    for owner in links["dwarf_owners"]:
        kind, _, name = owner.partition(":")
        if kind == "zig-package":
            names.add(name)
        elif kind == "vendored":
            if name in vendored_in_tree:
                names.add(name)
                continue
            covered = review.get(name, {}).get("covered_by")
            if covered == "ghostty":
                continue  # Ghostty's own code: Ghostty's LICENSE
            if covered and covered.startswith("zig-dependency:"):
                names.add(covered.split(":", 1)[1])
                continue
            raise NoticeError(f"{name}: vendored Ghostty directory without a reviewed license (ghostty_vendored.py)")
    # Zig code (libghostty_zcu.o) has no per-package DWARF: link-set.json lists the Zig-source
    # packages counted as linked.
    names |= set(links["zig_source_packages"])
    unknown = sorted(names - declared - vendored_in_tree - {GHOSTTY_OWN})
    if unknown:
        raise NoticeError(f"linked packages without a collected license: {unknown}")
    return sorted(names)


def build_pane(tree: Path, links: dict, pin: dict) -> dict:
    manifest = json.loads((tree / "SOURCE-MANIFEST.json").read_text())
    if manifest["ghostty_revision"] != pin["ghostty_revision"]:
        raise NoticeError(
            f"license tree is for Ghostty {manifest['ghostty_revision'][:11]}, the pin is {pin['ghostty_revision'][:11]}"
        )
    if manifest.get("unresolved_packages"):
        raise NoticeError("the license tree has unresolved packages")
    hand = HAND_WRITTEN.read_text()
    packages = linked_packages(links, manifest)
    texts = _tree_texts(tree, manifest, set(packages))
    zig = next((entry for entry in json.loads(TOOLCHAINS.read_text())["zig"] if entry["version"] == links["zig_version"]), None)
    if zig is None:
        raise NoticeError(f"no reviewed Zig {links['zig_version']} LICENSE in {TOOLCHAINS.relative_to(ROOT)}")
    zig_bytes = (TOOLCHAINS.parent / "texts" / zig["file"]).read_bytes()
    if hashlib.sha256(zig_bytes).hexdigest() != zig["sha256"]:
        raise NoticeError(f"{zig['file']}: sha256 differs from toolchains.json")
    zig_text = zig_bytes.decode()
    groups = [{"Type": "PSGroupSpecifier", "Title": "INTRO_TITLE", "FooterText": "INTRO_FOOTER"}]

    def group(title: str, footer: str) -> None:
        # Property lists cannot hold C0 controls: page breaks (form feeds) become line
        # breaks, CR LF becomes LF, other controls are dropped. Wording is unchanged.
        text = footer.replace("\r\n", "\n").replace("\f", "\n")
        text = re.sub(r"[\x00-\x08\x0b-\x1f\x7f]", "", text)
        groups.append({"Type": "PSGroupSpecifier", "Title": title, "FooterText": text.strip() + "\n"})

    for title in HAND_WRITTEN_SECTIONS:
        group(title, hand_written_section(title, hand))
    for package in packages:
        files = texts.get(package)
        if not files:
            raise NoticeError(f"{package}: linked but the license tree has no text for it")
        body = "\n\n".join(f"{label}:\n\n{text.strip()}" for label, text in files)
        if package == "z2d":
            url = next(value["url"] for value in manifest["zig_packages"].values() if value["dependency"] == "z2d")
            body += "\n\n" + Z2D_OFFER.format(url=url, revision=pin["ghostty_revision"])
        group("Ghostty (license, embedded fonts)" if package == GHOSTTY_OWN else f"{package} (in Ghostty)", body)
    group(f"Zig {zig['version']} (compiler_rt and standard library)", zig_text)
    group(
        "Build record",
        f"GhosttyNextKit {pin['url']} sha256 {pin['sha256']}; Ghostty {pin['ghostty_revision']}; "
        f"license tree {len(manifest['license_files'])} files. Generated by scripts/cmux-next/notices/ios_notices.py.",
    )
    return {"StringsTable": "Acknowledgements", "PreferenceSpecifiers": groups}


def pane_bytes(pane: dict) -> bytes:
    return plistlib.dumps(pane, fmt=plistlib.FMT_XML, sort_keys=True)


# ---------------------------------------------------------------- checks

def check_repo() -> list[str]:
    pin = ghostty_kit_pin()
    links = json.loads(LINK_SET.read_text())
    errors = []
    if links.get("pin") != pin:
        errors.append(
            f"{LINK_SET.relative_to(ROOT)} is for {links.get('pin', {}).get('sha256', '?')[:12]}, "
            f"CmuxGhosttyKit pins {pin['sha256'][:12]}: on a Mac run `ios_notices.py link-set --xcframework <unzipped "
            "GhosttyNextKit.xcframework>`, then `generate --ghostty-tree <ghostty-next-licenses from "
            "cmux-next-source-archive.yml>`"
        )
    if not PANE.is_file():
        return errors + [f"{PANE.relative_to(ROOT)} is missing"]
    record = plistlib.loads(PANE.read_bytes())["PreferenceSpecifiers"][-1]["FooterText"]
    if pin["sha256"] not in record or pin["ghostty_revision"] not in record:
        errors.append(f"{PANE.relative_to(ROOT)} was generated for another GhosttyNextKit pin; run generate")
    exceptions = json.loads(EXCEPTIONS.read_text())["pins"]
    if links.get("libintl") and pin["sha256"] not in exceptions:
        errors.append("the pinned GhosttyNextKit links LGPL libintl (link-set.json) and the pin has no exception")
    if not links.get("libintl") and pin["sha256"] in exceptions:
        errors.append("the pinned GhosttyNextKit has no libintl; remove its entry from lgpl-exceptions.json")
    for language in LANGUAGES:
        for table in ("Root", "Acknowledgements"):
            if not (SETTINGS / f"{language}.lproj/{table}.strings").is_file():
                errors.append(f"Settings.bundle has no {language}.lproj/{table}.strings")
    return errors


def _read_plist(path: Path) -> dict:
    data = path.read_bytes()
    if data.startswith(b"bplist") or data.lstrip().startswith(b"<?xml"):
        return plistlib.loads(data)
    # Old-style .strings ("key" = "value";): enough to read keys.
    return dict(re.findall(r'"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;', data.decode("utf-16" if data[:2] in (b"\xff\xfe", b"\xfe\xff") else "utf-8")))


def check_app(app: Path) -> list[str]:
    settings = app / "Settings.bundle"
    errors = []
    try:
        root = _read_plist(settings / "Root.plist")
        pane = _read_plist(settings / "Acknowledgements.plist")
    except FileNotFoundError as error:
        return [f"{app.name}: Settings.bundle is incomplete: {error.filename}"]
    if not any(item.get("Type") == "PSChildPaneSpecifier" and item.get("File") == "Acknowledgements" for item in root.get("PreferenceSpecifiers", [])):
        errors.append(f"{app.name}: Settings.bundle/Root.plist has no Acknowledgements pane")
    if pane != plistlib.loads(PANE.read_bytes()):
        errors.append(f"{app.name}: Settings.bundle/Acknowledgements.plist differs from {PANE.relative_to(ROOT)} (old pane)")
    for language in LANGUAGES:
        for table, key in (("Root", "Acknowledgements"), ("Acknowledgements", "INTRO_FOOTER")):
            path = settings / f"{language}.lproj/{table}.strings"
            try:
                if key not in _read_plist(path):
                    errors.append(f"{app.name}: {language}.lproj/{table}.strings has no {key!r}")
            except FileNotFoundError:
                errors.append(f"{app.name}: no {language}.lproj/{table}.strings")
    binaries = [path for path in app.rglob("*") if path.is_file() and path.read_bytes()[:4] in (b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe")]
    errors += libintl_errors(ghostty_kit_pin()["sha256"], binaries)
    return errors


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("link-set")
    p.add_argument("--xcframework", type=Path, required=True)
    p.add_argument("--manifest", type=Path, required=True, help="SOURCE-MANIFEST.json of the ghostty-next license tree")
    p.add_argument("--out", type=Path, default=LINK_SET)
    p = sub.add_parser("generate")
    p.add_argument("--ghostty-tree", type=Path, required=True)
    p.add_argument("--check", action="store_true")
    sub.add_parser("check-repo")
    p = sub.add_parser("check-app")
    p.add_argument("--app", type=Path, required=True)
    p = sub.add_parser("check-binaries")
    p.add_argument("--pin", default=None)
    p.add_argument("paths", nargs="+", type=Path)
    args = parser.parse_args(argv)
    try:
        if args.command == "link-set":
            pin = ghostty_kit_pin()
            result = link_set(args.xcframework, args.manifest)
            previous = json.loads(args.out.read_text()) if args.out.is_file() else {}
            result["pin"] = pin
            result["zig_source_packages"] = previous.get("zig_source_packages", [])
            args.out.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
            print(f"wrote {args.out} ({len(result['dwarf_owners'])} DWARF owners, libintl={result['libintl']})")
            return 0
        if args.command == "generate":
            data = pane_bytes(build_pane(args.ghostty_tree, json.loads(LINK_SET.read_text()), ghostty_kit_pin()))
            if args.check:
                if not PANE.is_file() or PANE.read_bytes() != data:
                    print(f"error: {PANE.relative_to(ROOT)} is stale; run ios_notices.py generate", file=sys.stderr)
                    return 1
                print("iOS Acknowledgements pane is current")
                return 0
            PANE.write_bytes(data)
            print(f"wrote {PANE.relative_to(ROOT)} ({len(data)} bytes)")
            return 0
        if args.command == "check-repo":
            errors = check_repo()
        elif args.command == "check-app":
            errors = check_app(args.app)
        else:
            errors = libintl_errors(args.pin or ghostty_kit_pin()["sha256"], args.paths, ratchet=True)
    except NoticeError as error:
        errors = [str(error)]
    for error in errors:
        print(f"error: {error}", file=sys.stderr)
    if not errors:
        print(f"ios_notices {args.command}: ok")
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
