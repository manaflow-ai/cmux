"""Shared parser for the deliberately small Python test execution registry.

The registry is a directory of fragments, tests/test-execution.d/<area>.toml, one per area, so
pull requests in different areas never edit the same file (tests/test-execution.toml had 186
commits in 14 days, and every pull request that touched it conflicted with the next). Leo,
2026-11-05, on splitting the hot files: "i meant can you do all of htem".

  - A fragment holds only [[test]] entries; the registry's `version = 1` is implied.
  - The entry for tests/test_<area>_....py goes in <area>.toml when that file exists, and in
    other.toml when it does not. Nothing lists the areas: a fragment's file is its area.
  - Entries in a fragment are sorted by path, so two pull requests that add tests to one area
    insert at different lines instead of both at the top.

Every reader sees one merged view: the old single file when it is still there (an old checkout,
a base commit before the split, or a test fixture), then each fragment in file name order.
`python3 scripts/ci/test_execution_registry.py fix` puts misplaced or unsorted entries back;
`absorb` moves an open pull request's edits to the old file into the fragments.

Lanes: automatic lanes describe where a test executes. `legacy` is migration inventory only:
existing files may remain legacy while we model their current execution path, but newly added
tests may not enter as legacy. `manual` entries require a reason. Lane runners may run a lane's
tests concurrently, so a test keeps its files and sockets in its own temporary directory or
pid-scoped names. `serial = true` runs an entry alone, for tests that assert wall-clock bounds a
busy machine could miss.
"""

from __future__ import annotations

import argparse
import ast
import re
import subprocess
import sys
from pathlib import Path
from typing import Optional


TOML_BOOLEANS = {"true": True, "false": False}

# The single file the registry was before the split, read when present.
LEGACY = "tests/test-execution.toml"
FRAGMENTS = "tests/test-execution.d"
OTHER_AREA = "other"
FRAGMENT_NAME_RE = re.compile(r"[a-z0-9]+\.toml")
FRAGMENT_PATH_RE = re.compile(r"tests/test-execution\.d/[^/]+\.toml")
# An area file is made at the split for every first word with at least this many tests.
SPLIT_AREA_MIN = 5
FRAGMENT_HEADER = (
    "# Python test execution registry: tests/test_{area}_*.py. Keep entries sorted by path;\n"
    "# scripts/ci/test_execution_registry.py says how the registry is split and read.\n"
)
OTHER_HEADER = (
    "# Python test execution registry: every test whose first word has no area file here.\n"
    "# Keep entries sorted by path; scripts/ci/test_execution_registry.py says how it is split.\n"
)


def is_registry_path(path: str) -> bool:
    """Whether a repository path is part of the registry (the old file or a fragment)."""
    return path == LEGACY or FRAGMENT_PATH_RE.fullmatch(path) is not None


def area_word(test_path: str) -> str:
    """The first word of a test's name: tests/test_ci_foo.py -> "ci"."""
    name = test_path.rsplit("/", 1)[-1]
    stem = name[len("test_"):] if name.startswith("test_") else name
    stem = stem[:-3] if stem.endswith(".py") else stem
    word = re.split(r"[_.-]", stem, maxsplit=1)[0].lower()
    return word if re.fullmatch(r"[a-z0-9]+", word) else OTHER_AREA


def fragment_for(test_path: str, areas: set[str]) -> str:
    """The fragment file name (`ci.toml`) a test's entry belongs in, given the area files that exist."""
    word = area_word(test_path)
    return f"{word}.toml" if word in areas else f"{OTHER_AREA}.toml"


def load_registry(path: Path) -> list[dict[str, object]]:
    """One registry file (the old single file), parsed."""
    return parse_registry(path.read_text(encoding="utf-8"), str(path))


