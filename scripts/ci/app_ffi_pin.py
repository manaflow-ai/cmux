#!/usr/bin/env python3
"""The app FFI pin: Packages/macOS/CmuxNext/app-ffi-pin.json, read and written strictly; no Swift is parsed.

    python3 scripts/ci/app_ffi_pin.py read [app-ffi-pin.json]                 # prints "SOURCE_SHA CHECKSUM"
    python3 scripts/ci/app_ffi_pin.py rewrite SHA CHECKSUM [app-ffi-pin.json]
    python3 scripts/ci/app_ffi_pin.py check-manifest [Package.swift]
    python3 scripts/ci/app_ffi_pin.py check-dump DUMP.json [app-ffi-pin.json]  # `swift package dump-package` output

Leo, 2026-11-07, on the Swift-reading pin match it replaces: "why were you writing a Swift parser in regex in the
first place, right?" The pin now lives in data. Package.swift reads app-ffi-pin.json at manifest time with Foundation
(LOADER below, one fixed block) and its one CCmuxAppFFI binary target takes the url and checksum from it, so every gate
reads the JSON and never Swift:

- app-ffi-pin.json is exactly {"url": URL, "checksum": CHECKSUM} in render()'s format, byte for byte: no other key,
  no other spacing, one trailing newline. The url is this repository's own cmux-app-ffi-<40 hex> release download of
  CCmuxAppFFI.xcframework.zip, the checksum 64 hex;
- Package.swift holds LOADER exactly once and no pin of its own: `binaryTarget` occurs once (in LOADER), no
  `releases/download/`, `xcframework.zip` or `cmux-app-ffi-` anywhere, and none of the constructs that can hide a
  line or carry one over several (`/*`, `*/`, three quotes, `#"`, `#/`, `#if`). Every other line that names a LOADER
  symbol has one fixed, anchored shape (OTHER_LINES), none of which can declare or extend one.

Anything else refuses, naming the first thing that does not match. base_red_excuse.py's published-base-pin rule,
scripts/cmux-next/check-app-ffi-pin.sh, the repin picker (scripts/cmux-next/newest_app_ffi_release.py) and the repin
script (scripts/cmux-next/repin-app-ffi.sh) all read and rewrite the pin through this file alone.
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

REPO = "manaflow-ai/cmux"
PACKAGE = Path(__file__).resolve().parents[2] / "Packages/macOS/CmuxNext"
PIN_FILE = "Packages/macOS/CmuxNext/app-ffi-pin.json"
MANIFEST_FILE = "Packages/macOS/CmuxNext/Package.swift"
TARGET = "CCmuxAppFFI"
ASSET = f"{TARGET}.xcframework.zip"

# The one block of Package.swift that reads the pin. Fully qualified Foundation names, so nothing else in the
# manifest can stand in for them; any read or decode error stops the manifest with the file's path.
LOADER = '''\
struct AppFFIPin: Decodable {
    let url: String
    let checksum: String
}

let appFFIPin: AppFFIPin = {
    let file = Foundation.URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("app-ffi-pin.json")
    do {
        return try Foundation.JSONDecoder().decode(AppFFIPin.self, from: Foundation.Data(contentsOf: file))
    } catch {
        fatalError("Packages/macOS/CmuxNext/app-ffi-pin.json: cannot read the CCmuxAppFFI pin (\\(file.path)): \\(error)")
    }
}()

let appFFI: Target = .binaryTarget(
    name: "CCmuxAppFFI",
    url: appFFIPin.url,
    checksum: appFFIPin.checksum
)
'''
IMPORT = "import Foundation"
FORBIDDEN = ("/*", "*/", '"""', '#"', "#/", "#if")
ABSENT = ("releases/download/", "xcframework.zip", "cmux-app-ffi-")
ONCE = ("binaryTarget", "JSONDecoder", "app-ffi-pin.json\")", "#filePath")
# A line outside LOADER that names one of these must be one of OTHER_LINES.
WATCHED = re.compile(r"CCmuxAppFFI|appFFI|AppFFIPin|\bFoundation\b|JSONDecoder")
NAME = r"[A-Za-z0-9_]+"
ELEMENT = rf'(?:"{NAME}"|\.product\(name: "{NAME}", package: "{NAME}"\))'
OTHER_LINES = (
    re.compile(r"^\s*//[^\n]*$"),  # a whole-line comment
    re.compile(r"^import Foundation$"),  # the loader's import
    re.compile(rf'^\s+"{TARGET}",?$'),  # an element of a multi-line dependencies list
    re.compile(r"^\s+appFFI,?$"),  # the target in the package's target list
    re.compile(r"^\s+\] \+ \[appFFI\],?$"),  # the target list's end, the target appended
    re.compile(rf"^\s+dependencies: \[{ELEMENT}(?:, {ELEMENT})*\],?$"),  # a one-line dependencies list
)


