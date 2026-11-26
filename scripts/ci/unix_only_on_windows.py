#!/usr/bin/env python3
"""unix-only-on-windows: unix-only Rust that the Windows check would refuse, found on Linux in seconds.

cmux-tui-windows-check (`cargo check --target x86_64-pc-windows-gnu`) runs in the feat-cmux-next
post-merge batch, not on pull requests (CI 10x, 2026-11-21), so a pull request that adds unix-only
code to acpmux lands green and turns the tip red: batches 45693869119, 45720080410 and 45726394764
were red on it, 46 errors in job 139597585051 alone, and cmux#54573 fixed them forward. This script
is the cheap half of that check: it reads the crate's sources the way rustc's cfg pass does for
x86_64-pc-windows-gnu and names every use, in code that Windows still compiles, of

  - `std::os::unix` and `std::os::fd`;
  - `UnixStream`, `UnixListener` and `UnixDatagram`;
  - a `libc::` item that libc does not have on windows-gnu (libc_windows_gnu.txt, libc 0.2.191);
  - a dependency that Windows does not get: one listed only under a target that is not Windows
    (`[target.'cfg(unix)'.dependencies]`), an optional one no default feature turns on, or a path
    dependency whose crate root is `#![cfg(unix)]`;
  - an item of a path dependency's crate root that is behind a cfg Windows does not set;
  - a module or item of the crate itself that is declared only under a cfg Windows does not set
    (`#[cfg(unix)] mod hub;`), named by a path (`super::hub::x`, `crate::a::hub`, `use
    super::{hub, ..}`, or bare `hub::x` / `f(` in the module that declares it).

What counts as compiled on Windows: rustc's cfg set for x86_64-pc-windows-gnu (windows,
target_os = "windows", target_env = "gnu", ...; an unset name is false, as in rustc), the crate's
default features, both with and without `test` (the check runs `-p acpmux` and `-p acpmux
--all-targets`). An item under a false `#[cfg(...)]` is skipped, and a `mod x;` under one skips
x's whole file; `#![cfg(...)]` skips its file or block. `cfg!()` in an expression does not remove
code, so a use under `if cfg!(unix)` is still named, as rustc would refuse it.

It is a lexical reader, not rustc: it can miss a use the cfg pass would keep (a macro's body is
read as code; a re-export through another name is not followed), so the post-merge Windows check
stays the judge. It does not name what it cannot prove: every finding is a path rustc resolves
against a module or crate that is not there on Windows.

Usage:
  python3 scripts/ci/unix_only_on_windows.py [--rev REV] [--crate DIR ...] [--github]
  python3 scripts/ci/unix_only_on_windows.py --write-libc-list LIBC_SRC_DIR

Exit 0 when nothing is found, 1 with findings, 2 on a usage error.
"""
from __future__ import annotations

import argparse
import bisect
import os
import re
import subprocess
import sys
import tomllib
from dataclasses import dataclass, field

HERE = os.path.dirname(os.path.abspath(__file__))
LIBC_LIST = os.path.join(HERE, "libc_windows_gnu.txt")
# The crates the Windows check builds whose own sources are scanned. acpmux first: every red of
# the Windows check since 2026-11-21 was in it.
DEFAULT_CRATES = [
    "cmux-tui/crates/acpmux",
    "cmux-tui/crates/cmux-fault",  # an acpmux dev-dependency that --all-targets builds
    "cmux-tui/crates/cmux-tui-core",
    "cmux-tui/crates/cmux-tui",
]

# rustc's cfg set for x86_64-pc-windows-gnu in a debug `cargo check` (`rustc --print cfg`).
WINDOWS_CFG_NAMES = {"windows", "debug_assertions", "overflow_checks"}
WINDOWS_CFG_VALUES = {
    "target_os": {"windows"},
    "target_family": {"windows"},
    "target_env": {"gnu"},
    "target_vendor": {"pc"},
    "target_arch": {"x86_64"},
    "target_pointer_width": {"64"},
    "target_endian": {"little"},
    "target_has_atomic": {"8", "16", "32", "64", "ptr"},
    "panic": {"unwind"},
}

# Comments, strings and char literals become spaces (newlines kept), so offsets and lines match
# the original text and nothing inside them reads as code.
STRIP_RE = re.compile(
    r"""//[^\n]*"""
    r"""|/\*.*?\*/"""
    r"""|(?<![\w])b?r(?P<h>\#*)".*?"(?P=h)"""
    r"""|(?<![\w])b?"(?:\\.|[^"\\])*\""""
    r"""|(?<![\w])b?'(?:\\(?:x[0-9a-fA-F]{2}|u\{[0-9a-fA-F]+\}|.)|[^\\'\n])'""",
    re.S,
)
CFG_ATTR_RE = re.compile(r"#\s*(!)?\s*\[\s*cfg\s*\(")
TOKEN_RE = re.compile(r"\bwhere\b|->|=>|==|!=|<=|>=|<<|>>|[{}()\[\];,<>=]")
NEXT_RE = re.compile(r"\s*(else\b|as\b|if\b|=>|\.|\?|[-+*/%&|^<>=!]|\S)")
MAIN_RE = re.compile(r"\bfn\s+main\s*\(")
NO_MAIN_RE = re.compile(r"#!\[\s*(?:no_main|cfg_attr\s*\((.*?),\s*no_main\s*\))\s*\]", re.S)
MOD_RE = re.compile(r"\bmod\s+(?:r#)?(\w+)\s*([;{])")
# A module-level item's name (functions, types, constants); `mod` is MOD_RE's.
ITEM_RE = re.compile(r"^[ \t]*(?:pub(?:\s*\([^)]*\))?\s+)?(?:(?:const|async|unsafe|extern(?:\s+\"\w+\")?)\s+)*"
                     r"(?:fn|struct|enum|trait|type|const|static|union)\s+(?:r#)?(\w+)\b", re.M)