def registry_sources(root: Path) -> list[tuple[str, str]]:
    """(repository path, text) of every registry file under `root`, in reading order.

    The old single file first, when it is there, then the fragments by name. Raises OSError when
    there is neither.
    """
    sources: list[tuple[str, str]] = []
    legacy = root / LEGACY
    if legacy.is_file():
        sources.append((LEGACY, legacy.read_text(encoding="utf-8")))
    directory = root / FRAGMENTS
    if directory.is_dir():
        for fragment in sorted(directory.glob("*.toml"), key=lambda item: item.name):
            sources.append((f"{FRAGMENTS}/{fragment.name}", fragment.read_text(encoding="utf-8")))
    if not sources:
        raise FileNotFoundError(f"{root / FRAGMENTS}: no test execution registry (nor {LEGACY})")
    return sources


def _git(root: Path, *args: str) -> str:
    return subprocess.check_output(["git", *args], cwd=root, text=True)


def registry_sources_at(root: Path, ref: str) -> list[tuple[str, str]]:
    """registry_sources for the tree of `ref`, read with git (a base commit has no checkout)."""
    sources: list[tuple[str, str]] = []
    names = _git(root, "ls-tree", "--name-only", ref, "--", LEGACY, f"{FRAGMENTS}/").splitlines()
    if LEGACY in names:
        sources.append((LEGACY, _git(root, "show", f"{ref}:{LEGACY}")))
    for name in sorted(name for name in names if FRAGMENT_PATH_RE.fullmatch(name)):
        sources.append((name, _git(root, "show", f"{ref}:{name}")))
    if not sources:
        raise ValueError(f"{ref}: no test execution registry")
    return sources


def parse_sources(sources: list[tuple[str, str]]) -> list[dict[str, object]]:
    """The merged entries of registry_sources(): the old file's, then each fragment's."""
    entries: list[dict[str, object]] = []
    for path, text in sources:
        entries.extend(parse_registry(text, path, fragment=path != LEGACY))
    if not entries:
        raise ValueError(f"{FRAGMENTS}: expected [[test]] entries")
    return entries


def load_tree(root: Path) -> list[dict[str, object]]:
    """Every registry entry under the repository root `root`."""
    return parse_sources(registry_sources(root))


def load_tree_at(root: Path, ref: str) -> list[dict[str, object]]:
    return parse_sources(registry_sources_at(root, ref))


def merged_text(sources: list[tuple[str, str]]) -> str:
    """One registry text equal to the merged view, for a reader that takes a single file."""
    body = "\n".join(text.rstrip("\n") + "\n" for _, text in sources)
    return body if any(path == LEGACY for path, _ in sources) else "version = 1\n\n" + body


def parse_registry(text: str, label: str, fragment: bool = False) -> list[dict[str, object]]:
    """Parse registry text. `label` names the source in error messages.

    The validator reads the base branch's registry through `git show`, which
    has no path on disk, so parsing is separate from reading. A fragment has no
    `version` line and may not have one; a whole registry must say version 1.
    """
    version: object = None
    tests: list[dict[str, object]] = []
    current: Optional[dict[str, object]] = None
    path = label

    for line_number, raw_line in enumerate(text.splitlines(), start=1):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if line == "[[test]]":
            current = {}
            tests.append(current)
            continue

        key, separator, raw_value = line.partition("=")
        if not separator:
            raise ValueError(f"{path}:{line_number}: expected key = value")
        key = key.strip()
        raw_value = raw_value.strip()
        try:
            # TOML spells booleans in lowercase; Python literals do not.
            value = TOML_BOOLEANS[raw_value] if raw_value in TOML_BOOLEANS else ast.literal_eval(raw_value)
        except (SyntaxError, ValueError) as error:
            raise ValueError(f"{path}:{line_number}: invalid literal: {error}") from error

        if current is None:
            if fragment:
                raise ValueError(f"{path}:{line_number}: a fragment holds only [[test]] entries, not {key!r}")
            if key != "version":
                raise ValueError(f"{path}:{line_number}: unsupported top-level key {key!r}")
            if version is not None:
                raise ValueError(f"{path}:{line_number}: duplicate version")
            version = value
            continue

        if key in current:
            raise ValueError(f"{path}:{line_number}: duplicate field {key!r}")
        current[key] = value

    if fragment:
        if not tests:
            raise ValueError(f"{path}: expected [[test]] entries (delete an empty fragment)")
        return tests
    if version != 1:
        raise ValueError(f"{path}: unsupported version {version!r}")
    if not tests:
        raise ValueError(f"{path}: expected [[test]] entries")
    return tests


