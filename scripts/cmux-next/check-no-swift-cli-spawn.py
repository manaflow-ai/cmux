#!/usr/bin/env python3
"""NO-SWIFT-CLI-SPAWN ratchet: Swift in CmuxNext does not run the cmux CLI or other children.

Leo, 2026-11-10, about the Swift spare warm whose stdin write held NIGHTLY's main thread
(NSFileHandle.write <- ProcessRunner.run <- cli.startChatWarmSpare <- CloudSpareWarm.start, on every
app activation): "Why is this even in Swift anyways mang". App logic is Rust or shared web; the app
reaches Rust over the daemon socket (a `DaemonRequest`), never by spawning `cmux` and piping JSON.

Kinds, per file of Packages/macOS/CmuxNext/Sources (comments and strings left out):
  process     a child started from Swift: `ProcessRunner.run(`, `SSHProcessRunner.run(`, a
              `PhoneProcessRunner(`, `ChildProcess(` (a runner's own stdin `PipeFeed` is no spawn of its own);
  cmux-cli    the bundled cmux CLI run from Swift: `CloudMoveCLI(binary:`, `CloudCLICall(`, and the
              CLI wrapper's verbs (`cli.startChat…(`, `cli.seedPush(`, `cli.agentMove(`, …);
  main-actor  any of the above in main-actor code (check-main-actor-work.py's lexical scopes: a
              `uiSwiftSettings` target's default, `@MainActor`, minus `nonisolated`, actors, detached
              tasks), the class that froze NIGHTLY.

scripts/cmux-next/swift-cli-spawn-baseline.tsv holds each file's count per kind and the owner who
moves it to the daemon (cmuxterm-hq's handoff issue). A count above its row, or a hit with no row,
fails: move the work into Rust behind a daemon command instead of raising the row. A count below its
row prints a note to lower it (exit 0), as the other ratchets do, since the pre-push hook judges
against the installed baseline. Children the app hosts by design (the daemon launcher's rows, owner
"keep:") stay; the rest move to a daemon command.

It runs in the local pre-push gate. An error in the guard itself prints a warning and passes (fail
open). Its rules are tested by tests/test_check_no_swift_cli_spawn.py.

Usage: scripts/cmux-next/check-no-swift-cli-spawn.py [repo-root] [--list] [--write-baseline]
  --list            print every hit and exit 0.
  --write-baseline  rewrite the baseline's counts from the tree (keeps owners; new rows get "unowned").
"""

from __future__ import annotations

import importlib.util
import os
import re
import sys

PACKAGE = "Packages/macOS/CmuxNext"
SOURCES = PACKAGE + "/Sources"
BASELINE = "scripts/cmux-next/swift-cli-spawn-baseline.tsv"
HEADER = "# path\tkind\tcount\towner who moves it to a daemon command (check-no-swift-cli-spawn.py; counts only go down)\n"

PROCESS = re.compile(r"\b(?:SSH)?ProcessRunner\s*\.\s*(?:run|start|stream|output)\s*\(|\bPhoneProcessRunner\s*\(|\bChildProcess\s*\(")
CLI_VERBS = (r"startChat\w*|seedPush|bringBackPull|agentMove|machineUpdate|machinePin")
CLI = re.compile(r"\bCloudMoveCLI\s*\(\s*binary:|\bCloudCLICall\s*\(|\bcli\s*\.\s*(?:" + CLI_VERBS + r")\s*\(")
TRIGGERS = ("ProcessRunner", "ChildProcess", "CloudMoveCLI", "CloudCLICall", "cli.")


def _main_actor_module():
    """check-main-actor-work.py by path: its scope rules are this guard's main-actor rule."""
    here = os.path.dirname(os.path.abspath(__file__))
    spec = importlib.util.spec_from_file_location("check_main_actor_work", os.path.join(here, "check-main-actor-work.py"))
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


def scan_text(text: str, default_main: bool, scopes) -> list[tuple[int, str, str]]:
    """(line, kind, source) for every hit in one file's TEXT; main-actor hits add a second row."""
    if not any(trigger in text for trigger in TRIGGERS):
        return []
    lines = text.split("\n")
    main_lines = scopes.main_actor_lines(lines, default_main)
    hits: list[tuple[int, str, str]] = []
    for index, raw in enumerate(lines):
        if scopes.COMMENT_ONLY.match(raw):
            continue
        code = scopes.strip(raw)
        kinds = [kind for kind, rx in (("process", PROCESS), ("cmux-cli", CLI)) if rx.search(code)]
        for kind in kinds:
            hits.append((index + 1, kind, raw.strip()))
        if kinds and main_lines[index]:
            hits.append((index + 1, "main-actor", raw.strip()))
    return hits