# A `use` the module brings a name in with (a `#[cfg(not(unix))] pub use stub::{f, g};` arm).
USE_RE = re.compile(r"^[ \t]*(?:pub(?:\s*\([^)]*\))?\s+)?use\s+([^;]*);", re.M)
# A path that starts at the crate, the parent or this module.
REL_RE = re.compile(r"\b(crate|super|self)\s*::")
SEG_RE = re.compile(r"\s*(?:r#)?(\w+)\s*(::)?")
DECL_BEFORE_RE = re.compile(r"\b(?:fn|mod|struct|enum|trait|type|const|static|union|let|macro_rules!)\s*$")
VIS_TAIL_RE = re.compile(r"\bpub\s*(?:\([^)]*\))?\s*$")
PATH_ATTR_RE = re.compile(r'#\s*\[\s*path\s*=\s*"([^"]+)"\s*\]')
ATTR_TAIL_RE = re.compile(r"(?:#\s*\[[^\]]*\]\s*)+$")
TOP_ITEM_RE = re.compile(
    r"(?:\bpub\s*(?:\([^)]*\))?\s*)(?:unsafe\s+|async\s+|const\s+|extern\s+)*"
    r"(?:mod|fn|struct|enum|trait|type|const|static|union)\s+(?:r#)?(\w+)"
)


def _blank(m: re.Match) -> str:
    g = m.group()
    return " " * len(g) if "\n" not in g else _NOT_NL.sub(" ", g)


_NOT_NL = re.compile(r"[^\n]")


# ---------------------------------------------------------------- cfg predicates


def _cfg_tokens(text: str) -> list[str]:
    return re.findall(r'"(?:\\.|[^"\\])*"|[A-Za-z_][\w]*|[(),=]', text)


def eval_cfg(text: str, test: bool, features: set[str]) -> bool:
    """Whether `text` (the inside of `cfg( ... )`) holds for x86_64-pc-windows-gnu."""
    toks = _cfg_tokens(text)
    pos = 0

    def pred() -> bool:
        nonlocal pos
        name = toks[pos]
        pos += 1
        if name in ("all", "any", "not") and pos < len(toks) and toks[pos] == "(":
            pos += 1
            vals = []
            while pos < len(toks) and toks[pos] != ")":
                vals.append(pred())
                if pos < len(toks) and toks[pos] == ",":
                    pos += 1
            pos += 1
            if name == "all":
                return all(vals)
            if name == "any":
                return any(vals)
            return not vals[0] if vals else True
        if pos < len(toks) and toks[pos] == "=":
            value = toks[pos + 1].strip('"')
            pos += 2
            if name == "feature":
                return value in features
            return value in WINDOWS_CFG_VALUES.get(name, ())
        if name == "test":
            return test
        return name in WINDOWS_CFG_NAMES

    try:
        return pred()
    except IndexError:
        return True  # unreadable: assume compiled, the safe side for a finder


def _match_paren(text: str, open_at: int) -> int:
    depth = 0
    for i in range(open_at, len(text)):
        c = text[i]
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return i
    return len(text) - 1


# ---------------------------------------------------------------- item extents


def item_end(code: str, start: int) -> int:
    """The end of the attribute-led item, field, arm, argument or statement at `start`."""
    level = 0
    angle = 0
    track_angle = True
    where = False  # in a `where` clause, whose commas list bounds, not items
    for m in TOKEN_RE.finditer(code, start):
        t = m.group()
        if t == "where":
            where = level == 0 or where
            continue
        if t in "([{":
            level += 1
            continue
        if t in ")]}":
            if level == 0:
                return m.start()
            level -= 1
            if level == 0 and t == "}":
                nxt = NEXT_RE.match(code, m.end())
                if nxt is None:
                    return len(code)
                n = nxt.group(1)
                if n in (";", ","):
                    return nxt.end()
                # `if`: a match arm's guard (`#[cfg(unix)] E::A { .. } if f() => ...`).
                if n in ("else", "as", "if", "=>", ".", "?") or n in "-+*/%&|^<>=!":
                    track_angle = False
                    continue
                return m.end()
            continue
        if level:
            continue
        if t == ";":
            return m.end()
        if t == ",":
            if angle <= 0 and not where:
                return m.end()
            continue
        if not track_angle:
            continue
        if t in ("=>", "="):
            track_angle = False
            angle = 0
        elif t == "<":
            angle += 1
        elif t == "<<":
            angle += 2
        elif t == ">":
            angle -= 1
        elif t == ">>":
            angle -= 2
    return len(code)


