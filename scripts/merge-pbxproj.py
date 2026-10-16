#!/usr/bin/env python3
"""Git merge driver for Xcode project files (project.pbxproj).

No target in this project is filesystem-synchronized, so every added source
file needs four explicit pbxproj entries: a PBXBuildFile, a PBXFileReference,
a child in its group, and a member of the target's Sources phase. Two branches
that each add a different file therefore append to the same four regions and
collide positionally, even though the entries are disjoint. That is the single
most common conflict in this repository and never a semantic disagreement.

The three-way union this performs is shared with the trusted local
merge-main resolver, rather than being reimplemented here. Exposing it as a
merge driver makes it available to everyone else: a local `git merge main`, a
rebase, and pull requests from forks.

It is deliberately conservative. A hunk is merged only when both sides purely
added distinct lines; if either side changed or removed a line the merge is
abandoned and git writes normal conflict markers. The union is then checked for
repeated object ids and handed to scripts/normalize-pbxproj.py, which rejects
broken syntax and duplicate entries, so a result that would not open in Xcode
is never written.

Usage (git passes these): merge-pbxproj.py %O %A %B %P
"""
from __future__ import annotations

import ast
import importlib.util
import re
import subprocess
import sys
import tempfile
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
MERGE_RESOLVER = SCRIPT_DIR / "ci" / "merge_main_resolver.py"
NORMALIZER = SCRIPT_DIR / "normalize-pbxproj.py"
SECTION_BEGIN_RE = re.compile(r"/\* Begin ([A-Za-z0-9]+) section \*/")
SECTION_END_RE = re.compile(r"/\* End ([A-Za-z0-9]+) section \*/")
BUILD_FILE_RE = re.compile(r"^\s*[0-9A-Za-z]+ /\* .* \*/ = \{isa = PBXBuildFile;.*\};\s*$")
FILE_REFERENCE_RE = re.compile(
    r"^\s*[0-9A-Za-z]+ /\* .* \*/ = \{isa = PBXFileReference;.*\};\s*$"
)
SOURCE_CHILD_RE = re.compile(
    r"^\s*[0-9A-Za-z]+ /\* .+\.(?:swift|m|mm|c|cc|cpp|h|metal) \*/,\s*$"
)
SOURCE_PHASE_RE = re.compile(
    r"^\s*[0-9A-Za-z]+ /\* .+\.(?:swift|m|mm|c|cc|cpp|h|metal) in Sources \*/,\s*$"
)
PBX_PATH_RE = re.compile(r"\bpath\s*=\s*([^;]+);")
PBX_SOURCE_TREE_RE = re.compile(r"\bsourceTree\s*=\s*([^;]+);")
PBX_COMMENT_RE = re.compile(r"^\s*[0-9A-Za-z]+ /\* (.*?) \*/")


def load_mergers():
    """Load the trusted merge-main helpers."""
    spec = importlib.util.spec_from_file_location("merge_main_resolver", MERGE_RESOLVER)
    if spec is None or spec.loader is None:
        raise ImportError(f"cannot load {MERGE_RESOLVER}")
    module = importlib.util.module_from_spec(spec)
    # The resolver declares dataclasses, and @dataclass resolves a field's
    # type through sys.modules[cls.__module__], so register it before
    # execution or the decorator raises.
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def project_location(module, text: str) -> tuple[str | None, int, str | None]:
    """The trusted section, dictionary depth and innermost array at text's end."""
    section: str | None = None
    stack: list[tuple[str, str | None]] = []
    assigned_key: str | None = None
    previous_token: str | None = None
    for match in module.PBX_TOKEN_RE.finditer(text):
        token = match.group()
        if match.lastgroup == "comment":
            # Section comments have meaning only between entries in the root
            # objects dictionary. In particular, marker-shaped text inside a
            # quoted shell script is part of one string token, never a comment.
            in_objects = stack == [("dictionary", None), ("dictionary", "objects")]
            if in_objects:
                stripped = token.strip()
                if begin := SECTION_BEGIN_RE.fullmatch(stripped):
                    section = begin.group(1)
                elif end := SECTION_END_RE.fullmatch(stripped):
                    if section == end.group(1):
                        section = None
            continue
        if token == "=" and previous_token is not None:
            assigned_key = previous_token.strip("\"'")
        elif token == "{":
            stack.append(("dictionary", assigned_key))
            assigned_key = None
        elif token == "(":
            stack.append(("array", assigned_key))
            assigned_key = None
        elif token in "})":
            if stack:
                stack.pop()
            assigned_key = None
        elif token not in {",", ";"}:
            assigned_key = None
        previous_token = token
    dictionary_depth = sum(kind == "dictionary" for kind, _ in stack)
    array = next((name for kind, name in reversed(stack) if kind == "array"), None)
    return section, dictionary_depth, array


