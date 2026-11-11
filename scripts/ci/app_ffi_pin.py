#!/usr/bin/env python3
"""The app FFI pin of Packages/macOS/CmuxNext/Package.swift, read by one fail-closed canonical match.

    python3 scripts/ci/app_ffi_pin.py read [Package.swift]               # prints "SOURCE_SHA CHECKSUM"
    python3 scripts/ci/app_ffi_pin.py read-pin-file app-ffi-pin.json Package.swift   # the JSON pin, same output
    python3 scripts/ci/app_ffi_pin.py rewrite SHA CHECKSUM [Package.swift]
    python3 scripts/ci/app_ffi_pin.py inputs ROOT                       # the FFI crates, "--", the input pathspecs
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

import json
import os
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
# - Each crate cmux-app-ffi reaches is an input as a whole directory (its git-tracked files), except its tests/,
#   benches/ and examples/ (cargo builds them only for tests) and the reviewed TEST_ONLY files.
# - Every string literal in the crate's source files (Rust, TOML, C) that names an existing path, relative to the file
#   or to the crate, adds that path when the crate directory does not already hold it: a file outside the crate (an
#   include_str! of a spec file, a build script's token table), or one in an excluded directory (then that directory
#   is not excluded). A named directory that holds a Cargo.toml is a crate, and is walked the same way. Escapes are
#   decoded first, and comments are not read, so neither can hide or invent a name.
# - What cannot be read refuses: a symlink in a crate, a scanned file that names a TEST_ONLY file without being one of
#   its readers, a manifest the line reader cannot read.
#
# - A build script that walks up with .parent() or .ancestors() refuses (BUILD_SCRIPT_PARENTS below).
#
# What is left: a path outside the crate computed with no literal that names it in a library source
# (concat!("../../", NAME) in an include). A literal that names a directory holding the crate ("..", "../") is
# ignored: runtime name checks spell it in every crate. No FFI crate computes such a path today; the review of a
# change that does must catch it.
EXCLUDED_DIRS = ("tests", "benches", "examples", "target")
SCANNED_SUFFIXES = {".rs": "rust", ".toml": "toml", ".c": "c", ".h": "c", ".cc": "c", ".cpp": "c", ".hpp": "c",
                    ".m": "c", ".mm": "c"}
# Each test-only file and the only sources that may name it (all of them test code). A change to the file cannot change
# the archive; another scanned file that names it refuses, so a library source cannot start to read it unnoticed.
TEST_ONLY = {
    # #39027 changed it and staled the pin on 2026-11-09.
    "cmux-tui/bindings/rust/.cmux-resource-api.json": ("cmux-tui/bindings/rust/tests/catalog_manifest.rs",),
    "Packages/macOS/CmuxNext/Tests/CmuxNextSidebarTests/Fixtures/sidebar-layout-cases.json":
        ("cmux-tui/crates/cmux-layout-reducer/src/sidebar_layout_tests.rs",),
    "schemas/remote-tab/client.json": ("cmux-tui/crates/cmux-rd-ffi/src/rb_client_tests.rs",),
}
FFI_ROOT_CRATE = "cmux-tui/crates/cmux-app-ffi"
# A build script that walks up from its crate computes a path outside it that no literal names (lead decision,
# 2026-11-10), so .parent() and .ancestors() refuse in a crate's build-script files: build.rs (or the file Cargo.toml's
# `build` names), every .rs file under build-support/, and the modules they reach (`mod NAME;` beside the file, or a
# #[path] literal). The only exception is a reviewed entry here: the build-script file, the path it reaches and why.
# No FFI build script walks up today (cmux-action-catalog/build.rs, cmux-motion/build.rs and build-support/json.rs).
BUILD_SCRIPT_PARENTS: dict[str, tuple[str, str]] = {}
WALKS_UP = re.compile(r"\.\s*(?:parent|ancestors)\s*\(")


class Unresolved(ValueError):
    """The inputs cannot be known (a symlink, a literal naming a directory that holds the crate, a test-only file named
    by a library source, a manifest the line reader cannot read): the check refuses rather than leave a file out."""


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
        elif code == "x":
            out.append(chr(int(body[index + 2:index + 4], 16)))
            index += 4
        elif code == "u":
            end = body.index("}", index)
            out.append(chr(int(body[index + 3:end], 16)))
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
            return chr(int(code[1:], 16))
        return {"b": "\b", "t": "\t", "n": "\n", "f": "\f", "r": "\r", '"': '"', "\\": "\\"}.get(code, code)
    return re.sub(r'\\(u[0-9A-Fa-f]{4}|U[0-9A-Fa-f]{8}|.)', one, body)


def _rust_literals(text: str, code: list[str] | None = None) -> list[str]:
    """The string literals of Rust TEXT (plain, raw, byte and C strings), escapes decoded; comments, chars and
    lifetimes skipped. CODE, when given, receives TEXT's code outside comments and literals, in pieces."""
    found, index, size = [], 0, len(text)
    while index < size:
        char = text[index]
        if code is not None and not (text.startswith("//", index) or text.startswith("/*", index) or char in "\"'rbc"):
            code.append(char)
        if text.startswith("//", index):
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
        elif char in "rbc" and re.match(r'(?:br|cr|r)#*"', text[index:index + 260]) and \
                (index == 0 or not (text[index - 1].isalnum() or text[index - 1] == "_")):
            match = re.match(r'(?:br|cr|r)(#*)"', text[index:])
            hashes = match.group(1)
            start = index + match.end()
            end = text.find('"' + hashes, start)
            if end < 0:
                raise Unresolved("a raw string that does not end")
            found.append(text[start:end])
            index = end + 1 + len(hashes)
        elif char == '"' or (char in "bc" and text.startswith('"', index + 1) and
                             (index == 0 or not (text[index - 1].isalnum() or text[index - 1] == "_"))):
            start = index + (1 if char == '"' else 2)
            end = start
            while end < size and text[end] != '"':
                end += 2 if text[end] == "\\" else 1
            if end >= size:
                raise Unresolved("a string that does not end")
            found.append(_rust_unescape(text[start:end]))
            index = end + 1
        elif char == "'":
            # A char literal ('x', '\n', '\u{2f}', '"') or a lifetime ('a): only a char literal ends with a quote.
            match = re.match(r"'(?:\\(?:u\{[0-9A-Fa-f]+\}|x[0-9A-Fa-f]{2}|.)|[^\\'\n])'", text[index:])
            index += match.end() if match else 1
        else:
            if code is not None and char in "rbc":
                code.append(char)
            index += 1
    return found


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