def block_of(code: str, inner_attr_at: int) -> tuple[int, int]:
    """The file or `{ }` block an inner attribute at `inner_attr_at` applies to."""
    j = inner_attr_at - 1
    while j >= 0 and code[j].isspace():
        j -= 1
    if j < 0 or code[j] != "{":
        # Inner attributes lead their file; another inner attribute may come first.
        k = j
        while k >= 0 and code[k] == "]":
            # Skip back over a preceding `#![...]`.
            depth = 0
            while k >= 0:
                if code[k] == "]":
                    depth += 1
                elif code[k] == "[":
                    depth -= 1
                    if depth == 0:
                        break
                k -= 1
            k -= 1
            while k >= 0 and code[k] in "! \t\r\n#":
                k -= 1
        if k < 0 or code[k] != "{":
            return 0, len(code)
        j = k
    return j, _match_brace(code, j)


def _match_brace(code: str, open_at: int) -> int:
    level = 0
    for m in TOKEN_RE.finditer(code, open_at):
        t = m.group()
        if t in "([{":
            level += 1
        elif t in ")]}":
            level -= 1
            if level == 0:
                return m.end()
    return len(code)


# ---------------------------------------------------------------- sources


class Tree:
    """The repository's files, from the work tree or from one commit (`--rev`)."""

    def __init__(self, root: str, rev: str | None):
        self.root = root
        self.rev = rev
        self.cache: dict[str, str | None] = {}
        self.files: set[str] | None = None
        self.batch = None
        if rev:
            out = subprocess.run(
                ["git", "-C", root, "ls-tree", "-r", "--name-only", rev, "--", "cmux-tui"],
                check=True, capture_output=True, text=True,
            ).stdout
            self.files = set(out.splitlines())
            self.batch = subprocess.Popen(
                ["git", "-C", root, "cat-file", "--batch"],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            )

    def exists(self, path: str) -> bool:
        path = os.path.normpath(path)
        if self.files is not None:
            return path in self.files
        return os.path.isfile(os.path.join(self.root, path))

    def listdir(self, path: str) -> list[str]:
        path = os.path.normpath(path)
        if self.files is not None:
            pre = path + "/"
            return sorted({f[len(pre):].split("/")[0] for f in self.files if f.startswith(pre)})
        full = os.path.join(self.root, path)
        return sorted(os.listdir(full)) if os.path.isdir(full) else []

    def read(self, path: str) -> str | None:
        path = os.path.normpath(path)
        if path in self.cache:
            return self.cache[path]
        text = None
        if self.batch is not None:
            if path in self.files:
                assert self.batch.stdin and self.batch.stdout
                self.batch.stdin.write(f"{self.rev}:{path}\n".encode())
                self.batch.stdin.flush()
                header = self.batch.stdout.readline().split()
                if len(header) == 3:
                    data = self.batch.stdout.read(int(header[2]))
                    self.batch.stdout.read(1)
                    text = data.decode("utf-8", "replace")
        else:
            try:
                with open(os.path.join(self.root, path), encoding="utf-8", errors="replace") as f:
                    text = f.read()
            except OSError:
                text = None
        self.cache[path] = text
        return text


@dataclass
class Source:
    path: str
    code: str  # comments, strings and chars blanked
    original: str
    lines: list[int] = field(default_factory=list)
    cfgs: list[tuple[int, int, bool, str]] = field(default_factory=list)  # attr start, after attr, inner, predicate
    mods: list[re.Match] | None = None

    @classmethod
    def load(cls, path: str, text: str) -> "Source":
        code = STRIP_RE.sub(_blank, text) if ("/" in text or '"' in text or "'" in text) else text
        lines = [m.start() for m in re.finditer("\n", code)]
        cfgs = []
        for m in CFG_ATTR_RE.finditer(code):
            open_at = m.end() - 1
            close = _match_paren(text, open_at)
            end = code.find("]", close)
            cfgs.append((m.start(), end + 1 if end >= 0 else close + 1, bool(m.group(1)), text[open_at + 1:close]))
        return cls(path, code, text, lines, cfgs)

    def line_of(self, pos: int) -> int:
        return bisect.bisect_left(self.lines, pos) + 1

    def dead_ranges(self, test: bool, features: set[str]) -> list[tuple[int, int]]:
        ranges: list[tuple[int, int]] = []
        covered_to = -1
        for start, _after, inner, pred in self.cfgs:
            if start < covered_to or eval_cfg(pred, test, features):
                continue
            if inner:
                lo, hi = block_of(self.code, start)
            else:
                lo, hi = start, item_end(self.code, start)
            ranges.append((lo, hi))
            covered_to = max(covered_to, hi)
        ranges.sort()
        merged: list[tuple[int, int]] = []
        for lo, hi in ranges:
            if merged and lo <= merged[-1][1]:
                merged[-1] = (merged[-1][0], max(merged[-1][1], hi))
            else:
                merged.append((lo, hi))
        return merged


