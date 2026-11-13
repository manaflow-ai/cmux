#!/usr/bin/env python3
"""Port-drift ratchet: every function a cmux-tui crate exports in its C header has a Swift caller.

A Rust port lands in two steps: step A adds the crate and its C ABI, step B switches Swift to it and deletes
the Swift copy. A port that stops after step A ships the Rust unused and keeps the Swift (cmuxterm-hq
docs/architecture/consolidation-2026-11-12.md: cmux-daemon-conn-core 0 of 28 functions called,
cmux-sdk-ffi 0 of 11, hover 16 with no caller). This check reads each function declared in
cmux-tui/crates/*/include/*.h and looks for its name in Packages/**/*.swift outside test targets and
comments. The functions with no caller are listed in scripts/cmux-next/ffi-caller-baseline.txt, a list that
may only shrink.

It fails, naming the function, when:
  - an exported function has no Swift caller and is not in the baseline (a new export, or one that lost its
    last caller);
  - a baseline entry now has a caller or is no longer exported (the list shrinks with it: rerun with
    --update, which only removes entries).

    python3 scripts/cmux-next/ffi_caller_ratchet.py               # the working tree; exit 1 on a finding
    python3 scripts/cmux-next/ffi_caller_ratchet.py --rev HEAD    # a commit, read from git
    python3 scripts/cmux-next/ffi_caller_ratchet.py --update      # drop entries that gained a caller
    python3 scripts/cmux-next/ffi_caller_ratchet.py --report      # called/exported per header
    python3 scripts/cmux-next/ffi_caller_ratchet.py --inputs      # the paths it reads, one per line
    --repo DIR reads another checkout (the tests' fixtures).

A Swift test target (a path under Packages with a Tests/ folder in it) is not a caller: a function only a test
reaches is still unadopted. A name inside a string literal counts (a dlsym lookup is a real caller).
prepush-gate.py runs it on every push that changes one of its inputs ("Port drift"), and refuses only what the
push adds over its base.
"""
from __future__ import annotations

import argparse
import fnmatch
import re
import subprocess
import sys
import tempfile
from pathlib import Path

BASELINE = "scripts/cmux-next/ffi-caller-baseline.txt"
SCRIPT = "scripts/cmux-next/ffi_caller_ratchet.py"
HEADER_GLOB = "cmux-tui/crates/*/include/*.h"
HEADER_ROOT = "cmux-tui/crates"
SWIFT_ROOT = "Packages"
# Every path this check reads (prepush-gate.py skips it on a push that changes none of them).
INPUTS = (HEADER_ROOT, SWIFT_ROOT, BASELINE, SCRIPT)
BASELINE_HEAD = (
    "# Port-drift ratchet (scripts/cmux-next/ffi_caller_ratchet.py): functions exported in\n"
    "# cmux-tui/crates/*/include/*.h with no caller in Packages/**/*.swift (test targets excluded).\n"
    "# header<TAB>function. This list only shrinks: `--update` removes entries that gained a caller.\n"
    "# Never add a line: a new export ships with its Swift caller.\n"
)

C_BLOCK_COMMENT = re.compile(r"/\*.*?\*/", re.S)
C_LINE_COMMENT = re.compile(r"//[^\n]*")
PREPROCESSOR = re.compile(r"^[ \t]*#(?:[^\n]*\\\n)*[^\n]*", re.M)
EXTERN_C = re.compile(r'extern\s+"C"\s*\{')
DECL_NAME = re.compile(r"([A-Za-z_]\w*)\s*\($")
# A Swift string (kept: a dlsym name is a caller) or a comment (dropped). Strings first, so "https://" is a string.
SWIFT_TOKEN = re.compile(r'"(?:[^"\\\n]|\\.)*"|/\*.*?\*/|//[^\n]*', re.S)


