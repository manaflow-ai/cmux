#!/usr/bin/env python3
"""Catch a pull request head up with its base: merge, resolve generated files, commit.

Slice 1 of RFC #14631. A pull request that was green goes stale when main
moves, and the mechanical conflicts that follow (pbxproj ordering, the
embedded config schema, string catalogs) cost a person a merge and a fix.
This merges the base into the checked-out head with `--no-ff`, resolves only
the files whose correct content a generator or a key-wise merge decides, and
commits. It never rebases, never force-pushes and never pushes at all: the
PR catch-up workflow (.github/workflows/pr-catch-up.yml) owns the push.

Resolved on conflict, all with tools from `--tools-root`, never from the tree
being merged (the workflow runs this against untrusted pull request bytes):

- cmux.xcodeproj/project.pbxproj: a three-way union of the conflicted hunks
  when both sides only inserted lines (two branches each adding a file), then
  scripts/normalize-pbxproj.py, which also rejects broken syntax and duplicate
  object IDs. A hunk where either side changed or removed a base line stops,
  and so does a union that repeats a key in any dictionary (two values for
  one build setting).
- The embedded config schema Swift: regenerated with
  scripts/generate-cmux-config-schema.py from the merged
  web/data/cmux.schema.json. It is also regenerated when both sides changed
  the schema and git merged the Swift text cleanly, since a textual merge of
  two base64 blobs is not the encoding of the merged schema. A conflict in the
  schema JSON itself, or merged schema text that is not valid JSON, stops.
- *.xcstrings: a key-level three-way merge through scripts/merge-xcstrings.py.
  The same key changed differently on both sides stops, naming the keys.
- Source files in brace languages (SOURCE_SUFFIXES): a conflicted hunk where
  one side only inserted whole declarations (a function, a type, an enum case)
  keeps the other side's lines and places those declarations at the same
  brace depth; where both sides only inserted declarations, both are kept.
  Anything else in the hunk (either side editing a base line that the other
  also touched, an inserted statement, an unbalanced block) stops. The push
  job re-derives each such file from the three blobs (verify), so nothing
  else can ride along.

Git attributes come from the base commit (`attr.tree`), not from the head, so
a pull request cannot pick merge drivers such as `union` for its own merge.
A resolver only touches regular files: a symlink or submodule at a resolved
path, or a symlinked parent directory, stops instead of reading or writing
through it.

Any other conflicted path, a path added or deleted on only one side, or a
generator failure aborts the merge and exits 1. `--json` prints a
machine-readable result with the blocking files either way.

Exit codes: 0 merged or already up to date, 1 blocked (needs a person),
2 error (dirty tree, unknown ref, git failure).

Usage:
  catch_up_pr.py merge --base origin/main|SHA [--repo DIR] [--tools-root DIR] [--title T] [--json]
  catch_up_pr.py verify --repo DIR --head SHA --base SHA --merged SHA --base-tip REF
  catch_up_pr.py comment --result result.json --push pushed|... [--auto --head-sha SHA]
  catch_up_pr.py read-result --file outputs.json [--pin SHA]
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import re
import subprocess
import sys
import tempfile
from dataclasses import dataclass, field
from pathlib import Path

RESULT_SCHEMA = "catch-up-result/v1"
DEFAULT_TOOLS_ROOT = Path(__file__).resolve().parents[2]

PBXPROJ = "cmux.xcodeproj/project.pbxproj"
SCHEMA_JSON = "web/data/cmux.schema.json"
SCHEMA_SWIFT = (
    "Packages/macOS/CmuxFoundation/Sources/CmuxFoundation/ConfigValidation/"
    "CmuxConfigSchema.generated.swift"
)
NORMALIZER = "scripts/normalize-pbxproj.py"
SCHEMA_GENERATOR = "scripts/generate-cmux-config-schema.py"
XCSTRINGS_MERGER = "scripts/merge-xcstrings.py"

# Wide conflict markers so a line of seven `<` inside the file cannot pass
# for one.
MARKER_SIZE = 32
# One pbxproj list or object entry: `ID /* label */,` or `ID /* label */ = {...};`.
PBX_ENTRY_RE = re.compile(r"^\s*[0-9A-Za-z]+ /\* .* \*/(,| = \{.*\};)\s*$")
PBX_ID_RE = re.compile(r"^\s*([0-9A-Za-z]+) /\*")
REGULAR_MODES = {"100644", "100755"}
# attr.tree, which keeps the head's .gitattributes out of the merge.
MIN_GIT = (2, 46)

# Every git call pins the settings that change what a merge produces or what
# runs during it. Hooks are off: this tree may be untrusted, and the
# generators already did what the pbxproj pre-commit hook would. The
# .xcstrings and .pbxproj merge drivers are replaced by `false` so git leaves
# those files unmerged for the trusted merges below; a clone configured by
# scripts/install-git-hooks.sh would otherwise run the driver from the tree
# being merged, which on a fork head is untrusted code.
GIT = [
    "git",
    "-c", "core.hooksPath=/dev/null",
    "-c", "merge.conflictStyle=diff3",
    "-c", "merge.xcstrings.driver=false",
    "-c", "merge.xcstrings-v2.driver=false",
    "-c", "merge.pbxproj.driver=false",
    "-c", "merge.pbxproj-v1.driver=false",
    "-c", "rerere.enabled=false",
    "-c", "maintenance.auto=false",
    "-c", "gc.auto=0",
]


class CatchUpError(Exception):
    """A failure that is not a conflict: bad input or git refusing to run."""


@dataclass
class Result:
    status: str = "error"
    base_ref: str = ""
    base: str | None = None
    head_before: str | None = None
    head_after: str | None = None
    resolved: list[dict[str, str]] = field(default_factory=list)
    blocking: list[dict[str, str]] = field(default_factory=list)
    message: str = ""

    def as_json(self) -> dict:
        return {
            "schema": RESULT_SCHEMA,
            "status": self.status,
            "base_ref": self.base_ref,
            "base": self.base,
            "head_before": self.head_before,
            "head_after": self.head_after,
            "resolved": self.resolved,
            "blocking": self.blocking,
            "message": self.message,
        }


class Repo:
    def __init__(self, path: Path) -> None:
        self.path = path
        # Read .gitattributes from this commit instead of the working tree.
        self.attr_tree: str | None = None

    def run(self, *args: str, check: bool = True, input_bytes: bytes | None = None) -> subprocess.CompletedProcess:
        attr = ["-c", f"attr.tree={self.attr_tree}"] if self.attr_tree else []
        completed = subprocess.run(
            [*GIT, *attr, *args], cwd=self.path, input=input_bytes, capture_output=True,
        )
        if check and completed.returncode != 0:
            raise CatchUpError(
                f"git {' '.join(args)} failed: {completed.stderr.decode(errors='replace').strip()}"
            )
        return completed

    def text(self, *args: str) -> str:
        return self.run(*args).stdout.decode().strip()

    def blob_id(self, rev: str, path: str) -> str | None:
        completed = self.run("rev-parse", "--verify", "--quiet", f"{rev}:{path}", check=False)
        return completed.stdout.decode().strip() or None

    def stage_bytes(self, stage: int, path: str) -> bytes:
        return self.run("show", f":{stage}:{path}").stdout

    def unmerged(self) -> dict[str, set[int]]:
        """Conflicted paths mapped to the index stages present (1 base, 2 ours, 3 theirs)."""
        return {path: set(stages) for path, stages in self.index_modes(unmerged=True).items()}

    def index_modes(self, *paths: str, unmerged: bool = False) -> dict[str, dict[int, str]]:
        """Index entries as path -> {stage: mode}; stage 0 is a merged entry."""
        modes: dict[str, dict[int, str]] = {}
        args = ["ls-files", "--unmerged" if unmerged else "--stage", "-z"]
        raw = self.run(*args, "--", *paths).stdout.decode()
        for record in filter(None, raw.split("\0")):
            meta, path = record.split("\t", 1)
            mode, _, stage = meta.split()
            modes.setdefault(path, {})[int(stage)] = mode
        return modes

    def unsafe(self, path: str) -> str | None:
        """Why a resolver must not read or write this path, or None when it is a plain file."""
        modes = self.index_modes(path).get(path, {})
        if any(mode not in REGULAR_MODES for mode in modes.values()):
            return "not a regular file (symlink or submodule)"
        current = self.path
        for part in Path(path).parts:
            current = current / part
            if current.is_symlink():
                return "reached through a symlink"
        return None


def run_tool(tools_root: Path, script: str, args: list[str], cwd: Path) -> subprocess.CompletedProcess:
    """Run a trusted repository script in isolated mode (no PYTHON* env, no cwd on sys.path)."""
    tool = tools_root / script
    if not tool.is_file():
        raise CatchUpError(f"trusted tool missing: {tool}")
    return subprocess.run(
        [sys.executable, "-I", str(tool), *args], cwd=cwd, capture_output=True, text=True,
    )


def load_xcstrings_merger(tools_root: Path):
    path = tools_root / XCSTRINGS_MERGER
    if not path.is_file():
        raise CatchUpError(f"trusted tool missing: {path}")
    spec = importlib.util.spec_from_file_location("catch_up_merge_xcstrings", path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


# --- pbxproj -----------------------------------------------------------------


def split_conflicts(text: str) -> list[str | tuple[list[str], list[str], list[str]]]:
    """Split `git merge-file --diff3` output into clean lines and (ours, base, theirs) hunks."""
    ours_mark, base_mark = "<" * MARKER_SIZE, "|" * MARKER_SIZE
    split_mark, theirs_mark = "=" * MARKER_SIZE, ">" * MARKER_SIZE
    parts: list[str | tuple[list[str], list[str], list[str]]] = []
    state = None
    ours: list[str] = []
    base: list[str] = []
    theirs: list[str] = []
    for line in text.splitlines(keepends=True):
        if line.startswith(ours_mark) and state is None:
            state, ours, base, theirs = "ours", [], [], []
        elif line.startswith(base_mark) and state == "ours":
            state = "base"
        elif line.rstrip("\r\n") == split_mark and state == "base":
            state = "theirs"
        elif line.startswith(theirs_mark) and state == "theirs":
            parts.append((ours, base, theirs))
            state = None
        elif state == "ours":
            ours.append(line)
        elif state == "base":
            base.append(line)
        elif state == "theirs":
            theirs.append(line)
        else:
            parts.append(line)
    if state is not None:
        raise ValueError("unterminated conflict hunk")
    return parts


def insertions(base: list[str], side: list[str]) -> list[list[str]] | None:
    """Lines this side inserted before each base line (and after the last).

    None when the side changed or removed any base line: only pure insertions
    are safe to union.
    """
    slots: list[list[str]] = [[] for _ in range(len(base) + 1)]
    index = 0
    for line in side:
        if index < len(base) and line == base[index]:
            index += 1
        else:
            slots[index].append(line)
    return slots if index == len(base) else None


def inserted_ids(slots: list[list[str]]) -> dict[str, list]:
    """Object IDs a side inserted, with their slots and lines."""
    ids: dict[str, list] = {}
    for slot, lines in enumerate(slots):
        for line in lines:
            if match := PBX_ID_RE.match(line):
                ids.setdefault(match.group(1), []).append((slot, line))
    return ids


def collides(ours_slots: list[list[str]], theirs_slots: list[list[str]]) -> bool:
    """Both sides inserted the same object ID differently.

    An identical entry in the same place is one entry and is deduplicated. The
    same ID elsewhere would become a duplicate list entry or object. Repeated
    dictionary keys (two values for one build setting) are caught on the
    whole merged file by duplicate_keys().
    """
    ours_ids, theirs_ids = inserted_ids(ours_slots), inserted_ids(theirs_slots)
    return any(ours_ids[key] != theirs_ids[key] for key in ours_ids.keys() & theirs_ids.keys())


PBX_TOKEN_RE = re.compile(
    r'(?P<comment>/\*.*?\*/|//[^\n]*)|(?P<string>"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\')|'
    r'(?P<data><[0-9A-Fa-f\s]*>)|(?P<punctuation>[{}=;(),])|(?P<scalar>[^\s{}=;(),"\']+)',
    re.DOTALL,
)


def duplicate_keys(text: str) -> list[str]:
    """Keys that appear twice in one dictionary, at any depth.

    A key is the scalar before `=` inside `{ }`, whatever its value: a
    scalar, a `( list )` or a nested `{ dictionary }`. Xcode keeps one of two
    values silently, so a union that produces both must stop.
    """
    tokens = [m.group() for m in PBX_TOKEN_RE.finditer(text) if m.lastgroup != "comment"]
    stack: list[set[str] | None] = []
    duplicates: list[str] = []
    for index, token in enumerate(tokens):
        if token == "{":
            stack.append(set())
        elif token == "(":
            stack.append(None)
        elif token in "})" and stack:
            stack.pop()
        elif token == "=" and index and stack and stack[-1] is not None:
            key = tokens[index - 1].strip("\"'")
            if key in stack[-1]:
                duplicates.append(key)
            stack[-1].add(key)
    return duplicates


def union_hunk(ours: list[str], base: list[str], theirs: list[str]) -> list[str] | None:
    ours_slots, theirs_slots = insertions(base, ours), insertions(base, theirs)
    if ours_slots is None or theirs_slots is None or collides(ours_slots, theirs_slots):
        return None
    merged: list[str] = []
    for slot, (ours_lines, theirs_lines) in enumerate(zip(ours_slots, theirs_slots)):
        merged.extend(ours_lines)
        # The same entry added on both sides is one entry, not two.
        merged.extend(
            line for line in theirs_lines
            if not (line in ours_lines and PBX_ENTRY_RE.match(line))
        )
        if slot < len(base):
            merged.append(base[slot])
    return merged


def merge_file(base: str, ours: str, theirs: str) -> str:
    """`git merge-file --diff3` of three texts, conflicts marked MARKER_SIZE wide."""
    with tempfile.TemporaryDirectory() as scratch:
        files = []
        for name, text in (("ours", ours), ("base", base), ("theirs", theirs)):
            path = Path(scratch) / name
            path.write_text(text, encoding="utf-8")
            files.append(str(path))
        completed = subprocess.run(
            ["git", "merge-file", "-p", "--diff3", f"--marker-size={MARKER_SIZE}",
             "-L", "ours", "-L", "base", "-L", "theirs", *files],
            capture_output=True,
        )
    if completed.returncode < 0 or completed.returncode > 127:
        raise ValueError(f"git merge-file failed: {completed.stderr.decode(errors='replace').strip()}")
    return completed.stdout.decode("utf-8")


def union_pbxproj(base: str, ours: str, theirs: str) -> str:
    """Three-way merge where each conflicted hunk must be insertions on both sides."""
    if any(marker_line(line) for text in (base, ours, theirs) for line in text.splitlines()):
        raise ValueError("a side has conflict-marker lines")
    out: list[str] = []
    for part in split_conflicts(merge_file(base, ours, theirs)):
        if isinstance(part, str):
            out.append(part)
            continue
        merged = union_hunk(*part)
        if merged is None:
            raise ValueError(
                "both sides changed the same lines or added the same entry differently;"
                " only distinct added lines can be merged"
            )
        out.extend(merged)
    result = "".join(out)
    if duplicates := duplicate_keys(result):
        raise ValueError("the union repeats a key: " + ", ".join(sorted(set(duplicates))[:5]))
    return result


# --- source files: inserted declarations ---------------------------------------

# Brace languages, where a declaration's nesting is its brace depth.
SOURCE_SUFFIXES = (".swift", ".m", ".mm", ".h", ".c", ".cc", ".cpp", ".go", ".rs", ".kt", ".java",
                   ".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs")
# A line that starts a declaration whose order among its siblings does not
# change what the program does: a keyword, then a name. Statements (let, var,
# const, calls, switch cases) and enum cases (raw values, CaseIterable) are
# not declarations here.
DECLARATION_RE = re.compile(
    r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*"
    r"(?:(?:public|private|internal|fileprivate|open|package|static|class|final|override|mutating|nonisolated|"
    r"convenience|required|export|default|async|abstract|pub(?:\([^)]*\))?|unsafe)\s+)*"
    r"(?:(?:func|struct|class|enum|extension|protocol|actor|typealias|function|interface|fn|impl|trait|fun|object)"
    r"\s+[A-Za-z_]"
    r"|(?:init|deinit|subscript)\b.*\{)"
)
ATTRIBUTE_RE = re.compile(r"^\s*@\w+(?:\([^)]*\))?\s*$")
CLOSING_RE = re.compile(r"^\s*\}[\s;,)]*$")
DIRECTIVE_RE = re.compile(r"^\s*#\s*(?:if|ifdef|ifndef|elif|elseif|else|endif)\b")


def marker_line(line: str) -> bool:
    return line.startswith(("<" * MARKER_SIZE, "|" * MARKER_SIZE, "=" * MARKER_SIZE, ">" * MARKER_SIZE))


def comment_line(line: str) -> bool:
    return line.lstrip().startswith(("//", "/*", "*/"))


def opaque(line: str) -> bool:
    """A line whose braces may not be code: a brace next to a quote, a comment or a directive."""
    if DIRECTIVE_RE.match(line):
        return True
    return ("{" in line or "}" in line) and any(mark in line for mark in ('"', "'", "`", "//", "/*", "*/"))


def depths(lines: list[str]) -> list[int]:
    """Brace depth before each line and after the last, relative to the first."""
    out = [0]
    for line in lines:
        out.append(out[-1] + line.count("{") - line.count("}"))
    return out


def declaration_block(lines: list[str]) -> bool:
    """Whole declarations: every line at the block's own level is a declaration start, an attribute,
    a comment, a closing brace or blank, and the braces balance without going below 0."""
    level = depths(lines)
    if level[-1] != 0 or min(level) < 0 or any(opaque(line) for line in lines):
        return False
    started = False
    for line, before in zip(lines, level):
        if before or not line.strip() or comment_line(line) or ATTRIBUTE_RE.match(line) or CLOSING_RE.match(line):
            continue
        if not DECLARATION_RE.match(line):
            return False
        started = True
    return started


def graft(other: list[str], base: list[str], slots: list[list[str]]) -> list[str] | None:
    """`other` with the declarations one side inserted into `base` placed in the hunk's own scope.

    Only blocks inserted at the scope the hunk starts in (depth 0, never
    leaving it before the slot) move, and only to a spot in `other` in that
    same scope: at its start, after a blank line or after a closing brace, so
    nothing takes or loses an attribute or a doc comment. The spot nearest the block's relative position wins, the
    earlier on a tie. None when anything does not hold.
    """
    if any(opaque(line) for line in other + base):
        return None
    base_level, other_level = depths(base), depths(other)
    placed: list[tuple[int, int, list[str]]] = []
    for slot, lines in enumerate(slots):
        if not lines:
            continue
        if not declaration_block(lines) or base_level[slot] != 0 or min(base_level[:slot + 1]) < 0:
            return None
        spots = []
        for p in range(len(other) + 1):
            if other_level[p] != 0 or min(other_level[:p + 1]) < 0:
                continue
            # Never right after an attribute or a comment, which belong to the next declaration.
            if p == 0 or not other[p - 1].strip() or CLOSING_RE.match(other[p - 1]):
                spots.append(p)
        if not spots:
            return None
        target = slot * len(other) / max(1, len(base))
        placed.append((min(spots, key=lambda p: (abs(p - target), p)), slot, lines))
    out: list[str] = []
    placed.sort(key=lambda item: (item[0], item[1]))
    index = 0
    for position, _slot, lines in placed:
        out.extend(other[index:position])
        out.extend(lines)
        index = position
    out.extend(other[index:])
    return out


def merge_declarations_hunk(ours: list[str], base: list[str], theirs: list[str]) -> list[str] | None:
    ours_slots, theirs_slots = insertions(base, ours), insertions(base, theirs)
    if ours_slots is not None and theirs_slots is not None:
        if not all(declaration_block(lines) for lines in ours_slots + theirs_slots if lines):
            return None
        merged: list[str] = []
        for slot, (ours_lines, theirs_lines) in enumerate(zip(ours_slots, theirs_slots)):
            merged.extend(ours_lines)
            if theirs_lines != ours_lines:
                merged.extend(theirs_lines)
            if slot < len(base):
                merged.append(base[slot])
        return merged
    if ours_slots is not None:
        return graft(theirs, base, ours_slots)
    if theirs_slots is not None:
        return graft(ours, base, theirs_slots)
    return None


def merge_declarations(base: str, ours: str, theirs: str) -> str:
    """Three-way merge where each conflicted hunk is inserted declarations on at least one side.

    A line that looks like a wide conflict marker in any input stops it, so
    marker-shaped lines in a pull request cannot steer split_conflicts().
    """
    if any(marker_line(line) for text in (base, ours, theirs) for line in text.splitlines()):
        raise ValueError("a side has conflict-marker lines")
    out: list[str] = []
    for part in split_conflicts(merge_file(base, ours, theirs)):
        if isinstance(part, str):
            out.append(part)
            continue
        merged = merge_declarations_hunk(*part)
        if merged is None:
            raise ValueError("both sides changed the same lines")
        out.extend(merged)
    return "".join(out)


def source_path(path: str) -> bool:
    return path.endswith(SOURCE_SUFFIXES) and not path.startswith(".github/")


# --- the merge ---------------------------------------------------------------


@dataclass
class Resolver:
    repo: Repo
    tools_root: Path
    resolved: list[dict[str, str]] = field(default_factory=list)
    blocking: list[dict[str, str]] = field(default_factory=list)

    def block(self, path: str, reason: str) -> None:
        if any(item["path"] == path for item in self.blocking):
            return
        self.blocking.append({"path": path, "reason": reason})

    def done(self, path: str, method: str) -> None:
        self.repo.run("add", "--", path)
        self.resolved.append({"path": path, "method": method})

    def xcstrings(self, path: str) -> None:
        if problem := self.repo.unsafe(path):
            self.block(path, problem)
            return
        merger = load_xcstrings_merger(self.tools_root)
        try:
            texts = [self.repo.stage_bytes(stage, path).decode("utf-8") for stage in (1, 2, 3)]
            merged, conflicts, planned = merger.merge_catalog_text(*texts)
            reparsed = json.loads(merged)
            if not isinstance(reparsed, dict):
                raise ValueError("catalog is not an object")
        except (ValueError, AttributeError, KeyError, TypeError, IndexError) as error:
            self.block(path, f"string catalog could not be merged by key ({error.__class__.__name__})")
            return
        if conflicts:
            shown = ", ".join(code(key) for key in conflicts[:10]) + (f" and {len(conflicts) - 10} more" if len(conflicts) > 10 else "")
            self.block(path, f"same key changed on both sides: {shown}")
            return
        if list(reparsed.get("strings", {})) != planned:
            self.block(path, "key-wise merge produced an unexpected key set")
            return
        (self.repo.path / path).write_text(merged, encoding="utf-8")
        self.done(path, "xcstrings key-level union")

    def pbxproj(self, path: str) -> None:
        if problem := self.repo.unsafe(path):
            self.block(path, problem)
            return
        try:
            texts = [self.repo.stage_bytes(stage, path).decode("utf-8") for stage in (1, 2, 3)]
            merged = union_pbxproj(*texts)
        except (ValueError, UnicodeDecodeError) as error:
            self.block(path, f"project conflict is not two sets of additions ({error})")
            return
        (self.repo.path / path).write_text(merged, encoding="utf-8")
        completed = run_tool(self.tools_root, NORMALIZER, [path], self.repo.path)
        if completed.returncode != 0:
            self.block(path, f"normalize-pbxproj.py rejected the union: {tail(completed.stderr)}")
            return
        self.done(path, "union of added entries, then normalize-pbxproj.py")

    def source(self, path: str) -> None:
        if problem := self.repo.unsafe(path):
            self.block(path, problem)
            return
        # verify re-derives the file from the one merge base's blob; anything
        # else (a criss-cross history, a rename) would fail there, so stop here.
        bases = self.repo.text("merge-base", "--all", "HEAD", "MERGE_HEAD").split()
        stage_base = self.repo.text("rev-parse", f":1:{path}")
        if len(bases) != 1 or self.repo.blob_id(bases[0], path) != stage_base:
            self.block(path, "both sides changed it")
            return
        try:
            texts = [self.repo.stage_bytes(stage, path).decode("utf-8") for stage in (1, 2, 3)]
            merged = merge_declarations(*texts)
        except (ValueError, UnicodeDecodeError):
            self.block(path, "both sides changed the same lines")
            return
        (self.repo.path / path).write_text(merged, encoding="utf-8")
        self.done(path, "kept both sides' declarations")

    def schema(self, conflicted: bool) -> None:
        # The generator reads one path and writes the other. A symlink at
        # either would read a runner file into the commit or write outside
        # the checkout.
        for path in (SCHEMA_JSON, SCHEMA_SWIFT):
            if problem := self.repo.unsafe(path):
                self.block(SCHEMA_SWIFT, f"{path} is {problem}; not regenerating")
                return
        try:
            json.loads((self.repo.path / SCHEMA_JSON).read_text(encoding="utf-8"))
        except (OSError, ValueError) as error:
            self.block(SCHEMA_SWIFT, f"merged {SCHEMA_JSON} is not valid JSON ({error.__class__.__name__}); not regenerating")
            return
        completed = run_tool(
            self.tools_root, SCHEMA_GENERATOR, ["--root", str(self.repo.path)], self.repo.path,
        )
        if completed.returncode != 0:
            self.block(SCHEMA_SWIFT, f"generate-cmux-config-schema.py failed: {tail(completed.stderr)}")
            return
        method = "regenerated from the merged schema" + ("" if conflicted else " (both sides changed the schema)")
        self.done(SCHEMA_SWIFT, "generate-cmux-config-schema.py, " + method)


def tail(text: str, limit: int = 300) -> str:
    text = " ".join(text.strip().split())
    return text if len(text) <= limit else "..." + text[-limit:]


def schema_needs_regeneration(repo: Repo, unmerged: dict[str, set[int]]) -> bool:
    """Both sides changed the schema, so neither side's Swift encodes the merge."""
    if SCHEMA_JSON in unmerged or not (repo.path / SCHEMA_JSON).is_file():
        return False
    merged = repo.text("hash-object", "--", SCHEMA_JSON)
    return merged not in {repo.blob_id("HEAD", SCHEMA_JSON), repo.blob_id("MERGE_HEAD", SCHEMA_JSON)}


