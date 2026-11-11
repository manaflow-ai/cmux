#!/usr/bin/env python3
"""SPAWN-OWNER ratchet (cmuxterm-hq#9096, proposal 2): every task and process has an owner.

A task or process nobody owns outlives the thing that started it: a dev Mac collected ~1,900
orphan processes and busy loops that way. The owners are `cmux_scope::Scope` (`scope.spawn`,
`spawn_named`, `spawn_until_cancelled`: its owner's close cancels and joins it) for tasks, and
`cmux_process::Child` for processes (dropped while it runs, it ends its process group and is
reaped, unless `Child::detach(reason)` says why it outlives its handle).

This guard counts, per file of the Rust crates under cmux-tui/crates (product code: no `tests/`,
`benches/`, `examples/`, `*_tests.rs` or `tests.rs` file, no file of a module its parent declares
`#[cfg(test)] mod name;` whatever its name, and nothing after a trailing `#[cfg(test)] mod ... {`),
the lines that start one with no owner:
  - `tokio::spawn(`, `tokio::task::spawn(`, `task::spawn(`;
  - `std::thread::spawn(`, `thread::spawn(`;
  - a bare `spawn(` in a file that imports one of those by name;
  - `.spawn()` (a process) in a file that names std's or tokio's process `Command`.
cmux-process and cmux-scope are the owners themselves and are not counted. A comment is not a
line. A text count, not a type check: fast enough for every push (well under a second). For the
exact list a crate's compiler sees, `--clippy -p CRATE` runs clippy's `disallowed_methods` with
scripts/cmux-next/spawn-owner-clippy/clippy.toml (through CLIPPY_CONF_DIR, so no other build
reads it: a clippy.toml under cmux-tui would turn every nested workspace's `-D warnings` red).

Existing sites are rows of scripts/cmux-next/spawn-owner-baseline.tsv (path, count). A file with
more than its row, or a new file with any, fails, with a `next:` line. A file with fewer prints a
note to lower its row; `--update` lowers it (and deletes a row at 0). Rows are never raised here:
the pre-push gate judges a push against the INSTALLED copy of the baseline, and CI
(`--base-ref REF`) fails a baseline whose row is above the base's or new.

An error in the guard itself prints a warning and passes (fail open), as the other ratchets do.
Its rules are tested by tests/test_spawn_owner_ratchet.py.

Usage: scripts/cmux-next/check-spawn-owner.py [repo-root] [--list] [--update] [--base-ref REF]
       scripts/cmux-next/check-spawn-owner.py [repo-root] --init   (a new baseline only)
       scripts/cmux-next/check-spawn-owner.py [repo-root] --clippy -p CRATE [-p CRATE ...]
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys

CRATES_DIR = "cmux-tui/crates"
OWNERS = {"cmux-process", "cmux-scope"}
SKIP_DIRS = {"target", ".build", "tests", "benches", "examples", "fixtures", "node_modules"}
BASELINE = "scripts/cmux-next/spawn-owner-baseline.tsv"
CLIPPY_CONF = "scripts/cmux-next/spawn-owner-clippy"
NEXT = ("next: spawn the task with its owner's `Scope::spawn` / `spawn_named` / `spawn_until_cancelled` "
        "(cmux-scope; the owner closes it), or start the process with `cmux_process::Command` and keep "
        "its `Child` (it ends with its owner; `Child::detach(reason)` when it must outlive it).")

TASK_SPAWN = re.compile(r"(?<![\w:])(?:tokio::(?:task::)?|task::|(?:std::)?thread::)spawn\s*\(")
SPAWN_IMPORT = re.compile(
    r"\buse\s+(?:tokio::(?:task::)?spawn\b|std::thread::spawn\b|tokio::(?:task::)?\{[^}]*\bspawn\b[^}]*\}"
    r"|std::thread::\{[^}]*\bspawn\b[^}]*\})")
BARE_SPAWN = re.compile(r"(?<![\w:.])spawn\s*\(")
RAW_COMMAND = re.compile(
    r"\b(?:std|tokio)::process::(?:Command\b|\{[^}]*\bCommand\b)|(?<![\w:])process::Command\b")
PROCESS_SPAWN = re.compile(r"\.spawn\(\s*\)")
COMMENT = re.compile(r"^\s*(//|/\*|\*(\s|/|$))")
TEST_TAIL = re.compile(r"^#\[cfg\(test\)\]\s*\n(?:#\[[^\n]*\]\s*\n)*(?:pub(?:\([^)]*\))?\s+)?mod\s+\w+\s*\{",
                       re.MULTILINE)
TRIGGER = b"spawn"
# `#[cfg(test)]` (other attributes may follow it) on an out-of-line `mod name;`: that file is test code.
TEST_MODULE = re.compile(r"^[ \t]*#\[cfg\(test\)\]\s*(?:#\[[^\n]*\]\s*)*(?:pub(?:\([^)]*\))?\s+)?mod\s+(\w+)\s*;",
                         re.MULTILINE)
TEST_TRIGGER = b"cfg(test)"


def product_text(text: str) -> str:
    """The file up to a trailing `#[cfg(test)] mod ... {` (a test module at the end of the file)."""
    match = TEST_TAIL.search(text)
    return text[: match.start()] if match else text


def matching_lines(text: str) -> list[tuple[int, str]]:
    text = product_text(text)
    patterns = [TASK_SPAWN]
    if SPAWN_IMPORT.search(text):
        patterns.append(BARE_SPAWN)
    if RAW_COMMAND.search(text):
        patterns.append(PROCESS_SPAWN)
    found = []
    for number, line in enumerate(text.split("\n"), 1):
        if COMMENT.match(line) or "spawn" not in line:
            continue
        code = line.split("//", 1)[0]
        if any(p.search(code) for p in patterns):
            found.append((number, line.rstrip()))
    return found


def test_module_paths(path: str, text: str) -> list[str]:
    """The files of the modules PATH declares under `#[cfg(test)]` (`#[cfg(test)] mod name;`): test
    code whatever the file is called, e.g. hub/mod.rs's `#[cfg(test)] mod remote_table_bench;`.
    Each is NAME.rs, or the folder NAME (its mod.rs and everything under it)."""
    folder, name = os.path.split(path)
    if name not in ("mod.rs", "lib.rs", "main.rs"):
        folder = os.path.join(folder, name[: -len(".rs")])
    paths = []
    for module in TEST_MODULE.findall(text):
        paths += [os.path.join(folder, module + ".rs"), os.path.join(folder, module) + os.sep]
    return paths


def scan(root: str) -> dict[str, list[tuple[int, str]]]:
    hits: dict[str, list[tuple[int, str]]] = {}
    base = os.path.join(root, CRATES_DIR)
    if not os.path.isdir(base):
        return hits
    for crate in sorted(os.listdir(base)):
        if crate in OWNERS:
            continue
        top = os.path.join(base, crate)
        texts: dict[str, bytes] = {}
        test_only: list[str] = []
        for dirpath, dirnames, filenames in os.walk(top):
            dirnames[:] = sorted(d for d in dirnames if d not in SKIP_DIRS and not d.startswith("."))
            for name in sorted(filenames):
                if not name.endswith(".rs") or name == "tests.rs" or name.endswith(("_tests.rs", "_test.rs")):
                    continue
                path = os.path.join(dirpath, name)
                try:
                    with open(path, "rb") as f:
                        raw = f.read()
                except OSError:
                    continue
                if TEST_TRIGGER in raw:
                    test_only += test_module_paths(path, raw.decode("utf-8", errors="replace"))
                if TRIGGER in raw:
                    texts[path] = raw
        for path, raw in texts.items():
            if path in test_only or any(p.endswith(os.sep) and path.startswith(p) for p in test_only):
                continue
            found = matching_lines(raw.decode("utf-8", errors="replace"))
            if found:
                hits[os.path.relpath(path, root).replace(os.sep, "/")] = found
    return dict(sorted(hits.items()))


def parse_baseline(text: str) -> dict[str, int]:
    rows: dict[str, int] = {}
    for line in text.splitlines():
        if not line or line.startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) < 2 or not parts[1].isdigit():
            print(f"check-spawn-owner: bad baseline row: {line!r}", file=sys.stderr)
            sys.exit(2)
        rows[parts[0]] = int(parts[1])
    return rows


HEADER = ("# path\tlines that spawn a task or process with no owner (check-spawn-owner.py; rows only go down:\n"
          "# move a site to Scope::spawn or cmux_process::Child, then lower its row with --update)\n")


def write_baseline(root: str, rows: dict[str, int]) -> None:
    with open(os.path.join(root, BASELINE), "w", encoding="utf-8") as f:
        f.write(HEADER)
        for path, count in sorted(rows.items()):
            if count > 0:
                f.write(f"{path}\t{count}\n")


def read_baseline(root: str) -> dict[str, int]:
    path = os.path.join(root, BASELINE)
    if not os.path.exists(path):
        return {}
    with open(path, encoding="utf-8") as f:
        return parse_baseline(f.read())


def base_baseline(root: str, ref: str) -> dict[str, int] | None:
    shown = subprocess.run(["git", "-C", root, "show", f"{ref}:{BASELINE}"], capture_output=True, text=True)
    return parse_baseline(shown.stdout) if shown.returncode == 0 else None


def judge_against_base(rows: dict[str, int], base: dict[str, int] | None, ref: str) -> int:
    """1 when the baseline has a row above the base's copy, or one the base had not (a new file's
    debt): the baseline only goes down. A base with no baseline file judges nothing."""
    if base is None:
        print(f"check-spawn-owner: {ref} has no {BASELINE}; the baseline is not judged against it")
        return 0
    status = 0
    for path, count in sorted(rows.items()):
        if count > base.get(path, 0):
            status = 1
            print(f"check-spawn-owner: {BASELINE} raises {path} to {count} (base {ref}: {base.get(path, 0)}). "
                  "The baseline only goes down.", file=sys.stderr)
    if status:
        print(NEXT, file=sys.stderr)
    return status


def clippy(root: str, crates: list[str]) -> int:
    """Clippy's own `disallowed_methods` findings for CRATES, counted per file beside the baseline."""
    env = dict(os.environ, CLIPPY_CONF_DIR=os.path.join(root, CLIPPY_CONF))
    args = ["cargo", "clippy", "--message-format=json", "--quiet"]
    for crate in crates:
        args += ["-p", crate]
    args += ["--", "-A", "clippy::all", "-W", "clippy::disallowed_methods"]
    out = subprocess.run(args, cwd=os.path.join(root, "cmux-tui"), env=env, capture_output=True, text=True)
    counts: dict[str, set[int]] = {}
    for line in out.stdout.splitlines():
        try:
            message = json.loads(line).get("message") or {}
        except json.JSONDecodeError:
            continue
        if (message.get("code") or {}).get("code") != "clippy::disallowed_methods":
            continue
        for span in message.get("spans", []):
            if span.get("is_primary"):
                path = os.path.normpath(os.path.join("cmux-tui", span["file_name"])).replace(os.sep, "/")
                counts.setdefault(path, set()).add(span["line_start"])
    baseline = read_baseline(root)
    for path, lines in sorted(counts.items()):
        print(f"{path}\tclippy {len(lines)}\tbaseline {baseline.get(path, 0)}")
    print(f"check-spawn-owner: clippy found {sum(len(v) for v in counts.values())} line(s) in {len(counts)} file(s)"
          f" (cargo exit {out.returncode})")
    return 0 if out.returncode == 0 else 2