def is_dead(ranges: list[tuple[int, int]], pos: int) -> bool:
    i = bisect.bisect_right(ranges, (pos, float("inf"))) - 1
    return i >= 0 and ranges[i][0] <= pos < ranges[i][1]


# ---------------------------------------------------------------- crates


@dataclass
class Crate:
    dir: str
    roots: list[tuple[str, bool]]  # (path, test-only)
    features: set[str]
    missing_crates: dict[str, str]  # ident -> why
    missing_items: dict[str, dict[str, str]]  # ident -> item -> why
    # Roots that must have a `main` on Windows too: bins, examples, `harness = false` tests and
    # benches. A `#![cfg(unix)]` file is empty there and fails with E0601 (turn_overhead, 037a5240).
    needs_main: set[str] = field(default_factory=set)


def _workspace_paths(tree: Tree, crate_dir: str) -> tuple[str | None, dict]:
    d = os.path.dirname(os.path.normpath(crate_dir))
    while True:
        text = tree.read(os.path.join(d, "Cargo.toml") if d else "Cargo.toml")
        if text and re.search(r"^\[workspace\]", text, re.M):
            data = tomllib.loads(text)
            return d, data.get("workspace", {}).get("dependencies", {})
        if not d or d == os.path.dirname(d):
            return None, {}
        d = os.path.dirname(d)


def _enabled_features(manifest: dict, start: list[str] | None = None) -> tuple[set[str], set[str]]:
    """The feature closure from `start` (default: `default`), and the optional deps it turns on."""
    feats = manifest.get("features", {})
    on: set[str] = set()
    deps_on: set[str] = set()
    todo = list(start) if start is not None else ["default"]
    while todo:
        f = todo.pop()
        if f in on:
            continue
        on.add(f)
        for item in feats.get(f, []):
            if item.startswith("dep:"):
                deps_on.add(item[4:])
            elif "/" in item:
                dep = item.split("/")[0].rstrip("?")
                if not item.split("/")[0].endswith("?"):
                    deps_on.add(dep)
                    if dep in feats:
                        todo.append(dep)
            elif item in feats:
                todo.append(item)
            else:
                deps_on.add(item)
    return on, deps_on


def _target_on_windows(key: str) -> bool:
    if key.startswith("cfg(") and key.endswith(")"):
        return eval_cfg(key[4:-1], False, set())
    return key == "x86_64-pc-windows-gnu"


def _crate_root_dead(tree: Tree, crate_path: str, asked: set[str], default: bool) -> tuple[bool, dict[str, str]]:
    """Whether a dependency's lib root is `#![cfg(...)]`-off on Windows, and the public top-level
    items of its root that Windows does not get (no arm of the same name is compiled there).
    `asked` and `default` are the features the dependent turns on, across its sections."""
    manifest_text = tree.read(os.path.join(crate_path, "Cargo.toml")) or ""
    lib = "src/lib.rs"
    manifest: dict = {}
    try:
        manifest = tomllib.loads(manifest_text)
        lib = manifest.get("lib", {}).get("path", lib)
    except tomllib.TOMLDecodeError:
        pass
    text = tree.read(os.path.join(crate_path, lib))
    if text is None:
        return False, {}
    features, _ = _enabled_features(manifest, (["default"] if default else []) + sorted(asked))
    src = Source.load(os.path.join(crate_path, lib), text)
    dead = src.dead_ranges(False, features)
    if dead and dead[0] == (0, len(src.code)):
        return True, {}
    # Depth of every offset: top-level items only.
    braces = [(m.start(), 1 if m.group() == "{" else -1) for m in re.finditer(r"[{}]", src.code)]
    depth_at: list[tuple[int, int]] = []
    d = 0
    for pos, step in braces:
        d += step
        depth_at.append((pos, d))

    def depth(pos: int) -> int:
        i = bisect.bisect_left(depth_at, (pos, -10**9)) - 1
        return depth_at[i][1] if i >= 0 else 0

    live: set[str] = set()
    off: dict[str, str] = {}
    for m in TOP_ITEM_RE.finditer(src.code):
        if depth(m.start()):
            continue
        if is_dead(dead, m.start()):
            off.setdefault(m.group(1), f"{src.path}:{src.line_of(m.start())} is behind a cfg Windows does not set")
        else:
            live.add(m.group(1))
    return False, {k: v for k, v in off.items() if k not in live}