def check_git_version() -> None:
    version = subprocess.run(["git", "version"], capture_output=True, text=True).stdout
    match = re.search(r"(\d+)\.(\d+)", version)
    if not match or (int(match.group(1)), int(match.group(2))) < MIN_GIT:
        need = ".".join(map(str, MIN_GIT))
        raise CatchUpError(f"git {need} or newer is required for attr.tree; found {version.strip()}")


def catch_up(repo_path: Path, base_ref: str, tools_root: Path, note: str = "", title: str = "") -> Result:
    check_git_version()
    repo = Repo(repo_path)
    result = Result(base_ref=base_ref)
    if repo.run("rev-parse", "--verify", "--quiet", "MERGE_HEAD", check=False).returncode == 0:
        raise CatchUpError("a merge is already in progress")
    if repo.text("status", "--porcelain", "--untracked-files=no"):
        raise CatchUpError("the working tree has uncommitted changes")
    result.head_before = repo.text("rev-parse", "--verify", "HEAD^{commit}")
    base = repo.run("rev-parse", "--verify", "--quiet", f"{base_ref}^{{commit}}", check=False)
    if base.returncode != 0:
        raise CatchUpError(f"unknown base ref: {base_ref}")
    result.base = base.stdout.decode().strip()
    repo.attr_tree = result.base

    if repo.run("merge-base", "--is-ancestor", result.base, "HEAD", check=False).returncode == 0:
        result.status = "up_to_date"
        result.head_after = result.head_before
        result.message = f"HEAD already contains {base_ref}"
        return result

    # One guard from the moment git starts merging: an interrupt (Ctrl-C in
    # scripts/merge-main.sh) or any error before the commit leaves no half
    # merge behind. No merge was in progress before this point (checked above).
    try:
        merge = repo.run("merge", "--no-ff", "--no-commit", "--no-edit", result.base, check=False)
        in_merge = repo.run("rev-parse", "--verify", "--quiet", "MERGE_HEAD", check=False).returncode == 0
        unmerged = repo.unmerged() if in_merge else {}
        if merge.returncode != 0 and not unmerged:
            raise CatchUpError(f"git merge failed: {tail(merge.stderr.decode(errors='replace'))}")
        return finish(repo, result, Resolver(repo, tools_root), unmerged, base_ref, note, title)
    except BaseException:
        if repo.run("rev-parse", "--verify", "--quiet", "MERGE_HEAD", check=False).returncode == 0:
            repo.run("merge", "--abort", check=False)
        raise


