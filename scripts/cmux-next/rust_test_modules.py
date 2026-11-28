# Opens only .rs files, below the folder its caller names (scripts/ci/guard_step_inputs.py DECLARED):
# guard-inputs: **/*.rs
"""Which Rust files under cmux-tui/crates compile only in tests, for the ratchets that count product code.

A file is test code when its name says so (`tests.rs`, `*_tests.rs`, `*_test.rs`), when its parent
declares it with a test-only cfg (`#[cfg(test)] mod name;` or `#[cfg(all(test, unix))]`, as `name.rs`,
`name/mod.rs` or a `#[path = "..."]`), or when it sits below such a module (its own `mod x;` files).
2026-11-11: hub/mod.rs's `#[cfg(test)] mod remote_table_bench;` (cmux#41040) made check-spawn-owner.py
count a bench's `std::thread::spawn` as product code and turned feat-cmux-next red; the guards that
skipped only by file name all shared that gap. crash_ratchet.py has had the same rule since 2026-10-24.

A text scan: each file is read once as bytes and only the ones naming `#[cfg(` are decoded, and a
declaration is matched only at each `#[cfg(` (about 0.15 s for every crate). Rules are tested by
tests/test_spawn_owner_ratchet.py.

The guards run as `python3 -I` from a checkout or from the installed copy of scripts/cmux-next (the whole
folder is copied together), so they load this file from their own folder:
    spec = importlib.util.spec_from_file_location("rust_test_modules", os.path.join(HERE, "rust_test_modules.py"))
"""

from __future__ import annotations

import os
import re

# A test-only cfg: `cfg(test)`, or `cfg(all(...))` with `test` as one of its top-level predicates
# (`cfg(all(test, unix))`); never `any(test, ...)` or `not(test)`, which also compile outside tests.
_CFG_ITEM = r'(?:(?:any|all|not)\([^()]*\)|\w+\s*=\s*"[^"]*"|\w+)'
_TEST_CFG = (r"(?:test|all\(\s*(?:" + _CFG_ITEM + r"\s*,\s*)*test\s*(?:,\s*" + _CFG_ITEM
             + r"\s*)*,?\s*\))")
# `#[cfg(test)] mod name;`, other attributes after the cfg; attributes before it are read back from it.
TEST_MOD_DECL = re.compile(r"#\[cfg\(" + _TEST_CFG + r"\)\]\s*(?P<attrs>(?:#\[[^\]]*\]\s*)*)"
                           r"(?:pub(?:\([^)]*\))?\s+)?mod\s+(?P<name>\w+)\s*;")
RUST_PATH_ATTR = re.compile(r'#\[path\s*=\s*"(?P<path>[^"]+)"\s*\]')
SKIP_DIRS = {"target", ".build", "node_modules"}


def is_test_name(name: str) -> bool:
    return name == "tests.rs" or name.endswith(("_tests.rs", "_test.rs"))


def module_folder(path: str) -> str:
    """The folder that holds PATH's own `mod x;` files: a mod.rs, lib.rs or main.rs owns its folder,
    any other foo.rs owns foo/."""
    here, name = os.path.split(path)
    return here if name in ("mod.rs", "lib.rs", "main.rs") else os.path.join(here, name[:-3])


class TestModules:
    """The files and folders that hold only test code. Paths are as the caller joins them (one root)."""

    def __init__(self) -> None:
        self.files: set[str] = set()
        self.folders: set[str] = set()

    def add_file(self, path: str, raw: bytes) -> None:
        """Notes PATH (its bytes RAW): a test-named file's own modules, and its `#[cfg(test)] mod x;`s."""
        if is_test_name(os.path.basename(path)):
            self.folders.add(module_folder(path))
            return
        if b"#[cfg(" in raw and b"mod " in raw:
            self._add_decls(path, raw.decode("utf-8", errors="replace"))

    def _add_decls(self, path: str, text: str) -> None:
        here = os.path.dirname(path)
        at = text.find("#[cfg(")
        while at >= 0:
            decl = TEST_MOD_DECL.match(text, at)
            line_start = text.rfind("\n", 0, at) + 1
            at = text.find("#[cfg(", at + 6)
            lead = text[line_start:decl.start()] if decl else ""
            if not decl or "//" in lead or not (lead.strip() == "" or lead.lstrip().startswith("#[")):
                continue  # no declaration, a commented-out one, or not at an item's start
            attrs, end = [lead, decl.group("attrs") or ""], line_start
            while end > 0:  # attributes on the lines above (a `#[path]` before the cfg)
                start = text.rfind("\n", 0, end - 1) + 1
                line = text[start:end].strip()
                if not line.startswith("#["):
                    break
                attrs.append(line)
                end = start
            attr = RUST_PATH_ATTR.search("\n".join(attrs))
            if attr:
                target = os.path.normpath(os.path.join(here, attr.group("path")))
                self.files.add(target)
                self.folders.add(os.path.dirname(target) if os.path.basename(target) == "mod.rs" else target[:-3])
                continue
            module = os.path.join(module_folder(path), decl.group("name"))
            self.files.update((module + ".rs", os.path.join(module, "mod.rs")))
            self.folders.add(module)

    def contains(self, path: str) -> bool:
        """True when PATH compiles only in tests (by its name, its parent's cfg, or a test module above it)."""
        if is_test_name(os.path.basename(path)) or os.path.normpath(path) in self.files:
            return True
        parent = os.path.dirname(os.path.normpath(path))
        while parent:
            if parent in self.folders:
                return True
            up = os.path.dirname(parent)
            if up == parent:
                return False
            parent = up
        return False