def collect(root: str) -> dict[tuple[str, str], list[tuple[int, str]]]:
    scopes = _main_actor_module()
    manifest = open(os.path.join(root, PACKAGE, "Package.swift"), encoding="utf-8").read()
    targets = scopes.package_targets(manifest)
    found: dict[tuple[str, str], list[tuple[int, str]]] = {}
    base = os.path.join(root, SOURCES)
    for folder, dirs, files in os.walk(base):
        dirs[:] = sorted(d for d in dirs if d not in {".build", "Resources"})
        for name in sorted(files):
            if not name.endswith(".swift"):
                continue
            path = os.path.join(folder, name)
            relative = os.path.relpath(path, os.path.join(root, PACKAGE)).replace(os.sep, "/")
            default_main = scopes.default_isolation(relative, targets) is True
            text = open(path, encoding="utf-8", errors="replace").read()
            for line, kind, source in scan_text(text, default_main, scopes):
                key = (os.path.relpath(path, root).replace(os.sep, "/"), kind)
                found.setdefault(key, []).append((line, source))
    return found


def read_baseline(root: str) -> dict[tuple[str, str], tuple[int, str]]:
    rows: dict[tuple[str, str], tuple[int, str]] = {}
    path = os.path.join(root, BASELINE)
    if not os.path.exists(path):
        return rows
    for line in open(path, encoding="utf-8"):
        if not line.strip() or line.startswith("#"):
            continue
        parts = line.rstrip("\n").split("\t")
        if len(parts) >= 3 and parts[2].isdigit():
            rows[(parts[0], parts[1])] = (int(parts[2]), parts[3] if len(parts) > 3 else "unowned")
    return rows


def write_baseline(root: str, found, rows) -> None:
    lines = [HEADER]
    for (path, kind), hits in sorted(found.items()):
        owner = rows.get((path, kind), (0, "unowned"))[1]
        lines.append(f"{path}\t{kind}\t{len(hits)}\t{owner}\n")
    with open(os.path.join(root, BASELINE), "w", encoding="utf-8") as handle:
        handle.writelines(lines)


def judge(found, rows) -> tuple[list[str], list[str]]:
    """(failures, notes)."""
    failures, notes = [], []
    for key, hits in sorted(found.items()):
        allowed = rows.get(key, (0, ""))[0]
        if len(hits) > allowed:
            path, kind = key
            where = ", ".join(str(line) for line, _ in hits)
            failures.append(f"{path}: {len(hits)} {kind} site(s), the baseline allows {allowed} (lines {where})")
    for key, (allowed, _) in sorted(rows.items()):
        now = len(found.get(key, []))
        if now < allowed:
            notes.append(f"{key[0]} {key[1]}: {now} < {allowed}, lower the row")
    return failures, notes


def main(argv: list[str]) -> int:
    args = [a for a in argv if not a.startswith("--")]
    root = args[0] if args else os.getcwd()
    found = collect(root)
    if "--list" in argv:
        for (path, kind), hits in sorted(found.items()):
            for line, source in hits:
                print(f"{path}:{line}\t{kind}\t{source}")
        return 0
    rows = read_baseline(root)
    if "--write-baseline" in argv:
        write_baseline(root, found, rows)
        return 0
    failures, notes = judge(found, rows)
    for note in notes:
        print(f"check-no-swift-cli-spawn: note: {note}")
    if failures:
        print("check-no-swift-cli-spawn: Swift runs a child process or the cmux CLI where the baseline allows none.\n"
              "  Move the logic into Rust behind a daemon command (a DaemonRequest over the socket), as cloud-spare-warm did;\n"
              "  see cmuxterm-hq docs/handbook/swift-spawns-the-cli.md.", file=sys.stderr)
        for failure in failures:
            print(f"  {failure}", file=sys.stderr)
        return 1
    print("check-no-swift-cli-spawn: ok")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except Exception as error:  # fail open: a guard bug must not block every push
        print(f"check-no-swift-cli-spawn: warning: the guard failed ({error}); passing", file=sys.stderr)
        sys.exit(0)
