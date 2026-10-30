#!/usr/bin/env python3
"""Repository scripts never turn a full clone shallow.

`git fetch --depth` (or --deepen, --shallow-since, --shallow-exclude) writes
.git/shallow. CI checkouts are already shallow, so there it only bounds the
download. Run in a developer's full clone, or in any worktree of one, the same
fetch truncates history for every worktree sharing that git directory:
`git merge-base` prints nothing, merges fail with "unrelated histories", and
`git worktree add` from the shared clone breaks. Agents run these scripts in the
shared clones on the team's machines, and those clones kept going shallow.

So a script passes a depth flag to a fetch in a checkout it did not create only
when `git rev-parse --is-shallow-repository` says the checkout is already
shallow (scripts/cmux-next/check-app-ffi-pin.sh has the pattern). This guard
scans tracked scripts for depth-limited fetches with no shallow check before
them in the file. A script that fetches into a repository it just created
belongs in OWN_REPOSITORY with the reason.

Limit: the check is per file. A file that already checks for a shallow
repository can still add a second, unguarded fetch further down.

Usage: python3 tests/test_ci_no_shallow_dev_fetch.py
"""
from __future__ import annotations

import re
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

SCRIPT_SUFFIXES = (".sh", ".bash", ".py", ".ts", ".mts", ".js", ".mjs", ".cjs")
# A depth flag on a fetch line, or on a line continuing a fetch call.
DEPTH = re.compile(r"--(depth|deepen|shallow-since|shallow-exclude)\b|\"--depth\"|'--depth'")
FETCH = re.compile(r"\bfetch\b")
# Lines that make a new repository or a submodule shallow, not the caller's checkout.
NEW_REPOSITORY = re.compile(r"\bclone\b|\bsubmodule\b")
SHALLOW_CHECK = re.compile(r"is-shallow-repository|is_shallow|isShallow|shallow_file")
# Scripts whose depth-limited fetches target a repository the script created
# itself (git init into a temp or cache directory), never the caller's clone.
OWN_REPOSITORY = {
    "backend/packages/cloud-env/src/build-script.ts":
        "the generated script fetches into $HOME/work/<repo> right after its own `git init` there",
    "cmux-tui/build-support/notices/fetch_crates.py": "fetches into a fresh `git init` cache directory",
    "scripts/ci/macos-cross.sh": "fetches into a directory it just ran `git init` in",
    "scripts/cmux-next/base-autofix-changed.sh": "fetches into a scratch `git init --bare` repository it just made",
    "scripts/cmux-next/build-cua-driver-sdk.sh": "fetches into its own `git init` work directory",
    "scripts/cmux-next/generate-third-party-notices.sh": "fetches into fresh `git init` cache directories",
    "scripts/cmux-next/notices/ghosttykit_repin.py": "fetches into a fresh `git init` cache directory",
    "scripts/cmux-next/notices/vt_link_graph.py": "fetches into a fresh `git init` temp directory",
    "scripts/cmux_agent_cursor_vendor.py": "fetches into a fresh `git init` temp directory",
}


def tracked_scripts() -> list[str]:
    names = subprocess.run(["git", "-C", str(ROOT), "ls-files", "-z"], check=True, capture_output=True,
                           text=True).stdout.split("\0")
    return sorted(
        name for name in names
        if name.endswith(SCRIPT_SUFFIXES)
        and not name.startswith((".github/", "tests/", "vendor/", "node_modules/"))
        and "/node_modules/" not in name
        and "/tests/" not in name and "/test/" not in name
        and not re.search(r"(^|/)test_[^/]*\.py$|\.test\.[a-z]+$|_test\.[a-z]+$", name)
    )


def unguarded_depth_fetches(text: str) -> list[int]:
    """1-based line numbers of depth-limited fetches with no shallow check earlier in TEXT."""
    lines = text.splitlines()
    found = []
    guarded = False
    for index, line in enumerate(lines):
        if SHALLOW_CHECK.search(line):
            guarded = True
        if not DEPTH.search(line) or NEW_REPOSITORY.search(line):
            continue
        # A fetch call split over lines keeps its arguments within a few lines of `fetch`.
        window = lines[max(0, index - 3):index + 1]
        if not any(FETCH.search(part) and not NEW_REPOSITORY.search(part) for part in window):
            continue
        stripped = line.lstrip()
        if stripped.startswith(("#", "//", "*")):
            continue
        if not guarded:
            found.append(index + 1)
    return found