def safe_source_line(
    line: str,
    section: str | None,
    dictionary_depth: int,
    array: str | None,
) -> bool:
    if not line.strip():
        return True
    if section == "PBXBuildFile" and dictionary_depth == 2 and array is None:
        return BUILD_FILE_RE.fullmatch(line) is not None
    if section == "PBXFileReference" and dictionary_depth == 2 and array is None:
        return FILE_REFERENCE_RE.fullmatch(line) is not None
    if section == "PBXGroup" and dictionary_depth == 3 and array == "children":
        return SOURCE_CHILD_RE.fullmatch(line) is not None
    if section == "PBXSourcesBuildPhase" and dictionary_depth == 3 and array == "files":
        return SOURCE_PHASE_RE.fullmatch(line) is not None
    return False


def openstep_scalar(value: str) -> str:
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in {'"', "'"}:
        try:
            decoded = ast.literal_eval(value)
            if isinstance(decoded, str):
                return decoded
        except (SyntaxError, ValueError):
            pass
    return value


def logical_source_key(
    line: str,
    section: str | None,
    array: str | None,
) -> tuple[str, str, str] | None:
    if section == "PBXFileReference" and array is None:
        path = PBX_PATH_RE.search(line)
        source_tree = PBX_SOURCE_TREE_RE.search(line)
        if path and source_tree:
            return (
                section,
                "",
                f"{openstep_scalar(path.group(1))}\0{openstep_scalar(source_tree.group(1))}",
            )
    comment = PBX_COMMENT_RE.match(line)
    if comment and (
        (section == "PBXBuildFile" and array is None)
        or (section == "PBXGroup" and array == "children")
        or (section == "PBXSourcesBuildPhase" and array == "files")
    ):
        return section, array or "", comment.group(1)
    return None


def logical_source_entries(module, text: str) -> dict[tuple[str, str, str], set[str]]:
    """All source identities in a project, with parser-derived locations.

    This scans the token stream once. In particular, marker-shaped text inside
    a quoted shell script cannot spoof a section or array boundary.
    """
    section: str | None = None
    stack: list[tuple[str, str | None]] = []
    assigned_key: str | None = None
    previous_token: str | None = None
    matches = iter(module.PBX_TOKEN_RE.finditer(text))
    current = next(matches, None)
    entries: dict[tuple[str, str, str], set[str]] = {}

    def consume(match) -> None:
        nonlocal section, assigned_key, previous_token
        token = match.group()
        if match.lastgroup == "comment":
            if stack == [("dictionary", None), ("dictionary", "objects")]:
                stripped = token.strip()
                if begin := SECTION_BEGIN_RE.fullmatch(stripped):
                    section = begin.group(1)
                elif end := SECTION_END_RE.fullmatch(stripped):
                    if section == end.group(1):
                        section = None
            return
        if token == "=" and previous_token is not None:
            assigned_key = previous_token.strip("\"'")
        elif token == "{":
            stack.append(("dictionary", assigned_key))
            assigned_key = None
        elif token == "(":
            stack.append(("array", assigned_key))
            assigned_key = None
        elif token in "})":
            if stack:
                stack.pop()
            assigned_key = None
        elif token not in {",", ";"}:
            assigned_key = None
        previous_token = token

    offset = 0
    for line in text.splitlines(keepends=True):
        while current is not None and current.end() <= offset:
            consume(current)
            current = next(matches, None)
        inside_multiline_token = (
            current is not None and current.start() < offset < current.end()
        )
        if not inside_multiline_token:
            array = next((name for kind, name in reversed(stack) if kind == "array"), None)
            if key := logical_source_key(line, section, array):
                entries.setdefault(key, set()).add(line.strip())
        offset += len(line)
    return entries


