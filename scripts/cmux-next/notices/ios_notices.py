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
      --check (CI, macOS runner) compares with the committed file instead and
      writes the generated one to --out (also for macos-link-set).
  ios_notices.py app-link --xcframework DIR --artifact ZIP --job ID --source-commit SHA --ghostty-source DIR
      (a Mac) The real link: the device archive app of a cmux-ci iOS job (symbols
      intact) against the pinned xcframework's members. Writes "app_link" into
      link-set.json: a DWARF owner is ABSENT only when every archive member that
      carries it defines symbols and the app defines none of them (positive
      evidence); otherwise it stays listed. Zig code keeps no symbol names, so a
      Zig-source package is absent only by a pinned build-graph fact (zig_js: a
      wasm32-only import; iterm2_themes: a resource directory that the app does not
      contain). Reproduce: `cmux-ci artifact <job> app.zip` and rerun.
  ios_notices.py generate --ghostty-tree DIR [--check]
      Writes ios/cmux/Settings.bundle/Acknowledgements.plist from link-set.json, the
      collected ghostty-next license tree (collect-ghostty-licenses.py, CI only:
      cmux-next-source-archive.yml), hand-written.md sections and Zig's LICENSE.
      --check fails when the committed pane differs.
  ios_notices.py macos-link-set --xcframework DIR --manifest FILE
      (a Mac) ghosttykit-macos-link-set.json: the DWARF owners of the macos slice
      that the macOS cmux-next app links (Contents/MacOS/cmux).
  ios_notices.py check-macos --ghostty-tree DIR
      Every package of the macOS link set has a license text in the ghostty-next
      tree at the pin's revision (the tree that nightly-next bundles).
  ios_notices.py check-repo
      No network, no tree: the link set, the pane and the libintl rule all name
      the CmuxGhosttyKit pin of Package.swift. A new pin stops here until
      link-set and generate run for it.
  ios_notices.py check-app --app cmux.app
      The built app: Settings.bundle has the Acknowledgements pane (en and ja
      strings) and its Acknowledgements.plist equals the committed one; the app
      binaries pass the libintl rule; and no package that the pane omits as absent
      (app_link) is in the app: none of its symbols, no libintl marker, no themes.
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
import tempfile
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
DATA = HERE / "ios"
LINK_SET = DATA / "link-set.json"
# The macOS cmux-next app links the macos slice into Contents/MacOS/cmux and ships the
# ghostty-next license tree (nightly.yml); like vt-link-graph.json for libghostty-vt.
MACOS_LINK_SET = HERE / "ghosttykit-macos-link-set.json"
MACOS_SLICE = "macos-arm64_x86_64"
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

# The FreeType License (docs/FTL.TXT, section 3) asks binary redistributions to cite the
# FreeType Project in their documentation, with the year of the FreeType version in use.
# Keyed by the sha256 of the package's LICENSE.TXT: a new FreeType needs a reviewed entry.
FREETYPE_YEARS = {
    # deps.files.ghostty.org/freetype-1220b81f6ecf...tar.gz = FreeType 2.13.2 (Copyright 1996-2023)
    "2e3bbb7d7c5c396368dd0853a790ec29ce5b8647163dde42a0493fb0d6556b2b": ("2.13.2", 2023),
}
# GhosttyNextKit's Termio inlines std.math.cbrt (Zig: "Ported from musl") into
# terminal.color.LAB.fromRgb; the macOS and iOS apps link it (machine-code match in
# nightly-next 3728109721001 and cmux-ci job a9f238cb599baeb9b17f8ff4). Both carry musl's COPYRIGHT:
# the pane from the reviewed file, THIRD_PARTY_LICENSES.md from the hand-written section.
PACKAGE_NOTICES = ROOT / "cmux-tui/dist/notices/package-notices.json"
MUSL_TITLE = "musl (in the Zig standard library)"
MUSL_INTRO = (
    "GhosttyNextKit (Ghostty's terminal library in this app) contains code from the Zig standard library "
    "that Zig ported from musl: std.math.cbrt (musl src/math/cbrtf.c and src/math/cbrt.c), which Ghostty's "
    "terminal I/O uses to generate its 256-color palette. musl is licensed under the MIT license. The text "
    "below is the COPYRIGHT file of musl 1.2.5 (https://musl.libc.org/releases/musl-1.2.5.tar.gz), the musl "
    "release that Zig 0.16.0 bundles."
)
FTL_CREDIT = """This software is based in part on the work of the FreeType Team (FreeType {version}, \
https://freetype.org). Portions of this software are copyright \u00a9 {year} The FreeType Project \
(www.freetype.org).  All rights reserved."""