def git(*args: str, cwd: Path) -> str:
    return subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@t", "-c", "init.defaultBranch=main",
                           *args], cwd=cwd, check=True, capture_output=True, text=True).stdout.strip()


class NoShallowDevFetchTests(unittest.TestCase):
    def test_every_depth_fetch_checks_for_a_shallow_checkout(self):
        problems = []
        for name in tracked_scripts():
            if name in OWN_REPOSITORY:
                continue
            path = ROOT / name
            try:
                text = path.read_text(encoding="utf-8")
            except (UnicodeDecodeError, FileNotFoundError, IsADirectoryError):
                continue
            problems += [f"{name}:{line}" for line in unguarded_depth_fetches(text)]
        self.assertEqual(problems, [], "depth-limited fetch without an `is-shallow-repository` check; pass "
                         "--depth only when the checkout is already shallow (see this file's docstring)")

    def test_own_repository_entries_are_real_and_still_fetch_with_a_depth(self):
        for name, reason in OWN_REPOSITORY.items():
            path = ROOT / name
            self.assertTrue(path.is_file(), f"{name} is listed but does not exist")
            self.assertTrue(reason.strip(), f"{name} needs a reason")
            self.assertTrue(DEPTH.search(path.read_text(encoding="utf-8")), f"{name} no longer needs an entry")

    def test_the_scan_flags_an_unguarded_fetch_and_passes_a_guarded_one(self):
        self.assertEqual(unguarded_depth_fetches('git fetch --no-tags --depth=1 origin "$sha"\n'), [1])
        self.assertEqual(unguarded_depth_fetches('subprocess.run(["git", "fetch",\n    "--depth=1", "origin"])\n'),
                         [2])
        self.assertEqual(unguarded_depth_fetches('git fetch --quiet --deepen=50 origin\n'), [1])
        guarded = ('[[ "$(git rev-parse --is-shallow-repository)" == true ]] && depth=(--depth=1)\n'
                   'git fetch ${depth[@]+"${depth[@]}"} origin "$sha"\n'
                   'git fetch --deepen=5 origin\n')
        self.assertEqual(unguarded_depth_fetches(guarded), [])
        self.assertEqual(unguarded_depth_fetches('git clone --depth 1 "$url" "$dir"\n'), [])
        self.assertEqual(unguarded_depth_fetches('git submodule update --init --depth 1 ghostty\n'), [])

    def test_fetch_complexity_base_keeps_a_full_clone_full(self):
        script = ROOT / "scripts/ci/fetch-complexity-base.sh"
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            origin = tmp_path / "origin"
            origin.mkdir()
            git("init", "-q", cwd=origin)
            git("config", "uploadpack.allowAnySHA1InWant", "true", cwd=origin)
            for number in range(3):
                (origin / "file").write_text(str(number))
                git("add", "file", cwd=origin)
                git("commit", "-qm", str(number), cwd=origin)
            full = tmp_path / "full"
            git("clone", "-q", origin.as_uri(), str(full), cwd=tmp_path)
            shallow = tmp_path / "shallow"
            git("clone", "-q", "--depth=1", origin.as_uri(), str(shallow), cwd=tmp_path)
            # A commit neither clone has, like a pull request head.
            git("checkout", "-q", "-b", "side", cwd=origin)
            (origin / "file").write_text("side")
            git("commit", "-qam", "side", cwd=origin)
            side = git("rev-parse", "HEAD", cwd=origin)
            git("checkout", "-q", "main", cwd=origin)

            for clone, expected in ((full, "false"), (shallow, "true")):
                subprocess.run(["bash", str(script), side], cwd=clone, check=True, capture_output=True)
                git("cat-file", "-e", f"{side}^{{commit}}", cwd=clone)
                self.assertEqual(git("rev-parse", "--is-shallow-repository", cwd=clone), expected, clone.name)
            self.assertEqual(git("rev-list", "--count", side, cwd=full), "4")


if __name__ == "__main__":
    unittest.main()