def finish(repo: Repo, result: Result, resolver: Resolver, unmerged: dict[str, set[int]],
           base_ref: str, note: str, title: str = "") -> Result:
    """Resolve, then commit or abort. The caller aborts the merge on any exception."""
    for path in sorted(unmerged):
        stages = unmerged[path]
        if stages != {1, 2, 3}:
            side = "added on both sides" if 1 not in stages else "deleted on one side and changed on the other"
            resolver.block(path, f"{side}; needs a person")
        elif path == SCHEMA_SWIFT:
            continue  # regenerated below, once the schema JSON is known to be merged
        elif path == SCHEMA_JSON:
            resolver.block(path, "schema source conflicts; resolve it, then run generate-cmux-config-schema.py")
        elif path.endswith(".xcstrings"):
            resolver.xcstrings(path)
        elif path == PBXPROJ:
            resolver.pbxproj(path)
        elif source_path(path):
            resolver.source(path)
        else:
            resolver.block(path, "both sides changed it")

    swift_conflicted = unmerged.get(SCHEMA_SWIFT) == {1, 2, 3}
    if swift_conflicted and SCHEMA_JSON in unmerged:
        resolver.block(SCHEMA_SWIFT, "generated from the conflicted schema source")
    elif swift_conflicted or schema_needs_regeneration(repo, unmerged):
        resolver.schema(conflicted=swift_conflicted)

    result.resolved = resolver.resolved
    result.blocking = resolver.blocking
    if result.blocking or repo.unmerged():
        repo.run("merge", "--abort", check=False)
        result.status = "blocked"
        result.message = f"{len(result.blocking)} file(s) need a person; merge aborted"
        return result

    lines = [title or f"Merge {base_ref} into the pull request head", ""]
    lines.append("Catch-up merge by scripts/ci/catch_up_pr.py (RFC #14631).")
    if note:
        lines.append(note)
    if result.resolved:
        lines += ["", "Resolved conflicts:"]
        lines += [f"- {item['path']}: {item['method']}" for item in result.resolved]
    lines += ["", f"Catch-up-previous-head: {result.head_before}", f"Catch-up-base: {result.base}"]
    repo.run("commit", "--no-verify", "-F", "-", input_bytes=("\n".join(lines) + "\n").encode())
    result.head_after = repo.text("rev-parse", "HEAD")
    result.status = "merged"
    result.message = f"merged {base_ref} with {len(result.resolved)} conflicted file(s) resolved"
    return result


