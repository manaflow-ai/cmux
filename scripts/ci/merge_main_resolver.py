#!/usr/bin/env python3
"""Trusted local merge and generated-file resolution helpers.

Used by scripts/merge-main.sh and the installed project-file merge driver.
Merge attributes come from the base commit. Resolvers use trusted generators
and refuse symlinks, submodules, and source conflicts they cannot reconcile.
The caller owns branch selection and any subsequent push.
"""

from __future__ import annotations

import importlib.util
import json
import re
import subprocess
import sys
import tempfile
from dataclasses import dataclass, field
from pathlib import Path

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
# The generated web bundle driver is pinned the same way: it keeps one side
# without reporting a conflict, and this resolver's unmerged list must stay
# the authority on what still needs resolving.
GIT = [
    "git",
    "-c", "core.hooksPath=/dev/null",
    "-c", "merge.conflictStyle=diff3",
    "-c", "merge.xcstrings.driver=false",
    "-c", "merge.xcstrings-v2.driver=false",
    "-c", "merge.pbxproj.driver=false",
    "-c", "merge.pbxproj-v1.driver=false",
    "-c", "merge.cmux-generated-v1.driver=false",
    "-c", "rerere.enabled=false",
    "-c", "maintenance.auto=false",
    "-c", "gc.auto=0",
]


class MergeResolverError(Exception):
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
            raise MergeResolverError(
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
        raise MergeResolverError(f"trusted tool missing: {tool}")
    return subprocess.run(
        [sys.executable, "-I", str(tool), *args], cwd=cwd, capture_output=True, text=True,
    )


def load_xcstrings_merger(tools_root: Path):
    path = tools_root / XCSTRINGS_MERGER
    if not path.is_file():
        raise MergeResolverError(f"trusted tool missing: {path}")
    spec = importlib.util.spec_from_file_location("merge_main_xcstrings", path)
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
            shown = ", ".join(repr(key) for key in conflicts[:10]) + (f" and {len(conflicts) - 10} more" if len(conflicts) > 10 else "")
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
        # Resolve only from one unambiguous merge base; a criss-cross history
        # or a rename needs a person.
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
        raise MergeResolverError(f"git {need} or newer is required for attr.tree; found {version.strip()}")


def merge_and_resolve(repo_path: Path, base_ref: str, tools_root: Path, note: str = "", title: str = "") -> Result:
    check_git_version()
    repo = Repo(repo_path)
    result = Result(base_ref=base_ref)
    if repo.run("rev-parse", "--verify", "--quiet", "MERGE_HEAD", check=False).returncode == 0:
        raise MergeResolverError("a merge is already in progress")
    if repo.text("status", "--porcelain", "--untracked-files=no"):
        raise MergeResolverError("the working tree has uncommitted changes")
    result.head_before = repo.text("rev-parse", "--verify", "HEAD^{commit}")
    base = repo.run("rev-parse", "--verify", "--quiet", f"{base_ref}^{{commit}}", check=False)
    if base.returncode != 0:
        raise MergeResolverError(f"unknown base ref: {base_ref}")
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
            raise MergeResolverError(f"git merge failed: {tail(merge.stderr.decode(errors='replace'))}")
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
    lines.append("Merge-main commit by scripts/merge-main.sh.")
    if note:
        lines.append(note)
    if result.resolved:
        lines += ["", "Resolved conflicts:"]
        lines += [f"- {item['path']}: {item['method']}" for item in result.resolved]
    lines += ["", f"Merge-main-previous-head: {result.head_before}", f"Merge-main-base: {result.base}"]
    repo.run("commit", "--no-verify", "-F", "-", input_bytes=("\n".join(lines) + "\n").encode())
    result.head_after = repo.text("rev-parse", "HEAD")
    result.status = "merged"
    result.message = f"merged {base_ref} with {len(result.resolved)} conflicted file(s) resolved"
    return result