# Fragment text, kept as each entry's own lines so comments and field order survive a move.

def split_blocks(text: str) -> tuple[str, list[str], str]:
    """(header, blocks, footer) of a registry text.

    The header is the lines before the first [[test]] (comments and, in the old file, the
    version line). A block runs from its [[test]] line to the next one, without the blank lines
    and the section comment (a comment after a blank line) that end it; those go with the next
    block, or into the footer after the last block.
    """
    lines = text.splitlines()
    starts = [index for index, line in enumerate(lines) if line.strip() == "[[test]]"]
    if not starts:
        return text, [], ""
    header = "\n".join(lines[: starts[0]])
    blocks: list[str] = []
    footer = ""
    for number, start in enumerate(starts):
        end = starts[number + 1] if number + 1 < len(starts) else len(lines)
        body = lines[start:end]
        # Trailing blank lines, and a comment group after a blank line, are not this entry's.
        cut = len(body)
        while cut > 1 and not body[cut - 1].strip():
            cut -= 1
        scan = cut
        while scan > 1 and body[scan - 1].strip().startswith("#"):
            scan -= 1
        if scan < cut and scan > 1 and not body[scan - 1].strip():
            cut = scan
            while cut > 1 and not body[cut - 1].strip():
                cut -= 1
        blocks.append("\n".join(body[:cut]))
        if number + 1 == len(starts):
            footer = "\n".join(line for line in body[cut:]).strip("\n")
    return header, blocks, footer


def block_path(block: str) -> str:
    entries = parse_registry(block, "<entry>", fragment=True)
    path = entries[0].get("path")
    if len(entries) != 1 or not isinstance(path, str):
        raise ValueError(f"an entry without a string path: {block!r}")
    return path


def render_fragment(area: str, blocks: list[str], header: str | None = None) -> str:
    """A fragment's text: its header comment, then its entries sorted by path."""
    if header is None or not header.strip():
        header = OTHER_HEADER if area == OTHER_AREA else FRAGMENT_HEADER.format(area=area)
    ordered = sorted(blocks, key=block_path)
    return header.rstrip("\n") + "\n\n" + "\n\n".join(block.strip("\n") for block in ordered) + "\n"