def _c_literals(text: str) -> list[str]:
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.S)
    text = re.sub(r"//[^\n]*", " ", text)
    return [_rust_unescape(m) for m in re.findall(r'"((?:[^"\\\n]|\\.)*)"', text)] + \
        re.findall(r"#\s*(?:include|import)\s*<([^>\n]+)>", text)


LITERALS = {"rust": _rust_literals, "toml": _toml_literals, "c": _c_literals}


def _tracked(root: Path, folder: str) -> list[str]:
    """The git-tracked files under FOLDER (relative to ROOT), refusing a symlink."""
    try:
        listed = subprocess.run(["git", "-C", str(root), "ls-files", "-s", "-z", "--", folder], check=True,
                                capture_output=True).stdout.decode("utf-8", "replace")
    except (OSError, subprocess.CalledProcessError) as error:
        raise Unresolved(f"git ls-files {folder} failed: {error}") from error
    files = []
    for entry in filter(None, listed.split("\0")):
        mode, _, rest = entry.partition(" ")
        path = rest.split("\t", 1)[1]
        if mode == "120000":
            raise Unresolved(f"{path} is a symlink: the app FFI pin cannot follow what it points to")
        if mode != "160000":
            files.append(path)
    return files


def walk(root: Path, start: str = FFI_ROOT_CRATE, workspace: str = "cmux-tui/Cargo.toml"
         ) -> tuple[list[str], list[str]]:
    """(the crates, the input pathspecs) of the FFI build: every crate START reaches, and each crate directory, every
    path outside a crate that a crate's source names, then `:(exclude)` pathspecs for each crate's tests/, benches/,
    examples/ and the TEST_ONLY files. Raises Unresolved (see above)."""
    root = Path(os.path.realpath(root))
    crates: list[str] = []
    queue = [start]
    named: set[str] = set()
    unexcluded: set[str] = set()
    tracked_cache: dict[str, list[str]] = {}

    def crate_of(relative: str) -> str | None:
        """The innermost walked crate holding RELATIVE."""
        holders = [c for c in crates if relative == c or relative.startswith(c + "/")]
        return max(holders, key=len) if holders else None

    def excluded_dir(crate: str, relative: str) -> str | None:
        rest = relative[len(crate) + 1:].split("/", 1)[0] if relative != crate else ""
        return f"{crate}/{rest}" if rest in EXCLUDED_DIRS else None

    while queue:
        crate = queue.pop()
        if crate in crates:
            continue
        if not (root / crate / "Cargo.toml").is_file():
            continue
        crates.append(crate)
        files = tracked_cache.setdefault(crate, _tracked(root, crate))
        manifest = (root / crate / "Cargo.toml").read_text(encoding="utf-8", errors="replace")
        if any(full == ["package", "workspace"] for full, _ in _toml_entries(manifest)):
            raise Unresolved(f"{crate}/Cargo.toml sets package.workspace: the app FFI pin reads only {workspace}")
        for path in _workspace_paths(root / workspace, root / crate / "Cargo.toml"):
            queue.append(Path(os.path.normpath(path)).relative_to(root).as_posix())
        for file in _build_files(root, crate, manifest, files):
            code: list[str] = []
            _rust_literals((root / file).read_text(encoding="utf-8", errors="replace"), code)
            if WALKS_UP.search("".join(code)) and file not in BUILD_SCRIPT_PARENTS:
                raise Unresolved(f"{file}, a build script file, walks up with .parent() or .ancestors(): a path it "
                                 "computes outside the crate names no literal; list it in app_ffi_pin.py "
                                 "BUILD_SCRIPT_PARENTS with the path it reaches, after review")
        for file in files:
            parts = file[len(crate) + 1:].split("/")
            if parts[0] in EXCLUDED_DIRS:
                continue
            kind = SCANNED_SUFFIXES.get(Path(file).suffix) or ("toml" if parts[-2:-1] == [".cargo"] else None)
            if kind is None:
                continue
            text = (root / file).read_text(encoding="utf-8", errors="replace")
            nearest = next((str(Path(file).parents[i]) for i in range(len(Path(file).parents) - 1)
                            if (root / Path(file).parents[i] / "Cargo.toml").is_file()), crate)
            for literal in LITERALS[kind](text):
                for target in _resolve(root, literal, (root / file).parent, root / nearest):
                    relative = target.relative_to(root).as_posix()
                    if relative in TEST_ONLY:
                        if file not in TEST_ONLY[relative]:
                            raise Unresolved(f"{file} names {relative}, which app_ffi_pin.py TEST_ONLY lists as "
                                             "read only by tests")
                        continue
                    if target.is_dir() and (target == root or target in (root / crate).parents):
                        continue  # ".." or "../" (a socket name check, a path join): not a file the build reads
                    if target.is_dir() and (target / "Cargo.toml").is_file():
                        queue.append(relative)
                        continue
                    named.add(relative)
    # A named path in a crate's tests/, benches/ or examples/ keeps that whole directory in (git's :(exclude) would
    # win over the path); one elsewhere in a crate is already in it.
    outside = set()
    for path in named:
        holder = crate_of(path)
        if holder is None:
            outside.add(path)
        elif excluded_dir(holder, path) is not None:
            unexcluded.add(excluded_dir(holder, path))
    includes = sorted(set(crates) | outside)
    excludes = set()
    for crate in crates:
        for file in tracked_cache[crate]:
            top = excluded_dir(crate, file)
            if top is not None and top not in unexcluded and crate_of(file) == crate:
                excludes.add(top)
    for path in TEST_ONLY:
        if crate_of(path) is not None and (root / path).exists():
            excludes.add(path)
    return sorted(crates), includes + [f":(exclude){p}" for p in sorted(excludes)]