class NotCanonical(ValueError):
    """The pin file or Package.swift's loader is not canonical: the reason names what fails."""


def url_pattern(repo: str = REPO) -> re.Pattern[str]:
    return re.compile(r"https://github\.com/" + re.escape(repo) + rf"/releases/download/cmux-app-ffi-([0-9a-f]{{40}})/"
                      + re.escape(ASSET))


def render(sha: str, checksum: str, repo: str = REPO) -> str:
    """The pin file's one accepted text for SHA and CHECKSUM."""
    url = f"https://github.com/{repo}/releases/download/cmux-app-ffi-{sha}/{ASSET}"
    return json.dumps({"url": url, "checksum": checksum}) + "\n"


def read(text: str, repo: str = REPO) -> tuple[str, str]:
    """(source sha, checksum) of TEXT, app-ffi-pin.json's whole text; NotCanonical unless it is render()'s."""
    def unique(pairs):
        keys = [key for key, _ in pairs]
        if len(keys) != len(set(keys)):
            raise NotCanonical(f"{PIN_FILE} repeats a key: {keys}")
        return dict(pairs)
    try:
        pin = json.loads(text, object_pairs_hook=unique)
    except NotCanonical:
        raise
    except ValueError as error:
        raise NotCanonical(f"{PIN_FILE} is not JSON: {error}") from error
    if not isinstance(pin, dict) or list(pin) != ["url", "checksum"]:
        raise NotCanonical(f"{PIN_FILE} must be exactly {{\"url\": ..., \"checksum\": ...}}, got "
                           f"{list(pin) if isinstance(pin, dict) else type(pin).__name__}")
    url, checksum = pin["url"], pin["checksum"]
    match = url_pattern(repo).fullmatch(url) if isinstance(url, str) else None
    if not match:
        raise NotCanonical(f"{PIN_FILE} url is not {repo}'s own cmux-app-ffi-<40 hex> release download of {ASSET}: "
                           f"{str(url)[:160]!r}")
    if not (isinstance(checksum, str) and re.fullmatch(r"[0-9a-f]{64}", checksum)):
        raise NotCanonical(f"{PIN_FILE} checksum is not 64 lowercase hex: {str(checksum)[:80]!r}")
    if text != render(match.group(1), checksum, repo):
        raise NotCanonical(f"{PIN_FILE} is not in its one format (one line, {render.__name__}() of its values, "
                           "a trailing newline)")
    return match.group(1), checksum


def rewrite(text: str, sha: str, checksum: str, repo: str = REPO) -> str:
    """The pin file for SHA and CHECKSUM, after TEXT (the current one) reads as canonical; NotCanonical otherwise."""
    if not re.fullmatch(r"[0-9a-f]{40}", sha) or not re.fullmatch(r"[0-9a-f]{64}", checksum):
        raise NotCanonical(f"bad pin {sha!r} {checksum!r}")
    read(text, repo)
    out = render(sha, checksum, repo)
    if read(out, repo) != (sha, checksum):
        raise NotCanonical("the rewritten pin does not read back")
    return out