class Tree:
    """The files of the working tree under --repo, or of a commit (--rev) read with git."""

    def __init__(self, repo: Path, rev: str | None):
        self.repo, self.rev = repo, rev

    def git(self, *args: str) -> bytes:
        result = subprocess.run(["git", "-C", str(self.repo), *args], capture_output=True)
        if result.returncode != 0:
            raise SystemExit(f"ffi-caller-ratchet: git {' '.join(args[:3])} failed: "
                             f"{result.stderr.decode(errors='replace').strip()}")
        return result.stdout

    def files(self, prefix: str) -> list[str]:
        if self.rev is None:
            base = self.repo / prefix
            if base.is_file():
                return [prefix]
            return sorted(p.relative_to(self.repo).as_posix() for p in base.rglob("*") if p.is_file())
        out = self.git("ls-tree", "-r", "-z", "--name-only", self.rev, "--", prefix)
        return sorted(name for name in out.decode("utf-8", "surrogateescape").split("\0") if name)

    def read(self, paths: list[str]) -> dict[str, str]:
        """path -> text; a missing path is left out."""
        if self.rev is None:
            texts = {}
            for path in paths:
                file = self.repo / path
                if file.is_file():
                    texts[path] = file.read_text(encoding="utf-8", errors="replace")
            return texts
        if not paths:
            return {}
        # Through a file, never a pipe: a big answer over a pipe can deadlock (arch_counts.py, check-ui-font.py).
        with tempfile.TemporaryFile() as stdin:
            stdin.write("".join(f"{self.rev}:{p}\n" for p in paths).encode())
            stdin.seek(0)
            result = subprocess.run(["git", "-C", str(self.repo), "cat-file", "--batch"], stdin=stdin,
                                    capture_output=True)
        if result.returncode != 0:
            raise SystemExit(f"ffi-caller-ratchet: git cat-file failed: {result.stderr.decode(errors='replace')}")
        out = result.stdout
        texts, pos = {}, 0
        for path in paths:
            end = out.index(b"\n", pos)
            header = out[pos:end].split()
            pos = end + 1
            if len(header) < 3 or header[1] != b"blob":
                continue  # "<rev>:<path> missing"
            size = int(header[2])
            texts[path] = out[pos:pos + size].decode("utf-8", errors="replace")
            pos += size + 1
        return texts


def collapse_braces(text: str) -> str:
    """Drop every {...} body (struct, enum, union): their fields are not exported functions."""
    out, depth = [], 0
    for ch in text:
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth = max(0, depth - 1)
        elif depth == 0:
            out.append(ch)
    return "".join(out)


def header_functions(text: str) -> list[str]:
    """Function names declared at the top level of a C header, in order (typedefs and macros excluded)."""
    text = C_BLOCK_COMMENT.sub(" ", text)
    text = C_LINE_COMMENT.sub(" ", text)
    text = PREPROCESSOR.sub(" ", text)
    if EXTERN_C.search(text):
        # The __cplusplus wrapper: its `{` opens the whole header and its `}` is the last brace.
        text = EXTERN_C.sub(" ", text, count=1)
        last = text.rfind("}")
        text = text[:last] + text[last + 1:]
    text = collapse_braces(text)
    names: list[str] = []
    for stmt in text.split(";"):
        stmt = " ".join(stmt.split())
        if not stmt or stmt.startswith("typedef ") or "(" not in stmt:
            continue
        match = DECL_NAME.search(stmt[: stmt.index("(") + 1])
        if match and match.group(1) not in names:
            names.append(match.group(1))
    return names


def exported(tree: Tree) -> dict[str, str]:
    """function -> repo-relative header path."""
    headers = [p for p in tree.files(HEADER_ROOT) if fnmatch.fnmatchcase(p, HEADER_GLOB) and p.count("/") == 4]
    found: dict[str, str] = {}
    for path, text in sorted(tree.read(headers).items()):
        for name in header_functions(text):
            found.setdefault(name, path)
    return found


def is_test_source(path: str) -> bool:
    return "Tests" in path.split("/")[1:-1] or any(part.endswith("Tests") for part in path.split("/")[1:-1])