def load_crate(tree: Tree, crate_dir: str) -> Crate:
    manifest = tomllib.loads(tree.read(os.path.join(crate_dir, "Cargo.toml")) or "")
    features, deps_on = _enabled_features(manifest)
    ws_dir, ws_deps = _workspace_paths(tree, crate_dir)

    def path_of(name: str, spec) -> str | None:
        if isinstance(spec, dict):
            if spec.get("workspace") and ws_dir is not None:
                w = ws_deps.get(name)
                if isinstance(w, dict) and "path" in w:
                    return os.path.normpath(os.path.join(ws_dir, w["path"]))
            if "path" in spec:
                return os.path.normpath(os.path.join(crate_dir, spec["path"]))
        return None

    on_windows: dict[str, object] = {}
    elsewhere: dict[str, str] = {}
    sections = [("[dependencies]", manifest.get("dependencies", {}), True),
                ("[dev-dependencies]", manifest.get("dev-dependencies", {}), True)]
    for key, tgt in manifest.get("target", {}).items():
        on = _target_on_windows(key)
        sections.append((f"[target.'{key}'.dependencies]", tgt.get("dependencies", {}), on))
        sections.append((f"[target.'{key}'.dev-dependencies]", tgt.get("dev-dependencies", {}), on))
    for label, deps, on in sections:
        for name, spec in deps.items():
            if on:
                optional = isinstance(spec, dict) and spec.get("optional")
                if optional and name not in deps_on:
                    elsewhere.setdefault(name, "an optional dependency no default feature turns on")
                    continue
                on_windows[name] = spec
            else:
                elsewhere.setdefault(name, f"listed only under {label}")

    missing_crates: dict[str, str] = {}
    for name, why in elsewhere.items():
        if name not in on_windows:
            missing_crates[name.replace("-", "_")] = why
    # Features each path dependency gets from this crate (all sections, as cargo unifies them).
    asked: dict[str, set[str]] = {}
    default_on: dict[str, bool] = {}
    for _label, deps, on in sections:
        if not on:
            continue
        for name, spec in deps.items():
            if not isinstance(spec, dict):
                default_on[name] = True
                continue
            w = ws_deps.get(name, {}) if spec.get("workspace") else {}
            w = w if isinstance(w, dict) else {}
            asked.setdefault(name, set()).update(spec.get("features", []), w.get("features", []))
            dflt = spec.get("default-features", w.get("default-features", True))
            default_on[name] = default_on.get(name, False) or bool(dflt)
    for f in features:
        for item in manifest.get("features", {}).get(f, []):
            if "/" in item:
                dep, feat = item.split("/", 1)
                asked.setdefault(dep.rstrip("?"), set()).add(feat)
    missing_items: dict[str, dict[str, str]] = {}
    for name, spec in on_windows.items():
        p = path_of(name, spec)
        if not p:
            continue
        dead, items = _crate_root_dead(tree, p, asked.get(name, set()), default_on.get(name, True))
        ident = name.replace("-", "_")
        if dead:
            missing_crates[ident] = f"its crate root ({p}) is `#![cfg(...)]`-off on Windows"
        elif items:
            missing_items[ident] = items

    roots: list[tuple[str, bool]] = []
    lib = manifest.get("lib", {}).get("path", "src/lib.rs")
    if tree.exists(os.path.join(crate_dir, lib)):
        roots.append((os.path.join(crate_dir, lib), False))
    named = set()
    needs_main: set[str] = set()
    for kind, auto_dir, test_only in (("bin", "src/bin", False), ("test", "tests", True),
                                      ("bench", "benches", True), ("example", "examples", True)):
        explicit = manifest.get(kind, [])
        no_harness = set()
        for t in explicit:
            path = t.get("path")
            if path:
                named.add(os.path.normpath(path))
            if kind in ("bin", "example") or t.get("harness", True) is False:
                if path:
                    needs_main.add(os.path.normpath(os.path.join(crate_dir, path)))
                elif t.get("name"):
                    no_harness.add(t["name"])
            if path and set(t.get("required-features", [])) <= features:
                roots.append((os.path.join(crate_dir, path), test_only))
        if manifest.get("package", {}).get(f"auto{kind}s", True) is False:
            continue
        for entry in tree.listdir(os.path.join(crate_dir, auto_dir)):
            rel = os.path.join(auto_dir, entry)
            if entry.endswith(".rs"):
                cand = rel
            elif tree.exists(os.path.join(crate_dir, rel, "main.rs")):
                cand = os.path.join(rel, "main.rs")
            else:
                continue
            if os.path.normpath(cand) not in named:
                roots.append((os.path.join(crate_dir, cand), test_only))
                stem = entry[:-3] if entry.endswith(".rs") else entry
                if kind in ("bin", "example") or stem in no_harness:
                    needs_main.add(os.path.normpath(os.path.join(crate_dir, cand)))
    if tree.exists(os.path.join(crate_dir, "src/main.rs")) and os.path.normpath("src/main.rs") not in named:
        roots.append((os.path.join(crate_dir, "src/main.rs"), False))
        needs_main.add(os.path.normpath(os.path.join(crate_dir, "src/main.rs")))
    return Crate(crate_dir, roots, features, missing_crates, missing_items, needs_main)


# ---------------------------------------------------------------- findings


def _starts_path(code: str, at: int) -> bool:
    """`at` begins a path (`x::`, `::x::`), not the tail of one (`a::x`, `a.x`, `ax`)."""
    if code.startswith("::", at - 2):
        at -= 2
    return at == 0 or not (code[at - 1].isalnum() or code[at - 1] in "_:.")


