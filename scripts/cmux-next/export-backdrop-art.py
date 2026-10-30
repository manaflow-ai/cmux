#!/usr/bin/env python3
"""Export cmux-next's backdrop art list to plans/cmux-next/backdrop-art.json (cmux2-0b, chief decision 4).

The Swift in CmuxNextAppearance/Backdrop and CmuxNextDesign is the source of truth; this reads it and writes the JSON, so the
GPUI app and other readers never copy the list by hand. With --check nothing is written; the exit
status says whether the JSON equals what the Swift gives (the cmux-next checks job runs it).

Read from Packages/macOS/CmuxNext/Sources/CmuxNextAppearance/Backdrop (the art's enum, records and
selection, p15-oracle-134) or, for the rest, Packages/macOS/CmuxNext/Sources/CmuxNextDesign:
- BackdropArt.swift: each work's id (its raw value) in catalog order, and its English title;
- BackdropArt+Entries.swift: artist, year, museum, collection, source, license, sha256, bundled, and
  the framing and color hints the app's tint and crop use: focal (the crop's focal anchor, x and y
  in 0...1), subject (the box the window keeps whole and in view, from the top-left, 0...1), tint (the preferred tint opacity), darkest and lightest (the image's range, #RRGGBB);
- BackdropArt+Catalog.swift: the collections in picker order with their titles, and retired ids;
- BackdropArt+DailyRotation.swift: the Shuffle Daily list (BackdropArt.dailyRotation);
- BackdropArtDownloads.swift: the download base (remoteBase), for the full image URL;
- AppleWallpapers.swift: the macOS wallpaper and video sources, which the app lists at run time.

URLs are the ones .github/workflows/cmux-art-publish.yml uploads: the full image is
<remoteBase><sha256>.avif, the thumbnail <remoteBase><sha256 of its .thumb.avif>.avif. Bundled
works also name their files in the app's resources. The bundled art has no light/dark pairs and no
videos: the macOS dynamic wallpapers (light/dark frames) and the video wallpapers are read from the
Mac at run time, so the JSON describes those sources, not entries.
"""
import argparse
import hashlib
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DESIGN = ROOT / "Packages/macOS/CmuxNext/Sources/CmuxNextDesign"
BACKDROP = ROOT / "Packages/macOS/CmuxNext/Sources/CmuxNextAppearance/Backdrop"
# Where the Swift files live; each name is in exactly one of them.
SOURCE_DIRS = (BACKDROP, DESIGN)
RESOURCES = DESIGN / "Resources/BackdropArt"
OUT = ROOT / "plans/cmux-next/backdrop-art.json"
STRING = r'"((?:[^"\\]|\\.)*)"'


def fail(message: str) -> None:
    sys.exit(f"export-backdrop-art: {message}")


def unescape(text: str) -> str:
    return re.sub(r"\\(.)", lambda m: {"n": "\n", "t": "\t"}.get(m.group(1), m.group(1)), text)


def read(name: str) -> str:
    found = [directory / name for directory in SOURCE_DIRS if (directory / name).is_file()]
    if len(found) != 1:
        where = " and ".join(str(d.relative_to(ROOT)) for d in SOURCE_DIRS)
        fail(f"{name}: expected in exactly one of {where}, found {len(found)}")
    return found[0].read_text(encoding="utf-8")


def block(text: str, start: str, name: str) -> str:
    """The text from `start` to the matching closing brace or bracket."""
    at = text.find(start)
    if at < 0:
        fail(f"{name}: no {start!r}")
    opener = start[-1]
    closer = {"{": "}", "[": "]"}[opener]
    depth = 0
    for index in range(at + len(start) - 1, len(text)):
        depth += {opener: 1, closer: -1}.get(text[index], 0)
        if depth == 0:
            return text[at + len(start):index]
    fail(f"{name}: {start!r} is not closed")