def command_merge(args: argparse.Namespace) -> int:
    result = Result(base_ref=args.base)
    try:
        result = catch_up(Path(args.repo).resolve(), args.base, Path(args.tools_root).resolve(), args.note,
                          args.title)
    except CatchUpError as error:
        result.status = "error"
        result.message = str(error)
    except Exception as error:  # the JSON result must always print
        result.status = "error"
        result.message = f"unexpected {error.__class__.__name__}: {error}"
    if args.json:
        print(json.dumps(result.as_json(), indent=2))
    else:
        print(f"catch-up: {result.status}: {result.message}")
        for item in result.resolved:
            print(f"  resolved {item['path']}: {item['method']}")
        for item in result.blocking:
            print(f"  blocking {item['path']}: {item['reason']}")
    return {"merged": 0, "up_to_date": 0, "blocked": 1}.get(result.status, 2)


# --- verifying a merge before it is pushed ------------------------------------


def allowed_generated_path(path: str) -> bool:
    return path in {PBXPROJ, SCHEMA_SWIFT} or path.endswith(".xcstrings")


def verify_merge(repo_path: Path, head: str, base: str, merged: str, base_tip: str) -> list[str]:
    """Why `merged` is not a catch-up merge of `base` into `head`; empty when it is.

    The push job runs this on its own fetch of the commits instead of trusting
    the merge job: the merge must have exactly the two expected parents, the
    base must be on the base branch, and its tree may differ from git's own
    merge of the two parents only in the generated files this tool resolves.
    """
    repo = Repo(repo_path)
    repo.attr_tree = base
    problems: list[str] = []
    parents = repo.text("rev-list", "--parents", "-n", "1", merged).split()
    if parents[1:] != [head, base]:
        problems.append(f"merge parents are {parents[1:]}, expected [{head}, {base}]")
        return problems
    if repo.run("merge-base", "--is-ancestor", base, base_tip, check=False).returncode != 0:
        problems.append(f"{base} is not on the base branch ({base_tip})")
    tree = repo.run("merge-tree", "--write-tree", "--name-only", "-z", head, base, check=False)
    if tree.returncode not in (0, 1):
        problems.append(f"git merge-tree failed: {tail(tree.stderr.decode(errors='replace'))}")
        return problems
    fields = tree.stdout.decode().split("\0")
    expected_tree, conflicted = fields[0], []
    for field in fields[1:]:
        if not field:
            break  # the informational messages follow an empty field
        conflicted.append(field)
    raw = repo.run("diff-tree", "-r", "--name-only", "-z", expected_tree, f"{merged}^{{tree}}").stdout.decode()
    differing = [path for path in raw.split("\0") if path]
    merge_bases = repo.text("merge-base", "--all", head, base).split()
    for path in sorted(set(differing) | set(conflicted)):
        if allowed_generated_path(path):
            continue
        if path in conflicted and source_path(path) and len(merge_bases) == 1 and \
                rederived(repo, path, merge_bases[0], head, base, merged):
            continue
        problems.append(f"{path} differs from git's merge of the parents")
    return problems