class Fragments:
    """The fragment directory under a checkout, edited in memory and written back."""

    def __init__(self, root: Path) -> None:
        self.directory = root / FRAGMENTS
        self.headers: dict[str, str] = {}
        self.blocks: dict[str, dict[str, str]] = {}
        self.changed: set[str] = set()
        if self.directory.is_dir():
            for fragment in sorted(self.directory.glob("*.toml")):
                header, blocks, _ = split_blocks(fragment.read_text(encoding="utf-8"))
                self.headers[fragment.name] = header
                self.blocks[fragment.name] = {}
                for block in blocks:
                    path = block_path(block)
                    if path in self.blocks[fragment.name] or self.where(path) is not None:
                        # Rewriting would keep one of them and drop the other's fields.
                        raise ValueError(f"{path}: registered more than once; delete one entry first")
                    self.blocks[fragment.name][path] = block

    def areas(self) -> set[str]:
        return {name.removesuffix(".toml") for name in self.blocks}

    def where(self, test_path: str) -> str | None:
        return next((name for name, blocks in self.blocks.items() if test_path in blocks), None)

    def remove(self, test_path: str) -> bool:
        name = self.where(test_path)
        if name is None:
            return False
        del self.blocks[name][test_path]
        self.changed.add(name)
        return True

    def put(self, test_path: str, block: str) -> str:
        """Add or replace the entry for `test_path` in the fragment it belongs in; return that name."""
        self.remove(test_path)
        name = fragment_for(test_path, self.areas())
        self.blocks.setdefault(name, {})[test_path] = block.strip("\n")
        self.changed.add(name)
        return name

    def place_all(self) -> list[str]:
        """Move every misplaced entry to its fragment and mark every unsorted fragment; return the moves."""
        moves = []
        areas = self.areas()
        for name in sorted(self.blocks):
            for test_path, block in list(self.blocks[name].items()):
                want = fragment_for(test_path, areas)
                if want != name:
                    moves.append(f"{test_path}: {name} -> {want}")
                    self.put(test_path, block)
        return moves

    def write(self, only_changed: bool = True) -> list[str]:
        self.directory.mkdir(parents=True, exist_ok=True)
        written = []
        for name in sorted(self.blocks):
            if only_changed and name not in self.changed:
                continue
            target = self.directory / name
            if not self.blocks[name]:
                target.unlink(missing_ok=True)
            else:
                target.write_text(
                    render_fragment(name.removesuffix(".toml"), list(self.blocks[name].values()),
                                    self.headers.get(name)),
                    encoding="utf-8")
            written.append(f"{FRAGMENTS}/{name}")
        return written


def layout_findings(root: Path) -> list[str]:
    """Fragments named outside [a-z0-9]+.toml, entries in the wrong fragment, and unsorted fragments.

    These are warnings: the registry reads the same either way, and `fix` repairs them.
    """
    directory = root / FRAGMENTS
    if not directory.is_dir():
        return []
    findings = []
    if (root / LEGACY).is_file():
        findings.append(
            f"{LEGACY} is still here beside {FRAGMENTS}/; move its entries into the fragments: "
            "python3 scripts/ci/test_execution_registry.py absorb")
    names = sorted(fragment.name for fragment in directory.glob("*.toml"))
    areas = {name.removesuffix(".toml") for name in names}
    for name in names:
        label = f"{FRAGMENTS}/{name}"
        if not FRAGMENT_NAME_RE.fullmatch(name):
            findings.append(f"{label}: a fragment is named for its area in lowercase letters and digits")
        try:
            paths = [str(entry.get("path")) for entry in
                     parse_registry((directory / name).read_text(encoding="utf-8"), label, fragment=True)]
        except (OSError, ValueError):
            continue  # the registry check reports it
        for path in paths:
            want = fragment_for(path, areas)
            if want != name:
                findings.append(f"{path}: registered in {label}; it belongs in {FRAGMENTS}/{want} "
                                "(fix: python3 scripts/ci/test_execution_registry.py fix)")
        if paths != sorted(paths):
            findings.append(f"{label}: entries are not sorted by path, so pull requests adding tests here "
                            "collide (fix: python3 scripts/ci/test_execution_registry.py fix)")
    return findings


def split_legacy(root: Path, minimum: int = SPLIT_AREA_MIN) -> list[str]:
    """Turn the old single file into fragments: an area file for each first word with at least
    `minimum` tests, the rest in other.toml. Returns the fragments written."""
    legacy = root / LEGACY
    _, blocks, _ = split_blocks(legacy.read_text(encoding="utf-8"))
    by_word: dict[str, int] = {}
    for block in blocks:
        word = area_word(block_path(block))
        by_word[word] = by_word.get(word, 0) + 1
    fragments = Fragments(root)
    for word, count in by_word.items():
        if count >= minimum and word != OTHER_AREA:
            fragments.blocks.setdefault(f"{word}.toml", {})
    for block in blocks:
        path = block_path(block)
        if fragments.where(path) is not None:
            raise ValueError(f"{path}: registered more than once in {LEGACY}")
        fragments.put(path, block)
    written = fragments.write()
    legacy.unlink()
    return written


