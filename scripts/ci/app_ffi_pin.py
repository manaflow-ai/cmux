#!/usr/bin/env python3
"""The app FFI pin of Packages/macOS/CmuxNext/Package.swift, read by one fail-closed canonical match.

    python3 scripts/ci/app_ffi_pin.py read [Package.swift]               # prints "SOURCE_SHA CHECKSUM"
    python3 scripts/ci/app_ffi_pin.py read-pin-file app-ffi-pin.json Package.swift   # the JSON pin, same output
    python3 scripts/ci/app_ffi_pin.py rewrite SHA CHECKSUM [Package.swift]
    python3 scripts/ci/app_ffi_pin.py inputs ROOT CRATE_DIR...          # the files of those crates the FFI build reads

No Swift is parsed (2026-11-07: five lexer holes in a row, so the reader stopped lexing). The whole file is read as raw
text, and nothing in it is skipped, comments and strings included:

- none of the constructs that can hide a line from the compiler or carry one over several lines appears anywhere: a
  block comment (`/*`, `*/`), a multiline string (three quotes), a raw string or extended regex (`#"`, `#/`), or a
  conditional compilation block (`#if`). With none of them, every line is code or a whole-line `//` comment, and a
  string or a bare regex ends on its own line;
- `binaryTarget`, `releases/download/`, `xcframework.zip` and `checksum:` each occur exactly once, all of them in the
  CANONICAL block below, which must match line for line (anchored, its text and indentation fixed). Only the release
  sha of its url (this repository's own cmux-app-ffi-<sha> release download) and its 64-hex checksum vary;
- every other line that names CCmuxAppFFI or appFFI has one fixed, anchored shape (OTHER_LINES): a whole-line `//`
  comment, a target list element, or a dependencies list of plain names and products. None of those can declare a
  target, so the canonical block is the only CCmuxAppFFI declaration in the file.

Anything else refuses, naming the first line that does not match. base_red_excuse.py's published-base-pin rule, the
repin picker (scripts/cmux-next/newest_app_ffi_release.py) and the repin script (scripts/cmux-next/repin-app-ffi.sh)
all read and rewrite the pin through this file alone.
"""
from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path

REPO = "manaflow-ai/cmux"
MANIFEST = Path(__file__).resolve().parents[2] / "Packages/macOS/CmuxNext/Package.swift"
TARGET = "CCmuxAppFFI"
FORBIDDEN = ("/*", "*/", '"""', '#"', "#/", "#if")
ONCE = ("binaryTarget", "releases/download/", "xcframework.zip", "checksum:")
NAME = r"[A-Za-z0-9_]+"
ELEMENT = rf'(?:"{NAME}"|\.product\(name: "{NAME}", package: "{NAME}"\))'
OTHER_LINES = (
    re.compile(r"^\s*//[^\n]*$"),  # a whole-line comment
    re.compile(rf'^\s+"{TARGET}",?$'),  # an element of a multi-line dependencies list
    re.compile(r"^\s+appFFI,?$"),  # the target in the package's target list
    re.compile(r"^\s+\] \+ \[appFFI\],?$"),  # the target list's end, the target appended
    re.compile(rf"^\s+dependencies: \[{ELEMENT}(?:, {ELEMENT})*\],?$"),  # a one-line dependencies list
)


def canonical(repo: str = REPO) -> tuple[re.Pattern[str], ...]:
    """The canonical block's lines, anchored: the url's release sha and the checksum are its only groups."""
    return (
        re.compile(r"^let appFFI: Target = \.binaryTarget\($"),
        re.compile(rf'^    name: "{TARGET}",$'),
        re.compile(r'^    url: "https://github\.com/' + re.escape(repo)
                   + rf'/releases/download/cmux-app-ffi-([0-9a-f]{{40}})/{TARGET}\.xcframework\.zip",$'),
        re.compile(r'^    checksum: "([0-9a-f]{64})"$'),
        re.compile(r"^\)$"),
    )


class NotCanonical(ValueError):
    """Package.swift's app FFI pin is not the canonical block: the reason names the first line that fails."""