def _build_files(root: Path, crate: str, manifest: str, files: list[str]) -> list[str]:
    """The build-script files of CRATE (relative to ROOT): its build script, every .rs under build-support/, and the
    modules they reach through `mod NAME;` or a #[path] literal."""
    build = "build.rs"
    for full, value in _toml_entries(manifest):
        if full == ["package", "build"]:
            literal = _toml_literals(value)
            build = literal[0] if literal else ("" if value == "false" else "build.rs")
    queue = [f"{crate}/{build}"] if build else []
    queue += [f for f in files if f.startswith(f"{crate}/build-support/") and f.endswith(".rs")]
    seen: list[str] = []
    while queue:
        file = os.path.normpath(queue.pop())
        if file in seen or not (root / file).is_file():
            continue
        seen.append(file)
        text = (root / file).read_text(encoding="utf-8", errors="replace")
        code: list[str] = []
        literals = _rust_literals(text, code)
        folder = Path(file).parent
        queue += [os.path.normpath(folder / literal) for literal in literals if literal.endswith(".rs")]
        for name in re.findall(r"\bmod\s+(?:r#)?(\w+)\s*;", "".join(code)):
            queue += [str(folder / f"{name}.rs"), str(folder / name / "mod.rs"),
                      str(folder / Path(file).stem / f"{name}.rs"), str(folder / Path(file).stem / name / "mod.rs")]
    return seen