def scan(top: str) -> TestModules:
    """Every test-only file and folder below TOP (a crate, or cmux-tui/crates), read once."""
    modules = TestModules()
    for dirpath, dirnames, filenames in os.walk(top):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS and not d.startswith(".")]
        for name in filenames:
            if not name.endswith(".rs"):
                continue
            path = os.path.join(dirpath, name)
            if is_test_name(name):
                modules.add_file(path, b"")
                continue
            try:
                with open(path, "rb") as f:
                    raw = f.read()
            except OSError:
                continue
            modules.add_file(path, raw)
    return modules


# An inline test module: `#[cfg(test)]`, any further attributes, then `[pub[(..)]] mod name {`.
INLINE_TEST_MOD = re.compile(r"^[ \t]*#\[cfg\(test\)\]\s*\n(?:[ \t]*#\[[^\n]*\]\s*\n)*[ \t]*(?:pub(?:\([^)]*\))?\s+)?"
                             r"mod\s+\w+\s*\{", re.MULTILINE)
_RAW_STRING = re.compile(r'b?r(#*)"')
_CHAR = re.compile(r"b?'(?:\\(?:x[0-9a-fA-F]{2}|u\{[0-9a-fA-F]+\}|.)|[^\\'\n])'")


def _block_end(text: str, open_brace: int) -> int | None:
    """The index just past the `}` closing the `{` at OPEN_BRACE, skipping comments, strings and char literals
    (None when it never closes)."""
    depth, i, n = 0, open_brace, len(text)
    while i < n:
        c = text[i]
        if c == "/" and text.startswith("//", i):
            nl = text.find("\n", i)
            i = n if nl < 0 else nl
            continue
        if c == "/" and text.startswith("/*", i):
            nested, i = 1, i + 2
            while i < n and nested:
                if text.startswith("/*", i):
                    nested, i = nested + 1, i + 2
                elif text.startswith("*/", i):
                    nested, i = nested - 1, i + 2
                else:
                    i += 1
            continue
        if c in "rb" and (i == 0 or not (text[i - 1].isalnum() or text[i - 1] == "_")):
            raw = _RAW_STRING.match(text, i)
            if raw:
                close = text.find('"' + raw.group(1), raw.end())
                if close < 0:
                    return None
                i = close + 1 + len(raw.group(1))
                continue
        if c == '"':
            i += 1
            while i < n and text[i] != '"':
                i += 2 if text[i] == "\\" else 1
            i += 1
            continue
        if c == "'" or (c == "b" and text.startswith("b'", i)):
            char = _CHAR.match(text, i)
            if char:
                i = char.end()
                continue
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return None


def product_text(text: str) -> str:
    """TEXT with each inline `#[cfg(test)] mod name { ... }` blanked (its newlines kept, so line numbers hold).
    Only the module's own block is test code: product code after a test module still counts (the old reading,
    everything after the first one, hid live code behind a mid-file test module, and a sweep that moved such a
    module out then read as adding that code). A module whose braces never close blanks the rest of the file."""
    out, pos = [], 0
    while True:
        match = INLINE_TEST_MOD.search(text, pos)
        if not match:
            out.append(text[pos:])
            return "".join(out)
        end = _block_end(text, match.end() - 1)
        out.append(text[pos:match.start()])
        if end is None:
            out.append("\n" * text.count("\n", match.start()))
            return "".join(out)
        out.append("\n" * text.count("\n", match.start(), end))
        pos = end