def works() -> list[dict]:
    art = read("BackdropArt.swift")
    cases = re.findall(r'^    case (\w+) = ' + STRING + r'$', block(art, "enum BackdropArt: String, CaseIterable, Sendable {", "BackdropArt.swift"), re.M)
    if not cases:
        fail("BackdropArt.swift: no cases")
    titles = dict(re.findall(r'^        case \.(\w+): String\(localized: "backdrop\.[a-z0-9-]+\.title", defaultValue: ' + STRING + r', bundle: \.module\)$', art, re.M))
    entries = {}
    entry_re = re.compile(r'^        case \.(\w+): BackdropArtEntry\(artist: ' + STRING + r', year: ' + STRING + r', museum: ' + STRING
                          + r', collection: \.(\w+), source: ' + STRING + r', license: ' + STRING + r', sha256: "([0-9a-f]{64})", bundled: (true|false), focal: \(([0-9.]+), ([0-9.]+)\), '
                          + r'subject: \(([0-9.]+), ([0-9.]+), ([0-9.]+), ([0-9.]+)\), '
                          + r'tone: \.\w+, palette: \[[^\]]*\], quietLeft: (?:true|false), tint: ([0-9.]+), '
                          + r'darkest: 0x([0-9A-F]{6}), lightest: 0x([0-9A-F]{6})\)$', re.M)
    for (case, artist, year, museum, collection, source, license, sha, bundled,
         focal_x, focal_y, sub_x0, sub_y0, sub_x1, sub_y1, tint, darkest, lightest) in entry_re.findall(read("BackdropArt+Entries.swift")):
        entries[case] = dict(artist=unescape(artist), year=unescape(year), museum=unescape(museum), collection=collection,
                             source=unescape(source), license=unescape(license), sha256=sha, bundled=bundled == "true",
                             focal={"x": float(focal_x), "y": float(focal_y)},
                             subject={"minX": float(sub_x0), "minY": float(sub_y0), "maxX": float(sub_x1), "maxY": float(sub_y1)}, tint=float(tint),
                             darkest=f"#{darkest}", lightest=f"#{lightest}")
    remote = re.search(r'static let remoteBase = URL\(string: ' + STRING + r'\)', read("BackdropArtDownloads.swift"))
    if not remote:
        fail("BackdropArtDownloads.swift: no remoteBase")
    base = remote.group(1)
    out = []
    for case, slug in cases:
        if case not in titles or case not in entries:
            fail(f"{slug}: no title or entry in the Swift")
        entry = entries[case]
        thumb = RESOURCES / f"{slug}.thumb.avif"
        if not thumb.exists():
            fail(f"{slug}: no {thumb.relative_to(ROOT)}")
        work = {"id": slug, "title": unescape(titles[case]), **{k: entry[k] for k in ("artist", "year", "museum", "collection")},
                "bundled": entry["bundled"],
                **{k: entry[k] for k in ("focal", "subject", "tint", "darkest", "lightest")},
                "thumbnail": {"url": f"{base}{hashlib.sha256(thumb.read_bytes()).hexdigest()}.avif",
                              "resource": str(thumb.relative_to(ROOT))},
                "full": {"url": f"{base}{entry['sha256']}.avif", "sha256": entry["sha256"]},
                "source": entry["source"], "license": entry["license"]}
        if entry["bundled"]:
            full = RESOURCES / f"{slug}.avif"
            if not full.exists():
                fail(f"{slug}: bundled, but no {full.relative_to(ROOT)}")
            work["full"]["resource"] = str(full.relative_to(ROOT))
        out.append(work)
    return out, {case: slug for case, slug in cases}, base