def read(text: str, repo: str = REPO) -> tuple[str, str, int]:
    """(source sha, checksum, the canonical block's first line index) of TEXT, Package.swift's whole text."""
    for token in FORBIDDEN:
        if token in text:
            line = text[:text.index(token)].count("\n") + 1
            raise NotCanonical(f"Package.swift line {line} has {token!r}, which no canonical pin file has")
    for token in ONCE:
        if text.count(token) != 1:
            raise NotCanonical(f"Package.swift has {text.count(token)} {token!r}, not one")
    lines = text.split("\n")
    start = next(i for i, line in enumerate(lines) if "binaryTarget" in line)
    block, found = canonical(repo), []
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
        if not any(pattern.fullmatch(line) for pattern in OTHER_LINES):
            raise NotCanonical(f"Package.swift line {index + 1} names {TARGET} or appFFI outside the canonical pin and its "
                               f"fixed reference shapes: {line[:160]!r}")
    return found[0], found[1], start


def rewrite(text: str, sha: str, checksum: str, repo: str = REPO) -> str:
    """TEXT with only the canonical block's release sha and checksum replaced; NotCanonical before or after."""
    if not re.fullmatch(r"[0-9a-f]{40}", sha) or not re.fullmatch(r"[0-9a-f]{64}", checksum):
        raise NotCanonical(f"bad pin {sha!r} {checksum!r}")
    old_sha, old_checksum, start = read(text, repo)
    lines = text.split("\n")
    lines[start + 2] = lines[start + 2].replace(f"cmux-app-ffi-{old_sha}/", f"cmux-app-ffi-{sha}/")
    lines[start + 3] = lines[start + 3].replace(f'"{old_checksum}"', f'"{checksum}"')
    out = "\n".join(lines)
    if read(out, repo)[:2] != (sha, checksum):
        raise NotCanonical("the rewritten pin does not read back")
    return out


# The JSON pin (cmux#37645, 2026-11-07), read here before it lands so that feat-cmux-next's classifier
# (base_red_excuse.py, which always runs from the base) can read a head in either form: app-ffi-pin.json beside
# Package.swift, which reads it through one fixed loader block whose first line repeats the checksum (SwiftPM caches
# the evaluated manifest by Package.swift's text). Byte for byte the rules of cmux#37645's app_ffi_pin.py read and
# check_manifest, under names that leave the template reader above as it is; cmux#37645 replaces both.
PIN_FILE = "Packages/macOS/CmuxNext/app-ffi-pin.json"
ASSET = f"{TARGET}.xcframework.zip"

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
PIN_ABSENT = ("releases/download/", "xcframework.zip", "cmux-app-ffi-")
PIN_ONCE = ("binaryTarget", "JSONDecoder", "app-ffi-pin.json\")", "#filePath", "app-ffi-pin-checksum")
# A line outside the loader block that names one of these must be one of PIN_OTHER_LINES.
PIN_WATCHED = re.compile(r"CCmuxAppFFI|appFFI|AppFFIPin|\bFoundation\b|JSONDecoder")
PIN_OTHER_LINES = (
    re.compile(r"^\s*//[^\n]*$"),  # a whole-line comment
    re.compile(r"^import Foundation$"),  # the loader's import
    re.compile(rf'^\s+"{TARGET}",?$'),  # an element of a multi-line dependencies list
    re.compile(r"^\s+appFFI,?$"),  # the target in the package's target list
    re.compile(r"^\s+\] \+ \[appFFI\],?$"),  # the target list's end, the target appended
    re.compile(rf"^\s+dependencies: \[{ELEMENT}(?:, {ELEMENT})*\],?$"),  # a one-line dependencies list
)


def pin_url_pattern(repo: str = REPO) -> re.Pattern[str]:
    return re.compile(r"https://github\.com/" + re.escape(repo) + rf"/releases/download/cmux-app-ffi-([0-9a-f]{{40}})/"
                      + re.escape(ASSET))


def render_pin_file(sha: str, checksum: str, repo: str = REPO) -> str:
    """The pin file's one accepted text for SHA and CHECKSUM."""
    url = f"https://github.com/{repo}/releases/download/cmux-app-ffi-{sha}/{ASSET}"
    return json.dumps({"url": url, "checksum": checksum}) + "\n"


