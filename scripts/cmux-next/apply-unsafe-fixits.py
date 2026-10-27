#!/usr/bin/env python3
"""Apply the compiler's strict-memory-safety `unsafe` fix-its by machine, each site marked SAFETY-TODO(p10).

p10-stability-211 (plans/cmux-next/chrome-parity/p10-stability.md C.2), Chromium's unsafe-buffers order
(docs/unsafe_buffers.md, build/config/unsafe_buffers_paths.txt): the check goes on for every target first and the
old sites are marked (Chromium's UNSAFE_TODO()); the marks are the queue, and module tasks 063-078 replace each mark
with a real `// SAFETY:` argument or a safe API. New code never gets a mark (guardrails.py's `safety-todo` rule).

The pass, per package, on one tip:
  1. The settings lander turns `.strictMemorySafety()` on (stability-settings.json row of p10-stability-211;
     apply-stability-settings.py --commit).
  2. A fleet step at that sha writes the fix-its (swift-diagnostics.sh, p10-stability-036):
       cmux-ci run --class isolated --ref SHA --script scripts/cmux-next/swift-diagnostics.sh -- \\
         --package PACKAGE --group StrictMemorySafety --fixits-out artifacts/unsafe-fixits.jsonl --summary
  3. This script applies them on the checkout: apply-unsafe-fixits.py --fixits FILE --ref SHA [--commit].

What it applies: a pure insertion of `unsafe ` or `@unsafe ` (offset == end_offset) in a .swift file under
Packages/<...>/Sources or Tests of a closure package that is not vendored: not a package vendored verbatim (a
SOURCE file) and not a file its vendor.tsv lists (CmuxMessagesLab: sync-messageslab.sh copies pin + Patches/ over
those, so an edit there would be lost and would fail its --check). It adds one
`// SAFETY-TODO(p10)` comment line above each line that gains an insertion, at that line's indentation (above the
line that opens the literal when the line starts inside a multi-line string or a block comment). Everything else
is refused and listed, never applied: another fix-it, another group, a file outside the closure's sources, a file
whose text differs from its text at --ref (the offsets are that text's: rerun swift-diagnostics on the new tip,
the plan's conflict rule), an offset that disagrees with its line and column, or an insertion inside a word.
So the source diff is only `unsafe` insertions and SAFETY-TODO comment lines, and a second run over the same
fix-its is refused as stale instead of marking twice.

Fix-it paths are the fleet host's absolute paths: --source-root names that checkout's root; without it the path's
first `/Packages/` segment starts the repository-relative path.

What the pass cannot do is the module tasks' list (p10-stability-063..078, by the plan's file globs): every refused
fix-it and, with --diagnostics (swift-diagnostics.sh --out), every StrictMemorySafety diagnostic with no fix-it.
It prints the count per owning task and --leftovers-out writes one JSON line per site ({kind, where, path, owner,
why}). The diagnostics count reaches 0 only after those tasks; the pass alone does not get there.

Usage: scripts/cmux-next/apply-unsafe-fixits.py --fixits FILE --ref SHA [--source-root DIR] [--package DIR]...
                                                [--diagnostics FILE] [--leftovers-out FILE]
                                                [--repo DIR] [--dry-run | --commit]
  (default)   write the edits into the working tree
  --dry-run   only print what would change
  --commit    refuse unless the files it edits are clean, then one commit per package (subject UNSAFE_SUBJECT),
              with the package's SAFETY-TODO(p10) count after it (the Q04 queue). Pushing and the fleet
              compile-check are the operator's steps; the script prints them.
Exit status: 0 every fix-it applied (or already part of a skipped duplicate) and no diagnostic lacks one; 1 some
sites are left (the rest are applied); 2 bad arguments or input. Stdlib only.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import re
import subprocess
import sys
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
GROUP = "StrictMemorySafety"
MARK = "// SAFETY-TODO(p10)"
UNSAFE_SUBJECT = "unsafe fix-its lander:"
INSERTION = re.compile(r"@?unsafe ")
SOURCE_PATH = re.compile(r"^Packages/.+/(?:Sources|Tests)/.+\.swift$")
WORD = re.compile(rb"[A-Za-z0-9_]")
VENDORED_MARKER = "SOURCE"  # the whole package is an upstream copy
VENDOR_TABLE = "vendor.tsv"  # upstream path<TAB>vendored path (relative to the package)[<TAB>pin], `#` comments
PLAN = "plans/cmux-next/chrome-parity/design-result.json"
PLAN_PROGRAM = "p10-stability"
MODULE_TASK_TITLE = "SAFETY-TODO removal"
UNOWNED = "(no module task)"
BRACES = re.compile(r"\{([^}]*)\}")


class UsageError(Exception):
    """Bad arguments or unreadable input (exit 2)."""


def git(root: Path, *args: str, check: bool = True) -> subprocess.CompletedProcess[bytes]:
    return subprocess.run(["git", "-C", str(root), *args], capture_output=True, check=check)


def load_lander():
    """apply-stability-settings.py next to this file: the closure is its definition, not a second one."""
    name = "cmux_next_apply_stability_settings"
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, HERE / "apply-stability-settings.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


@dataclass(frozen=True)
class Fixit:
    path: str  # repository-relative
    line: int
    column: int
    offset: int
    text: str


@dataclass
class Refusal:
    where: str  # as the fix-it names it: the fleet host's path:line:column
    why: str
    path: str | None  # repository-relative, None when the fix-it's file is not inside the repository


@dataclass
class FileEdit:
    path: str
    package: str
    fixits: list[Fixit] = field(default_factory=list)


@dataclass
class Result:
    edits: dict[str, bytes]  # path -> new text
    packages: dict[str, list[str]]  # package -> paths
    inserted: Counter  # package -> insertions
    marked: Counter  # package -> SAFETY-TODO lines added
    refused: list[Refusal]
    duplicates: int


# ---------------------------------------------------------------- reading

def relative_path(file: str, source_root: str | None) -> str | None:
    """FILE (a fleet host's absolute path) relative to the repository, or None when it is not inside it."""
    if source_root:
        prefix = source_root.rstrip("/") + "/"
        return file[len(prefix):] if file.startswith(prefix) else None
    index = file.find("/Packages/")
    if index >= 0:
        return file[index + 1:]
    return file if file.startswith("Packages/") else None


def read_fixits(path: Path, source_root: str | None) -> tuple[list[Fixit], list[Refusal], int]:
    """(the StrictMemorySafety insertions to judge, refusals, duplicates dropped) of a --fixits-out file."""
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as error:
        raise UsageError(f"cannot read --fixits {path}: {error}") from error
    found: dict[tuple, Fixit] = {}
    refused: list[Refusal] = []
    duplicates = 0
    for number, line in enumerate(lines, 1):
        if not line.strip():
            continue
        try:
            row = json.loads(line)
            file, text = row["file"], row["text"]
            start = (int(row["line"]), int(row["column"]), int(row["offset"]))
            end = (int(row["end_line"]), int(row["end_column"]), int(row["end_offset"]))
        except (ValueError, KeyError, TypeError) as error:
            raise UsageError(f"{path}:{number}: not a swift-diagnostics fix-it line ({error})") from error
        where = f"{file}:{start[0]}:{start[1]}"
        relative = relative_path(file, source_root)
        if row.get("group") != GROUP:
            refused.append(Refusal(where, f"group {row.get('group') or '(none)'}, not {GROUP}", relative))
            continue
        if start != end or not INSERTION.fullmatch(text):
            refused.append(Refusal(where, f"not an `unsafe` insertion: replace {start}..{end} with {text!r} "
                                          "(a person applies it)", relative))
            continue
        if relative is None or not SOURCE_PATH.match(relative):
            refused.append(Refusal(where, "not a .swift file under Packages/<package>/Sources or Tests", relative))
            continue
        fixit = Fixit(relative, start[0], start[1], start[2], text)
        key = (relative, fixit.offset, text)
        if key in found:
            duplicates += 1
            continue
        found[key] = fixit
    return list(found.values()), refused, duplicates


# ---------------------------------------------------------------- placement

def literal_line_starts(text: str) -> list[bool]:
    """Per line of TEXT.split("\\n"): the line starts inside a string literal (any string still open across the
    line break, so a multi-line or interpolated one) or a block comment, where a comment line would change the
    program or end nowhere. A small Swift lexer: comments, nested block comments, raw (`#"..."#`) and multi-line
    strings, escapes and `\\(...)` interpolations (code with its own strings) inside them."""
    starts = [False]
    # Each frame: ("code", paren depth) for an interpolation, ("string", hashes, multiline), ("block", depth).
    stack: list[list] = []
    index, size = 0, len(text)
    while index < size:
        char = text[index]
        top = stack[-1] if stack else None
        if char == "\n":
            if top is not None and top[0] == "string" and not top[2]:
                stack.pop()  # an unterminated single-line string ends at the line break (the compiler's error)
            starts.append(any(frame[0] in ("string", "block") for frame in stack))
            index += 1
            continue
        if top is None or top[0] == "code":
            if text.startswith("//", index):
                end = text.find("\n", index)
                index = size if end < 0 else end
                continue
            if text.startswith("/*", index):
                stack.append(["block", 1])
                index += 2
                continue
            hashes = 0
            while text.startswith("#", index + hashes):
                hashes += 1
            if text.startswith('"', index + hashes):
                multiline = text.startswith('"""', index + hashes)
                stack.append(["string", hashes, multiline])
                index += hashes + (3 if multiline else 1)
                continue
            if top is not None:
                if char == "(":
                    top[1] += 1
                elif char == ")":
                    top[1] -= 1
                    if top[1] == 0:
                        stack.pop()
            index += max(1, hashes)
            continue
        if top[0] == "block":
            if text.startswith("/*", index):
                top[1] += 1
                index += 2
            elif text.startswith("*/", index):
                top[1] -= 1
                index += 2
                if top[1] == 0:
                    stack.pop()
            else:
                index += 1
            continue
        hashes, multiline = top[1], top[2]
        delimiter = "\\" + "#" * hashes
        if text.startswith(delimiter, index):
            after = index + len(delimiter)
            if text.startswith("(", after):
                stack.append(["code", 1])
                index = after + 1
            else:  # the escaped character; an escaped line break (a multi-line string's continuation) stays a break
                index = after if text.startswith("\n", after) else after + 1
            continue
        closing = ('"""' if multiline else '"') + "#" * hashes
        if text.startswith(closing, index):
            stack.pop()
            index += len(closing)
            continue
        index += 1
    return starts


def line_starts(data: bytes) -> list[int]:
    starts = [0]
    position = data.find(b"\n")
    while position >= 0:
        starts.append(position + 1)
        position = data.find(b"\n", position + 1)
    return starts


def apply_file(data: bytes, fixits: list[Fixit]) -> tuple[bytes, int, int, list[Refusal]]:
    """(new text, insertions, marks added, refusals) for FIXITS on DATA, the text the fix-its were made from."""
    starts = line_starts(data)
    refused: list[Refusal] = []
    good: list[Fixit] = []
    for fixit in fixits:
        where = f"{fixit.path}:{fixit.line}:{fixit.column}"
        if not 1 <= fixit.line <= len(starts) or starts[fixit.line - 1] + fixit.column - 1 != fixit.offset \
                or fixit.offset > len(data):
            refused.append(Refusal(where, f"offset {fixit.offset} is not line {fixit.line} column {fixit.column} of "
                                          "this text", fixit.path))
            continue
        before = data[fixit.offset - 1:fixit.offset] if fixit.offset else b""
        at = data[fixit.offset:fixit.offset + 1]
        if WORD.fullmatch(before or b" ") or not at or at.isspace():
            refused.append(Refusal(where, "the insertion point is not the start of an expression", fixit.path))
            continue
        good.append(fixit)
    try:
        flags = literal_line_starts(data.decode("utf-8"))
    except UnicodeDecodeError:
        return data, 0, 0, refused + [Refusal(fixits[0].path, "not UTF-8 text", fixits[0].path)]
    lines = data.split(b"\n")
    marks: set[int] = set()  # 0-based lines that get a mark above them
    for fixit in good:
        index = fixit.line - 1
        while index > 0 and flags[index]:
            index -= 1
        marks.add(index)
    out = bytearray(data)
    for fixit in sorted(good, key=lambda f: -f.offset):
        out[fixit.offset:fixit.offset] = fixit.text.encode()
    new_lines = bytes(out).split(b"\n")
    added = 0
    for index in sorted(marks, reverse=True):
        if index > 0 and lines[index - 1].strip() == MARK.encode():
            continue  # the line is marked already (another fix-it on a line of the same statement)
        indent = re.match(rb"[ \t]*", new_lines[index]).group(0)
        new_lines.insert(index, indent + MARK.encode())
        added += 1
    return b"\n".join(new_lines), len(good), added, refused


# ---------------------------------------------------------------- what is left

@dataclass(frozen=True)
class Leftover:
    kind: str  # "refused" (a fix-it the pass did not apply) or "no fix-it" (a diagnostic the compiler gave none)
    where: str
    path: str | None  # repository-relative
    why: str


def read_unfixable(path: Path, source_root: str | None) -> list[Leftover]:
    """The StrictMemorySafety rows of a swift-diagnostics.sh --out file that carry no fix-it."""
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as error:
        raise UsageError(f"cannot read --diagnostics {path}: {error}") from error
    found: dict[tuple, Leftover] = {}
    for number, line in enumerate(lines, 1):
        if not line.strip():
            continue
        try:
            row = json.loads(line)
            file, fixits = row["file"], row["fixits"]
            where = f"{file}:{int(row['line'])}:{int(row['column'])}"
        except (ValueError, KeyError, TypeError) as error:
            raise UsageError(f"{path}:{number}: not a swift-diagnostics row ({error})") from error
        if row.get("group") == GROUP and not fixits:
            message = str(row.get("message") or "")
            found.setdefault((where, message), Leftover("no fix-it", where, relative_path(file, source_root), message))
    return list(found.values())


def module_owners(plan: Path) -> list[tuple[str, str]]:
    """(path prefix, task id) of the SAFETY-TODO removal tasks of PLAN (this checkout's design-result.json), longest
    prefix first: the task whose file glob (`Packages/X/**`, `.../Sources/{A,B}/**`) covers a path owns its sites."""
    try:
        program = json.loads(plan.read_text(encoding="utf-8"))["programs"][PLAN_PROGRAM]
    except (OSError, ValueError, KeyError) as error:
        raise UsageError(f"cannot read the module tasks from {PLAN}: {error}") from error
    owners = []
    for task in program["tasks"]:
        if not task["title"].startswith(MODULE_TASK_TITLE):
            continue
        for glob in task["files"]:
            stem = glob.split(" (", 1)[0].split("**", 1)[0]
            brace = BRACES.search(stem)
            if brace is None:
                owners.append((stem, task["id"]))
                continue
            owners += [(stem[:brace.start()] + name + stem[brace.end():], task["id"])
                       for name in brace.group(1).split(",")]
    return sorted(owners, key=lambda owner: -len(owner[0]))


def owner_of(path: str | None, owners: list[tuple[str, str]]) -> str:
    return next((task for prefix, task in owners if path and path.startswith(prefix)), UNOWNED)


def leftovers(refused: list[Refusal], unfixable: list[Leftover]) -> list[Leftover]:
    """Every refused fix-it, then every diagnostic with no fix-it."""
    return [Leftover("refused", r.where, r.path, r.why) for r in refused] + unfixable


# ---------------------------------------------------------------- the pass

def package_of(path: str, packages: list[str]) -> str | None:
    owners = [p for p in packages if path.startswith(p.rstrip("/") + "/")]
    return max(owners, key=len) if owners else None


def vendored_files(root: Path, package: str) -> set[str]:
    """The repository-relative files PACKAGE's vendor.tsv lists: sync-messageslab.sh owns them (pin + Patches/)."""
    table = root / package / VENDOR_TABLE
    try:
        lines = table.read_text(encoding="utf-8").splitlines()
    except FileNotFoundError:
        return set()
    except OSError as error:
        raise UsageError(f"cannot read {package}/{VENDOR_TABLE}: {error}") from error
    files = set()
    for number, line in enumerate(lines, 1):
        if not line.strip() or line.startswith("#"):
            continue
        columns = line.split("\t")
        if len(columns) < 2 or not columns[1]:
            raise UsageError(f"{package}/{VENDOR_TABLE}:{number}: not `upstream<TAB>vendored path[<TAB>pin]`")
        files.add(f"{package}/{columns[1]}")
    return files


def plan_pass(root: Path, ref: str, fixits: list[Fixit], only: list[str]) -> Result:
    lander = load_lander()
    tree = lander.WorkTree(root)
    try:
        closure = lander.closure(tree)
    except lander.LanderError as error:
        raise UsageError(f"cannot read the package closure: {error}") from error
    vendored = {p for p in closure if (root / p / VENDORED_MARKER).is_file()}
    vendored_by_table = {path: package for package in closure for path in vendored_files(root, package)}
    by_file: dict[str, FileEdit] = {}
    refused: list[Refusal] = []
    for fixit in fixits:
        where = f"{fixit.path}:{fixit.line}:{fixit.column}"
        package = package_of(fixit.path, closure)
        if package is None:
            refused.append(Refusal(where, "not in a package of the app's closure (apply-stability-settings.py "
                                          "--list-closure)", fixit.path))
            continue
        if package in vendored:
            refused.append(Refusal(where, f"{package} is vendored verbatim ({VENDORED_MARKER}); change its upstream",
                                   fixit.path))
            continue
        if fixit.path in vendored_by_table:
            refused.append(Refusal(where, f"vendored by {package}/{VENDOR_TABLE}: an edit is lost on the next sync "
                                          "and fails its --check; change it with its Patches/", fixit.path))
            continue
        if only and package not in only:
            continue
        by_file.setdefault(fixit.path, FileEdit(fixit.path, package)).fixits.append(fixit)
    result = Result({}, defaultdict(list), Counter(), Counter(), refused, 0)
    for path, edit in sorted(by_file.items()):
        shown = git(root, "show", f"{ref}:{path}", check=False)
        try:
            current = (root / path).read_bytes()
        except OSError:
            current = None
        if shown.returncode or current != shown.stdout:
            result.refused.extend(Refusal(f"{f.path}:{f.line}:{f.column}", f"stale: {path} is not its text at "
                                          f"{ref[:12]}; rerun swift-diagnostics on this tip", f.path)
                                  for f in edit.fixits)
            continue
        text, inserted, marked, problems = apply_file(current, edit.fixits)
        result.refused.extend(problems)
        if inserted:
            result.edits[path] = text
            result.packages[edit.package].append(path)
            result.inserted[edit.package] += inserted
            result.marked[edit.package] += marked
    return result


def queue_count(root: Path, package: str) -> int:
    """The package's Q04 count: SAFETY-TODO(p10) lines in its Sources and Tests (the module tasks' queue)."""
    done = git(root, "grep", "-c", "-F", "SAFETY-TODO(p10)", "--", f"{package}/Sources", f"{package}/Tests",
               check=False)
    return sum(int(line.rsplit(b":", 1)[1]) for line in done.stdout.splitlines() if b":" in line)


def write_edits(root: Path, edits: dict[str, bytes]) -> None:
    for path, text in edits.items():
        (root / path).write_bytes(text)


def commit_packages(root: Path, ref: str, result: Result) -> list[str]:
    """One commit per package of RESULT's edits; their shas."""
    dirty = [path for path in result.edits if git(root, "status", "--porcelain", "--", path).stdout.strip()]
    if dirty:
        raise UsageError(f"uncommitted edits in {', '.join(sorted(dirty))}; the pass commits only its own edits")
    shas = []
    for package, paths in sorted(result.packages.items()):
        write_edits(root, {path: result.edits[path] for path in paths})
        subject = f"{UNSAFE_SUBJECT} {package} (p10-stability-211)"
        body = (f"Machine pass of scripts/cmux-next/apply-unsafe-fixits.py over the {GROUP} fix-its of "
                f"{ref}: {result.inserted[package]} `unsafe` insertion(s), {result.marked[package]} "
                f"{MARK} mark(s) in {len(paths)} file(s). Q04 count after it: {queue_count(root, package)}.\n\n"
                "Source diff: only `unsafe` insertions and SAFETY-TODO(p10) comment lines. A conflict is resolved "
                "by rerunning swift-diagnostics and this script on the new tip, never by hand.\n\n"
                "Test phase: fleet compile-check (cmux-ci build cmux --ref <this sha>); swift-diagnostics.sh "
                f"--package {package} --summary --group {GROUP} counts what is left.")
        try:
            git(root, "add", "--", *paths)
            git(root, "commit", "-q", "-m", subject, "-m", body, "--", *paths)
        except subprocess.CalledProcessError as error:
            raise UsageError(f"the commit of {package} failed: {error.stderr.decode(errors='replace').strip()}") \
                from error
        shas.append(git(root, "rev-parse", "HEAD").stdout.decode().strip())
    return shas


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(prog="apply-unsafe-fixits.py", description=__doc__.split("\n\n", 1)[0])
    parser.add_argument("--fixits", type=Path, required=True, help="swift-diagnostics.sh --fixits-out JSONL")
    parser.add_argument("--ref", required=True, help="the commit swift-diagnostics built (its summary.json head)")
    parser.add_argument("--source-root", help="the fleet checkout root the fix-it paths start with")
    parser.add_argument("--package", action="append", default=[], help="only this closure package; repeatable")
    parser.add_argument("--diagnostics", type=Path,
                        help="swift-diagnostics.sh --out JSONL: list its StrictMemorySafety rows with no fix-it")
    parser.add_argument("--leftovers-out", type=Path, help="write what the pass left, one JSON line per site")
    parser.add_argument("--repo", type=Path, default=ROOT, help="the repository (default: this script's)")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--dry-run", action="store_true")
    mode.add_argument("--commit", action="store_true")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    try:
        args = parse_args(list(sys.argv[1:] if argv is None else argv))
    except SystemExit as error:
        return 2 if error.code else 0
    root = args.repo.resolve()
    try:
        done = git(root, "rev-parse", "--verify", "--quiet", f"{args.ref}^{{commit}}", check=False)
        if done.returncode:
            raise UsageError(f"--ref {args.ref} is not a commit here; fetch it first")
        ref = done.stdout.decode().strip()
        only = [p.rstrip("/") for p in args.package]
        fixits, refused, duplicates = read_fixits(args.fixits, args.source_root)
        unfixable = read_unfixable(args.diagnostics, args.source_root) if args.diagnostics else []
        owners = module_owners(ROOT / PLAN)
        result = plan_pass(root, ref, fixits, only)
        result.refused[:0] = refused
        result.duplicates = duplicates
        shas: list[str] = []
        if args.commit:
            shas = commit_packages(root, ref, result)
        elif not args.dry_run:
            write_edits(root, result.edits)
    except UsageError as error:
        print(f"apply-unsafe-fixits: {error}", file=sys.stderr)
        return 2
    verb = "would apply" if args.dry_run else "applied"
    for package, paths in sorted(result.packages.items()):
        print(f"apply-unsafe-fixits: {verb} {result.inserted[package]} insertion(s), {result.marked[package]} "
              f"mark(s) in {len(paths)} file(s) of {package}")
    if not result.packages:
        print("apply-unsafe-fixits: nothing to apply")
    if result.duplicates:
        print(f"apply-unsafe-fixits: {result.duplicates} duplicate fix-it line(s) dropped")
    for refusal in result.refused:
        print(f"apply-unsafe-fixits: refused {refusal.where}: {refusal.why}", file=sys.stderr)
    left = leftovers(result.refused, unfixable)
    by_owner = Counter(owner_of(item.path, owners) for item in left)
    for item in unfixable:
        print(f"apply-unsafe-fixits: no fix-it {item.where}: {item.why}", file=sys.stderr)
    if left:
        print(f"apply-unsafe-fixits: {len(left)} site(s) left for the module tasks ({len(unfixable)} with no fix-it): "
              + ", ".join(f"{owner} {count}" for owner, count in sorted(by_owner.items())))
    if args.leftovers_out:
        args.leftovers_out.parent.mkdir(parents=True, exist_ok=True)
        args.leftovers_out.write_text("".join(json.dumps({"kind": item.kind, "where": item.where, "path": item.path,
                                                          "owner": owner_of(item.path, owners), "why": item.why},
                                                         sort_keys=True) + "\n" for item in left), encoding="utf-8")
    if shas:
        print("apply-unsafe-fixits: committed " + ", ".join(sha[:12] for sha in shas)
              + "\n  push, then compile-check the tip on the fleet (the operator's step):\n"
              "  cmux-ci build cmux --ref <pushed sha> --tag unsafe-fixits-<sha9> --workspace <branch URL> "
              "--receipt artifacts/fleet/<sha>-submit.json && cmux-ci wait <job id>")
    return 1 if left else 0


if __name__ == "__main__":
    sys.exit(main())
