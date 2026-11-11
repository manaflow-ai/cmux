#!/usr/bin/env python3
"""The app FFI pin of Packages/macOS/CmuxNext/Package.swift, read by one fail-closed canonical match.

    python3 scripts/ci/app_ffi_pin.py read [Package.swift]               # prints "SOURCE_SHA CHECKSUM"
    python3 scripts/ci/app_ffi_pin.py read-pin-file app-ffi-pin.json Package.swift   # the JSON pin, same output
    python3 scripts/ci/app_ffi_pin.py rewrite SHA CHECKSUM [Package.swift]
    python3 scripts/ci/app_ffi_pin.py inputs ROOT [REV...]              # the FFI crates, "--", the input pathspecs
    python3 scripts/ci/app_ffi_pin.py workspace-view WORKSPACE.toml CRATE.toml...   # what the crates inherit of it
    python3 scripts/ci/app_ffi_pin.py own-root CRATE.toml               # "yes" when it has its own [workspace]

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

import bisect
import json
import os
import posixpath
import re
import subprocess
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


# The app FFI inputs, fail-closed (lead decision, 2026-11-10). Three review rounds of a fine scan (include! forms,
# #[path], build-script reads, test-only modules) each found new Rust or TOML forms that hid an input, so the rule no
# longer reads the languages' grammar for what is built:
#
# - Each crate cmux-app-ffi reaches is an input as a whole directory (its git-tracked files), except its own tests/,
#   benches/ and examples/ (cargo builds them only for tests) and the reviewed TEST_ONLY files. Such a directory is not
#   excluded when it holds a walked crate, a reached module or a named path, or when a named directory holds it.
# - Every string literal in a scanned file that names a path, relative to the file (or, in a Rust inline module, to that
#   module's directory) or to its crate, adds that path: a file outside the crate (an include_str! of a spec file, a
#   build script's token table), or one in an excluded directory (then that directory is an input, and its files are
#   scanned). A named directory that holds a Cargo.toml is a crate, and is walked the same way. A named file is scanned
#   too, transitively, by its suffix (Rust, TOML, C; any other suffix: the strings of all three, a name with a '/' or
#   a '.' only). `mod NAME;` is resolved in every scanned Rust file. Escapes are decoded first, and comments are not
#   read, so neither can hide or invent a name.
# - Above the crates: the cargo configs that apply where build-app-ffi.sh builds (ABOVE), scanned like a crate's
#   TOML relative to the directory that holds their .cargo, the toolchain files, build-app-ffi.sh (scanned: its strings
#   and its words with a '/' or a '.') and the release workflow.
# - Paths are resolved through git, never the disk: REV's tree, its exact case, no symlink and no submodule on the way.
#   Every input is a :(literal) pathspec, and a found path that git would read as magic or a glob refuses.
# - What cannot be listed refuses: a symlink, a submodule, another case, an untracked path that exists, a literal
#   naming a package that holds the crate, a TEST_ONLY file named by a source that is not one of its readers, a reader
#   reached by a library module, a manifest the line reader cannot read, and the build-script forms below.
#
# The check lists the inputs at both commits it compares and compares their union, so a path that one side names is an
# input even when the other side does not have it (a file a head deletes, or adds where a literal named a missing path).
#
# What is left: a path computed with no literal that names it in a library source (concat!("../../", NAME) in an
# include); a literal naming a path that is in no tree and not on the disk (a missing path is not refused: most
# literals are no paths at all; once the file is added, the head's list has it); a bare name with no '/' or '.' that git
# has only in another case (a data file's words, "Images", are no paths, so only a name that looks like one refuses);
# and an untracked path on the disk of a commit other than the checked-out HEAD (only HEAD's working tree is read). A
# literal that names a directory holding the scanned file or its crate ("..", "../") is ignored outside TOML: runtime
# name checks spell it in every crate. No FFI crate computes such a path today; the review of a change that does must
# catch it.
EXCLUDED_DIRS = ("tests", "benches", "examples", "target")
SCANNED_SUFFIXES = {".rs": "rust", ".toml": "toml", ".c": "c", ".h": "c", ".cc": "c", ".cpp": "c", ".hpp": "c",
                    ".m": "c", ".mm": "c"}
# Each test-only file and the only sources that may name it (all of them test code). A change to the file cannot change
# the archive. Another scanned file that names it refuses, so a library source cannot start to read it unnoticed; and a
# reader must stay test code: a `mod` that reaches it without #[cfg(test)], or a scanned file other than a reader that
# names it (include!), refuses.
TEST_ONLY = {
    # #39027 changed it and staled the pin on 2026-11-09.
    "cmux-tui/bindings/rust/.cmux-resource-api.json": ("cmux-tui/bindings/rust/tests/catalog_manifest.rs",),
    "Packages/macOS/CmuxNext/Tests/CmuxNextSidebarTests/Fixtures/sidebar-layout-cases.json":
        ("cmux-tui/crates/cmux-layout-reducer/src/sidebar_layout_tests.rs",),
    "schemas/remote-tab/client.json": ("cmux-tui/crates/cmux-rd-ffi/src/rb_client_tests.rs",),
}
FFI_ROOT_CRATE = "cmux-tui/crates/cmux-app-ffi"
BUILD_SCRIPT = "scripts/cmux-next/build-app-ffi.sh"
RELEASE_WORKFLOW = ".github/workflows/app-ffi-release.yml"
# The cargo configs cargo reads where build-app-ffi.sh builds (cmux-tui/crates/cmux-app-ffi and each directory above it
# in the repository): their files `config` and `config.toml` are scanned, a path in them relative to the directory that
# holds the .cargo ([patch] and `paths` crates, a rustc-wrapper, a vendored directory).
CARGO_CONFIG_DIRS = (f"{FFI_ROOT_CRATE}/.cargo", "cmux-tui/crates/.cargo", "cmux-tui/.cargo", ".cargo")
# The inputs above the crates: those cargo configs, the toolchain files rustup reads there, the build script (scanned
# like a source, with the directories it builds from as bases) and the release workflow that runs it. A crate's own
# .cargo and toolchain files are in its directory.
TOOLCHAIN_FILES = ("cmux-tui/rust-toolchain", "cmux-tui/rust-toolchain.toml", "cmux-tui/crates/rust-toolchain",
                   "cmux-tui/crates/rust-toolchain.toml", "rust-toolchain", "rust-toolchain.toml")
ABOVE = tuple(d for d in CARGO_CONFIG_DIRS if d != f"{FFI_ROOT_CRATE}/.cargo") + TOOLCHAIN_FILES + (
    BUILD_SCRIPT, RELEASE_WORKFLOW)
BUILD_SCRIPT_BASES = ("", "scripts/cmux-next", "cmux-tui/crates", FFI_ROOT_CRATE)
# A build script computes a path that no literal names when it walks up from its crate (.parent(), .ancestors(), .pop(),
# Path::parent as a function, a '..' literal that names no file), lists a directory (read_dir), globs, or runs a command
# (Command: git rev-parse, a code generator) (lead decision and review round 4 of #40095). So each refuses in a crate's
# build-script files: build.rs (or the file Cargo.toml's `build` names), every .rs file under build-support/, and the
# Rust files they reach (`mod`, #[path], include!). The only exception is a reviewed entry here: the build-script file,
# then what it reaches that way and why. None today: cmux-action-catalog/build.rs, cmux-motion/build.rs and
# cmux-motion/build-support/json.rs use none of them (cmux-motion names design-tokens.json by a '..' literal that names
# that file).
BUILD_SCRIPT_REVIEWED: dict[str, str] = {}
BUILD_SCRIPT_IDENTS = ("parent", "ancestors", "pop", "Command", "read_dir")
# What git reads as pathspec magic or a glob; every pathspec is :(literal) as well (review round 4 of #40095).
PATHSPEC_MAGIC = re.compile(r"^:|[*?\[\\]")


class Unresolved(ValueError):
    """The inputs cannot be known (see above): the check refuses rather than leave a file out."""


def _rust_unescape(body: str) -> str:
    out, index = [], 0
    simple = {"n": "\n", "t": "\t", "r": "\r", "0": "\0", "\\": "\\", "'": "'", '"': '"'}
    while index < len(body):
        char = body[index]
        if char != "\\" or index + 1 >= len(body):
            out.append(char)
            index += 1
            continue
        code = body[index + 1]
        if code in simple:
            out.append(simple[code])
            index += 2
        elif code == "x" and re.fullmatch(r"[0-9A-Fa-f]{2}", body[index + 2:index + 4]):
            out.append(chr(int(body[index + 2:index + 4], 16)))
            index += 4
        elif code == "u" and re.match(r"\{[0-9A-Fa-f]{1,6}\}", body[index + 2:]):
            end = body.index("}", index)
            out.append(chr(min(int(body[index + 3:end], 16), 0x10FFFF)))
            index = end + 1
        elif code == "\n":  # a line continuation drops the newline and the next line's leading whitespace
            index += 2
            while index < len(body) and body[index] in " \t\n\r":
                index += 1
        else:
            out.append(body[index:index + 2])
            index += 2
    return "".join(out)


def _toml_unescape(body: str) -> str:
    def one(match: re.Match) -> str:
        code = match.group(1)
        if code[0] in "uU":
            return chr(min(int(code[1:], 16), 0x10FFFF))
        return {"b": "\b", "t": "\t", "n": "\n", "f": "\f", "r": "\r", '"': '"', "\\": "\\"}.get(code, code)
    return re.sub(r'\\(u[0-9A-Fa-f]{4}|U[0-9A-Fa-f]{8}|.)', one, body, flags=re.S)


RUST_RAW = re.compile(r'(?:br|cr|r)(#*)"')
RUST_CHAR = re.compile(r"'(?:\\(?:u\{[0-9A-Fa-f]+\}|x[0-9A-Fa-f]{2}|.)|[^\\'\n])'")
IDENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")


def _rust_tokens(text: str) -> list[tuple[str, str]]:
    """Rust TEXT as ("str", value) for every string literal (plain, raw, byte and C strings, escapes decoded), ("ident",
    name) and ("punct", char) tokens; comments, chars, lifetimes and numbers skipped."""
    tokens: list[tuple[str, str]] = []
    index, size = 0, len(text)
    while index < size:
        char = text[index]
        if char in " \t\r\n":
            index += 1
        elif text.startswith("//", index):
            index = text.find("\n", index)
            index = size if index < 0 else index
        elif text.startswith("/*", index):
            depth, index = 1, index + 2
            while index < size and depth:
                if text.startswith("/*", index):
                    depth, index = depth + 1, index + 2
                elif text.startswith("*/", index):
                    depth, index = depth - 1, index + 2
                else:
                    index += 1
        elif char in "rbc" and RUST_RAW.match(text, index):
            match = RUST_RAW.match(text, index)
            end = text.find('"' + match.group(1), match.end())
            if end < 0:
                raise Unresolved("a Rust raw string that does not end")
            tokens.append(("str", text[match.end():end]))
            index = end + 1 + len(match.group(1))
        elif char == '"' or (char in "bc" and text.startswith('"', index + 1)):
            start = index + (1 if char == '"' else 2)
            end = start
            while end < size and text[end] != '"':
                end += 2 if text[end] == "\\" else 1
            if end >= size:
                raise Unresolved("a Rust string that does not end")
            tokens.append(("str", _rust_unescape(text[start:end])))
            index = end + 1
        elif char == "b" and text.startswith("'", index + 1) and RUST_CHAR.match(text, index + 1):
            index = RUST_CHAR.match(text, index + 1).end()
        elif char == "'":
            # A char literal ('x', '\n', '\u{2f}', '"') or a lifetime ('a): only a char literal ends with a quote.
            match = RUST_CHAR.match(text, index)
            if match:
                index = match.end()
            else:
                lifetime = IDENT.match(text, index + 1)
                index = lifetime.end() if lifetime else index + 1
        elif text.startswith("r#", index) and IDENT.match(text, index + 2):
            match = IDENT.match(text, index + 2)
            tokens.append(("ident", match.group(0)))
            index = match.end()
        elif char.isalpha() or char == "_":
            match = IDENT.match(text, index)
            tokens.append(("ident", match.group(0)))
            index = match.end()
        elif char.isdigit():
            index = re.compile(r"[0-9][0-9A-Za-z_]*").match(text, index).end()
        else:
            tokens.append(("punct", char))
            index += 1
    return tokens


def _rust_literals(text: str) -> list[str]:
    """The string literals of Rust TEXT, escapes decoded."""
    return [value for kind, value in _rust_tokens(text) if kind == "str"]


class RustItems:
    """What a Rust file declares that the walk reads: its literals (value, the inline modules around it, whether it is
    the #[path] of a module declaration), its `mod NAME;` declarations and its identifiers."""

    def __init__(self, text: str):
        tokens = _rust_tokens(text)
        self.literals: list[list] = []  # [value, chain, is a module's #[path]]
        # (name, chain, #[path] value or None, cfg_attr path values, test-only)
        self.mods: list[tuple[str, tuple[str, ...], str | None, list[str], bool]] = []
        self.idents = [value for kind, value in tokens if kind == "ident"]
        stack: list[tuple[str, bool] | None] = []  # an inline module (name, test-only), or another brace
        attrs: list[tuple[list[tuple[str, str]], list[int]]] = []  # attributes since the last item boundary
        index, size = 0, len(tokens)

        def chain() -> tuple[str, ...]:
            return tuple(entry[0] for entry in stack if entry is not None)

        while index < size:
            kind, value = tokens[index]
            if kind == "str":
                self.literals.append([value, chain(), False])
            elif (kind, value) == ("punct", "#"):
                start = index + 1
                inner = start < size and tokens[start] == ("punct", "!")
                start += inner
                if start < size and tokens[start] == ("punct", "["):
                    depth, end = 0, start
                    while end < size:
                        depth += (tokens[end] == ("punct", "[")) - (tokens[end] == ("punct", "]"))
                        if depth == 0:
                            break
                        end += 1
                    body = tokens[start + 1:end]
                    positions = []
                    for token in body:
                        if token[0] == "str":
                            positions.append(len(self.literals))
                            self.literals.append([token[1], chain(), False])
                    if not inner:
                        attrs.append((body, positions))
                    index = end + 1
                    continue
            elif kind == "punct" and value in ";{}":
                if value == "{":
                    stack.append(None)
                elif value == "}" and stack:
                    stack.pop()
                attrs = []
            elif (kind, value) == ("ident", "mod") and index + 2 < size and tokens[index + 1][0] == "ident" and \
                    tokens[index + 2] in (("punct", ";"), ("punct", "{")):
                name = tokens[index + 1][1]
                test = any(body == [("ident", "cfg"), ("punct", "("), ("ident", "test"), ("punct", ")")]
                           for body, _ in attrs) or any(entry is not None and entry[1] for entry in stack)
                path = None
                conditional = []
                for body, positions in attrs:
                    if len(body) == 3 and body[:2] == [("ident", "path"), ("punct", "=")] and body[2][0] == "str":
                        path = body[2][1]
                        self.literals[positions[0]][2] = True
                    elif body[:1] == [("ident", "cfg_attr")]:
                        conditional += [body[i + 2][1] for i in range(len(body) - 2)
                                        if body[i:i + 2] == [("ident", "path"), ("punct", "=")]
                                        and body[i + 2][0] == "str"]
                if tokens[index + 2] == ("punct", "{"):
                    stack.append((name, test))
                else:
                    self.mods.append((name, chain(), path, conditional, test))
                attrs = []
                index += 3
                continue
            index += 1


def _toml_literals(text: str) -> list[str]:
    """The strings of TOML TEXT (basic, literal and multi-line), escapes decoded; comments skipped."""
    found, index, size = [], 0, len(text)
    while index < size:
        char = text[index]
        if char == "#":
            index = text.find("\n", index)
            index = size if index < 0 else index
        elif text.startswith('"""', index) or text.startswith("'''", index):
            quote = text[index:index + 3]
            end = text.find(quote, index + 3)
            if end < 0:
                raise Unresolved("a TOML multi-line string that does not end")
            body = text[index + 3:end]
            found.append(_toml_unescape(body) if quote == '"""' else body)
            index = end + 3
        elif char in "\"'":
            end = index + 1
            while end < size and text[end] != char and text[end] != "\n":
                end += 2 if (char == '"' and text[end] == "\\") else 1
            if end >= size or text[end] != char:
                raise Unresolved("a TOML string that does not end")
            body = text[index + 1:end]
            found.append(_toml_unescape(body) if char == '"' else body)
            index = end + 1
        else:
            index += 1
    return found


C_RAW = re.compile(r'(?:u8|[uUL])?R"([^()\\\s]{0,16})\(')
C_PREFIX = re.compile(r'(?:u8|[uUL])"')
C_INCLUDE = re.compile(r"#[ \t]*(?:include|include_next|import)[ \t]*<([^>\n]+)>")


def _c_literals(text: str) -> list[str]:
    """The strings and angle-bracket includes of C, C++ or Objective-C TEXT, read left to right in one pass (review
    round 4 of #40095: a regex that strips comments first reads "/*" in a string as a comment): strings, raw strings,
    char literals, both comment forms (a `//` comment continues over a backslash-newline)."""
    found, index, size = [], 0, len(text)
    line_start = True
    while index < size:
        char = text[index]
        if char == "\n":
            line_start, index = True, index + 1
            continue
        if char in " \t\r":
            index += 1
            continue
        at_line_start, line_start = line_start, False
        if at_line_start and char == "#":
            match = C_INCLUDE.match(text, index)
            if match:
                found.append(match.group(1))
                index = match.end()
                continue
            index += 1
        elif text.startswith("//", index):
            while index < size and text[index] != "\n":
                index += 2 if text.startswith("\\\n", index) else 1
        elif text.startswith("/*", index):
            end = text.find("*/", index + 2)
            if end < 0:
                raise Unresolved("a C comment that does not end")
            index = end + 2
        elif C_RAW.match(text, index) and (index == 0 or not (text[index - 1].isalnum() or text[index - 1] == "_")):
            match = C_RAW.match(text, index)
            end = text.find(")" + match.group(1) + '"', match.end())
            if end < 0:
                raise Unresolved("a C++ raw string that does not end")
            found.append(text[match.end():end])
            index = end + 2 + len(match.group(1))
        elif char == '"' or (C_PREFIX.match(text, index) and
                             (index == 0 or not (text[index - 1].isalnum() or text[index - 1] == "_"))):
            start = text.index('"', index) + 1
            end = start
            while end < size and text[end] not in '"\n':
                end += 2 if text[end] == "\\" else 1
            if end >= size or text[end] != '"':
                raise Unresolved("a C string that does not end")
            found.append(_rust_unescape(text[start:end]))
            index = end + 1
        elif char == "'":
            end = index + 1
            while end < size and text[end] not in "'\n":
                end += 2 if text[end] == "\\" else 1
            index = end + 1
        else:
            match = IDENT.match(text, index)
            index = match.end() if match else index + 1
    return found


WORD = re.compile(r"[^\s\"'`,;()\[\]{}<>|&]+")


def _any_literals(text: str) -> list[str]:
    """A file of another kind (a .rs.in include, a data file a build script reads): the strings each scanner finds."""
    found: list[str] = []
    for scanner in (_rust_literals, _toml_literals, _c_literals):
        try:
            found += scanner(text)
        except Unresolved:
            pass
    return found


def _shell_literals(text: str) -> list[str]:
    """A shell script (build-app-ffi.sh): the strings each scanner finds, and every word (a path is often unquoted or
    split by $(...))."""
    return _any_literals(text) + WORD.findall(text)


def _variants(literal: str) -> set[str]:
    """The paths a literal may spell: itself, after an `=` (cargo:rerun-if-changed=PATH), from its first `../`, before a
    `:` (a header:Module pair), without a leading `$VAR/`, and without a leading `/`."""
    found = {literal}
    for _ in range(2):
        for variant in list(found):
            found.add(variant.split("=")[-1])
            found.add(variant.lstrip("/"))
            found.add(variant.split(":")[0])
            if "../" in variant:
                found.add(variant[variant.find("../"):])
            var = re.match(r"\$\{?\w+\}?/?", variant)
            if var:
                found.add(variant[var.end():])
    return {v for v in found if v and not v.startswith("/") and len(v) <= 300 and "\n" not in v and "\0" not in v}


def _join(base: str, path: str) -> str | None:
    """BASE/PATH normalized, relative to the repository ("" is its root), or None outside it."""
    joined = posixpath.normpath(posixpath.join(base, path) if base else path)
    if joined == ".":
        return ""
    if joined == ".." or joined.startswith("../") or joined.startswith("/"):
        return None
    return joined


def _under(path: str, folder: str) -> bool:
    """Whether PATH is FOLDER or inside it ("" is the repository root)."""
    return folder == "" or path == folder or path.startswith(folder + "/")


class Tree:
    """REV's tree in the repository at ROOT, read through git: what a path is (its exact case), and a file's text. DISK:
    the working tree is REV's checkout, so a path that exists there but not in git can be told apart."""

    def __init__(self, root: Path, rev: str, disk: bool):
        self.root, self.rev, self.disk = root, rev, disk
        try:
            listed = subprocess.run(["git", "-C", str(root), "ls-tree", "-r", "-z", "--full-tree", rev], check=True,
                                    capture_output=True).stdout
        except (OSError, subprocess.CalledProcessError) as error:
            raise Unresolved(f"git ls-tree {rev} failed: {error}") from error
        self.modes: dict[str, str] = {}
        self.blobs: dict[str, str] = {}
        self.dirs: set[str] = {""}
        for entry in filter(None, listed.split(b"\0")):
            meta, _, raw = entry.partition(b"\t")
            mode, _, sha = meta.decode().split(" ")
            path = raw.decode("utf-8", "surrogateescape")
            self.modes[path] = mode
            self.blobs[path] = sha
            parts = path.split("/")
            for end in range(1, len(parts)):
                self.dirs.add("/".join(parts[:end]))
        self.sorted = sorted(self.modes)
        self.folded: dict[str, str] = {}
        for path in list(self.modes) + list(self.dirs):
            self.folded.setdefault(path.lower(), path)
        self.texts: dict[str, str] = {}
        self.batch: subprocess.Popen | None = None
        self.others: set[str] | None = None

    def is_file(self, path: str) -> bool:
        return self.modes.get(path) in ("100644", "100755")

    def is_dir(self, path: str) -> bool:
        return path in self.dirs

    def files_under(self, folder: str) -> list[str]:
        """Every entry (file, symlink, submodule) under FOLDER."""
        prefix = folder + "/"
        start = bisect.bisect_left(self.sorted, prefix)
        found = []
        for path in self.sorted[start:]:
            if not path.startswith(prefix):
                break
            found.append(path)
        return found

    def read(self, path: str) -> str:
        """PATH's text at REV (one `git cat-file --batch` for the whole walk)."""
        if path not in self.texts:
            if path not in self.blobs or self.modes[path] not in ("100644", "100755"):
                raise Unresolved(f"{path} at {self.rev} is not a file git can read")
            try:
                if self.batch is None:
                    self.batch = subprocess.Popen(["git", "-C", str(self.root), "cat-file", "--batch"],
                                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE)
                self.batch.stdin.write(self.blobs[path].encode() + b"\n")
                self.batch.stdin.flush()
                header = self.batch.stdout.readline().split()
                if len(header) != 3 or header[1] != b"blob":
                    raise OSError(f"git cat-file answered {header!r}")
                blob = self.batch.stdout.read(int(header[2]))
                self.batch.stdout.read(1)
            except OSError as error:
                raise Unresolved(f"{path} at {self.rev} cannot be read: {error}") from error
            self.texts[path] = blob.decode("utf-8", "replace")
        return self.texts[path]

    def close(self) -> None:
        if self.batch is not None:
            self.batch.stdin.close()
            self.batch.wait()
            self.batch = None

    def kind(self, path: str, why: str, why_literal: str = "") -> str | None:
        """"file", "dir" or None (not in the tree) for PATH, which WHY names (through WHY_LITERAL, when a literal);
        Unresolved for a path git cannot compare as the build reads it."""
        parts = path.split("/") if path else []
        for end in range(1, len(parts) + 1):
            mode = self.modes.get("/".join(parts[:end]))
            if mode == "120000":
                raise Unresolved(f"{why} names {path}, which goes through the symlink {'/'.join(parts[:end])}: the app "
                                 "FFI pin cannot follow what it points to")
            if mode == "160000":
                raise Unresolved(f"{why} names {path}, which is in the submodule {'/'.join(parts[:end])}: git diff does "
                                 "not compare a submodule's files")
        if self.is_file(path):
            found = "file"
        elif self.is_dir(path):
            found = "dir"
        else:
            other = self.folded.get(path.lower())
            # Only a name that looks like a path (a '/' or a '.') refuses: a data file's bare words ("Images") are no
            # paths.
            if other is not None and re.search(r"[/.]", posixpath.basename(why_literal) if why_literal else path):
                raise Unresolved(f"{why} names {path}, which git has only in another case ({other}): a build on a "
                                 "case-insensitive disk reads it, git diff does not")
            if self.disk and self.untracked(path):
                raise Unresolved(f"{why} names {path}, which exists but git does not track: git diff cannot compare it")
            return None
        if PATHSPEC_MAGIC.search(path):
            raise Unresolved(f"{why} names {path}, which starts with ':' or holds a glob character (*?[\\): git would "
                             "read it as pathspec magic")
        return found

    def untracked(self, path: str) -> bool:
        """Whether PATH is a file, or a directory holding a file, on the disk that git neither tracks nor ignores (one
        `git ls-files --others` for the whole walk)."""
        if self.others is None:
            try:
                listed = subprocess.run(["git", "-C", str(self.root), "ls-files", "-z", "--others", "--exclude-standard",
                                         "--full-name", ":/"], check=True, capture_output=True).stdout
            except (OSError, subprocess.CalledProcessError) as error:
                raise Unresolved(f"git ls-files --others failed: {error}") from error
            self.others = set()
            for raw in filter(None, listed.split(b"\0")):
                parts = raw.decode("utf-8", "surrogateescape").rstrip("/").split("/")
                self.others.update("/".join(parts[:end]) for end in range(1, len(parts) + 1))
        return path in self.others


class _Walk:
    """One walk of the FFI inputs in a Tree (walk below)."""

    def __init__(self, tree: Tree, workspace: str):
        self.tree, self.workspace = tree, workspace
        self.crates: list[str] = []
        self.crate_queue: list[str] = []
        self.scan_queue: list[tuple[str, str, tuple[str, ...], str, bool]] = []
        self.scanned: dict[str, bool] = {}  # file -> scanned as a build-script file
        self.named: set[str] = set()
        self.unexcluded: set[str] = set()
        self.reaching: dict[str, list[tuple[str, bool]]] = {}  # module file -> (declaring file, test-only)
        self.namers: dict[str, set[str]] = {}  # file -> the scanned files whose literal names it
        self.readers = {reader: path for path, readers in TEST_ONLY.items() for reader in readers}

    def run(self, start: str) -> tuple[list[str], list[str], list[str]]:
        tree = self.tree
        for path in ABOVE:
            tree.kind(path, "the app FFI build")
        self.crate_queue.append(start)
        for folder in CARGO_CONFIG_DIRS:
            for name in ("config", "config.toml"):
                if tree.kind(f"{folder}/{name}", "the app FFI build") == "file":
                    self.queue(f"{folder}/{name}", "toml", (posixpath.dirname(folder), folder), FFI_ROOT_CRATE, False)
        for path in TOOLCHAIN_FILES:
            if tree.is_file(path):
                self.queue(path, "any", (posixpath.dirname(path),), FFI_ROOT_CRATE, False)
        if tree.is_file(BUILD_SCRIPT):
            self.queue(BUILD_SCRIPT, "shell", BUILD_SCRIPT_BASES, FFI_ROOT_CRATE, False)
        while True:
            while self.crate_queue or self.scan_queue:
                if self.crate_queue:
                    self.walk_crate(self.crate_queue.pop())
                else:
                    self.scan(*self.scan_queue.pop())
            more = self.to_unexclude() - self.unexcluded
            if not more:
                break
            for folder in sorted(more):
                self.unexclude(folder)
        self.check_readers()
        outside = sorted(p for p in self.named if self.crate_of(p) is None)
        includes = sorted(set(self.crates) | set(outside) | set(ABOVE))
        excludes = sorted(self.excluded_tops() - self.unexcluded)
        excludes += sorted(p for p in TEST_ONLY if self.crate_of(p) is not None and tree.is_file(p))
        for path in self.crates + includes + excludes:
            if PATHSPEC_MAGIC.search(path):
                raise Unresolved(f"the input {path} starts with ':' or holds a glob character (*?[\\): git would read "
                                 "it as pathspec magic")
        return sorted(self.crates), includes, excludes

    def crate_of(self, path: str) -> str | None:
        """The innermost walked crate holding PATH."""
        holders = [crate for crate in self.crates if _under(path, crate)]
        return max(holders, key=len) if holders else None

    def excluded_tops(self) -> set[str]:
        return {f"{crate}/{top}" for crate in self.crates for top in EXCLUDED_DIRS
                if self.tree.is_dir(f"{crate}/{top}") and self.crate_of(f"{crate}/{top}") == crate}

    def to_unexclude(self) -> set[str]:
        """The excluded directories that hold a named path or reached module, a walked crate (a path dependency inside
        tests/), or lie inside a named directory."""
        found = set()
        for top in self.excluded_tops():
            if any(_under(path, top) or _under(top, path) for path in self.named) or \
                    any(crate != top.rsplit("/", 1)[0] and _under(crate, top) for crate in self.crates):
                found.add(top)
        return found

    def unexclude(self, folder: str) -> None:
        """FOLDER (an excluded directory) is an input: its files are scanned like the rest of its crate."""
        self.unexcluded.add(folder)
        crate = self.crate_of(folder) or folder
        for file in self.tree.files_under(folder):
            kind = self.kind_of(file, named=False)
            if kind is not None:
                self.queue(file, kind, (posixpath.dirname(file), self.nearest(file, crate)), crate, False)

    def nearest(self, file: str, crate: str) -> str:
        """The nearest directory above FILE that holds a Cargo.toml (CRATE when none does)."""
        folder = posixpath.dirname(file)
        while folder:
            if self.tree.is_file(f"{folder}/Cargo.toml"):
                return folder
            folder = posixpath.dirname(folder)
        return crate

    @staticmethod
    def kind_of(file: str, named: bool) -> str | None:
        """The scanner of FILE by its suffix; a named file of another suffix is read by all of them ("any")."""
        kind = SCANNED_SUFFIXES.get(posixpath.splitext(file)[1])
        if kind is None and file.split("/")[-2:-1] == [".cargo"]:
            kind = "toml"
        if kind is None and named and ".rs." in posixpath.basename(file):
            kind = "rust"  # an include!d gen.rs.in: its `mod` lines and literals are Rust
        return kind or ("any" if named else None)

    def queue(self, file: str, kind: str, bases: tuple[str, ...], crate: str, build: bool) -> None:
        if file in self.scanned and (self.scanned[file] or not build):
            return
        self.scanned[file] = build or self.scanned.get(file, False)
        self.scan_queue.append((file, kind, bases, crate, build))

    def walk_crate(self, crate: str) -> None:
        tree = self.tree
        if crate in self.crates or not tree.is_file(f"{crate}/Cargo.toml"):
            return
        self.crates.append(crate)
        files = tree.files_under(crate)
        for file in files:
            if tree.modes[file] == "120000":
                raise Unresolved(f"{file} is a symlink: the app FFI pin cannot follow what it points to")
        manifest = tree.read(f"{crate}/Cargo.toml")
        entries = _toml_entries(manifest)
        if any(full == ["package", "workspace"] for full, _ in entries):
            raise Unresolved(f"{crate}/Cargo.toml sets package.workspace: the app FFI pin reads only {self.workspace}")
        for path in self.workspace_paths(f"{crate}/Cargo.toml"):
            if tree.kind(path, f"{self.workspace} (inherited by {crate})") == "dir" and \
                    tree.is_file(f"{path}/Cargo.toml"):
                self.crate_queue.append(path)
        build = "build.rs"
        for full, value in entries:
            if full == ["package", "build"]:
                literal = _toml_literals(value)
                build = literal[0] if literal else ("" if value == "false" else "build.rs")
        entry = _join(crate, build) if build else None
        build_files = {entry} if entry else set()
        build_files |= {f for f in files if f.startswith(f"{crate}/build-support/") and f.endswith(".rs")}
        for file in files:
            if file[len(crate) + 1:].split("/", 1)[0] in EXCLUDED_DIRS and file not in build_files:
                continue
            kind = self.kind_of(file, named=file in build_files)
            if kind is not None:
                self.queue(file, kind, (posixpath.dirname(file), self.nearest(file, crate)), crate,
                           file in build_files)

    def workspace_paths(self, manifest: str) -> list[str]:
        """The paths of the [workspace.dependencies] entries MANIFEST inherits, relative to the repository. A crate that
        inherits anything must find the workspace manifest as the nearest one above it, or it refuses."""
        text = self.tree.read(manifest)
        if own_root(text) or inherited(text) == (set(), set(), False):
            return []
        home = posixpath.dirname(self.workspace)
        folder = posixpath.dirname(manifest)
        between = []
        parent = posixpath.dirname(folder)
        while parent != home and _under(parent, home) and parent:
            between.append(parent)
            parent = posixpath.dirname(parent)
        if not _under(folder, home) or folder == home or any(self.tree.is_file(f"{p}/Cargo.toml") for p in between):
            raise Unresolved(f"{manifest} inherits from a workspace other than {self.workspace}")
        workspace = self.tree.read(self.workspace) if self.tree.is_file(self.workspace) else ""
        return [p for p in (_join(home, path) for path in workspace_paths(workspace, text)) if p is not None]

    def scan(self, file: str, kind: str, bases: tuple[str, ...], crate: str, build: bool) -> None:
        tree = self.tree
        text = tree.read(file)
        folder = posixpath.dirname(file)
        stem = posixpath.splitext(posixpath.basename(file))[0]
        if kind == "rust":
            items = RustItems(text)
            literals = [(value, self.chain_bases(folder, stem, chain), mod_path)
                        for value, chain, mod_path in items.literals]
        else:
            items = None
            scanners = {"toml": _toml_literals, "c": _c_literals, "any": _any_literals, "shell": _shell_literals}
            found = scanners[kind](text)
            if kind in ("any", "shell"):
                # A data file's or a script's bare word ("components", "libs") is a key or a variable, not a path: only
                # a name with a '/' or a '.' counts there.
                found = [value for value in found if re.search(r"[/.]", value)]
            literals = [(value, (), False) for value in found]
        reviewed = file in BUILD_SCRIPT_REVIEWED
        if build and items is not None and not reviewed:
            for ident in items.idents:
                if ident in BUILD_SCRIPT_IDENTS:
                    raise Unresolved(f"{file}, a build script file, uses {ident}: it can reach a path no literal names; "
                                     "list it in app_ffi_pin.py BUILD_SCRIPT_REVIEWED with what it reaches, after "
                                     "review")
        for value, extra, mod_path in literals:
            targets = self.resolve(value, bases + extra, file)
            if build and not reviewed:
                variants = _variants(value)
                if any(".." in v.split("/") for v in variants) and not any(t[1] == "file" for t in targets):
                    raise Unresolved(f"{file}, a build script file, has a '..' path component in {value[:80]!r} that "
                                     "names no file: it walks up to a path no literal names")
                if not re.search(r"\s|\{", value) and re.search(r"[*?]", value):
                    raise Unresolved(f"{file}, a build script file, has the glob {value[:80]!r}: it reads paths no "
                                     "literal names")
            for target, target_kind in targets:
                self.name(target, target_kind, file, crate, kind, build, mod_path)
        if items is not None:
            for name, chain, path, conditional, test in items.mods:
                for target in self.module_files(folder, stem, name, chain, path, conditional):
                    self.reaching.setdefault(target, []).append((file, test))
                    self.named.add(target)
                    owner = self.crate_of(target) or crate
                    self.queue(target, "rust", (posixpath.dirname(target), self.nearest(target, owner)), owner, build)

    @staticmethod
    def chain_bases(folder: str, stem: str, chain: tuple[str, ...]) -> tuple[str, ...]:
        """The directories of the inline modules CHAIN in a file FOLDER/STEM.rs, as rustc resolves a #[path] in them (a
        mod.rs-like file: FOLDER/CHAIN; another: FOLDER/STEM/CHAIN)."""
        if not chain:
            return ()
        return (posixpath.join(folder, *chain), posixpath.join(folder, stem, *chain))

    def module_files(self, folder: str, stem: str, name: str, chain: tuple[str, ...], path: str | None,
                     conditional: list[str]) -> list[str]:
        """The existing files `mod NAME;` may load (both the mod.rs-like and the other layout)."""
        homes = [posixpath.join(folder, *chain), posixpath.join(folder, stem, *chain)]
        path_homes = homes if chain else [folder]
        candidates = [_join(home, p) for home in path_homes for p in conditional]
        if path is not None:
            candidates += [_join(home, path) for home in path_homes]
        else:
            candidates += [_join(home, f"{name}.rs") for home in homes]
            candidates += [_join(home, f"{name}/mod.rs") for home in homes]
        found = []
        for candidate in candidates:
            if candidate is not None and candidate not in found and \
                    self.tree.kind(candidate, f"a `mod {name};` of {folder}/{stem}") == "file":
                found.append(candidate)
        return found

    def resolve(self, literal: str, bases: tuple[str, ...], file: str) -> list[tuple[str, str]]:
        """The paths of the tree LITERAL may name relative to BASES, with their kinds ("file" or "dir")."""
        found = []
        for variant in _variants(literal):
            for base in bases:
                path = _join(base, variant)
                if path is None or any(path == p for p, _ in found):
                    continue
                kind = self.tree.kind(path, file, variant)
                if kind is not None:
                    found.append((path, kind))
        return found

    def name(self, target: str, target_kind: str, file: str, crate: str, kind: str, build: bool,
             mod_path: bool) -> None:
        """FILE (scanned as KIND, in CRATE) names TARGET."""
        if target in TEST_ONLY:
            if file not in TEST_ONLY[target]:
                raise Unresolved(f"{file} names {target}, which app_ffi_pin.py TEST_ONLY lists as read only by tests")
            return
        if not mod_path:
            self.namers.setdefault(target, set()).add(file)
        if target_kind == "dir":
            holds_crate = _under(crate, target) and target != crate
            if holds_crate or _under(posixpath.dirname(file), target):
                if kind == "toml" and holds_crate and self.tree.is_file(f"{target}/Cargo.toml" if target else
                                                                         "Cargo.toml"):
                    raise Unresolved(f"{file} names {target or '.'}, a directory that holds this crate and is a package "
                                     "(it holds a Cargo.toml): its files would not be inputs")
                return  # ".." or "../" (a socket name check, a path join): not a file the build reads
            if self.tree.is_file(f"{target}/Cargo.toml"):
                self.crate_queue.append(target)
                return
            self.named.add(target)
            return
        self.named.add(target)
        owner = self.crate_of(target) or crate
        rust_like = target.endswith(".rs") or ".rs." in posixpath.basename(target)
        self.queue(target, self.kind_of(target, named=True), (posixpath.dirname(target), self.nearest(target, owner)),
                   owner, build and rust_like)

    def check_readers(self) -> None:
        """A TEST_ONLY reader stays test code: every `mod` that reaches it is #[cfg(test)], and no scanned file but a
        reader names it."""
        for reader in self.readers:
            for file, test in self.reaching.get(reader, []):
                if not test:
                    raise Unresolved(f"{reader}, a TEST_ONLY reader in app_ffi_pin.py, is reached by a module {file} "
                                     "declares without #[cfg(test)]: the library would read the test-only file")
            for file in sorted(self.namers.get(reader, set())):
                if file not in self.readers:
                    raise Unresolved(f"{file} names {reader}, a TEST_ONLY reader in app_ffi_pin.py: only test code "
                                     "may read it")


def walk(root: Path, rev: str = "HEAD", start: str = FFI_ROOT_CRATE, workspace: str = "cmux-tui/Cargo.toml"
         ) -> tuple[list[str], list[str], list[str]]:
    """(the crates, the input paths, the excluded paths) of the FFI build in REV's tree (above). The working tree is read
    only when REV is HEAD, to refuse a named path that exists but git does not track. Raises Unresolved."""
    tree = Tree(Path(os.path.realpath(root)), rev, disk=rev == "HEAD")
    try:
        return _Walk(tree, workspace).run(start)
    finally:
        tree.close()


def merge(walks: list[tuple[list[str], list[str], list[str]]]) -> tuple[list[str], list[str]]:
    """The union of several walks (the trees a check compares): every crate and input of any of them, and an exclusion
    only where no walk has the path as an input and no input of any walk lies inside it. As pathspecs."""
    crates = sorted({c for crate_list, _, _ in walks for c in crate_list})
    includes = sorted({p for _, paths, _ in walks for p in paths})

    def input_in(path: str, paths: list[str], excludes: list[str]) -> bool:
        return any(_under(path, p) for p in paths) and not any(_under(path, e) for e in excludes)

    excludes = sorted({e for _, _, excluded in walks for e in excluded
                       if not any(input_in(e, paths, excluded_there) for _, paths, excluded_there in walks)
                       and not any(p != e and _under(p, e) for p in includes)})
    return crates, [f":(literal){p}" for p in includes] + [f":(exclude,literal){p}" for p in excludes]


# What the FFI build reads of the cmux-tui workspace manifest (cmux-tui/Cargo.toml). cmux-app-ffi has its own
# [workspace] table, so cargo builds it as its own workspace root: its own [patch], [profile] and Cargo.lock
# (cmux-tui/crates/cmux-app-ffi/Cargo.lock, a crate input, built with --locked) apply, never those of cmux-tui. A crate
# it reaches that has no [workspace] of its own still reads cmux-tui/Cargo.toml, the nearest workspace manifest above
# it, for the keys it inherits: `KEY.workspace = true` under [package] takes [workspace.package] KEY, `NAME = {
# workspace = true, ... }` in a dependency table takes [workspace.dependencies] NAME, and `[lints] workspace = true`
# takes [workspace.lints]. The rest of that manifest (members, other crates' entries, its [patch] and [profile]) cannot
# change the archive, and it changed 55 times on feat-cmux-next in the 14 days to 2026-11-10, so the pin check compares
# only this view (check-app-ffi-pin.sh workspace_view). A dev-dependency is built only for tests, so its entry is not
# in the view; its crate is still followed as an input crate (workspace_paths), as a `path` dev-dependency is.
#
# The manifests are read line by line (_toml_entries), the same on every Python: /usr/bin/python3 on a macOS runner is
# 3.9, which has no tomllib, and a verdict must not depend on the runner. Where tomllib exists (3.11 and later, the
# Linux runners) each answer is also read through it, and a disagreement refuses, so the line reader cannot be wrong
# unnoticed. The view holds each entry's own lines (comments dropped), so a formatting change of an inherited entry
# counts as a change.
DEPENDENCY_TABLES = ("dependencies", "build-dependencies", "dev-dependencies")
BARE_KEY = re.compile(r"[A-Za-z0-9_-]+")
TRIPLE_QUOTES = ('"' * 3, "'" * 3)


def _toml_loads():
    try:
        import tomllib
    except ImportError:
        return None
    return tomllib.loads


def _scan(text: str):
    """Yield (index, char, in_string) over TEXT, TOML basic and literal strings tracked."""
    quote, escaped = "", False
    for index, char in enumerate(text):
        if quote:
            yield index, char, True
            if escaped:
                escaped = False
            elif char == "\\" and quote == '"':
                escaped = True
            elif char == quote:
                quote = ""
        elif char in "\"'":
            quote = char
            yield index, char, True
        else:
            yield index, char, False


def _strip_comment(line: str) -> str:
    """LINE without a `#` comment outside a string."""
    for index, char, in_string in _scan(line):
        if char == "#" and not in_string:
            return line[:index]
    return line


def _depth(text: str) -> int:
    """How many brackets and braces TEXT leaves open, strings skipped."""
    depth = 0
    for _, char, in_string in _scan(text):
        if not in_string:
            depth += (char in "[{") - (char in "]}")
    return depth


def _split_key(key: str) -> list[str]:
    """A dotted TOML key (`target.'cfg(unix)'.dependencies` included) as its parts, the quotes removed."""
    parts, rest = [], key.strip()
    while rest:
        if rest[0] in "\"'":
            end = rest.find(rest[0], 1)
            if end < 0 or "\\" in rest[1:end]:
                raise Unresolved(f"a Cargo.toml key the line reader cannot read: {key}")
            parts.append(rest[1:end])
            rest = rest[end + 1:].lstrip()
        else:
            match = BARE_KEY.match(rest)
            if not match:
                raise Unresolved(f"a Cargo.toml key the line reader cannot read: {key}")
            parts.append(match.group(0))
            rest = rest[match.end():].lstrip()
        if rest:
            if rest[0] != ".":
                raise Unresolved(f"a Cargo.toml key the line reader cannot read: {key}")
            rest = rest[1:].lstrip()
    return parts


def _toml_entries(text: str) -> list[tuple[list[str], str]]:
    """Every table header (its key, value "") and key/value (table and key as one full key, the value's text, a value
    over several lines joined) of a Cargo.toml, in order. A multi-line string refuses: no manifest here has one."""
    entries: list[tuple[list[str], str]] = []
    table: list[str] = []
    pending: list | None = None
    for raw in text.splitlines():
        if any(quotes in raw for quotes in TRIPLE_QUOTES):
            raise Unresolved("a Cargo.toml with a multi-line string, which the line reader does not read")
        # An escape could spell a key or a path the reader then misses (review round 3 of #40095); no manifest needs
        # one.
        if re.search(r"\\[uU]", raw):
            raise Unresolved(f"a Cargo.toml line with a unicode escape, which the line reader does not read: {raw}")
        line = _strip_comment(raw).strip()
        if pending is not None:
            pending[1] += "\n" + line
            if _depth(pending[1]) <= 0:
                entries.append((pending[0], pending[1]))
                pending = None
            continue
        if not line:
            continue
        header = re.fullmatch(r"\[\[?([^\[\]]+)\]\]?", line)
        if header:
            table = _split_key(header.group(1))
            entries.append((table, ""))
            continue
        key, equals, value = line.partition("=")
        if not equals or not value.strip():
            raise Unresolved(f"a Cargo.toml line the line reader cannot read: {raw}")
        full, value = table + _split_key(key), value.strip()
        # A quoted key inside an inline table ({ "workspace" = true }) is not read by the patterns below.
        if value.startswith("{") and re.search(r"""(?:^|[{,])\s*(?:"[^"]*"|'[^']*')\s*=""", value):
            raise Unresolved(f"a Cargo.toml inline table with a quoted key, which the line reader does not read: {raw}")
        if _depth(value) > 0:
            pending = [full, value]
        else:
            entries.append((full, value))
    if pending is not None:
        raise Unresolved("a Cargo.toml value that does not end")
    return entries


def _parsed(text: str, loads) -> dict:
    try:
        return loads(text)
    except ValueError as error:  # tomllib.TOMLDecodeError
        raise Unresolved(f"a Cargo.toml that is not TOML: {error}") from error


def _dependency(owner: list[str]) -> tuple[str, str] | None:
    """(TABLE, NAME) when OWNER is dependency NAME of TABLE, in a target table or not."""
    rest = owner[2:] if owner[:1] == ["target"] else owner
    if len(rest) == 2 and rest[0] in DEPENDENCY_TABLES:
        return rest[0], rest[1]
    return None


def own_root(text: str, loads=_toml_loads()) -> bool:
    """Whether a Cargo.toml has a [workspace] table, so that cargo builds it as its own workspace root."""
    answer = any(full[:1] == ["workspace"] for full, _ in _toml_entries(text))
    if loads is not None and answer != ("workspace" in _parsed(text, loads)):
        raise Unresolved("the line reader and tomllib disagree on a [workspace] table")
    return answer


def inherited(text: str, loads=_toml_loads()) -> tuple[set, set, bool]:
    """What a crate's Cargo.toml inherits from its workspace: package keys, (table, name) dependencies, and lints."""
    package: set[str] = set()
    dependencies: set[tuple[str, str]] = set()
    lints = False
    for full, value in _toml_entries(text):
        if full[-1:] == ["workspace"] and value == "true":
            owner = full[:-1]
        elif value.startswith("{") and re.search(r"(?:^|[{,\s])workspace\s*=\s*true\b", value):
            owner = full
        else:
            continue
        if len(owner) == 2 and owner[0] == "package":
            package.add(owner[1])
        elif owner == ["lints"]:
            lints = True
        elif _dependency(owner):
            dependencies.add(_dependency(owner))
    if loads is not None:
        data = _parsed(text, loads)
        tables = [data] + [t for t in data.get("target", {}).values() if isinstance(t, dict)]
        expected = (
            {key for key, v in data.get("package", {}).items() if isinstance(v, dict) and v.get("workspace") is True},
            {(name, dep) for t in tables for name in DEPENDENCY_TABLES for dep, v in t.get(name, {}).items()
             if isinstance(v, dict) and v.get("workspace") is True},
            data.get("lints", {}).get("workspace") is True,
        )
        if (package, dependencies, lints) != expected:
            raise Unresolved("the line reader and tomllib disagree on what a Cargo.toml inherits from its workspace")
    return package, dependencies, lints


def _workspace_groups(text: str, loads) -> dict[tuple[str, str], str]:
    """The lines of each [workspace.package] key, [workspace.dependencies] entry, and the [workspace.lints] tables of a
    workspace manifest, keyed ("package" | "dependencies" | "lints", NAME); NAME is "" for the lints."""
    groups: dict[tuple[str, str], list[str]] = {}
    for full, value in _toml_entries(text):
        if full[:1] != ["workspace"] or len(full) < 3 or full[1] not in ("package", "dependencies", "lints"):
            continue
        name = "" if full[1] == "lints" else full[2]
        groups.setdefault((full[1], name), []).append(".".join(full[2:]) + (" = " + value if value else ""))
    if loads is not None:
        table = _parsed(text, loads).get("workspace", {})
        for section in ("package", "dependencies"):
            if {name for kind, name in groups if kind == section} != set(table.get(section, {})):
                raise Unresolved(f"the line reader and tomllib disagree on [workspace.{section}]")
    return {key: "\n".join(lines) for key, lines in groups.items()}


def workspace_view(workspace: str, crates: list[str], loads=_toml_loads()) -> str:
    """One canonical JSON line of what CRATES (Cargo.toml texts; one with its own [workspace] is skipped) inherit for
    their library from WORKSPACE (a workspace manifest's text): those entries' lines, None for a missing entry."""
    groups = _workspace_groups(workspace, loads)
    view: dict[str, dict] = {"package": {}, "dependencies": {}, "lints": {}}
    for crate in crates:
        if own_root(crate, loads):
            continue
        package, dependencies, lints = inherited(crate, loads)
        for key in package:
            view["package"][key] = groups.get(("package", key))
        for table, name in dependencies:
            if table != "dev-dependencies":
                view["dependencies"][name] = groups.get(("dependencies", name))
        if lints:
            view["lints"][""] = groups.get(("lints", ""))
    return json.dumps(view, sort_keys=True)


def workspace_paths(workspace: str, crate: str, loads=_toml_loads()) -> list[str]:
    """The `path` of each [workspace.dependencies] entry a crate's Cargo.toml inherits (from any dependency table, a
    test's included, as a `path` dependency is followed), relative to the workspace manifest's directory. An inherited
    entry that the workspace does not have refuses."""
    if own_root(crate, loads):
        return []
    groups = _workspace_groups(workspace, loads)
    table = _parsed(workspace, loads).get("workspace", {}).get("dependencies", {}) if loads is not None else None
    paths = []
    for _, name in sorted(inherited(crate, loads)[1]):
        lines = groups.get(("dependencies", name))
        if lines is None:
            raise Unresolved(f"a crate inherits {name}, which [workspace.dependencies] does not have")
        found = re.findall(r'(?:^|[{,\s.])path\s*=\s*"([^"\\]+)"', lines)
        if len(found) > 1:
            raise Unresolved(f"[workspace.dependencies] {name} names more than one path")
        if table is not None:
            entry = table.get(name)
            if found != ([entry["path"]] if isinstance(entry, dict) and "path" in entry else []):
                raise Unresolved(f"the line reader and tomllib disagree on the path of {name}")
        paths += found
    return sorted(set(paths))


def _text(path: str) -> str:
    """A file's text; a missing file reads as empty (a manifest that a revision does not have)."""
    return Path(path).read_text(encoding="utf-8") if Path(path).is_file() else ""


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
        if argv[:1] == ["workspace-view"] and len(argv) >= 2:
            print(workspace_view(_text(argv[1]), [_text(path) for path in argv[2:]]))
            return 0
        if argv[:1] == ["own-root"] and len(argv) == 2:
            print("yes" if own_root(_text(argv[1])) else "no")
            return 0
        if argv[:1] == ["inputs"] and len(argv) >= 2:
            # The crates, a line "--", then the input pathspecs: the union of the inputs at each REV (walk, merge).
            crates, paths = merge([walk(Path(argv[1]), rev) for rev in argv[2:] or ["HEAD"]])
            print("\n".join(crates + ["--"] + paths))
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