def _git_quiet(root: Path, *args: str) -> str | None:
    try:
        return subprocess.run(["git", *args], cwd=root, text=True, capture_output=True, check=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return None


def legacy_blocks_at(root: Path, ref: str) -> dict[str, str]:
    text = _git(root, "show", f"{ref}:{LEGACY}")
    return {block_path(block): block for block in split_blocks(text)[1]}


def absorb(root: Path, base: str | None, ours: str | None) -> list[str]:
    """Apply what a branch changed in the old single file to the fragments, then delete the file.

    `ours` is the branch's version of the file (default: the working tree's copy, which git leaves
    in place on a modify/delete conflict), `base` the version the branch started from (default:
    during a merge, the merge base of HEAD and MERGE_HEAD; during a rebase or cherry-pick, the
    parent of the commit being replayed). Entries the branch added or changed are put in their
    fragments; entries it removed are removed. Returns a line per change.
    """
    git_dir = Path(_git(root, "rev-parse", "--absolute-git-dir").strip())
    if base is None:
        for head in ("REBASE_HEAD", "CHERRY_PICK_HEAD"):
            if (git_dir / head).is_file():
                base = f"{head}^"
                ours = ours or head
                break
        else:
            if (git_dir / "MERGE_HEAD").is_file():
                base = _git_quiet(root, "merge-base", "HEAD", "MERGE_HEAD")
    if base is None:
        raise ValueError("no merge, rebase or cherry-pick in progress: pass --base REF (where the branch started)")
    before = legacy_blocks_at(root, base)
    if ours is not None:
        after = legacy_blocks_at(root, ours)
    else:
        _, blocks, _ = split_blocks((root / LEGACY).read_text(encoding="utf-8"))
        after = {block_path(block): block for block in blocks}
    fragments = Fragments(root)
    if not fragments.blocks:
        raise ValueError(f"{FRAGMENTS}/ is not here: merge or rebase onto a base that has it first")
    report = []
    for path in sorted(set(before) - set(after)):
        if fragments.remove(path):
            report.append(f"removed {path}")
    for path in sorted(after):
        if before.get(path) != after[path]:
            name = fragments.put(path, after[path])
            report.append(f"{'changed' if path in before else 'added'} {path} in {FRAGMENTS}/{name}")
    fragments.write()
    subprocess.run(["git", "rm", "-q", "-f", "--ignore-unmatch", "--", LEGACY], cwd=root, check=True)
    (root / LEGACY).unlink(missing_ok=True)
    subprocess.run(["git", "add", "-A", "--", FRAGMENTS], cwd=root, check=True)
    return report


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--repo-root", type=Path, default=Path(__file__).resolve().parents[2])
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("fix", help="move misplaced entries to their fragment and sort every fragment")
    take = commands.add_parser("absorb", help="move a branch's edits to the old tests/test-execution.toml "
                               "into the fragments (run it on the conflict a merge or rebase leaves)")
    take.add_argument("--base", help="the commit the branch's edits started from")
    take.add_argument("--ours", help="the commit holding the branch's version of the old file")
    split = commands.add_parser("split", help="turn the old single file into fragments")
    split.add_argument("--min", type=int, default=SPLIT_AREA_MIN, help="tests a first word needs for its own file")
    commands.add_parser("cat", help="print the merged registry as one file")
    args = parser.parse_args(argv)
    root = args.repo_root.resolve()
    try:
        if args.command == "fix":
            fragments = Fragments(root)
            for move in fragments.place_all():
                print(f"moved {move}")
            fragments.changed.update(fragments.blocks)
            for path in fragments.write():
                print(f"wrote {path}")
        elif args.command == "absorb":
            for line in absorb(root, args.base, args.ours):
                print(line)
        elif args.command == "split":
            for path in split_legacy(root, args.min):
                print(f"wrote {path}")
        elif args.command == "cat":
            sys.stdout.write(merged_text(registry_sources(root)))
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"test_execution_registry: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
