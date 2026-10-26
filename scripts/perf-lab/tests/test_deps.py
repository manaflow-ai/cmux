#!/usr/bin/env python3
"""deps.py: a culprit that only rolls ghostty, ghostty-next or the CEF pin becomes a nested bisect.

  python3 -m unittest scripts/perf-lab/tests/test_deps.py

The fixtures are real git repositories in a temporary directory: a dependency repository with its own
commits, and a cmux repository whose gitlinks and cef-manifest.json point into it.
"""
from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

LAB = Path(__file__).resolve().parent.parent


def _load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


deps = _load("perf_lab_deps", LAB / "deps.py")

GIT_ENV = {
    **os.environ,
    "GIT_CONFIG_NOSYSTEM": "1",
    "GIT_CONFIG_GLOBAL": os.devnull,
    "GIT_AUTHOR_NAME": "lab",
    "GIT_AUTHOR_EMAIL": "lab@example.invalid",
    "GIT_COMMITTER_NAME": "lab",
    "GIT_COMMITTER_EMAIL": "lab@example.invalid",
    "GIT_AUTHOR_DATE": "2026-10-26T00:00:00Z",
    "GIT_COMMITTER_DATE": "2026-10-26T00:00:00Z",
}
MANIFEST = "scripts/cmux-next/cef-manifest.json"
PACKAGE = "Packages/Shared/CmuxGhosttyKit/Package.swift"


def git(repo: Path, *args: str) -> str:
    proc = subprocess.run(["git", "-C", str(repo), *args], env=GIT_ENV, capture_output=True, text=True, check=True)
    return proc.stdout.strip()


class Repo:
    def __init__(self, path: Path) -> None:
        self.path = path
        path.mkdir(parents=True)
        git(path, "init", "-q", "-b", "main")

    def write(self, rel: str, text: str) -> None:
        target = self.path / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text)
        git(self.path, "add", "--", rel)

    def gitlink(self, rel: str, sha: str) -> None:
        git(self.path, "update-index", "--add", "--cacheinfo", f"160000,{sha},{rel}")

    def drop(self, rel: str) -> None:
        git(self.path, "rm", "-q", "--cached", "--", rel)

    def manifest(self, fork_ref: str, version: str) -> None:
        self.write(MANIFEST, json.dumps({"version": version, "fork_ref": fork_ref}, indent=2) + "\n")

    def commit(self, message: str) -> str:
        git(self.path, "commit", "-q", "--allow-empty", "-m", message)
        return git(self.path, "rev-parse", "HEAD")

    def dep_commits(self, count: int, prefix: str = "c") -> list[str]:
        shas = []
        for i in range(count):
            self.write("src/file.txt", f"{prefix}{i}\n")
            shas.append(self.commit(f"{prefix}{i}"))
        return shas

    @property
    def git(self):
        return deps.GitRepo(str(self.path))