def source_entry_union(module, base: str, ours: str, theirs: str) -> str:
    """Union only source-file entries in their known order-insensitive containers."""
    merged = module.union_pbxproj(base, ours, theirs)
    base_entries = logical_source_entries(module, base)
    ours_entries = logical_source_entries(module, ours)
    theirs_entries = logical_source_entries(module, theirs)
    for key in ours_entries.keys() & theirs_entries.keys():
        base_lines = base_entries.get(key, set())
        ours_added = ours_entries[key] - base_lines
        theirs_added = theirs_entries[key] - base_lines
        if ours_added and theirs_added and ours_added != theirs_added:
            raise ValueError(
                "both sides added the same logical file with different Xcode object IDs"
            )
    prefix = ""
    for part in module.split_conflicts(module.merge_file(base, ours, theirs)):
        if isinstance(part, str):
            prefix += part
            continue
        ours_lines, base_lines, theirs_lines = part
        for side in (ours_lines, theirs_lines):
            slots = module.insertions(base_lines, side)
            if slots is None:
                raise ValueError(
                    "automatic union is limited to source-file project entries;"
                    " order-sensitive or unknown insertions need a person"
                )
            for slot, lines in enumerate(slots):
                section, depth, array = project_location(
                    module, prefix + "".join(base_lines[:slot])
                )
                if any(not safe_source_line(line, section, depth, array) for line in lines):
                    raise ValueError(
                        "automatic union is limited to source-file project entries;"
                        " order-sensitive or unknown insertions need a person"
                    )
        prefix += "".join(base_lines)
    return merged


def conflict_text(module, base: str, ours: str, theirs: str) -> str:
    """The ordinary diff3 conflict, or an explicit whole-file semantic conflict."""
    width = module.MARKER_SIZE
    marker_prefixes = tuple(character * width for character in "<|=>")
    if any(
        line.startswith(marker_prefixes)
        for text in (base, ours, theirs)
        for line in text.splitlines()
    ):
        return explicit_conflict(base, ours, theirs, width)
    try:
        merged = module.merge_file(base, ours, theirs)
        parts = module.split_conflicts(merged)
    except Exception:
        parts = []
    if any(not isinstance(part, str) for part in parts):
        return merged
    return explicit_conflict(base, ours, theirs, width)


def explicit_conflict(base: str, ours: str, theirs: str, width: int = 32) -> str:
    """A visible whole-file conflict for failures before the merge helper is available."""
    return (
        f"{'<' * width} ours\n{ours.rstrip()}\n"
        f"{'|' * width} base\n{base.rstrip()}\n"
        f"{'=' * width}\n{theirs.rstrip()}\n"
        f"{'>' * width} theirs\n"
    )


def explicit_conflict_bytes(base: bytes, ours: bytes, theirs: bytes, width: int = 32) -> bytes:
    """The byte-preserving equivalent used when one side is not UTF-8."""
    return (
        b"<" * width + b" ours\n" + ours.rstrip() + b"\n"
        + b"|" * width + b" base\n" + base.rstrip() + b"\n"
        + b"=" * width + b"\n" + theirs.rstrip() + b"\n"
        + b">" * width + b" theirs\n"
    )


def read_merge_input(path: Path, label: str) -> tuple[bytes, OSError | None]:
    """Read one driver input, preserving a visible placeholder on failure."""
    try:
        return path.read_bytes(), None
    except OSError as error:
        detail = f"[merge-pbxproj could not read {label}: {error}]\n"
        return detail.encode("utf-8", errors="replace"), error