def rederived(repo: Repo, path: str, merge_base: str, head: str, base: str, merged: str) -> bool:
    """True when `merged` holds exactly merge_declarations() of the three regular-file blobs of `path`."""
    texts = []
    for rev in (merge_base, head, base, merged):
        listing = repo.text("ls-tree", "-z", rev, "--", path).rstrip("\0")
        if not listing or listing.split()[0] not in REGULAR_MODES:
            return False
        try:
            texts.append(repo.run("show", f"{rev}:{path}").stdout.decode("utf-8"))
        except UnicodeDecodeError:
            return False
    try:
        return merge_declarations(texts[0], texts[1], texts[2]) == texts[3]
    except ValueError:
        return False


def command_verify(args: argparse.Namespace) -> int:
    try:
        check_git_version()
        problems = verify_merge(Path(args.repo).resolve(), args.head, args.base, args.merged, args.base_tip)
    except CatchUpError as error:
        problems = [str(error)]
    for problem in problems:
        print(f"catch-up verify: {problem}", file=sys.stderr)
    if not problems:
        print(f"catch-up verify: {args.merged} is a catch-up merge of {args.base} into {args.head}")
    return 1 if problems else 0


# --- the pull request comment -------------------------------------------------


def code(text: str) -> str:
    """Inline code for text from the pull request (paths, keys), inert in Markdown."""
    return "`" + " ".join(str(text).replace("`", "'").split()) + "`"