class Fixture(unittest.TestCase):
    def setUp(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.next = Repo(self.root / "ghostty-next")
        self.next_shas = self.next.dep_commits(9)  # [0] is pinned, then 8 upstream commits
        self.classic = Repo(self.root / "ghostty")
        self.classic_shas = self.classic.dep_commits(4, "g")
        self.cef = Repo(self.root / "cef")
        self.cef_shas = self.cef.dep_commits(5, "f")
        for sha, tag in ((self.cef_shas[0], "cef-154.0.28-cmux.20"), (self.cef_shas[2], "cef-154.0.28-cmux.21"),
                         (self.cef_shas[4], "cef-154.0.28-cmux.22")):
            git(self.cef.path, "tag", tag, sha)
        git(self.cef.path, "tag", "unrelated-tag", self.cef_shas[3])
        self.cmux = Repo(self.root / "cmux")
        self.cmux.write("Sources/App.swift", "app\n")
        self.cmux.write(PACKAGE, "pin a\n")
        self.cmux.gitlink("ghostty-next", self.next_shas[0])
        self.cmux.gitlink("ghostty", self.classic_shas[0])
        self.cmux.manifest(self.cef_shas[0], "cef-154.0.28-cmux.20")
        self.base = self.cmux.commit("base")
        self.repos = {"ghostty-next": self.next.git, "ghostty": self.classic.git, "cef": self.cef.git}

    def expand(self, good: str, bad: str, repos=None):
        return deps.expand(good, bad, self.cmux.git, self.repos if repos is None else repos)


class SubmoduleRollTest(Fixture):
    def bump(self) -> str:
        self.cmux.gitlink("ghostty-next", self.next_shas[8])
        self.cmux.write(PACKAGE, "pin b\n")
        return self.cmux.commit("ghostty-next: bump")

    def test_bump_with_8_upstream_commits_expands_to_a_nested_bisect(self) -> None:
        bump = self.bump()
        decision = self.expand(self.base, bump)
        self.assertIsNotNone(decision.expansion, decision.reason)
        expansion = decision.expansion
        self.assertTrue(decision.reason.startswith("roll: ghostty-next"), decision.reason)
        (roll,) = expansion.rolls
        self.assertEqual((roll.dep, roll.old, roll.new), ("ghostty-next", self.next_shas[0], self.next_shas[8]))
        self.assertEqual(roll.commits, tuple(self.next_shas[1:]))
        self.assertEqual(len(expansion.changes), 9)
        self.assertEqual([c.sha for c in expansion.changes], [self.base] * 9)
        self.assertEqual([c.dep("ghostty-next") for c in expansion.changes], self.next_shas)
        self.assertEqual(expansion.unbuildable, frozenset())

    def test_nested_bisect_finds_the_upstream_commit(self) -> None:
        expansion = self.expand(self.base, self.bump()).expansion
        regressed_at = self.next_shas[5]

        def slow(change) -> bool:  # the fake measurement: commit 5 and later are slow
            return self.next_shas.index(change.dep("ghostty-next")) >= self.next_shas.index(regressed_at)

        good, bad = expansion.changes[0], expansion.changes[-1]
        visited = []
        while (mid := expansion.midpoint(good, bad)) is not None:
            visited.append(mid)
            good, bad = (good, mid) if slow(mid) else (mid, bad)
        self.assertEqual(expansion.culprit(good, bad), ("ghostty-next", regressed_at))
        self.assertLessEqual(len(visited), 4)  # ceil(log2(8)) + 1

    def test_nested_changes_build_with_the_dependency_override(self) -> None:
        expansion = self.expand(self.base, self.bump()).expansion
        change = expansion.changes[3]
        self.assertEqual(change.build_key, f"{self.base}+ghostty-next={self.next_shas[3]}")
        self.assertEqual(change.build_args("bench"),
                         [f"--build-sha={self.base}", f"--dep=ghostty-next={self.next_shas[3]}", "--config=bench"])
        self.assertEqual(deps.Change(self.base).build_key, self.base)

    def test_nested_job_keeps_the_parent_story_and_class(self) -> None:
        expansion = self.expand(self.base, self.bump()).expansion
        parent = {"kind": "bisect", "mode": "performance", "story": "terminal.key_to_frame", "metric": "p95_ms",
                  "host_class": "apple-m4/16gb/120hz", "magnitude": 2.5, "good": "x", "bad": "y"}
        job = deps.nested_job(parent, expansion)
        self.assertEqual(job, {"kind": "bisect", "mode": "performance", "story": "terminal.key_to_frame",
                               "metric": "p95_ms", "host_class": "apple-m4/16gb/120hz", "magnitude": 2.5,
                               "good": expansion.changes[0], "bad": expansion.changes[-1]})

    def test_range_of_several_commits_that_only_rolls_expands(self) -> None:
        self.cmux.gitlink("ghostty-next", self.next_shas[4])
        self.cmux.commit("bump 1")
        self.cmux.gitlink("ghostty-next", self.next_shas[6])
        bad = self.cmux.commit("bump 2")
        expansion = self.expand(self.base, bad).expansion
        self.assertEqual([c.dep("ghostty-next") for c in expansion.changes], self.next_shas[:7])

    def test_a_culprit_that_also_changes_code_is_not_expanded(self) -> None:
        self.cmux.gitlink("ghostty-next", self.next_shas[8])
        self.cmux.write("Sources/App.swift", "app 2\n")
        decision = self.expand(self.base, self.cmux.commit("bump and code"))
        self.assertIsNone(decision.expansion)
        self.assertEqual(decision.reason, "mixed: the range also changes Sources/App.swift")

    def test_a_companion_of_a_pin_that_did_not_move_is_not_allowed(self) -> None:
        self.cmux.gitlink("ghostty-next", self.next_shas[8])
        self.cmux.write("scripts/ghosttykit-checksums.txt", "x\n")  # ghostty's, and ghostty did not move
        decision = self.expand(self.base, self.cmux.commit("bump"))
        self.assertEqual(decision.reason, "mixed: the range also changes scripts/ghosttykit-checksums.txt")

    def test_no_pin_moved(self) -> None:
        self.cmux.write(PACKAGE, "pin b\n")
        decision = self.expand(self.base, self.cmux.commit("comment"))
        self.assertEqual(decision.reason, "no-dep-moved: no pin moves in the range")
        self.assertEqual(self.expand(self.base, self.base).reason, "no-change: the range changes no file")

    def test_rewind_is_non_linear(self) -> None:
        self.cmux.gitlink("ghostty-next", self.next_shas[8])
        ahead = self.cmux.commit("bump")
        self.cmux.gitlink("ghostty-next", self.next_shas[2])
        decision = self.expand(ahead, self.cmux.commit("back"))
        self.assertIsNone(decision.expansion)
        self.assertTrue(decision.reason.startswith("non-linear: ghostty-next"), decision.reason)

    def test_branch_switch_is_non_linear(self) -> None:
        git(self.next.path, "checkout", "-q", "-b", "side", self.next_shas[0])
        (side,) = self.next.dep_commits(1, "side")
        self.cmux.gitlink("ghostty-next", self.next_shas[3])
        on_main = self.cmux.commit("bump")
        self.cmux.gitlink("ghostty-next", side)
        self.assertTrue(self.expand(on_main, self.cmux.commit("switch")).reason.startswith("non-linear"))

    def test_added_submodule_is_not_expanded(self) -> None:
        self.cmux.drop("ghostty-next")
        without = self.cmux.commit("drop")
        self.cmux.gitlink("ghostty-next", self.next_shas[8])
        self.assertTrue(self.expand(without, self.cmux.commit("add")).reason.startswith("dep-added: ghostty-next"))

    def test_missing_repository_or_commit(self) -> None:
        bump = self.bump()
        no_repo = self.expand(self.base, bump, repos={"ghostty": self.classic.git})
        self.assertEqual(no_repo.reason, "no-repo: no repository of ghostty-next on this host")
        missing = self.expand(self.base, bump, repos={"ghostty-next": self.classic.git})
        self.assertTrue(missing.reason.startswith("dep-commit-missing: ghostty-next"), missing.reason)

    def test_two_pins_step_one_after_another(self) -> None:
        self.cmux.gitlink("ghostty-next", self.next_shas[2])
        self.cmux.gitlink("ghostty", self.classic_shas[3])
        expansion = self.expand(self.base, self.cmux.commit("both")).expansion
        self.assertEqual([r.dep for r in expansion.rolls], ["ghostty", "ghostty-next"])
        self.assertEqual(
            [(c.dep("ghostty"), c.dep("ghostty-next")) for c in expansion.changes],
            [(g, self.next_shas[0]) for g in self.classic_shas] + [(self.classic_shas[3], n) for n in self.next_shas[1:3]],
        )
        last, before = expansion.changes[-1], expansion.changes[-2]
        self.assertEqual(expansion.culprit(before, last), ("ghostty-next", self.next_shas[2]))
        self.assertEqual(expansion.culprit(expansion.changes[0], expansion.changes[1]), ("ghostty", self.classic_shas[1]))

    def test_midpoint_rejects_a_change_outside_the_roll(self) -> None:
        expansion = self.expand(self.base, self.bump()).expansion
        with self.assertRaises(deps.DepsError):
            expansion.midpoint(deps.Change(self.base), expansion.changes[-1])
        with self.assertRaises(deps.DepsError):
            expansion.culprit(expansion.changes[0], expansion.changes[2])


class CefPinTest(Fixture):
    def test_cef_pin_expands_and_only_published_commits_build(self) -> None:
        self.cmux.manifest(self.cef_shas[4], "cef-154.0.28-cmux.22")
        decision = self.expand(self.base, self.cmux.commit("CEF: pin cmux.22"))
        expansion = decision.expansion
        self.assertIsNotNone(expansion, decision.reason)
        self.assertEqual([c.dep("cef") for c in expansion.changes], self.cef_shas)
        unbuildable = sorted(expansion.index(c) for c in expansion.unbuildable)
        self.assertEqual(unbuildable, [1, 3])  # untagged, and a tag that is not a runtime release

    def test_manifest_that_is_not_json_is_an_error(self) -> None:
        self.cmux.write(MANIFEST, "not json")
        with self.assertRaises(deps.DepsError):
            self.expand(self.base, self.cmux.commit("broken manifest"))


class CliTest(Fixture):
    def test_expand_prints_the_decision_and_finds_submodule_git_dirs(self) -> None:
        # The submodule's git dir where a checkout keeps it: <common dir>/modules/ghostty-next.
        modules = self.cmux.path / ".git" / "modules"
        modules.mkdir()
        git(self.root, "clone", "-q", "--bare", str(self.next.path), str(modules / "ghostty-next"))
        self.cmux.gitlink("ghostty-next", self.next_shas[8])
        bump = self.cmux.commit("bump")
        proc = subprocess.run(
            [sys.executable, "-I", str(LAB / "deps.py"), "expand", "--repo", str(self.cmux.path),
             "--good", "HEAD~1", "--bad", "HEAD", "--dep-repo", f"cef={self.cef.path}"],
            env=GIT_ENV, capture_output=True, text=True, check=False,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        out = json.loads(proc.stdout)
        self.assertTrue(out["expanded"])
        self.assertEqual(len(out["expansion"]["changes"]), 9)
        self.assertEqual(out["expansion"]["rolls"][0]["commits"], self.next_shas[1:])
        self.assertEqual((out["expansion"]["good"], out["expansion"]["bad"]), (self.base, bump))

    def test_unknown_dep_repo_name_is_a_usage_error(self) -> None:
        proc = subprocess.run(
            [sys.executable, "-I", str(LAB / "deps.py"), "expand", "--repo", str(self.cmux.path),
             "--good", self.base, "--bad", self.base, "--dep-repo", "v8=/tmp"],
            env=GIT_ENV, capture_output=True, text=True, check=False,
        )
        self.assertEqual(proc.returncode, 2)


if __name__ == "__main__":
    unittest.main()
