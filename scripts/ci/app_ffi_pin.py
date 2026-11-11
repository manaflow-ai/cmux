#!/usr/bin/env python3
"""The app FFI pin: Packages/macOS/CmuxNext/app-ffi-pin.json, read and written strictly; no Swift is parsed.

    python3 scripts/ci/app_ffi_pin.py read [app-ffi-pin.json]                 # prints "SOURCE_SHA CHECKSUM"
    python3 scripts/ci/app_ffi_pin.py read-pin-file app-ffi-pin.json Package.swift  # read, then check-manifest
    python3 scripts/ci/app_ffi_pin.py rewrite SHA CHECKSUM [app-ffi-pin.json [Package.swift]]
    python3 scripts/ci/app_ffi_pin.py check-manifest [Package.swift [app-ffi-pin.json]]
    python3 scripts/ci/app_ffi_pin.py check-dump DUMP.json [app-ffi-pin.json]  # `swift package dump-package` output

Leo, 2026-11-07, on the Swift-reading pin match it replaces: "why were you writing a Swift parser in regex in the
first place, right?" The pin now lives in data. Package.swift reads app-ffi-pin.json at manifest time with Foundation
(LOADER below, one fixed block) and its one CCmuxAppFFI binary target takes the url and checksum from it, so every gate
reads the JSON and never Swift:

- app-ffi-pin.json is exactly {"url": URL, "checksum": CHECKSUM} in render()'s format, byte for byte: no other key,
  no other spacing, one trailing newline. The url is this repository's own cmux-app-ffi-<40 hex> release download of
  CCmuxAppFFI.xcframework.zip, the checksum 64 hex;
- Package.swift holds loader(CHECKSUM) exactly once, CHECKSUM being the pin file's: LOADER after one fixed comment
  line, CHECKSUM_LINE + CHECKSUM. SwiftPM caches an evaluated manifest by Package.swift's own text, not by the files
  it reads, so a re-pin that changed only the pin file would leave a reused package path on the old pin; the comment
  makes every re-pin change Package.swift's text too, and is its only change there. It holds no other pin:
  `binaryTarget` occurs once (in LOADER), no `releases/download/`, `xcframework.zip` or `cmux-app-ffi-` anywhere,
  and none of the constructs that can hide a line or carry one over several (`/*`, `*/`, three quotes, `#"`, `#/`,
  `#if`), nor `#sourceLocation`, which would point `#filePath` at another pin file. Every other line that names a
  LOADER symbol has one fixed, anchored shape (OTHER_LINES), none of which can declare or extend one.

Anything else refuses, naming the first thing that does not match. base_red_excuse.py's published-base-pin rule,
scripts/cmux-next/check-app-ffi-pin.sh, the repin picker (scripts/cmux-next/newest_app_ffi_release.py), the repin
script (scripts/cmux-next/repin-app-ffi.sh), the re-pin publisher (scripts/cmux-next/publish-app-ffi-repin.sh), the pin
on the base (scripts/cmux-next/pin-app-ffi-on-base.sh), the router's pure re-pin (scripts/ci/cmux_next_route.py) and the
base autofix's re-pin trigger (scripts/cmux-next/base-autofix-ffi-pin.sh, which compares pin files) all read and
rewrite the pin through this file alone; a rewrite writes the pin file and the comment line together.
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
# The loader block's first line: the pinned checksum again, so the manifest text changes with every pin (above).
CHECKSUM_LINE = "// app-ffi-pin-checksum: "
CHECKSUM_LINE_RE = re.compile(r"^// app-ffi-pin-checksum: ([0-9a-f]{64})$", re.M)


def loader(checksum: str) -> str:
    """The one loader block Package.swift holds for CHECKSUM: its checksum comment line, then LOADER."""
    return f"{CHECKSUM_LINE}{checksum}\n{LOADER}"


IMPORT = "import Foundation"
# `#sourceLocation(file:line:)` would redirect the loader's `#filePath`, so SwiftPM read another pin file than the
# one checked here (review of 0505923b, F1).
FORBIDDEN = ("/*", "*/", '"""', '#"', "#/", "#if", "#sourceLocation")
ABSENT = ("releases/download/", "xcframework.zip", "cmux-app-ffi-")
ONCE = ("binaryTarget", "JSONDecoder", "app-ffi-pin.json\")", "#filePath", "app-ffi-pin-checksum")
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


