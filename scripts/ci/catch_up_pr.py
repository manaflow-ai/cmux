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
  object IDs. A hunk where either side changed or removed a base line stops.
- The embedded config schema Swift: regenerated with
  scripts/generate-cmux-config-schema.py from the merged
  web/data/cmux.schema.json. It is also regenerated when both sides changed
  the schema and git merged the Swift text cleanly, since a textual merge of
  two base64 blobs is not the encoding of the merged schema. A conflict in the
  schema JSON itself stops.
- *.xcstrings: a key-level three-way merge through scripts/merge-xcstrings.py.
  The same key changed differently on both sides stops, naming the keys.

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
  catch_up_pr.py merge --base origin/main [--repo DIR] [--tools-root DIR] [--json]
  catch_up_pr.py comment --result result.json --push pushed|...
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
PBX_SETTING_RE = re.compile(r"^\s*([^\s=]+)\s*=\s*[^{(]*;\s*$")
REGULAR_MODES = {"100644", "100755"}
# attr.tree, which keeps the head's .gitattributes out of the merge.
MIN_GIT = (2, 46)

# Every git call pins the settings that change what a merge produces or what
# runs during it. Hooks are off: this tree may be untrusted, and the
# generators already did what the pbxproj pre-commit hook would. The
# .xcstrings merge driver is replaced by `false` so git leaves those files
# unmerged for the trusted key-wise merge below; a clone configured by
# scripts/install-git-hooks.sh would otherwise run the driver from the tree
# being merged.
GIT = [
    "git",
    "-c", "core.hooksPath=/dev/null",
    "-c", "merge.conflictStyle=diff3",
    "-c", "merge.xcstrings.driver=false",
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


def keyed_insertions(slots: list[list[str]]) -> tuple[dict[str, list], dict[str, list]]:
    """Object IDs and flat `KEY = value;` settings a side inserted, with their slots."""
    ids: dict[str, list] = {}
    settings: dict[str, list] = {}
    for slot, lines in enumerate(slots):
        for line in lines:
            if match := PBX_ID_RE.match(line):
                ids.setdefault(match.group(1), []).append((slot, line))
            elif match := PBX_SETTING_RE.match(line):
                settings.setdefault(match.group(1), []).append((slot, line))
    return ids, settings


def collides(ours_slots: list[list[str]], theirs_slots: list[list[str]]) -> bool:
    """Both sides inserted the same object ID, or the same setting key, differently.

    An identical entry in the same place is one entry and is deduplicated. The
    same ID elsewhere would become a duplicate list entry or object that the
    normalizer cannot always see, and the same build setting twice is a
    duplicate dictionary key. Settings are only compared when neither side
    opened a new object or list, where repeated keys such as `isa` are normal.
    """
    ours_ids, ours_settings = keyed_insertions(ours_slots)
    theirs_ids, theirs_settings = keyed_insertions(theirs_slots)
    if any(ours_ids[key] != theirs_ids[key] for key in ours_ids.keys() & theirs_ids.keys()):
        return True
    opens = any(
        line.rstrip().endswith(("{", "("))
        for slots in (ours_slots, theirs_slots) for lines in slots for line in lines
    )
    return not opens and any(
        ours_settings[key] != theirs_settings[key] for key in ours_settings.keys() & theirs_settings.keys()
    )


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


def union_pbxproj(base: str, ours: str, theirs: str) -> str:
    """Three-way merge where each conflicted hunk must be insertions on both sides."""
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
    out: list[str] = []
    for part in split_conflicts(completed.stdout.decode("utf-8")):
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
    return "".join(out)


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
            shown = ", ".join(conflicts[:10]) + (f" and {len(conflicts) - 10} more" if len(conflicts) > 10 else "")
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

    def schema(self, conflicted: bool) -> None:
        # The generator reads one path and writes the other. A symlink at
        # either would read a runner file into the commit or write outside
        # the checkout.
        for path in (SCHEMA_JSON, SCHEMA_SWIFT):
            if problem := self.repo.unsafe(path):
                self.block(SCHEMA_SWIFT, f"{path} is {problem}; not regenerating")
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


def catch_up(repo_path: Path, base_ref: str, tools_root: Path, note: str = "") -> Result:
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

    merge = repo.run("merge", "--no-ff", "--no-commit", "--no-edit", result.base, check=False)
    in_merge = repo.run("rev-parse", "--verify", "--quiet", "MERGE_HEAD", check=False).returncode == 0
    unmerged = repo.unmerged() if in_merge else {}
    if merge.returncode != 0 and not unmerged:
        if in_merge:
            repo.run("merge", "--abort", check=False)
        raise CatchUpError(f"git merge failed: {tail(merge.stderr.decode(errors='replace'))}")

    try:
        return finish(repo, result, Resolver(repo, tools_root), unmerged, base_ref, note)
    except BaseException:
        repo.run("merge", "--abort", check=False)
        raise


def finish(repo: Repo, result: Result, resolver: Resolver, unmerged: dict[str, set[int]],
           base_ref: str, note: str) -> Result:
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
        else:
            resolver.block(path, "not a generated file; needs a person")

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

    lines = [f"Merge {base_ref} into the pull request head", ""]
    lines.append("Catch-up merge by scripts/ci/catch_up_pr.py (RFC #14631).")
    if note:
        lines.append(note)
    if result.resolved:
        lines += ["", "Resolved generated files:"]
        lines += [f"- {item['path']}: {item['method']}" for item in result.resolved]
    lines += ["", f"Catch-up-previous-head: {result.head_before}", f"Catch-up-base: {result.base}"]
    repo.run("commit", "--no-verify", "-F", "-", input_bytes=("\n".join(lines) + "\n").encode())
    result.head_after = repo.text("rev-parse", "HEAD")
    result.status = "merged"
    result.message = f"merged {base_ref} with {len(result.resolved)} generated file(s) resolved"
    return result


def command_merge(args: argparse.Namespace) -> int:
    result = Result(base_ref=args.base)
    try:
        result = catch_up(Path(args.repo).resolve(), args.base, Path(args.tools_root).resolve(), args.note)
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


# --- the pull request comment -------------------------------------------------


def code(text: str) -> str:
    """Inline code for text from the pull request (paths, keys), inert in Markdown."""
    return "`" + " ".join(str(text).replace("`", "'").split()) + "`"


def plain(text: str) -> str:
    """Our own reason strings can quote pull request keys; keep them on one inert line."""
    text = str(text).replace("`", "'").replace("@", "@\u200b")
    for char in "\\[]()<>!*_~|#":
        text = text.replace(char, "\\" + char)
    return " ".join(text.split())


def render_comment(result: dict, push: str, base_name: str, head_name: str, run_url: str) -> str:
    base = (result.get("base") or "")[:12]
    base_label = f"{code(base_name)} ({code(base)})" if base else code(base_name)
    status = result.get("status")
    footer = f"\n\n<sub>[Catch-up run]({run_url}) · RFC #14631</sub>" if run_url else ""
    if status == "up_to_date":
        return f"This branch already has {base_label}, so there was nothing to catch up.{footer}"
    if status == "blocked":
        lines = [f"I tried to catch this branch up with {base_label}, but these files need a person:", ""]
        lines += [f"- {code(item['path'])}: {plain(item['reason'])}" for item in result.get("blocking", [])[:20]]
        extra = len(result.get("blocking", [])) - 20
        if extra > 0:
            lines.append(f"- and {extra} more in the run log")
        lines += ["", f"Nothing was pushed. Merge {code(base_name)} locally, fix those, and push;"
                  " `/catch-up` is there again whenever you want it."]
        return "\n".join(lines) + footer
    if status != "merged":
        return (f"Catch-up stopped before merging ({plain(result.get('message', 'unknown error'))})."
                f" Nothing was pushed.{footer}")
    head = (result.get("head_after") or "")[:12]
    resolved = [f"- {code(item['path'])}: {plain(item['method'])}" for item in result.get("resolved", [])]
    if push == "pushed" or push == "pushed-without-ci":
        lines = [f"Caught {code(head_name)} up with {base_label} in {code(head)}."]
        if resolved:
            lines += ["", "Resolved with their generators:", *resolved]
        if push == "pushed-without-ci":
            lines += ["", "This push used the Actions token, so CI will not start on its own."
                      " Push any commit (or close and reopen) to get checks on the new head."]
        return "\n".join(lines) + footer
    if push == "fork-not-editable":
        return (f"The merge with {base_label} is clean, but this branch lives on a fork that does not allow"
                " edits by maintainers, so I cannot push it. Turn on *Allow edits by maintainers*"
                f" and comment `/catch-up` again, or merge {code(base_name)} yourself.{footer}")
    if push == "needs-workflows":
        return (f"The merge with {base_label} is clean, but it brings in workflow changes and the token"
                " I had cannot push those. Nothing changed on the branch; merge"
                f" {code(base_name)} yourself this time.{footer}")
    if push == "push-denied":
        return (f"The merge with {base_label} is clean, but I was not allowed to push to {code(head_name)}."
                f" Nothing changed on the branch; merge {code(base_name)} yourself this time.{footer}")
    return (f"The merge with {base_label} is clean, but {code(head_name)} moved while I worked, so I"
            f" did not push. Nothing changed on the branch; comment `/catch-up` to try again.{footer}")


def command_comment(args: argparse.Namespace) -> int:
    try:
        result = json.loads(Path(args.result).read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        result = {"status": "error", "message": f"no catch-up result ({error.__class__.__name__})"}
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
    merge.add_argument("--json", action="store_true", help="print a machine-readable result")
    merge.set_defaults(func=command_merge)
    comment = sub.add_parser("comment", help="render the pull request comment for a result")
    comment.add_argument("--result", required=True)
    comment.add_argument("--push", required=True,
                         choices=["pushed", "pushed-without-ci", "rejected", "needs-workflows", "push-denied",
                                  "fork-not-editable", "not-attempted"])
    comment.add_argument("--base-name", default="main")
    comment.add_argument("--head-name", default="this branch")
    comment.add_argument("--run-url", default="")
    comment.set_defaults(func=command_comment)
    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