def read_pin_file(text: str, repo: str = REPO) -> tuple[str, str]:
    """(source sha, checksum) of TEXT, app-ffi-pin.json's whole text; NotCanonical unless it is render_pin_file()'s."""
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
    match = pin_url_pattern(repo).fullmatch(url) if isinstance(url, str) else None
    if not match:
        raise NotCanonical(f"{PIN_FILE} url is not {repo}'s own cmux-app-ffi-<40 hex> release download of {ASSET}: "
                           f"{str(url)[:160]!r}")
    if not (isinstance(checksum, str) and re.fullmatch(r"[0-9a-f]{64}", checksum)):
        raise NotCanonical(f"{PIN_FILE} checksum is not 64 lowercase hex: {str(checksum)[:80]!r}")
    if text != render_pin_file(match.group(1), checksum, repo):
        raise NotCanonical(f"{PIN_FILE} is not in its one format (one line, render_pin_file() of its values, "
                           "a trailing newline)")
    return match.group(1), checksum


def check_loader(text: str, checksum: str) -> None:
    """NotCanonical unless TEXT (Package.swift's whole text) holds loader(CHECKSUM) once, CHECKSUM being the pin file's,
    and no pin of its own (above)."""
    for token in FORBIDDEN:
        if token in text:
            line = text[:text.index(token)].count("\n") + 1
            raise NotCanonical(f"Package.swift line {line} has {token!r}, which no canonical manifest has")
    for token in PIN_ABSENT:
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
    for token in PIN_ONCE:
        if text.count(token) != 1:
            raise NotCanonical(f"Package.swift has {text.count(token)} {token!r}, not one (the loader's)")
    lines = text.split("\n")
    if IMPORT not in lines:
        raise NotCanonical(f"Package.swift has no {IMPORT!r} line for the loader")
    start = text[:text.index(block)].count("\n")
    end = start + block.count("\n")
    for index, line in enumerate(lines):
        if start <= index < end or not PIN_WATCHED.search(line):
            continue
        if not any(pattern.fullmatch(line) for pattern in PIN_OTHER_LINES):
            raise NotCanonical(f"Package.swift line {index + 1} names a pin loader symbol outside the loader and its "
                               f"fixed reference shapes: {line[:160]!r}")


# What `cargo build --release` of cmux-app-ffi reads in each crate it reaches, and what build-app-ffi.sh copies: the
# manifest, the lock file, the build script and its support modules, the library sources, the C headers, and every file
# a non-test source or build script names (inputs() below). Tests, benches, examples, scripts, READMEs and a file only
# they read are not built into the archive, so a change to them leaves the pin current (2026-11-09: #39027 changed
# cmux-tui/bindings/rust/.cmux-resource-api.json, which only tests/catalog_manifest.rs reads, and staled the pin).
CRATE_INPUTS = ("Cargo.toml", "Cargo.lock", "build.rs", "build-support", "src", "include")
INCLUDE = re.compile(r'\binclude(?:_str|_bytes)?!\s*\(\s*"([^"\\]+)"\s*\)')
INCLUDE_ANY = re.compile(r'\binclude(?:_str|_bytes)?!\s*\(\s*(?!")([^)]*)')
PATH_ATTR = re.compile(r'#\[path\s*=\s*"([^"\\]+)"\]')
BUILD_READ = re.compile(r'(?:rerun-if-changed=([^"{}]+)"|(?:read_to_string|fs::read|File::open)\(\s*"([^"\\]+)"\s*\))')
MANIFEST_PATH = re.compile(r'^\s*(?:path|build)\s*=\s*"([^"\\]+\.rs)"', re.M)
MOD_DECL = re.compile(r'^\s*(?:pub(?:\([^)]*\))?\s+)?mod\s+(r#)?(\w+)\s*;', re.M)
CFG_TEST = re.compile(r'#\[cfg\(\s*(?:all\(\s*)?test\b')


class Unresolved(ValueError):
    """A non-test source names a file that is not a string literal: the inputs cannot be known, so the check refuses."""


def _declarations(files: list[Path]) -> dict[Path, list[tuple[Path, bool]]]:
    """For each module file, the files that declare it (`mod NAME;`) and whether that declaration is #[cfg(test)]."""
    found: dict[Path, list[tuple[Path, bool]]] = {}
    for file in files:
        lines = file.read_text(encoding="utf-8", errors="replace").split("\n")
        for index, line in enumerate(lines):
            match = MOD_DECL.match(line)
            if not match:
                continue
            attrs, back = [], index - 1
            while back >= 0 and lines[back].strip().startswith("#["):
                attrs.append(lines[back].strip())
                back -= 1
            name = match.group(2)
            paths = [PATH_ATTR.search(attr) for attr in attrs]
            given = next((m.group(1) for m in paths if m), None)
            if given is not None:
                targets = [file.parent / given]
            elif file.name in ("lib.rs", "main.rs", "mod.rs", "build.rs"):
                targets = [file.parent / f"{name}.rs", file.parent / name / "mod.rs"]
            else:
                targets = [file.parent / file.stem / f"{name}.rs", file.parent / file.stem / name / "mod.rs"]
            test = any(CFG_TEST.match(attr) for attr in attrs)
            for target in targets:
                found.setdefault(Path(os.path.normpath(target)), []).append((file, test))
    return found


