#!/usr/bin/env python3
"""The MessagesLab Swift 6 queue (p10-stability-038): concurrency diagnostics per folder under complete checking.

Usage (a build runs only as a fleet step; see messageslab-queue.sh):
  cmux-ci run --class isolated --ref SHA --script scripts/cmux-next/messageslab-queue.sh -- --ref SHA
  messageslab-queue.sh --from-jsonl FILE      # any host: re-count a saved diagnostics.jsonl

The build is swift_diagnostics.py's clean build (p10-stability-036) with two extra build flags:
`-Xswiftc -strict-concurrency=complete` and `--build-tests`. Complete checking is a flag of this one build, not a
Package.swift setting, so the app build and its Swift warning budget (.github/swift-warning-budget.tsv) never see
these warnings; the targets keep `.swiftLanguageMode(.v5)` until 039 and 045 request `.v6`.

A row counts when it is a concurrency diagnostic: an error, a row in one of CONCURRENCY_GROUPS, or a warning that
Swift 6 mode makes an error (the compiler's "this is an error in the Swift 6 language mode" suffix; some, such as a
non-Sendable stored property of a Sendable type, have no group). Deprecations and unused values do not count.
Rows outside the package (its dependencies, built with the same flag) do not count.

Exit status: 0 the package compiles; 1 it does not (the table is still printed); 2 bad arguments or a host that may
not build; 3 no verdict (swift_diagnostics.py missing, no toolchain, no diagnostics).
"""

from __future__ import annotations

import argparse
import fnmatch
import importlib.util
import json
import subprocess
import sys
from collections import Counter
from pathlib import Path
from typing import Iterable, Mapping

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
PACKAGE = "Packages/Shared/CmuxMessagesLab"
DEFAULT_OUT = Path(".build/messageslab-queue/diagnostics.jsonl")
SPLIT_ABOVE = 400
SWIFT6_ERROR = "this is an error in the Swift 6 language mode"
COMPLETE_CHECKING = ("-Xswiftc", "-strict-concurrency=complete", "--build-tests")
# The concurrency groups of the Swift 6.2/6.3 diagnostics docs (usr/share/doc/swift/diagnostics).
CONCURRENCY_GROUPS = frozenset({
    "ActorIsolatedCall", "ConformanceIsolation", "IsolatedConformances", "MutableGlobalVariable",
    "PreconcurrencyImport", "SendableClosureCaptures", "SendableMetatypes", "SendingClosureRisksDataRace",
    "SendingRisksDataRace", "NonisolatedNonsendingByDefault",
})
# (folder glob under the package, queue task). The first match wins; stability-DESIGN.md section 6 Q01.
FOLDERS = (
    ("Sources/MessagesLabHome/Vendor/catalyst/[A-L]*", "040"),
    ("Sources/MessagesLabHome/Vendor/catalyst/[M-Z]*", "041"),
    ("Sources/MessagesLabHome/Vendor/appkit-native/*", "042"),
    ("Sources/MessagesLabHome/Vendor/appkit-port/*", "042"),
    ("Sources/MessagesLabHome/Cmux/[A-L]*", "043"),
    ("Sources/MessagesLabHome/Cmux/[M-Z]*", "044"),
    ("Sources/MessagesLabSidebar/*", "039"),
    ("Tests/MessagesLabHomeTests/*", "045"),
    ("Tests/MessagesLabSidebarTests/*", "039"),
)
OTHER = "(other files in the package)"


def is_concurrency(row: Mapping) -> bool:
    if row.get("severity") in ("error", "fatal"):
        return True
    return row.get("group") in CONCURRENCY_GROUPS or SWIFT6_ERROR in row.get("message", "")


def folder_of(file: str, package_dir: Path) -> str | None:
    """The FOLDERS glob of a diagnostic's file, OTHER for another file of the package, None outside it."""
    path = Path(file)
    if not path.is_absolute():
        path = package_dir / path
    try:
        relative = path.resolve().relative_to(package_dir.resolve()).as_posix()
    except ValueError:
        return None
    return next((glob for glob, _ in FOLDERS if fnmatch.fnmatchcase(relative, glob)), OTHER)