def _resolve(root: Path, literal: str, folder: Path, crate: Path) -> list[Path]:
    """The existing repository paths LITERAL may name, relative to FOLDER (an include!, #[path]) or to CRATE (a build
    script, a manifest, CARGO_MANIFEST_DIR joined with it)."""
    if not literal or "\n" in literal or len(literal) > 300 or "\0" in literal:
        return []
    variants = {literal, literal.split("=")[-1], literal.lstrip("/")}
    if "../" in literal:
        variants.add(literal[literal.find("../"):])
    found = []
    for variant in variants:
        if not variant or variant.startswith("/"):
            continue
        for base in (folder, crate):
            path = Path(os.path.normpath(base / variant))
            try:
                if (path == root or root in path.parents) and path.exists():
                    found.append(path)
            except OSError:  # a prose string that is no path (too long a name)
                continue
    return found


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


def _workspace_paths(workspace: Path, crate: Path) -> list[str]:
    """workspace_paths of the files WORKSPACE and CRATE, as absolute paths. A crate that inherits anything must find
    WORKSPACE as the nearest workspace manifest above it (no Cargo.toml in between), or it refuses."""
    text = _text(str(crate))
    if own_root(text) or inherited(text) == (set(), set(), False):
        return []
    folder, home = crate.resolve().parent, workspace.resolve().parent
    between = [parent for parent in folder.parents if home in parent.parents]
    if home not in folder.parents or any((parent / "Cargo.toml").is_file() for parent in between):
        raise Unresolved(f"{crate} inherits from a workspace other than {workspace}")
    return [str(home / path) for path in workspace_paths(_text(str(workspace)), text)]


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
        if argv[:1] == ["inputs"] and len(argv) == 2:
            # The crates, a line "--", then the input pathspecs (walk above).
            crates, paths = walk(Path(argv[1]))
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