def _led(why):
    # Patterns open with their literal so `re` can skip ahead to it (a leading look-behind made
    # it try every offset: 1.4 s of the 5 s over acpmux); the start is checked here instead.
    return lambda m: why(m) if _starts_path(m.string, m.start()) else None


def _patterns(crate: Crate, libc_ok: set[str]):
    out = [
        (("unix", "fd"), re.compile(r"std\s*::\s*os\s*::\s*(?:(unix|fd)\b|\{[^}]*?\b(unix|fd)\b)"),
         _led(lambda m: f"`std::os::{m.group(1) or m.group(2)}` is unix-only"), False),
        # `net::UnixStream` (tokio's, std's through std::os::unix): a bare `UnixStream` may be a
        # crate's own Windows stand-in (router_socket::UnixStream), so only the `net::` path counts.
        ("Unix", re.compile(r"net\s*::\s*(?:(Unix(?:Stream|Listener|Datagram))\b|\{[^}]*?\b(Unix(?:Stream|Listener|Datagram))\b)"),
         lambda m: (f"`net::{m.group(1) or m.group(2)}` is unix-only"
                    if m.start() == 0 or not (m.string[m.start() - 1].isalnum() or m.string[m.start() - 1] == "_") else None), False),
    ]
    libc_re = re.compile(r"libc\s*::\s*(?:(\w+)|\{([^}]*)\})")

    def libc_why(m):
        names = [m.group(1)] if m.group(1) else re.findall(r"\b\w+\b", m.group(2) or "")
        bad = [n for n in names if n not in libc_ok and n != "self"]
        return f"`libc::{', '.join(bad)}` is not in libc for windows-gnu" if bad else None

    out.append(("libc", libc_re, _led(libc_why), False))
    if crate.missing_crates:
        alt = "|".join(sorted(map(re.escape, crate.missing_crates), key=len, reverse=True))
        cre = re.compile(rf"({alt})\b(?=\s*(?:::|;|\s+as\b))")
        out.append((tuple(crate.missing_crates), cre,
                    _led(lambda m: f"crate `{m.group(1)}` is not built for Windows ({crate.missing_crates[m.group(1)]})"), True))
    for ident, items in crate.missing_items.items():
        alt = "|".join(sorted(map(re.escape, items), key=len, reverse=True))
        ire = re.compile(rf"({re.escape(ident)})\s*::\s*(?:\{{[^}}]*?\b)?({alt})\b")
        out.append((ident, ire, _led(lambda m, items=items: f"`{m.group(1)}::{m.group(2)}` is off on Windows ({items[m.group(2)]})"), True))
    return out


def _brace_depths(code: str) -> tuple[list[int], list[int]]:
    """Positions of `{` and `}` and the depth just after each, for depth_at."""
    pos: list[int] = []
    depth: list[int] = []
    d = 0
    for m in re.finditer(r"[{}]", code):
        d += 1 if m.group() == "{" else -1
        pos.append(m.start())
        depth.append(d)
    return pos, depth


def _depth_at(braces: tuple[list[int], list[int]], at: int) -> int:
    i = bisect.bisect_left(braces[0], at) - 1
    return braces[1][i] if i >= 0 else 0


@dataclass
class _Visit:
    src: Source
    dead: list[tuple[int, int]]
    module: tuple  # (root, name, name, ...)
    inline: list[tuple[int, int, str]]


def _module_at(v: _Visit, at: int) -> tuple:
    return v.module + tuple(n for lo, hi, n in v.inline if lo < at < hi)


def _path_groups(code: str, at: int) -> list[list[str]]:
    """The paths that start at `at` (just after `crate::`, `super::` or `self::`): one, or each entry
    of a `{a, b::c}` group (their leading segments; enough to resolve the module part)."""
    segs: list[str] = []
    while True:
        m = SEG_RE.match(code, at)
        if m and m.group(1) not in ("super", "self", "crate") or (m and m.group(1) == "super" and m.group(2)):
            segs.append(m.group(1))
            at = m.end()
            if not m.group(2):
                return [segs]
            continue
        rest = code[at:at + 1] if not m else ""
        k = at
        while k < len(code) and code[k].isspace():
            k += 1
        if k < len(code) and code[k] == "{":
            close = _match_brace(code, k)
            out = []
            depth = 0
            start = k + 1
            for q in range(k + 1, close + 1):
                c = code[q]
                if c == "{":
                    depth += 1
                elif c == "}" and depth:
                    depth -= 1
                elif (c == "," and depth == 0) or q == close:
                    entry = code[start:q]
                    first = [x for x in re.findall(r"\w+", entry.split("{")[0]) if x != "as"]
                    if first and first[0] not in ("self", "super", "crate"):
                        parts = re.split(r"\s*::\s*", entry.split("{")[0].split(" as ")[0].strip())
                        out.append(segs + [x for x in parts if x])
                    start = q + 1
            return out or [segs]
        del rest
        return [segs]