class NoticeError(Exception):
    pass


def ghostty_kit_pin(path: Path = GHOSTTY_KIT, text: str | None = None) -> dict:
    text = path.read_text() if text is None else text
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


def macos_link_set(xcframework: Path, manifest: Path) -> dict:
    """The DWARF owners of the macos slice (a universal archive: both architectures)."""
    archive = xcframework / MACOS_SLICE / "libghostty-internal.a"
    sources = subprocess.run(
        ["xcrun", "llvm-dwarfdump", "--show-sources", str(archive)], check=True, capture_output=True, text=True
    ).stdout.splitlines()
    tree = json.loads(manifest.read_text())
    names = {key: value["dependency"] for key, value in tree["zig_packages"].items()}
    return {
        "schema": 1,
        "slice": MACOS_SLICE,
        "pin": ghostty_kit_pin(),
        "dwarf_owners": sorted({owner for line in sources if (owner := attribute(line.strip(), names))}),
        "libintl": contains_libintl(archive),
        # Zig code keeps no package-level DWARF: the same conservative list as iOS.
        "zig_source_packages": json.loads(LINK_SET.read_text())["zig_source_packages"],
    }


def macos_link_errors(links: dict) -> list[str]:
    pin = ghostty_kit_pin()
    if links.get("pin") != pin or links.get("slice") != MACOS_SLICE:
        return [
            f"{MACOS_LINK_SET.relative_to(ROOT)} is for {links.get('pin', {}).get('sha256', '?')[:12]}, CmuxGhosttyKit "
            f"pins {pin['sha256'][:12]}: commit it from the ghosttykit-link-sets artifact of "
            "cmux-next-source-archive.yml (or on a Mac run `ios_notices.py macos-link-set --xcframework <unzipped "
            "GhosttyNextKit.xcframework> --manifest <ghostty-next-licenses/SOURCE-MANIFEST.json>`)"
        ]
    return []


def check_macos(tree: Path, links: dict, pin: dict) -> list[str]:
    """Every package that the macos slice links has a license in the ghostty-next tree at the pin."""
    manifest = json.loads((tree / "SOURCE-MANIFEST.json").read_text())
    if manifest["ghostty_revision"] != pin["ghostty_revision"]:
        return [f"license tree is for Ghostty {manifest['ghostty_revision'][:11]}, the GhosttyNextKit pin is {pin['ghostty_revision'][:11]}"]
    try:
        packages = linked_packages({"dwarf_owners": links["dwarf_owners"], "zig_source_packages": links["zig_source_packages"]}, manifest)
        texts = _tree_texts(tree, manifest, set(packages))
    except NoticeError as error:
        return [f"macOS GhosttyNextKit: {error}"]
    return [f"macOS GhosttyNextKit links {package} but the license tree has no text for it" for package in packages if package not in texts]


# ---------------------------------------------------------------- app link (the real link)