def _test_only(files: list[Path]) -> set[Path]:
    """The files compiled only under cfg(test): every declaration of them is #[cfg(test)] or sits in such a file. A file
    no source declares (a crate root, or one compiled nowhere) is not test-only, so a missed declaration only adds."""
    declared = _declarations(files)
    test: set[Path] = set()
    changed = True
    while changed:
        changed = False
        for file in files:
            uses = declared.get(Path(os.path.normpath(file)))
            if file in test or not uses:
                continue
            if all(is_test or by in test for by, is_test in uses):
                test.add(file)
                changed = True
    return test


def inputs(root: Path, crates: list[str]) -> list[str]:
    """The repository paths (files, or directories as prefixes) the FFI build reads in CRATES, relative to ROOT: each
    crate's CRATE_INPUTS, plus every file outside them that a non-test source, a build script or the manifest names.
    Raises Unresolved when a non-test source includes a file by a computed path (OUT_DIR, the build's own output, aside).
    """
    root = Path(os.path.normpath(root))
    found: set[str] = set()

    def add(path: Path) -> None:
        path = Path(os.path.normpath(path))
        if path == root or root not in path.parents:
            return
        found.add(path.relative_to(root).as_posix())

    for crate in crates:
        folder = root / crate
        for name in CRATE_INPUTS:
            found.add(f"{crate}/{name}")
        sources = sorted((folder / "src").rglob("*.rs")) + sorted((folder / "build-support").rglob("*.rs"))
        if (folder / "build.rs").is_file():
            sources.append(folder / "build.rs")
        test = _test_only(sources)
        for source in sources:
            if source in test:
                continue
            text = source.read_text(encoding="utf-8", errors="replace")
            for literal in INCLUDE.findall(text) + PATH_ATTR.findall(text):
                add(source.parent / literal)
            for computed in INCLUDE_ANY.findall(text):
                if "OUT_DIR" not in computed:
                    raise Unresolved(f"{source.relative_to(root)} includes a file by a computed path ({computed[:80]!r}): "
                                     "name it with a string literal so the app FFI pin knows its inputs")
        if (folder / "build.rs").is_file():
            for changed, read in BUILD_READ.findall((folder / "build.rs").read_text(encoding="utf-8", errors="replace")):
                add(folder / (changed or read).strip())
        if (folder / "Cargo.toml").is_file():
            for literal in MANIFEST_PATH.findall((folder / "Cargo.toml").read_text(encoding="utf-8", errors="replace")):
                add(folder / literal)
    prefixes = [f"{crate}/{name}/" for crate in crates for name in ("src", "build-support", "include")]
    return sorted(path for path in found if not any(path.startswith(prefix) for prefix in prefixes))


def main(argv: list[str]) -> int:
    try:
        if argv[:1] == ["read"] and len(argv) <= 2:
            path = Path(argv[1]) if len(argv) == 2 else MANIFEST
            sha, checksum, _ = read(path.read_text(encoding="utf-8"))
            print(sha, checksum)
            return 0
        if argv[:1] == ["read-pin-file"] and len(argv) == 3:
            # The JSON pin (below): the pin file's values, once Package.swift holds only their loader block.
            sha, checksum = read_pin_file(Path(argv[1]).read_text(encoding="utf-8"))
            check_loader(Path(argv[2]).read_text(encoding="utf-8"), checksum)
            print(sha, checksum)
            return 0
        if argv[:1] == ["inputs"] and len(argv) >= 2:
            print("\n".join(inputs(Path(argv[1]), argv[2:])))
            return 0
        if argv[:1] == ["rewrite"] and len(argv) in (3, 4):
            path = Path(argv[3]) if len(argv) == 4 else MANIFEST
            path.write_text(rewrite(path.read_text(encoding="utf-8"), argv[1], argv[2]), encoding="utf-8")
            return 0
    except (NotCanonical, Unresolved) as why:
        print(f"error: {why}", file=sys.stderr)
        return 1
    print(__doc__.split("\n\n")[0], file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