def scan(tree: Tree, crate_dir: str, libc_ok: set[str]) -> list[tuple[str, int, str]]:
    crate = load_crate(tree, crate_dir)
    pats = _patterns(crate, libc_ok)
    sources: dict[str, Source] = {}
    hits: dict[str, list[tuple[int, str, str | None]]] = {}
    found: dict[tuple[str, int, str], None] = {}
    braces: dict[str, tuple[list[int], list[int]]] = {}
    for test in (False, True):
        seen: set[str] = set()
        visits: dict[str, _Visit] = {}
        # Every module and module-level item, by its full path: declared live, or only under a cfg
        # Windows does not set (with where that cfg is).
        live_decl: set[tuple] = set()
        dead_decl: dict[tuple, tuple[str, int]] = {}
        todo = [(path, os.path.dirname(path), (path,)) for path, test_only in crate.roots if test or not test_only]
        while todo:
            path, mod_dir, module = todo.pop()
            path = os.path.normpath(path)
            if path in seen:
                continue
            seen.add(path)
            src = sources.get(path)
            if src is None:
                text = tree.read(path)
                if text is None:
                    continue
                src = sources[path] = Source.load(path, text)
            dead = src.dead_ranges(test, crate.features)
            no_main = any(m.group(1) is None or eval_cfg(m.group(1), test, crate.features)
                          for m in NO_MAIN_RE.finditer(src.original)) if "no_main" in src.original else False
            if path in crate.needs_main and not no_main:
                mains = [m.start() for m in MAIN_RE.finditer(src.code)]
                if not any(not is_dead(dead, at) for at in mains):
                    at = mains[0] if mains else next((c[0] for c in src.cfgs if c[2]), 0)
                    found[(path, src.line_of(at), "no `main` on Windows: a `#![cfg(...)]` or `#[cfg]` takes it out "
                           "(E0601); add a `#[cfg(not(unix))] fn main() {}`")] = None
            if dead and dead[0] == (0, len(src.code)):
                continue
            # Inline modules (`mod x { ... }`) nest the directory of a `mod y;` inside them.
            if src.mods is None:
                src.mods = list(MOD_RE.finditer(src.code)) if "mod" in src.code else []
            inline: list[tuple[int, int, str]] = []
            for m in src.mods:
                if m.group(2) == "{" and not is_dead(dead, m.start()):
                    inline.append((m.end() - 1, _match_brace(src.code, m.end() - 1), m.group(1)))
            v = visits[path] = _Visit(src, dead, module, inline)
            if path not in braces:
                braces[path] = _brace_depths(src.code)
            bd = braces[path]
            for m in src.mods:
                full = _module_at(v, m.start()) + (m.group(1),)
                if is_dead(dead, m.start()):
                    dead_decl.setdefault(full, (path, src.line_of(m.start())))
                else:
                    live_decl.add(full)
            for m in USE_RE.finditer(src.code):
                if is_dead(dead, m.start()):
                    continue
                here = _module_at(v, m.start())
                for name in re.findall(r"(\w+)\s*(?=[,}]|$)", m.group(1).strip()):
                    live_decl.add(here + (name,))
            for m in ITEM_RE.finditer(src.code):
                at = m.start(1)
                here = _module_at(v, at)
                if _depth_at(bd, at) != len(here) - len(module):
                    continue  # a method, a local or a field, not a module-level item
                full = here + (m.group(1),)
                if is_dead(dead, at):
                    dead_decl.setdefault(full, (path, src.line_of(at)))
                else:
                    live_decl.add(full)
            for m in src.mods:
                if m.group(2) != ";" or is_dead(dead, m.start()):
                    continue
                name = m.group(1)
                nest = [n for lo, hi, n in inline if lo < m.start() < hi] if inline else []
                lead = VIS_TAIL_RE.sub("", src.original[max(0, m.start() - 600):m.start()]).rstrip()
                attrs = ATTR_TAIL_RE.search(lead)
                pa = PATH_ATTR_RE.search(attrs.group()) if attrs else None
                here = os.path.dirname(path)
                child = module + tuple(nest) + (name,)
                if pa:
                    # A `#[path]` file reads its own `mod x;` as a mod.rs does: from its directory.
                    target = os.path.normpath(os.path.join(os.path.join(here, *nest) if nest else here, pa.group(1)))
                    todo.append((target, os.path.dirname(target), child))
                    continue
                base = mod_dir if mod_dir is not None else os.path.splitext(path)[0]
                base = os.path.join(base, *nest)
                for cand in (os.path.join(base, name + ".rs"), os.path.join(base, name, "mod.rs")):
                    if tree.exists(cand):
                        child_dir = os.path.dirname(cand) if cand.endswith("mod.rs") else os.path.join(base, name)
                        todo.append((cand, child_dir, child))
                        break
            if path not in hits:
                hits[path] = []
                for need, rx, why, shadow in pats:
                    needs = (need,) if isinstance(need, str) else need
                    if not any(n in src.code for n in needs):
                        continue
                    for m in rx.finditer(src.code):
                        w = why(m)
                        if w:
                            hits[path].append((m.start(), w, m.group(1) if shadow else None))
        off = {k: where for k, where in dead_decl.items() if k not in live_decl}
        children: dict[tuple, set[str]] = {}
        for k in off:
            children.setdefault(k[:-1], set()).add(k[-1])
        for path, v in visits.items():
            src, dead = v.src, v.dead
            for pos, w, ident in hits[path]:
                if is_dead(dead, pos):
                    continue
                # A module of the same name declared here is what the path names (`mod time;`).
                if ident and _module_at(v, pos) + (ident,) in live_decl:
                    continue
                found[(path, src.line_of(pos), w)] = None
            if not off:
                continue
            for m in REL_RE.finditer(src.code):
                at = m.start()
                if not _starts_path(src.code, at) or is_dead(dead, at):
                    continue
                here = _module_at(v, at)
                base = (here[0],) if m.group(1) == "crate" else here
                if m.group(1) == "super":
                    base = base[:-1]
                for segs in _path_groups(src.code, m.end()):
                    cur = base
                    for seg in segs:
                        if seg == "super":
                            cur = cur[:-1]
                            continue
                        cur = cur + (seg,)
                        if cur in off:
                            wp, wl = off[cur]
                            found[(path, src.line_of(at), f"`{'::'.join(cur[1:])}` is declared only under a cfg Windows "
                                   f"does not set ({wp}:{wl})")] = None
                            break
                        if cur not in live_decl:
                            break
            names = set()
            for lo_mod in {v.module} | {_module_at(v, lo + 1) for lo, _hi, _n in v.inline}:
                names |= children.get(lo_mod, set())
            if not names:
                continue
            alt = "|".join(sorted(map(re.escape, names), key=len, reverse=True))
            for m in re.finditer(rf"\b({alt})\b(?=\s*(?:::|\())", src.code):
                at = m.start()
                if not _starts_path(src.code, at) or is_dead(dead, at):
                    continue
                if DECL_BEFORE_RE.search(src.code, max(0, at - 16), at):
                    continue
                full = _module_at(v, at) + (m.group(1),)
                if full in off:
                    wp, wl = off[full]
                    found[(path, src.line_of(at), f"`{m.group(1)}` is declared only under a cfg Windows "
                           f"does not set ({wp}:{wl})")] = None
    return sorted(found)