APP_IN_ARTIFACT = "cmux-ios.xcarchive/Products/Applications/cmux.app"
MACHO_MAGIC = (b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe")
# Zig-source packages that a pinned build-graph fact excludes from the iOS app.
# (package, the only file that may name it, text that its enclosing `if` must hold
# or None, and whether the package is a resource directory that the app must not hold.)
ZIG_ABSENT_RULES = (
    ("zig_js", "src/build/SharedDeps.zig", "cpu.arch == .wasm32", False),
    ("iterm2_themes", "src/build/GhosttyResources.zig", None, True),
)


def archive_members(path: Path):
    """(name, bytes) of each member of a BSD ar archive, in order (names may repeat)."""
    data = path.read_bytes()
    if data[:8] != b"!<arch>\n":
        raise NoticeError(f"{path}: not an ar archive")
    offset = 8
    while offset < len(data):
        header = data[offset : offset + 60]
        name, size = header[:16].decode().strip(), int(header[48:58])
        body = data[offset + 60 : offset + 60 + size]
        offset += 60 + size + (size & 1)
        if name.startswith("#1/"):
            length = int(name[3:])
            name, body = body[:length].rstrip(b"\0").decode(), body[length:]
        if not name.startswith("__.SYMDEF"):
            yield name, body


def defined_symbols(path: Path) -> set[str]:
    """Names of the symbols that a Mach-O file (or object) defines, local ones included."""
    result = subprocess.run(["nm", "-U", "-j", str(path)], capture_output=True, text=True)
    if result.returncode != 0:
        raise NoticeError(f"nm failed for {path}: {result.stderr.strip()}")
    return {name for name in result.stdout.split() if name.startswith("_")}


def member_evidence(archive: Path, names: dict[str, str]) -> list[dict]:
    """Per archive member: the DWARF owners of all its source files and its defined symbols."""
    members = []
    with tempfile.TemporaryDirectory() as tmp:
        for index, (name, body) in enumerate(archive_members(archive)):
            path = Path(tmp) / f"{index}.o"
            path.write_bytes(body)
            sources = subprocess.run(
                ["xcrun", "llvm-dwarfdump", "--show-sources", str(path)], check=True, capture_output=True, text=True
            ).stdout.split()
            owners = sorted({owner for line in sources if (owner := attribute(line, names))})
            members.append({"name": name, "owners": owners, "symbols": defined_symbols(path)})
    return members


def decide_owners(members: list[dict], app_symbols: set[str]) -> tuple[dict, dict]:
    """(absent, present) DWARF owners. Absent needs positive evidence: every member that
    carries the owner defines symbols, and the app defines none of them. An owner with a
    member that defines no symbol (nothing to look for) stays present."""
    by_owner: dict[str, list[dict]] = {}
    for member in members:
        for owner in member["owners"]:
            by_owner.setdefault(owner, []).append(member)
    absent, present = {}, {}
    for owner, carriers in sorted(by_owner.items()):
        symbols = set().union(*(member["symbols"] for member in carriers))
        found = symbols & app_symbols
        if found or any(not member["symbols"] for member in carriers):
            present[owner] = len(found)
        else:
            absent[owner] = {"members": sorted({member["name"] for member in carriers}), "symbols": sorted(symbols)}
    return absent, present


def zig_absent_reason(source: Path, package: str, only_file: str, guard: str | None, resource: bool, app_files: list[str]) -> str | None:
    """Why a Zig-source package cannot be in the iOS app, or None (keep it listed)."""
    pattern = re.compile(rf'(?:lazyDependency|dependency)\("{re.escape(package)}"')
    uses = []
    for path in sorted(source.rglob("*.zig")):
        relative = path.relative_to(source).as_posix()
        if relative.startswith(("zig-pkg/", ".zig-cache/", "zig-out/")):
            continue
        lines = path.read_text(errors="replace").splitlines()
        uses += [(relative, lines, index) for index, line in enumerate(lines) if pattern.search(line)]
    if not uses or any(relative != only_file for relative, _, _ in uses):
        return None
    if guard is not None:
        for _, lines, index in uses:
            indent = len(lines[index]) - len(lines[index].lstrip())
            # The block that holds the use: the nearest earlier non-blank line indented less.
            enclosing = next((line for line in reversed(lines[:index]) if line.strip() and len(line) - len(line.lstrip()) < indent), "")
            if not (enclosing.strip().startswith("if (") and guard in enclosing):
                return None
        return f"{only_file} adds it only under `{guard}`; the iOS slice is arm64"
    if resource:
        if any("/themes/" in f"/{name}" for name in app_files):
            return None
        return f"only {only_file} names it (an installed resource directory, not code); the app holds no themes file"
    return None


def app_link(xcframework: Path, artifact: Path, job: str, source_commit: str, ghostty_source: Path, manifest: Path) -> dict:
    pin = ghostty_kit_pin()
    shown = subprocess.run(
        ["git", "-C", str(ROOT), "show", f"{source_commit}:{GHOSTTY_KIT.relative_to(ROOT).as_posix()}"],
        check=True, capture_output=True, text=True,
    ).stdout
    if ghostty_kit_pin(text=shown) != pin:
        raise NoticeError(f"job source {source_commit[:11]} pins another GhosttyNextKit than {pin['sha256'][:12]}")
    revision = subprocess.run(["git", "-C", str(ghostty_source), "rev-parse", "HEAD"], check=True, capture_output=True, text=True).stdout.strip()
    if revision != pin["ghostty_revision"]:
        raise NoticeError(f"--ghostty-source is at {revision[:11]}, the pin is Ghostty {pin['ghostty_revision'][:11]}")
    tree = json.loads(manifest.read_text())
    names = {key: value["dependency"] for key, value in tree["zig_packages"].items()}
    with tempfile.TemporaryDirectory() as tmp, zipfile.ZipFile(artifact) as archive:
        app_files = [name[len(APP_IN_ARTIFACT) + 1 :] for name in archive.namelist() if name.startswith(APP_IN_ARTIFACT + "/") and not name.endswith("/")]
        if not app_files:
            raise NoticeError(f"{artifact}: no {APP_IN_ARTIFACT} (the device archive app)")
        binaries, app_symbols, markers = {}, set(), []
        for name in app_files:
            data = archive.read(f"{APP_IN_ARTIFACT}/{name}")
            if data[:4] not in MACHO_MAGIC:
                continue
            path = Path(tmp) / f"{len(binaries)}.bin"
            path.write_bytes(data)
            binaries[name] = hashlib.sha256(data).hexdigest()
            app_symbols |= defined_symbols(path)
            if contains_libintl(path):
                markers.append(name)
    members = member_evidence(xcframework / SLICE / "libghostty-internal.a", names)
    absent, present = decide_owners(members, app_symbols)
    if not any(present.values()):
        raise NoticeError("the app defines no symbol of the GhosttyNextKit archive: symbols are stripped, no evidence")
    gettext = {"zig-package:gettext", "vendored:pkg/libintl"}
    if markers and gettext & set(absent):
        raise NoticeError(f"libintl symbols are gone but its marker strings are in {markers}: keep gettext")
    zig_absent = {}
    for package, only_file, guard, resource in ZIG_ABSENT_RULES:
        reason = zig_absent_reason(ghostty_source, package, only_file, guard, resource, app_files)
        if reason:
            zig_absent[package] = reason
    witnesses = []  # one symbol per present owner that the app defines: proves the symbols are intact
    for owner, count in present.items():
        if count:
            owned = set().union(*(member["symbols"] for member in members if owner in member["owners"]))
            witnesses.append(min(owned & app_symbols))
    return {
        "pin_sha256": pin["sha256"],
        "evidence": {
            "cmux_ci_job": job,
            "artifact_sha256": hashlib.sha256(artifact.read_bytes()).hexdigest(),
            "source_commit": source_commit,
            "app": APP_IN_ARTIFACT,
            "binaries": binaries,
        },
        "absent_owners": absent,
        "present_owners": present,
        "absent_zig_packages": zig_absent,
        "witness_symbols": sorted(set(witnesses)),
    }


def app_link_errors(binaries: list[Path], app_files: list[str], links: dict) -> list[str]:
    """The built app does not contain a package that the pane omits as absent."""
    record = links.get("app_link")
    if not record:
        return ["link-set.json has no app_link (run ios_notices.py app-link)"]
    symbols: set[str] = set()
    for path in binaries:
        symbols |= defined_symbols(path)
    if not symbols & set(record["witness_symbols"]):
        return ["the app binaries define no GhosttyNextKit witness symbol (stripped?): cannot show that omitted packages are absent"]
    errors = []
    job = record["evidence"]["cmux_ci_job"]
    for owner, info in record["absent_owners"].items():
        found = sorted(symbols & set(info["symbols"]))
        if found:
            errors.append(
                f"{owner} is omitted from the pane (absent in cmux-ci job {job}) but the app defines {found[:3]}: "
                "rerun ios_notices.py app-link on a new iOS job, then generate"
            )
    if {"zig-package:gettext", "vendored:pkg/libintl"} & set(record["absent_owners"]):
        marked = [str(path) for path in binaries if contains_libintl(path)]
        if marked:
            errors.append(f"gettext (libintl) is omitted from the pane but {marked} contain libintl")
    if "iterm2_themes" in record["absent_zig_packages"] and any("/themes/" in f"/{name}" for name in app_files):
        errors.append("iterm2_themes is omitted from the pane but the app holds a themes file")
    return errors


def merge_link_set(generated: dict, previous: dict, pin: dict) -> dict:
    """A generated link set plus the hand-kept fields of the committed one."""
    result = dict(generated, pin=pin)
    result["zig_source_packages"] = previous.get("zig_source_packages", [])
    if "app_link" in previous and previous["app_link"].get("pin_sha256") == pin["sha256"]:
        result["app_link"] = previous["app_link"]
    return result


def link_set_differences(generated: dict, committed: dict) -> list[str]:
    return sorted(key for key in set(generated) | set(committed) if generated.get(key) != committed.get(key))


def write_or_check(result: dict, committed_path: Path, out: Path, check: bool) -> int:
    """Write the link set, or (--check) compare it with the committed file and write it to out."""
    text = json.dumps(result, indent=2, sort_keys=True) + "\n"
    if not check:
        out.write_text(text)
        print(f"wrote {out}")
        return 0
    committed = json.loads(committed_path.read_text()) if committed_path.is_file() else {}
    differences = link_set_differences(result, committed)
    if out != committed_path:
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(text)
    if differences:
        print(
            f"error: {committed_path.relative_to(ROOT)} differs from the pinned xcframework in {differences}; "
            f"commit the generated file ({out}; the workflow uploads it)",
            file=sys.stderr,
        )
        return 1
    print(f"{committed_path.relative_to(ROOT)} matches the pinned xcframework")
    return 0


# ---------------------------------------------------------------- pane

def musl_text() -> str:
    entry = json.loads(PACKAGE_NOTICES.read_text())["musl"]
    data = (PACKAGE_NOTICES.parent / entry["file"]).read_bytes()
    if hashlib.sha256(data).hexdigest() != entry["sha256"]:
        raise NoticeError(f"{entry['file']}: sha256 differs from package-notices.json")
    return data.decode()


def mac_notice_errors(hand: str | None = None) -> list[str]:
    """The macOS app's hand-written notices carry what GhosttyNextKit's macos slice needs
    beyond the license tree: musl's COPYRIGHT (std.math.cbrt)."""
    hand = HAND_WRITTEN.read_text() if hand is None else hand
    try:
        section = hand_written_section(MUSL_TITLE, hand)
    except NoticeError as error:
        return [str(error)]
    if MUSL_INTRO not in section or f"```text\n{musl_text().rstrip(chr(10))}\n```" not in section:
        return [
            f"hand-written.md section {MUSL_TITLE!r} must hold MUSL_INTRO and, in a text block, the reviewed musl "
            "COPYRIGHT (cmux-tui/dist/notices/package-notices.json musl) unchanged"
        ]
    return []


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
    # app_link (the real link of a cmux-ci device archive) removes only what it proves absent.
    record = links.get("app_link", {})
    absent_owners = set(record.get("absent_owners", {}))
    for owner in links["dwarf_owners"]:
        if owner in absent_owners:
            continue
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
    names |= set(links["zig_source_packages"]) - set(record.get("absent_zig_packages", {}))
    unknown = sorted(names - declared - vendored_in_tree - {GHOSTTY_OWN})
    if unknown:
        raise NoticeError(f"linked packages without a collected license: {unknown}")
    return sorted(names)


def link_record(links: dict) -> str:
    record = links.get("app_link")
    if not record:
        return ""
    evidence = record["evidence"]
    omitted = sorted({owner.partition(":")[2] for owner in record["absent_owners"]} | set(record["absent_zig_packages"]))
    return (
        f"Omitted as absent from the linked app ({', '.join(omitted)}): cmux-ci job {evidence['cmux_ci_job']}, "
        f"artifact sha256 {evidence['artifact_sha256']}. "
    )


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
        if package == "freetype":
            license_text = next((text for label, text in files if label.endswith("LICENSE.TXT")), None)
            digest = hashlib.sha256(license_text.encode()).hexdigest() if license_text is not None else None
            if digest not in FREETYPE_YEARS:
                raise NoticeError(
                    f"freetype: LICENSE.TXT sha256 {digest} is not in FREETYPE_YEARS; review the FreeType version "
                    "and add its year for the FTL credit"
                )
            version, year = FREETYPE_YEARS[digest]
            body += "\n\n" + FTL_CREDIT.format(version=version, year=year)
        if package == "z2d":
            url = next(value["url"] for value in manifest["zig_packages"].values() if value["dependency"] == "z2d")
            body += "\n\n" + Z2D_OFFER.format(url=url, revision=pin["ghostty_revision"])
        group("Ghostty (license, embedded fonts)" if package == GHOSTTY_OWN else f"{package} (in Ghostty)", body)
    group(f"Zig {zig['version']} (compiler_rt and standard library)", zig_text)
    group(MUSL_TITLE, MUSL_INTRO + "\n\n" + musl_text())
    group(
        "Build record",
        f"GhosttyNextKit {pin['url']} sha256 {pin['sha256']}; Ghostty {pin['ghostty_revision']}; "
        f"license tree {len(manifest['license_files'])} files. " + link_record(links) + "Generated by scripts/cmux-next/notices/ios_notices.py.",
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
            f"CmuxGhosttyKit pins {pin['sha256'][:12]}: commit link-set.json from the ghosttykit-link-sets artifact "
            "of cmux-next-source-archive.yml (or on a Mac run `ios_notices.py link-set --xcframework <unzipped "
            "GhosttyNextKit.xcframework> --manifest <ghostty-next-licenses/SOURCE-MANIFEST.json>`), then "
            "`generate --ghostty-tree <ghostty-next-licenses from that run>`"
        )
    errors += macos_link_errors(json.loads(MACOS_LINK_SET.read_text())) if MACOS_LINK_SET.is_file() else [f"{MACOS_LINK_SET.relative_to(ROOT)} is missing"]
    errors += mac_notice_errors()
    record = links.get("app_link")
    if not record or record.get("pin_sha256") != pin["sha256"]:
        errors.append(
            f"{LINK_SET.relative_to(ROOT)} has no app_link for pin {pin['sha256'][:12]}: build the iOS app with "
            "cmux-ci, then run `ios_notices.py app-link` on its artifact and `generate`"
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
    files = sorted(path for path in app.rglob("*") if path.is_file())
    binaries = [path for path in files if path.read_bytes()[:4] in MACHO_MAGIC]
    errors += libintl_errors(ghostty_kit_pin()["sha256"], binaries)
    errors += app_link_errors(binaries, [path.relative_to(app).as_posix() for path in files], json.loads(LINK_SET.read_text()))
    return errors


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("link-set")
    p.add_argument("--xcframework", type=Path, required=True)
    p.add_argument("--manifest", type=Path, required=True, help="SOURCE-MANIFEST.json of the ghostty-next license tree")
    p.add_argument("--out", type=Path, default=LINK_SET)
    p.add_argument("--check", action="store_true", help="compare with the committed file; write the generated one to --out")
    p = sub.add_parser("macos-link-set")
    p.add_argument("--xcframework", type=Path, required=True)
    p.add_argument("--manifest", type=Path, required=True, help="SOURCE-MANIFEST.json of the ghostty-next license tree")
    p.add_argument("--out", type=Path, default=None)
    p.add_argument("--check", action="store_true", help="compare with the committed file; write the generated one to --out")
    p = sub.add_parser("check-macos")
    p.add_argument("--ghostty-tree", type=Path, required=True, help="the ghostty-next license tree (cmux-next-source-archive.yml)")
    p = sub.add_parser("app-link")
    p.add_argument("--xcframework", type=Path, required=True, help="the unzipped pinned GhosttyNextKit.xcframework")
    p.add_argument("--artifact", type=Path, required=True, help="the zip from `cmux-ci artifact <job>` of an iOS build")
    p.add_argument("--job", required=True, help="the cmux-ci job id of that artifact")
    p.add_argument("--source-commit", required=True, help="the cmux commit that the job built")
    p.add_argument("--ghostty-source", type=Path, required=True, help="a ghostty-next checkout at the pin's revision")
    p.add_argument("--manifest", type=Path, required=True, help="SOURCE-MANIFEST.json of the ghostty-next license tree")
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
            previous = json.loads(LINK_SET.read_text()) if LINK_SET.is_file() else {}
            result = merge_link_set(link_set(args.xcframework, args.manifest), previous, ghostty_kit_pin())
            print(f"{len(result['dwarf_owners'])} DWARF owners, libintl={result['libintl']}")
            return write_or_check(result, LINK_SET, args.out, args.check)
        if args.command == "macos-link-set":
            result = macos_link_set(args.xcframework, args.manifest)
            print(f"{len(result['dwarf_owners'])} DWARF owners, libintl={result['libintl']}")
            return write_or_check(result, MACOS_LINK_SET, args.out or MACOS_LINK_SET, args.check)
        if args.command == "app-link":
            links = json.loads(LINK_SET.read_text())
            links["app_link"] = app_link(args.xcframework, args.artifact, args.job, args.source_commit, args.ghostty_source, args.manifest)
            LINK_SET.write_text(json.dumps(links, indent=2, sort_keys=True) + "\n")
            record = links["app_link"]
            print(f"wrote app_link: absent owners {sorted(record['absent_owners'])}, absent Zig packages {sorted(record['absent_zig_packages'])}")
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
        elif args.command == "check-macos":
            links = json.loads(MACOS_LINK_SET.read_text())
            errors = macos_link_errors(links) + check_macos(args.ghostty_tree, links, ghostty_kit_pin())
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
