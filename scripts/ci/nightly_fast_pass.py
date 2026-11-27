#!/usr/bin/env python3
"""The nightly-next fast pass: which waiting diffs are a safe fix that starts its build sooner.

Leo, 2026-11-25 (ask-8fd18d379e): "when can we get the next nightly. like just the fast pass way to go".

The rolling rule (nightly_next_rolling.py) spaces nightly-next build starts NIGHTLY_NEXT_CADENCE_MINUTES (20)
apart, so a landing after a quiet spell can wait up to 20 minutes for a free signer slot. That spacing is a
comfort, not a check: it keeps a burst of landings from becoming a burst of builds (Leo, 2026-11-25,
ask-f1544451a4: "at least evenly space them out a bit"). For a safe fix the rule waits FAST_PASS_CADENCE_MINUTES
(5) instead. Every check that protects the build still runs: no start beside a running build (a cancelled
nightly), the signer stagger, the precheck's Release compile verdict, strings, the tree marker, signing,
notarization and the canary.

The risk rule. Everything between nightly-next's head and the tip (every landing the next start would take)
is a safe fix when all of these hold:
- at most MAX_COMMITS commits, MAX_FILES files and MAX_LINES added plus deleted lines;
- no binary file, no submodule move, no symlink, no file mode change (an executable bit);
- no path on the release surface (.github/release-surface.txt: what a signing or publishing job runs or
  reads), none under .github/, and no build or dependency manifest (RISKY_NAMES, RISKY_SUFFIXES).
Anything unreadable (head not in the checkout, a git error) is not a safe fix: the cadence stays.

usage: nightly_fast_pass.py --base SHA --tip SHA   (prints the verdict as JSON; exit 0 either way)
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

HERE = Path(__file__).resolve().parent
RELEASE_SURFACE = HERE.parent.parent / ".github" / "release-surface.txt"

MAX_COMMITS = 3
MAX_FILES = 12
MAX_LINES = 200
FAST_PASS_CADENCE_MINUTES = 5.0

RISKY_PREFIXES = (".github/",)
RISKY_NAMES = frozenset({
    "Package.swift", "Package.resolved", "Cargo.toml", "Cargo.lock", "package.json", "package-lock.json",
    "pnpm-lock.yaml", "yarn.lock", "bun.lock", "bun.lockb", "go.mod", "go.sum", "build.zig", "build.zig.zon",
    ".gitmodules", "Makefile", "project.yml", "Info.plist", "rust-toolchain", "rust-toolchain.toml",
})
RISKY_SUFFIXES = (".entitlements", ".pbxproj", ".xcconfig", ".xcscheme", ".xcworkspacedata", ".plist",
                  ".provisionprofile", ".p12", ".cer")


@dataclass(frozen=True)
class Verdict:
    fast: bool
    reason: str
    commits: int = 0
    files: int = 0
    lines: int = 0

    def as_dict(self) -> dict:
        return {"fast_pass": self.fast, "reason": self.reason, "commits": self.commits, "files": self.files,
                "lines": self.lines}


def surface_patterns(path: Path = RELEASE_SURFACE) -> list[re.Pattern] | None:
    """The release surface's globs (`**` across directories, `*` within one) as regexes, read as
    promote-nightly-next.mjs's globToRegExp reads them (`**/` also matches no directory). None when the
    file cannot be read: then nothing is a fast pass."""
    patterns = []
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError:
        return None
    for line in lines:
        line = line.strip()
        if not line or line.startswith("#") or line.startswith("@"):
            continue
        regex = ""
        index = 0
        while index < len(line):
            if line.startswith("**/", index):
                regex += "(?:.*/)?"
                index += 3
            elif line.startswith("**", index):
                regex += ".*"
                index += 2
            elif line[index] == "*":
                regex += "[^/]*"
                index += 1
            elif line[index] == "?":
                regex += "[^/]"
                index += 1
            else:
                regex += re.escape(line[index])
                index += 1
        patterns.append(re.compile(f"^{regex}$"))
    return patterns


def risky_path(path: str, surface: list[re.Pattern]) -> str:
    """Why `path` is not a safe-fix path, "" when it is."""
    name = path.rsplit("/", 1)[-1]
    if path.startswith(RISKY_PREFIXES):
        return f"{path} is CI configuration"
    if name in RISKY_NAMES or name.endswith(RISKY_SUFFIXES):
        return f"{path} is a build, dependency or signing file"
    if any(pattern.match(path) for pattern in surface):
        return f"{path} is on the release surface"
    return ""


def classify(commits: int, numstat: list[tuple[str, str, str]], raw_modes: list[tuple[str, str, str]],
             surface: list[re.Pattern] | None = None) -> Verdict:
    """numstat: (added, deleted, path) rows of `git diff --numstat` ("-" for a binary file); raw_modes:
    (old mode, new mode, path) rows of `git diff --raw`."""
    surface = surface_patterns() if surface is None else surface
    files = len(numstat)
    lines = sum(int(a) + int(d) for a, d, _ in numstat if a.isdigit() and d.isdigit())
    def verdict(fast: bool, reason: str) -> Verdict:
        return Verdict(fast, reason, commits, files, lines)
    if commits < 1 or files < 1:
        return verdict(False, "nothing waits between nightly-next and the tip")
    if commits > MAX_COMMITS:
        return verdict(False, f"{commits} commits wait (a fast pass is at most {MAX_COMMITS})")
    if files > MAX_FILES:
        return verdict(False, f"{files} files changed (a fast pass is at most {MAX_FILES})")
    if lines > MAX_LINES:
        return verdict(False, f"{lines} lines changed (a fast pass is at most {MAX_LINES})")
    for added, deleted, path in numstat:
        if added == "-" or deleted == "-":
            return verdict(False, f"{path} is binary")
    if surface is None:
        return verdict(False, f"{RELEASE_SURFACE} could not be read; no fast pass")
    for old, new, path in raw_modes:
        if "160000" in (old, new):
            return verdict(False, f"{path} moves a submodule")
        if "120000" in (old, new):
            return verdict(False, f"{path} is a symlink")
        if old != new and "000000" not in (old, new):
            return verdict(False, f"{path} changes its file mode ({old} -> {new})")
    for _, _, path in numstat:
        why = risky_path(path, surface)
        if why:
            return verdict(False, why)
    return verdict(True, f"a safe fix: {commits} commit(s), {files} file(s), {lines} line(s), none on the release "
                         "surface, CI or build files")


def _git(*args: str) -> str:
    return subprocess.run(["git", *args], check=True, capture_output=True, text=True, stdin=subprocess.DEVNULL,
                          timeout=60).stdout


def evaluate(base: str, tip: str, git=_git, surface: list[re.Pattern] | None = None) -> Verdict:
    """The verdict for base..tip from the local checkout; any git failure is not a fast pass."""
    try:
        git("merge-base", "--is-ancestor", base, tip)
        commits = len(git("rev-list", f"{base}..{tip}").split())
        # -z: paths come unquoted (no core.quotePath escaping), so every check sees the real path.
        numstat = []
        for record in git("diff", "--no-renames", "--numstat", "-z", base, tip).split("\0"):
            parts = record.split("\t", 2)
            if len(parts) == 3:
                numstat.append((parts[0], parts[1], parts[2]))
        raw_modes = []
        fields = git("diff", "--no-renames", "--raw", "-z", base, tip).split("\0")
        for meta, path in zip(fields[0::2], fields[1::2]):
            modes = meta.lstrip(":").split()
            if len(modes) >= 2 and path:
                raw_modes.append((modes[0], modes[1], path))
    except (OSError, subprocess.SubprocessError) as error:
        return Verdict(False, f"could not read {base[:12]}..{tip[:12]} here ({type(error).__name__}); no fast pass")
    return classify(commits, numstat, raw_modes, surface)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--base", required=True)
    parser.add_argument("--tip", required=True)
    args = parser.parse_args(argv)
    print(json.dumps(evaluate(args.base, args.tip).as_dict()))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