def swift_callers(tree: Tree, wanted: set[str]) -> set[str]:
    """The wanted names that appear in a non-test Swift file under Packages/, outside comments."""
    if not wanted:
        return set()
    paths = [p for p in tree.files(SWIFT_ROOT) if p.endswith(".swift") and not is_test_source(p)]
    names = re.compile(r"\b(?:" + "|".join(sorted(map(re.escape, wanted), key=len, reverse=True)) + r")\b")
    seen: set[str] = set()
    for text in tree.read(paths).values():
        if not names.search(text):
            continue
        code = SWIFT_TOKEN.sub(lambda m: m.group(0) if m.group(0).startswith('"') else " ", text)
        seen.update(names.findall(code))
    return seen


def read_baseline(tree: Tree) -> dict[str, str]:
    entries: dict[str, str] = {}
    for line in tree.read([BASELINE]).get(BASELINE, "").splitlines():
        if not line.strip() or line.startswith("#"):
            continue
        header, _, name = line.partition("\t")
        entries[name.strip()] = header.strip()
    return entries


def baseline_text(entries: dict[str, str]) -> str:
    rows = sorted(entries.items(), key=lambda item: (item[1], item[0]))
    return BASELINE_HEAD + "".join(f"{header}\t{name}\n" for name, header in rows)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--rev", help="check this commit (default: the working tree)")
    parser.add_argument("--update", action="store_true", help="drop baseline entries that gained a caller")
    parser.add_argument("--report", action="store_true", help="print called/exported per header")
    parser.add_argument("--inputs", action="store_true", help="print the paths it reads, and stop")
    args = parser.parse_args(argv)
    if args.inputs:
        print("\n".join(INPUTS))
        return 0
    if args.update and args.rev:
        parser.error("--update writes the working tree; it takes no --rev")
    tree = Tree(args.repo.resolve(), args.rev)

    exports = exported(tree)
    called = swift_callers(tree, set(exports))
    uncalled = {name: header for name, header in exports.items() if name not in called}
    baseline = read_baseline(tree)

    if args.report:
        per: dict[str, list[int]] = {}
        for name, header in exports.items():
            row = per.setdefault(header, [0, 0])
            row[0] += name in called
            row[1] += 1
        for header, (hit, total) in sorted(per.items()):
            print(f"{hit:4d} of {total:4d} called  {header}")
        print(f"ffi-caller-ratchet: {len(called)} of {len(exports)} exported functions have a Swift caller;"
              f" {len(uncalled)} have none")

    new = sorted(set(uncalled) - set(baseline), key=lambda n: (uncalled[n], n))
    stale = sorted(set(baseline) - set(uncalled), key=lambda n: (baseline[n], n))

    if args.update:
        for name in new:
            print(f"ffi-caller-ratchet: {name} ({uncalled[name]}) has no Swift caller and is not in the baseline;"
                  f" --update never adds it: give it a Swift caller or drop it from the header", file=sys.stderr)
        kept = {name: header for name, header in baseline.items() if name in uncalled}
        (tree.repo / BASELINE).write_text(baseline_text(kept), encoding="utf-8")
        print(f"ffi-caller-ratchet: baseline {len(baseline)} -> {len(kept)} entries")
        return 1 if new else 0

    for name in new:
        print(f"ffi-caller-ratchet: {name} is exported in {uncalled[name]} and no Swift outside a test target calls"
              f" it (port drift). Fix: call it from the Swift that does this work and delete that Swift (the port's"
              f" step B), or drop it from the header if the app does not need it. Never add it to {BASELINE}.")
    for name in stale:
        why = "now has a Swift caller" if name in exports else "is no longer exported"
        print(f"ffi-caller-ratchet: {name} ({baseline[name]}) {why}, so its baseline line goes."
              f" Fix: python3 {SCRIPT} --update")
    if not new and not stale and not args.report:
        print(f"ffi-caller-ratchet: ok: {len(exports)} exported functions, {len(uncalled)} with no Swift caller,"
              f" all in the baseline")
    return 1 if new or stale else 0


if __name__ == "__main__":
    sys.exit(main())