def library(case_ids: dict) -> tuple[list[dict], dict]:
    text = read("BackdropArt+Catalog.swift")
    collection_cases = re.findall(r'^    case (\w+)$', block(text, "enum BackdropArtCollection: String, CaseIterable, Equatable, Sendable {", "BackdropArt+Catalog.swift"), re.M)
    titles = dict(re.findall(r'case \.(\w+): String\(localized: "backdrop\.collection\.\w+", defaultValue: ' + STRING, text))
    if not collection_cases or set(collection_cases) - set(titles):
        fail("BackdropArt+Catalog.swift: collections without titles")
    retired = {}
    for old, case in re.findall(STRING + r': \.(\w+),', block(text, "static let retiredIDs: [String: BackdropArt] = [", "BackdropArt+Catalog.swift")):
        if case not in case_ids:
            fail(f"retired id {old} names an unknown case .{case}")
        retired[unescape(old)] = case_ids[case]
    return [{"id": c, "title": unescape(titles[c])} for c in collection_cases], retired


def daily(case_ids: dict) -> list[str]:
    body = block(read("BackdropArt+DailyRotation.swift"), "static let dailyRotation: [BackdropArt] = [", "BackdropArt+DailyRotation.swift")
    cases = re.findall(r'\.(\w+)', body)
    unknown = [c for c in cases if c not in case_ids]
    if unknown or not cases:
        fail(f"dailyRotation: unknown cases {unknown}")
    return [case_ids[c] for c in cases]


def video_extensions(apple_text: str) -> list[str]:
    """The movie types: listed in AppleWallpapers.swift, or forwarded from the type that lists them
    (`static var videoExtensions: Set<String> { BackdropUserImages.videoExtensions }`)."""
    literal = r'static let videoExtensions: Set<String> = \[([^\]]*)\]'
    name, text = "AppleWallpapers.swift", apple_text
    forward = re.search(r'static var videoExtensions: Set<String> \{ (\w+)\.videoExtensions \}', text)
    if forward:
        name = f"{forward.group(1)}.swift"
        text = read(name)
    found = re.search(literal, text)
    if not found:
        fail(f"{name}: no videoExtensions")
    return sorted(re.findall(STRING, found.group(1)))


def apple() -> dict:
    text = read("AppleWallpapers.swift")
    def one(pattern: str, what: str) -> str:
        found = re.search(pattern, text)
        if not found:
            fail(f"AppleWallpapers.swift: no {what}")
        return found.group(1)
    return {
        "note": "Listed from the Mac at run time, not bundled: the picker reads every entry of the desktop pictures folder "
                "(in .orderedPictures.plist order) and the downloaded aerials. A dynamic wallpaper is a light/dark pair "
                "inside one image (its apr, solar or h24 metadata names the light and dark frames, BackdropAppearance.swift).",
        "collection": one(r'static let collection = ' + STRING, "collection"),
        "videoCollection": one(r'static let videoCollection = ' + STRING, "videoCollection"),
        "videoExtensions": video_extensions(text),
        "aerialsFolder": one(r'static let systemAerials = URL\(fileURLWithPath: ' + STRING, "systemAerials"),
    }


def render() -> str:
    art, case_ids, base = works()
    collections, retired = library(case_ids)
    known = {c["id"] for c in collections}
    for work in art:
        if work["collection"] not in known:
            fail(f"{work['id']}: unknown collection {work['collection']}")
    document = {
        "generated_by": "scripts/cmux-next/export-backdrop-art.py from the CmuxNextDesign Swift; do not edit",
        "remote": base,
        "collections": collections,
        "works": art,
        "dailyRotation": daily(case_ids),
        "retiredIds": retired,
        "appleWallpapers": apple(),
    }
    return json.dumps(document, ensure_ascii=False, indent=1) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--check", action="store_true", help="write nothing; fail when the JSON differs from the Swift")
    args = parser.parse_args()
    text = render()
    current = OUT.read_text(encoding="utf-8") if OUT.exists() else None
    if args.check:
        if current != text:
            print(f"{OUT.relative_to(ROOT)} differs from the Swift backdrop art list; run scripts/cmux-next/export-backdrop-art.py", file=sys.stderr)
            return 1
        print(f"{OUT.relative_to(ROOT)} is current")
        return 0
    if current != text:
        OUT.write_text(text, encoding="utf-8")
    print(f"wrote {OUT.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
