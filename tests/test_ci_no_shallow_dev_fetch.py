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

Tests get the same rule for the checkout they run in, and one more. Under car
guards every test shares the job's checkout: full history, blob-less
(actions/checkout's filter: blob:none). test_ci_owned_pool_sources.py's
`git fetch --depth=1` there wrote .git/shallow, and
test_cmux_next_guards_notices_pair.py's `git clone --shared` of the checkout,
running beside it, then died: clone ignores --shared and --local for a shallow
source and packs through upload-pack, which may not fetch the blobs the source
never had ("could not fetch ... from promisor remote", cmux#40871). So a test
file that runs git in the repository root (`-C ROOT`, `cwd=ROOT`, `-C "$ROOT"`)
fetches with a depth flag only behind a shallow check, and no test clones the
repository root with --shared, --reference, --local or -s: it clones over
file:// (depth 1, blob-less: see the notices-pair test) or builds a fixture.
A file the first scan misreads goes in TESTS_NOT_IN_THE_CHECKOUT with the reason.

Usage: python3 tests/test_ci_no_shallow_dev_fetch.py
"""
from __future__ import annotations

import re
import subprocess
import tempfile
import unittest
from pathlib import Path
# tests/git_fixture_env.py, loaded by path: `python3 -I` puts no script folder on sys.path.
import importlib.util as _git_fixture_importlib  # noqa: E402
from os import path as _git_fixture_path  # noqa: E402
_git_fixture_spec = _git_fixture_importlib.spec_from_file_location(
    "git_fixture_env", _git_fixture_path.join(_git_fixture_path.dirname(_git_fixture_path.abspath(__file__)), "git_fixture_env.py"))
git_fixture_env = _git_fixture_importlib.module_from_spec(_git_fixture_spec)
_git_fixture_spec.loader.exec_module(git_fixture_env)

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
    "cmux-tui/build-support/notices/fetch_crates.py": "fetches into a fresh `git init` cache directory",
    "scripts/ci/macos-cross.sh": "fetches into a directory it just ran `git init` in",
    "images/cmux-vm/image-roll-record.sh": "fetches only into its own `git init` temp directory of the record branch",
    "scripts/pr-media.py": "fetches only into its own `git init --bare` cache clone of the media branch",
    "scripts/cmux-next/base-autofix-changed.sh": "fetches into a scratch `git init --bare` repository it just made",
    "scripts/cmux-next/base_autofix_pushed_exports.py":
        "remote_history fetches into a scratch `git init --bare` repository it just made, then deletes it",
    "scripts/cmux-next/build-cua-driver-sdk.sh": "fetches into its own `git init` work directory",
    "scripts/cmux-next/generate-third-party-notices.sh": "fetches into fresh `git init` cache directories",
    "scripts/cmux-next/notices/ghosttykit_repin.py": "fetches into a fresh `git init` cache directory",
    "scripts/cmux-next/notices/vt_link_graph.py": "fetches into a fresh `git init` temp directory",
    "scripts/cmux_agent_cursor_vendor.py": "fetches into a fresh `git init` temp directory",
    "scripts/ci/swiftpm_prefetch_binary_artifacts.py": "fetches each dependency pin into its own temporary `git init` directory",
    "scripts/ci/base_red_excuse.py": "git_text fetches only into its own `git init --bare` cache repository under source_cache(), never the caller's clone",
    "scripts/measure/agent-loop.sh": "fetch_tree fetches into $tree right after its own `git init` there",
    "webviews/src/agent-session/acpmux/session-info/commandRules.ts":
        "runs no git: it names a shown command line in words, and lists `git clone`'s --depth as a flag to skip",
}


# Test files whose depth flags never reach a fetch in the repository root.
TESTS_NOT_IN_THE_CHECKOUT = {
    "tests/test_ci_test_execution_registry.py": "the depth fetch is workflow text it asserts on, never run",
    "tests/test_cmux_next_fast_gates.py": "its depth fetches and clones run in its own fixture repositories",
}
# Git run in the repository root: `-C ROOT`, `cwd=ROOT`, `-C "$ROOT"` and the like.
IN_ROOT = re.compile(r"""-C["']?,?\s*(str\()?\s*["']?\$?\{?(ROOT|REPO_ROOT|repo_root)\b|cwd=(str\()?(ROOT|REPO_ROOT)\b""")
# A clone that borrows its source's object store, or copies it as a local clone.
BORROWING_CLONE = re.compile(r"""\bclone\b.*(--shared|--reference|--local|["']-s["']|\s-s\s)""")
ROOT_NAME = re.compile(r"\b(ROOT|REPO_ROOT|repo_root)\b")


def tracked_test_files() -> list[str]:
    names = subprocess.run(["git", "-C", str(ROOT), "ls-files", "-z"], check=True, capture_output=True,
                           text=True).stdout.split("\0")
    return sorted(
        name for name in names
        if name.endswith((".py", ".sh", ".bash"))
        and not name.startswith(("vendor/", "node_modules/")) and "/node_modules/" not in name
        and re.search(r"(^|/)tests?/|(^|/)test_[^/]*\.py$|\.test\.[a-z]+$|_test\.[a-z]+$", name)
    )


def root_depth_fetches(text: str) -> list[int]:
    """Unguarded depth-limited fetches in a test file that also runs git in the repository root."""
    return unguarded_depth_fetches(text) if IN_ROOT.search(text) else []


def borrowing_root_clones(text: str) -> list[int]:
    """1-based lines that clone the repository root with --shared, --reference, --local or -s."""
    return [index for index, line in enumerate(text.splitlines(), 1)
            if BORROWING_CLONE.search(line) and ROOT_NAME.search(line)
            and not line.lstrip().startswith(("#", "//", "*"))]


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


class TestsLeaveTheJobCheckoutAlone(unittest.TestCase):
    """cmux#40871: one test made car guards' checkout shallow, and another's --shared clone of it died."""

    def scan(self, finder) -> list[str]:
        problems = []
        for name in tracked_test_files():
            if name in TESTS_NOT_IN_THE_CHECKOUT or name == "tests/test_ci_no_shallow_dev_fetch.py":
                continue
            try:
                text = (ROOT / name).read_text(encoding="utf-8")
            except (UnicodeDecodeError, FileNotFoundError, IsADirectoryError):
                continue
            problems += [f"{name}:{line}" for line in finder(text)]
        return problems

    def test_no_test_makes_the_repository_root_shallow(self):
        self.assertEqual(self.scan(root_depth_fetches), [],
                         "a test that runs git in the repository root fetches with a depth flag and no "
                         "`is-shallow-repository` check: under car guards that makes the job's checkout "
                         "shallow for every test beside it (see this file's docstring)")

    def test_no_test_borrows_the_repository_roots_objects(self):
        self.assertEqual(self.scan(borrowing_root_clones), [],
                         "a test clones the repository root with --shared/--reference/--local/-s: under car "
                         "guards that is the job's blob-less checkout, and the clone dies once it is shallow; "
                         "clone it over file:// at depth 1 with --filter=blob:none instead "
                         "(tests/test_cmux_next_guards_notices_pair.py)")

    def test_allowlisted_files_exist_and_still_need_it(self):
        for name, reason in TESTS_NOT_IN_THE_CHECKOUT.items():
            path = ROOT / name
            self.assertTrue(path.is_file(), f"{name} is listed but does not exist")
            self.assertTrue(reason.strip(), f"{name} needs a reason")
            self.assertTrue(root_depth_fetches(path.read_text(encoding="utf-8")), f"{name} no longer needs an entry")

    def test_the_scans_flag_cmux_40871s_two_lines(self):
        # test_ci_owned_pool_sources.py and test_cmux_next_guards_notices_pair.py as they were at 8349c18e.
        owned_pool = ('def git(*args):\n    return subprocess.run(["git", "-C", str(ROOT), *args])\n'
                      'git("fetch", "--no-tags", "--depth=1", "--filter=blob:none", "origin", ref)\n')
        self.assertEqual(root_depth_fetches(owned_pool), [3])
        self.assertEqual(root_depth_fetches(owned_pool.replace(
            'git("fetch"', 'shallow = git("rev-parse", "--is-shallow-repository")\ngit("fetch"')), [])
        self.assertEqual(root_depth_fetches('git("fetch", "--depth=1", "origin")  # in a fixture repo\n'), [])
        notices = 'subprocess.run(["git", "clone", "-q", "--shared", "--no-checkout", str(ROOT), str(path)])\n'
        self.assertEqual(borrowing_root_clones(notices), [1])
        self.assertEqual(borrowing_root_clones('git clone -q --reference "$ROOT" "$url" "$dir"\n'), [1])
        self.assertEqual(borrowing_root_clones(
            'clone_repo(ROOT.as_uri(), path, "--depth=1", "--filter=blob:none")\n'), [])
        self.assertEqual(borrowing_root_clones('git clone -q --shared app mid\n'), [])


if __name__ == "__main__":
    unittest.main()