def rewrite(text: str, manifest: str, sha: str, checksum: str, repo: str = REPO) -> tuple[str, str]:
    """(pin file, Package.swift) for SHA and CHECKSUM, after TEXT (the current pin file) reads as canonical and MANIFEST
    (the current Package.swift) holds its loader; only the checksum comment line of the manifest changes. NotCanonical
    otherwise."""
    if not re.fullmatch(r"[0-9a-f]{40}", sha) or not re.fullmatch(r"[0-9a-f]{64}", checksum):
        raise NotCanonical(f"bad pin {sha!r} {checksum!r}")
    _, old = read(text, repo)
    check_manifest(manifest, old)
    out = render(sha, checksum, repo)
    new_manifest = manifest.replace(f"{CHECKSUM_LINE}{old}\n", f"{CHECKSUM_LINE}{checksum}\n", 1)
    if read(out, repo) != (sha, checksum):
        raise NotCanonical("the rewritten pin does not read back")
    check_manifest(new_manifest, checksum)
    return out, new_manifest


def check_manifest(text: str, checksum: str) -> None:
    """NotCanonical unless TEXT (Package.swift's whole text) holds loader(CHECKSUM) once, CHECKSUM being the pin file's,
    and no pin of its own (above)."""
    for token in FORBIDDEN:
        if token in text:
            line = text[:text.index(token)].count("\n") + 1
            raise NotCanonical(f"Package.swift line {line} has {token!r}, which no canonical manifest has")
    for token in ABSENT:
        if token in text:
            line = text[:text.index(token)].count("\n") + 1
            raise NotCanonical(f"Package.swift line {line} has {token!r}: the pin lives in {PIN_FILE} only")
    found = CHECKSUM_LINE_RE.findall(text)
    if len(found) != 1:
        raise NotCanonical(f"Package.swift has {len(found)} {CHECKSUM_LINE.strip()!r} <64 hex> lines, not one "
                           "(the loader block's first line)")
    if found[0] != checksum:
        raise NotCanonical(f"Package.swift's {CHECKSUM_LINE.strip()} {found[0]} is not {PIN_FILE}'s checksum "
                           f"{checksum}: a re-pin rewrites both (scripts/cmux-next/repin-app-ffi.sh)")
    block = loader(checksum)
    if text.count(block) != 1:
        raise NotCanonical(f"Package.swift does not hold the one fixed {PIN_FILE} loader block exactly once "
                           f"({text.count(block)} copies; scripts/ci/app_ffi_pin.py loader())")
    for token in ONCE:
        if text.count(token) != 1:
            raise NotCanonical(f"Package.swift has {text.count(token)} {token!r}, not one (the loader's)")
    lines = text.split("\n")
    if IMPORT not in lines:
        raise NotCanonical(f"Package.swift has no {IMPORT!r} line for the loader")
    start = text[:text.index(block)].count("\n")
    end = start + block.count("\n")
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


# The template form a head that predates app-ffi-pin.json still has (2026-11-07, review of 6bc829a2): Package.swift's own
# canonical CCmuxAppFFI block, read by the fail-closed match this file used before the pin moved to data. Only
# base_red_excuse.py reads it, for a PR whose head has no app-ffi-pin.json, until no open PR is in that form.
TEMPLATE_ONCE = ("binaryTarget", "releases/download/", "xcframework.zip", "checksum:")
TEMPLATE_OTHER_LINES = (
    re.compile(r"^\s*//[^\n]*$"),  # a whole-line comment
    re.compile(rf'^\s+"{TARGET}",?$'),  # an element of a multi-line dependencies list
    re.compile(r"^\s+appFFI,?$"),  # the target in the package's target list
    re.compile(r"^\s+\] \+ \[appFFI\],?$"),  # the target list's end, the target appended
    re.compile(rf"^\s+dependencies: \[{ELEMENT}(?:, {ELEMENT})*\],?$"),  # a one-line dependencies list
)