def main(argv: list[str]) -> int:
    flags = {"--list", "--update", "--init"}
    args, base_ref, crates, use_clippy = [], None, [], False
    it = iter(argv)
    for a in it:
        if a == "--base-ref":
            base_ref = next(it)
        elif a == "-p":
            crates.append(next(it))
        elif a == "--clippy":
            use_clippy = True
        elif a not in flags:
            args.append(a)
    root = os.path.abspath(args[0]) if args else os.getcwd()
    if use_clippy:
        return clippy(root, crates)
    hits = scan(root)
    if "--list" in argv:
        for rel, found in sorted(hits.items()):
            for number, line in found:
                print(f"{rel}:{number}: {line.strip()}")
        return 0
    if "--init" in argv:
        # Only where there is no baseline yet: an existing one only goes down.
        if os.path.exists(os.path.join(root, BASELINE)):
            print(f"check-spawn-owner: {BASELINE} exists; --init writes a new one only", file=sys.stderr)
            return 2
        write_baseline(root, {rel: len(found) for rel, found in hits.items()})
        print(f"check-spawn-owner: wrote {BASELINE}: {sum(len(v) for v in hits.values())} line(s) in {len(hits)} file(s)")
        return 0
    baseline = read_baseline(root)
    status = 0
    for rel, found in sorted(hits.items()):
        allowed = baseline.get(rel, 0)
        if len(found) > allowed:
            status = 1
            what = "a new file" if rel not in baseline else f"baseline {allowed}"
            print(f"check-spawn-owner: {rel} has {len(found)} spawn line(s) with no owner ({what}).", file=sys.stderr)
            for number, line in found:
                print(f"  {rel}:{number}: {line.strip()}", file=sys.stderr)
    if status:
        print(NEXT, file=sys.stderr)
    lowered = {}
    for rel, allowed in sorted(baseline.items()):
        count = len(hits.get(rel, []))
        if count < allowed:
            lowered[rel] = count
            if "--update" not in argv:
                print(f"check-spawn-owner: {rel} now has {count} spawn line(s) with no owner, baseline {allowed}. "
                      f"Lower its row: scripts/cmux-next/check-spawn-owner.py --update", file=sys.stderr)
    if "--update" in argv and lowered:
        write_baseline(root, {**baseline, **lowered})
        for rel, count in lowered.items():
            print(f"check-spawn-owner: lowered {rel} {baseline[rel]} -> {count}")
    if base_ref:
        status |= judge_against_base(read_baseline(root), base_baseline(root, base_ref), base_ref)
    if status == 0:
        total = sum(min(len(v), baseline.get(k, 0)) for k, v in hits.items())
        print(f"check-spawn-owner: ok ({total} baselined line(s) in {len(hits)} file(s))")
    return status


def guarded_main(argv: list[str]) -> int:
    """`main`, failing open on a bug in the guard (not on a finding)."""
    try:
        return main(argv)
    except SystemExit:
        raise
    except Exception as error:  # noqa: BLE001 - fail open on any guard bug
        print(f"check-spawn-owner: WARNING: the guard failed ({type(error).__name__}: {error}); not applied.",
              file=sys.stderr)
        return 0


if __name__ == "__main__":
    sys.exit(guarded_main(sys.argv[1:]))