def plain(text: str) -> str:
    """Our own reason strings can quote pull request keys; keep them on one inert line."""
    text = str(text).replace("`", "'").replace("@", "@\u200b")
    for char in "\\[]()<>!*_~|#":
        text = text.replace(char, "\\" + char)
    return re.sub(r"\s+", " ", text)


def reason(text: str) -> str:
    """A reason may carry `code()` spans (key names); keep those, make the rest inert."""
    parts = str(text).split("`")
    return "".join(code(part) if index % 2 else plain(part) for index, part in enumerate(parts)).strip()


def conflicts(result: dict) -> str:
    """The blocking files on one line: `a` (why), `b` (why) and N more."""
    items = result.get("blocking", [])
    shown = [f"{code(item['path'])} ({reason(item['reason'])})" for item in items[:5]]
    if len(items) > 5:
        shown.append(f"{len(items) - 5} more in the run log")
    return ", ".join(shown) if shown else "a conflict"


def render_comment(result: dict, push: str, base_name: str, head_name: str, run_url: str) -> str:
    base = (result.get("base") or "")[:12]
    base_label = f"{code(base_name)} ({code(base)})" if base else code(base_name)
    status = result.get("status")
    footer = f"\n\n<sub>[Catch-up run]({run_url}) · RFC #14631</sub>" if run_url else ""
    if status == "up_to_date":
        return f"This branch already has {base_label}, so there was nothing to catch up.{footer}"
    if status == "blocked":
        return (f"Couldn't merge {base_label}: {conflicts(result)}. Nothing was pushed;"
                f" merge {code(base_name)} by hand, or comment `/catch-up` to try again.{footer}")
    if status != "merged":
        return (f"Catch-up stopped before merging ({plain(result.get('message', 'unknown error'))})."
                f" Nothing was pushed.{footer}")
    head = (result.get("head_after") or "")[:12]
    resolved = [f"- {code(item['path'])}: {plain(item['method'])}" for item in result.get("resolved", [])]
    if push == "pushed" or push == "pushed-without-ci":
        lines = [f"Caught {code(head_name)} up with {base_label} in {code(head)}."]
        if resolved:
            lines += ["", "Resolved:", *resolved]
        if push == "pushed-without-ci":
            lines += ["", "This push used the Actions token, so CI will not start on its own."
                      " Push any commit (or close and reopen) to get checks on the new head."]
        return "\n".join(lines) + footer
    if push == "needs-workflows":
        return (f"The merge with {base_label} is clean, but it brings in workflow changes and the token"
                " I had cannot push those. Nothing changed on the branch; merge"
                f" {code(base_name)} yourself this time.{footer}")
    if push == "unverified":
        return ("The merge did not pass the push job's own checks (the pull request changed, or the merge"
                f" commit was not what I expected), so nothing was pushed. Comment `/catch-up` to try again.{footer}")
    if push == "push-denied":
        return (f"The merge with {base_label} is clean, but I was not allowed to push to {code(head_name)}."
                f" Nothing changed on the branch; merge {code(base_name)} yourself this time.{footer}")
    return (f"The merge with {base_label} is clean, but {code(head_name)} moved while I worked, so I"
            f" did not push. Nothing changed on the branch; comment `/catch-up` to try again.{footer}")