def normalized(text: str, name: str) -> str | None:
    """The merged text after scripts/normalize-pbxproj.py, or None if it rejects it.

    The normalizer rewrites in place and reports broken syntax or duplicate
    entries, so it runs on a temporary copy: a rejected union must never leave
    a half-written project file behind.
    """
    if not NORMALIZER.exists():
        print(f"merge-pbxproj: {name}: normalizer is unavailable; falling back", file=sys.stderr)
        return None
    with tempfile.TemporaryDirectory() as directory:
        scratch = Path(directory) / "project.pbxproj"
        scratch.write_text(text, encoding="utf-8")
        completed = subprocess.run(
            [sys.executable, "-I", str(NORMALIZER), str(scratch)],
            capture_output=True,
            text=True,
            check=False,
        )
        if completed.returncode != 0:
            lines = (completed.stderr or completed.stdout).strip().splitlines()
            detail = lines[-1] if lines else f"exit {completed.returncode}"
            print(f"merge-pbxproj: {name}: normalizer rejected the union ({detail})",
                  file=sys.stderr)
            return None
        return scratch.read_text(encoding="utf-8")


def main(argv: list[str]) -> int:
    if len(argv) < 4:
        print("usage: merge-pbxproj.py %O %A %B [%P]", file=sys.stderr)
        return 2
    base_path, ours_path, theirs_path = (Path(p) for p in argv[1:4])
    name = argv[4] if len(argv) > 4 else str(ours_path)
    base_bytes, base_error = read_merge_input(base_path, "base")
    ours_bytes, ours_error = read_merge_input(ours_path, "ours")
    theirs_bytes, theirs_error = read_merge_input(theirs_path, "theirs")
    read_errors = [error for error in (base_error, ours_error, theirs_error) if error is not None]
    if read_errors:
        try:
            ours_path.write_bytes(explicit_conflict_bytes(base_bytes, ours_bytes, theirs_bytes))
        except OSError as write_error:
            print(
                f"merge-pbxproj: {name}: cannot materialize input failure ({write_error})",
                file=sys.stderr,
            )
        print(
            f"merge-pbxproj: {name}: cannot read merge inputs ({read_errors[0]}); falling back",
            file=sys.stderr,
        )
        return 1
    try:
        base = base_bytes.decode("utf-8")
        ours = ours_bytes.decode("utf-8")
        theirs = theirs_bytes.decode("utf-8")
    except UnicodeDecodeError as error:
        ours_path.write_bytes(explicit_conflict_bytes(base_bytes, ours_bytes, theirs_bytes))
        print(f"merge-pbxproj: {name}: merge input is not UTF-8 ({error}); falling back", file=sys.stderr)
        return 1
    try:
        module = load_mergers()
    except Exception as error:
        ours_path.write_text(explicit_conflict(base, ours, theirs), encoding="utf-8")
        print(f"merge-pbxproj: {name}: cannot load merge helpers ({error}); falling back", file=sys.stderr)
        return 1
    try:
        merged = source_entry_union(module, base, ours, theirs)
    except Exception as error:
        # A custom merge driver owns %A even when it returns failure: Git does
        # not rerun the built-in text merge for us. Leave the ordinary diff3
        # conflict there so a person cannot mistake an ours-only file for the
        # complete project and stage away the incoming change.
        ours_path.write_text(conflict_text(module, base, ours, theirs), encoding="utf-8")
        print(f"merge-pbxproj: {name}: {error}; falling back", file=sys.stderr)
        return 1
    try:
        settled = normalized(merged, name)
    except Exception as error:
        print(f"merge-pbxproj: {name}: cannot validate the union ({error}); falling back", file=sys.stderr)
        settled = None
    if settled is None:
        ours_path.write_text(conflict_text(module, base, ours, theirs), encoding="utf-8")
        return 1
    ours_path.write_text(settled, encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