def count(rows: Iterable[Mapping], package_dir: Path) -> tuple[Counter, int]:
    """Concurrency diagnostics per folder, and how many were outside the package."""
    per_folder: Counter = Counter()
    outside = 0
    for row in rows:
        if not is_concurrency(row):
            continue
        folder = folder_of(row.get("file", ""), package_dir)
        if folder is None:
            outside += 1
        else:
            per_folder[folder] += 1
    return per_folder, outside


def table(per_folder: Mapping[str, int]) -> list[str]:
    lines = ["| Folder (under CmuxMessagesLab/) | Task | Concurrency diagnostics |", "| --- | --- | ---: |"]
    for glob, task in FOLDERS:
        n = per_folder.get(glob, 0)
        lines.append(f"| {glob.removesuffix('/*')} | {task} | {n:,}{' (split)' if n > SPLIT_ABOVE else ''} |")
    if per_folder.get(OTHER):
        lines.append(f"| {OTHER} | - | {per_folder[OTHER]:,} |")
    return lines


def read_jsonl(path: Path) -> list[dict]:
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


def load_swift_diagnostics(scripts: Path = HERE):
    path = scripts / "swift_diagnostics.py"
    if not path.is_file():
        return None
    spec = importlib.util.spec_from_file_location("swift_diagnostics", path)
    module = importlib.util.module_from_spec(spec)
    sys.modules["swift_diagnostics"] = module
    spec.loader.exec_module(module)
    return module


def complete_checking_build(package_dir: Path, scratch: Path, configuration: str, env: Mapping[str, str],
                            log: Path) -> int:
    """swift_diagnostics.run_build's command plus COMPLETE_CHECKING."""
    command = ["xcrun", "--sdk", "macosx", "swift", "build", "--package-path", str(package_dir),
               "--scratch-path", str(scratch), "-c", configuration, "-Xswiftc", "-print-diagnostic-groups",
               *COMPLETE_CHECKING]
    print(f"messageslab-queue: {' '.join(command)}", flush=True)
    with log.open("w", encoding="utf-8") as handle:
        return subprocess.run(command, env=dict(env), stdout=handle, stderr=subprocess.STDOUT,
                              stdin=subprocess.DEVNULL).returncode


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--from-jsonl", type=Path, help="count this diagnostics.jsonl, no build")
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT, help="diagnostics JSONL (default %(default)s)")
    parser.add_argument("--ref", default="", help="refuse unless the checkout is this commit")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None, root: Path = ROOT, scripts: Path = HERE, **diagnostics_seams) -> int:
    try:
        args = parse_args(list(sys.argv[1:] if argv is None else argv))
    except SystemExit as error:
        return 2 if error.code else 0
    package_dir = root / PACKAGE
    status = 0
    if args.from_jsonl:
        source = args.from_jsonl
    else:
        diagnostics = load_swift_diagnostics(scripts)
        if diagnostics is None:
            print("messageslab-queue: no verdict: scripts/cmux-next/swift_diagnostics.py (p10-stability-036) is "
                  "not on this commit", file=sys.stderr)
            return 3
        source = args.out if args.out.is_absolute() else root / args.out
        forwarded = ["--package", PACKAGE, "--out", str(source)] + (["--ref", args.ref] if args.ref else [])
        status = diagnostics.main(forwarded, build=complete_checking_build, root=root, **diagnostics_seams)
        if status not in (0, 1):
            return status
    per_folder, outside = count(read_jsonl(source), package_dir)
    print("\n".join(table(per_folder)))
    print(f"messageslab-queue: {sum(per_folder.values()):,} concurrency diagnostic(s) in {PACKAGE}, {outside:,} in "
          f"its dependencies (not counted); {'compiles' if status == 0 else 'DOES NOT COMPILE'}")
    return status


if __name__ == "__main__":
    sys.exit(main())