def template_block(repo: str = REPO) -> tuple[re.Pattern[str], ...]:
    """The template form's canonical block, anchored: the url's release sha and the checksum are its only groups."""
    return (
        re.compile(r"^let appFFI: Target = \.binaryTarget\($"),
        re.compile(rf'^    name: "{TARGET}",$'),
        re.compile(r'^    url: "https://github\.com/' + re.escape(repo)
                   + rf'/releases/download/cmux-app-ffi-([0-9a-f]{{40}})/{TARGET}\.xcframework\.zip",$'),
        re.compile(r'^    checksum: "([0-9a-f]{64})"$'),
        re.compile(r"^\)$"),
    )


def read_template(text: str, repo: str = REPO) -> tuple[str, str]:
    """(source sha, checksum) of TEXT, a template-form Package.swift's whole text: no hiding construct anywhere, each
    TEMPLATE_ONCE token once, the canonical block line for line, and every other CCmuxAppFFI or appFFI line one of
    TEMPLATE_OTHER_LINES. Anything else raises NotCanonical."""
    for token in FORBIDDEN:
        if token in text:
            line = text[:text.index(token)].count("\n") + 1
            raise NotCanonical(f"Package.swift line {line} has {token!r}, which no canonical pin file has")
    for token in TEMPLATE_ONCE:
        if text.count(token) != 1:
            raise NotCanonical(f"Package.swift has {text.count(token)} {token!r}, not one")
    lines = text.split("\n")
    start = next(i for i, line in enumerate(lines) if "binaryTarget" in line)
    block, found = template_block(repo), []
    for offset, pattern in enumerate(block):
        line = lines[start + offset] if start + offset < len(lines) else ""
        match = pattern.fullmatch(line)
        if not match:
            raise NotCanonical(f"Package.swift line {start + offset + 1} is not the canonical {TARGET} pin line "
                               f"{pattern.pattern!r}: {line[:160]!r}")
        found.extend(match.groups())
    for index, line in enumerate(lines):
        if start <= index < start + len(block) or (TARGET not in line and "appFFI" not in line):
            continue
        if not any(pattern.fullmatch(line) for pattern in TEMPLATE_OTHER_LINES):
            raise NotCanonical(f"Package.swift line {index + 1} names {TARGET} or appFFI outside the canonical pin and its "
                               f"fixed reference shapes: {line[:160]!r}")
    return found[0], found[1]


def main(argv: list[str]) -> int:
    try:
        if argv[:1] == ["read"] and len(argv) <= 2:
            path = Path(argv[1]) if len(argv) == 2 else PACKAGE / "app-ffi-pin.json"
            print(*read(path.read_text(encoding="utf-8")))
            return 0
        if argv[:1] == ["read-pin-file"] and len(argv) == 3:
            # A tree's pin as every gate takes it: the pin file read strictly, and Package.swift holding its loader.
            sha, checksum = read(Path(argv[1]).read_text(encoding="utf-8"))
            check_manifest(Path(argv[2]).read_text(encoding="utf-8"), checksum)
            print(sha, checksum)
            return 0
        if argv[:1] == ["rewrite"] and len(argv) in (3, 4, 5):
            path = Path(argv[3]) if len(argv) >= 4 else PACKAGE / "app-ffi-pin.json"
            manifest = Path(argv[4]) if len(argv) == 5 else path.with_name("Package.swift")
            pin_text, manifest_text = rewrite(path.read_text(encoding="utf-8"), manifest.read_text(encoding="utf-8"),
                                              argv[1], argv[2])
            path.write_text(pin_text, encoding="utf-8")
            manifest.write_text(manifest_text, encoding="utf-8")
            return 0
        if argv[:1] == ["check-dump"] and len(argv) in (2, 3):
            path = Path(argv[2]) if len(argv) == 3 else PACKAGE / "app-ffi-pin.json"
            print(*check_dump(Path(argv[1]).read_text(encoding="utf-8"), path.read_text(encoding="utf-8")))
            return 0
        if argv[:1] == ["check-manifest"] and len(argv) <= 3:
            path = Path(argv[1]) if len(argv) >= 2 else PACKAGE / "Package.swift"
            pin = Path(argv[2]) if len(argv) == 3 else path.with_name("app-ffi-pin.json")
            check_manifest(path.read_text(encoding="utf-8"), read(pin.read_text(encoding="utf-8"))[1])
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