def check_manifest(text: str) -> None:
    """NotCanonical unless TEXT (Package.swift's whole text) holds LOADER once and no pin of its own (above)."""
    for token in FORBIDDEN:
        if token in text:
            line = text[:text.index(token)].count("\n") + 1
            raise NotCanonical(f"Package.swift line {line} has {token!r}, which no canonical manifest has")
    for token in ABSENT:
        if token in text:
            line = text[:text.index(token)].count("\n") + 1
            raise NotCanonical(f"Package.swift line {line} has {token!r}: the pin lives in {PIN_FILE} only")
    if text.count(LOADER) != 1:
        raise NotCanonical(f"Package.swift does not hold the one fixed {PIN_FILE} loader block exactly once "
                           f"({text.count(LOADER)} copies; scripts/ci/app_ffi_pin.py LOADER)")
    for token in ONCE:
        if text.count(token) != 1:
            raise NotCanonical(f"Package.swift has {text.count(token)} {token!r}, not one (the loader's)")
    lines = text.split("\n")
    if IMPORT not in lines:
        raise NotCanonical(f"Package.swift has no {IMPORT!r} line for the loader")
    start = text[:text.index(LOADER)].count("\n")
    end = start + LOADER.count("\n")
    for index, line in enumerate(lines):
        if start <= index < end or not WATCHED.search(line):
            continue
        if not any(pattern.fullmatch(line) for pattern in OTHER_LINES):
            raise NotCanonical(f"Package.swift line {index + 1} names a pin loader symbol outside the loader and its "
                               f"fixed reference shapes: {line[:160]!r}")


def check_dump(dump: str, pin_text: str, repo: str = REPO) -> tuple[str, str]:
    """(source sha, checksum) when DUMP (`swift package dump-package`'s JSON) has exactly one CCmuxAppFFI target, a
    binary one whose url and checksum are the pin file's (PIN_TEXT): SwiftPM evaluated the loader to this pin."""
    sha, checksum = read(pin_text, repo)
    try:
        targets = json.loads(dump)["targets"]
    except (ValueError, KeyError, TypeError) as error:
        raise NotCanonical(f"the dump-package output has no targets list: {error}") from error
    found = [t for t in targets if isinstance(t, dict) and t.get("name") == TARGET]
    if len(found) != 1:
        raise NotCanonical(f"the evaluated manifest has {len(found)} {TARGET} targets, not one")
    target, url = found[0], json.loads(render(sha, checksum, repo))["url"]
    if (target.get("type"), target.get("url"), target.get("checksum")) != ("binary", url, checksum):
        raise NotCanonical(f"the evaluated manifest pins {TARGET} to {target.get('url')!r} {target.get('checksum')!r} "
                           f"({target.get('type')}), not {PIN_FILE}'s {url!r} {checksum!r}")
    return sha, checksum


def main(argv: list[str]) -> int:
    try:
        if argv[:1] == ["read"] and len(argv) <= 2:
            path = Path(argv[1]) if len(argv) == 2 else PACKAGE / "app-ffi-pin.json"
            print(*read(path.read_text(encoding="utf-8")))
            return 0
        if argv[:1] == ["rewrite"] and len(argv) in (3, 4):
            path = Path(argv[3]) if len(argv) == 4 else PACKAGE / "app-ffi-pin.json"
            path.write_text(rewrite(path.read_text(encoding="utf-8"), argv[1], argv[2]), encoding="utf-8")
            return 0
        if argv[:1] == ["check-dump"] and len(argv) in (2, 3):
            path = Path(argv[2]) if len(argv) == 3 else PACKAGE / "app-ffi-pin.json"
            print(*check_dump(Path(argv[1]).read_text(encoding="utf-8"), path.read_text(encoding="utf-8")))
            return 0
        if argv[:1] == ["check-manifest"] and len(argv) <= 2:
            path = Path(argv[1]) if len(argv) == 2 else PACKAGE / "Package.swift"
            check_manifest(path.read_text(encoding="utf-8"))
            return 0
    except NotCanonical as why:
        print(f"error: {why}", file=sys.stderr)
        return 1
    except OSError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    print(__doc__.split("\n\n")[1], file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