AUTO_MARKER = "<!-- cmux-auto-catch-up head={head} -->"
# The automatic path speaks only when it pushed or when a person must act on
# this head; the marker then keeps auto_catch_up_select.py off the head. Every
# other outcome (up to date, an error or a lost runner, the branch moved, the
# push job refused the merge, no push token) says nothing and marks nothing:
# the selector's ledger bounds how often such a head is tried again.
AUTO_SPOKEN = frozenset({("blocked", None), ("merged", "pushed"), ("merged", "push-denied"),
                         ("merged", "needs-workflows")})


def render_auto_comment(result: dict, push: str, base_name: str, head_name: str, run_url: str,
                        head_sha: str) -> str:
    """The comment for a catch-up nobody asked for, or "" when it should stay silent.

    It carries AUTO_MARKER for the head it tried, which auto_catch_up_select.py
    reads so that head is not tried again. No @-mentions and no issue
    references, so a comment on many pull requests pings nobody.
    """
    status = result.get("status")
    if not re.fullmatch(r"[0-9a-f]{40}", head_sha or ""):
        return ""
    if (status, None if status == "blocked" else push) not in AUTO_SPOKEN:
        return ""
    base = (result.get("base") or "")[:12]
    base_label = f"{code(base_name)} ({code(base)})" if base else code(base_name)
    if status == "blocked":
        body = (f"Automatic catch-up couldn't merge {base_label}: {conflicts(result)}."
                " Nothing was pushed; merge it by hand. A new push or `/catch-up` tries again.")
    elif push == "pushed":
        body = (render_comment(result, push, base_name, head_name, "")
                + "\nRun `git pull --no-rebase` before your next push; do not force-push over this merge.")
    else:
        body = render_comment(result, push, base_name, head_name, "")
    link = f" · [Catch-up run]({run_url})" if run_url else ""
    return f"{AUTO_MARKER.format(head=head_sha)}\n{body}\n\n<sub>Label `no-auto-catch-up` to opt out{link}</sub>"