def write_libc_list(src_dir: str) -> None:
    names = {"c_void"}
    for rel in ("windows/mod.rs", "windows/gnu/mod.rs", "primitives.rs"):
        with open(os.path.join(src_dir, rel), encoding="utf-8") as f:
            text = STRIP_RE.sub(" ", f.read())
        names.update(re.findall(r"\b(?:fn|const|type|struct|union|enum|static)\s+(?:mut\s+)?([A-Za-z_]\w*)", text))
        for group in re.findall(r"\bpub\s+use\s+[\w:]+::\{([^}]*)\}", text):
            names.update(re.findall(r"\b[A-Za-z_]\w*\b", group))
        names.update(re.findall(r"\bpub\s+use\s+[\w:]+::([A-Za-z_]\w*)\s*;", text))
    with open(LIBC_LIST, "w", encoding="utf-8") as f:
        f.write(f"# libc items on x86_64-pc-windows-gnu, from {os.path.basename(os.path.dirname(src_dir.rstrip('/')))}\n")
        f.write("# (src/windows/mod.rs, src/windows/gnu/mod.rs, src/primitives.rs, core::ffi::c_void).\n")
        f.write("# Regenerate: python3 scripts/ci/unix_only_on_windows.py --write-libc-list ~/.cargo/registry/src/*/libc-0.2.N/src\n")
        for n in sorted(names):
            f.write(n + "\n")


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--rev", help="read the sources at this commit instead of the work tree")
    ap.add_argument("--crate", action="append", help="crate directory (repeatable)")
    ap.add_argument("--root", default=os.path.dirname(os.path.dirname(HERE)))
    ap.add_argument("--github", action="store_true", help="print ::error annotations")
    ap.add_argument("--write-libc-list", metavar="LIBC_SRC_DIR")
    args = ap.parse_args(argv)
    if args.write_libc_list:
        write_libc_list(args.write_libc_list)
        return 0
    with open(LIBC_LIST, encoding="utf-8") as f:
        libc_ok = {ln.strip() for ln in f if ln.strip() and not ln.startswith("#")}
    tree = Tree(args.root, args.rev)
    findings = []
    for crate_dir in args.crate or DEFAULT_CRATES:
        findings += scan(tree, crate_dir, libc_ok)
    for path, line, why in findings:
        if args.github:
            print(f"::error file={path},line={line},title=unix-only on Windows::{why}; put it behind #[cfg(unix)] and give Windows its own arm")
        else:
            print(f"{path}:{line}: {why}")
    if findings:
        print(f"unix-only-on-windows: {len(findings)} use(s) that cargo check --target x86_64-pc-windows-gnu refuses "
              "(cmux-tui-windows-check runs only after merge). A #[cfg(unix)] covers one item; a mod's covers its file.",
              file=sys.stderr)
        return 1
    print(f"unix-only-on-windows: clean ({', '.join(args.crate or DEFAULT_CRATES)})", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