# --- the merge job's hand-off, read by the push job -----------------------------

RESULT_STATUSES = frozenset({"merged", "up_to_date", "blocked", "error"})
RESULT_SHAS = ("head_sha", "base_sha", "merged_sha")
RESULT_REFS = ("head_ref", "base_ref")
REFUSAL_LIMIT = 400


def valid_branch(name: str) -> bool:
    completed = subprocess.run(["git", "check-ref-format", "--branch", name], capture_output=True, text=True)
    return completed.returncode == 0


def one_line(value: object) -> str:
    """A string with no control characters, or "" (a line break could add a step output)."""
    return value if isinstance(value, str) and not re.search(r"[\x00-\x1f\x7f]", value) else ""


def read_merge_result(data: object, pin: str) -> tuple[dict[str, str], str | None]:
    """The merge job's outputs.json, validated for the push job: (outputs, warning).

    Nothing in it is trusted. Commit ids are 40 hex, branch names pass
    check-ref-format, the status is one the merge prints (anything else reads
    as error), the head is the pin when there is one, and the refusal is one
    line without workflow commands. A failed check yields no merge values, so
    nothing is verified or pushed.
    """
    if not isinstance(data, dict):
        return {}, "the merge result is not an object"
    refusal = one_line(data.get("refusal")).replace("::", ":")[:REFUSAL_LIMIT]
    outputs = {"refusal": refusal} if refusal else {}
    status = one_line(data.get("status"))
    values = {"status": status if status in RESULT_STATUSES or not status else "error"}
    for key in RESULT_SHAS:
        value = one_line(data.get(key))
        if value and not re.fullmatch(r"[0-9a-f]{40}", value):
            return outputs, f"bad commit id in {key}"
        values[key] = value
    for key in RESULT_REFS:
        value = one_line(data.get(key))
        if value and not valid_branch(value):
            return outputs, f"bad branch name in {key}"
        values[key] = value
    if pin and values["head_sha"] and values["head_sha"] != pin:
        return outputs, "the merge result is for another head than the one selected"
    return {**values, **outputs}, None


def command_read_result(args: argparse.Namespace) -> int:
    path = Path(args.file)
    if not path.is_file():
        print(f"No merge result at {path}.", file=sys.stderr)
        return 0
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        data = None
    pin = args.pin if re.fullmatch(r"[0-9a-f]{40}", args.pin or "") else ""
    outputs, warning = read_merge_result(data, pin)
    if warning:
        print(f"::warning::{warning}", file=sys.stderr)
    for key, value in outputs.items():
        print(f"{key}={value}")
    return 0


def command_comment(args: argparse.Namespace) -> int:
    try:
        result = json.loads(Path(args.result).read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        result = {"status": "error", "message": f"no catch-up result ({error.__class__.__name__})"}
    if args.auto:
        text = render_auto_comment(result, args.push, args.base_name, args.head_name, args.run_url, args.head_sha)
        if text:
            print(text)
        return 0
    print(render_comment(result, args.push, args.base_name, args.head_name, args.run_url))
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    merge = sub.add_parser("merge", help="merge the base into the checked-out head and commit")
    merge.add_argument("--base", required=True, help="base ref or sha to merge, e.g. origin/main")
    merge.add_argument("--repo", default=".", help="checkout of the pull request head")
    merge.add_argument("--tools-root", default=str(DEFAULT_TOOLS_ROOT),
                       help="trusted checkout whose generators resolve conflicts")
    merge.add_argument("--note", default="", help="extra line for the merge commit message")
    merge.add_argument("--title", default="", help="merge commit subject (default: Merge <base> into the pull request head)")
    merge.add_argument("--json", action="store_true", help="print a machine-readable result")
    merge.set_defaults(func=command_merge)
    verify = sub.add_parser("verify", help="check a merge commit before pushing it")
    verify.add_argument("--repo", required=True)
    verify.add_argument("--head", required=True)
    verify.add_argument("--base", required=True)
    verify.add_argument("--merged", required=True)
    verify.add_argument("--base-tip", required=True, help="current tip of the base branch")
    verify.set_defaults(func=command_verify)
    comment = sub.add_parser("comment", help="render the pull request comment for a result")
    comment.add_argument("--result", required=True)
    comment.add_argument("--push", required=True,
                         choices=["pushed", "pushed-without-ci", "rejected", "needs-workflows", "push-denied",
                                  "unverified", "not-attempted", "skipped-no-app-token"])
    comment.add_argument("--base-name", default="main")
    comment.add_argument("--head-name", default="this branch")
    comment.add_argument("--run-url", default="")
    comment.add_argument("--auto", action="store_true",
                         help="the automatic path: marked with --head-sha, empty when nothing needs saying")
    comment.add_argument("--head-sha", default="", help="the head the automatic catch-up tried")
    comment.set_defaults(func=command_comment)
    read_result = sub.add_parser("read-result", help="validate the merge job's outputs.json; print key=value lines")
    read_result.add_argument("--file", required=True)
    read_result.add_argument("--pin", default="", help="the head the request or selection pinned, if any")
    read_result.set_defaults(func=command_read_result)
    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
