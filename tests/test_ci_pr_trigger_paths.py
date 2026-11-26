#!/usr/bin/env python3
"""Every pull request workflow has trigger `paths:` or a written reason to start on every head.

A workflow run takes a queue slot from the moment GitHub creates it, even when every job in it skips. On 2026-11-19
46 pull request heads made 851 runs (18.5 each) and 29 workflows had no paths filter. scripts/ci/pr_trigger_paths.py
`detect` fails on a PR-triggered workflow with neither `paths:` nor an every_pr reason in
scripts/ci/pr-trigger-paths.json; `check` fails when a derived workflow's `paths:` differ from what its decider (the
script its own jobs decide with) derives. The fix the failure names: `pr_trigger_paths.py write`.
"""
from __future__ import annotations

import importlib.util
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
# tests/git_fixture_env.py, loaded by path: `python3 -I` puts no script folder on sys.path.
_git_fixture_spec = importlib.util.spec_from_file_location("git_fixture_env", ROOT / "tests" / "git_fixture_env.py")
git_fixture_env = importlib.util.module_from_spec(_git_fixture_spec)
_git_fixture_spec.loader.exec_module(git_fixture_env)
if str(ROOT / "scripts" / "ci") not in sys.path:
    sys.path.insert(0, str(ROOT / "scripts" / "ci"))
import pr_trigger_paths as router  # noqa: E402


def git(repo: Path, *args: str) -> None:
    subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True,
                   env=git_fixture_env.fixture_env({
                       "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t",
                       "GIT_COMMITTER_EMAIL": "t@t", "PATH": "/usr/bin:/bin", "HOME": "/nonexistent"}))


class Fixture:
    """A repository with a workflow folder and the map, for detect."""

    def __init__(self, workflows: dict[str, str], derived: dict | None = None, every: dict | None = None):
        self.dir = tempfile.TemporaryDirectory()
        self.root = Path(self.dir.name)
        (self.root / ".github/workflows").mkdir(parents=True)
        (self.root / "scripts/ci").mkdir(parents=True)
        for name, text in workflows.items():
            (self.root / ".github/workflows" / name).write_text(text, encoding="utf-8")
        (self.root / router.MAP).write_text(json.dumps({"derived": derived or {}, "every_pr": every or {}}),
                                            encoding="utf-8")

    def __enter__(self) -> Path:
        return self.root

    def __exit__(self, *exc) -> None:
        self.dir.cleanup()


OPEN = "on:\n  pull_request:\n    branches: [feat-cmux-next]\njobs: {}\n"
FILTERED = "on:\n  pull_request:\n    paths:\n      - \"a/**\"\njobs: {}\n"
IGNORE_ONLY = "on:\n  pull_request:\n    paths-ignore:\n      - \"docs/**\"\njobs: {}\n"
PUSH_ONLY = "on:\n  push:\n    branches: [main]\njobs: {}\n"
REASON = "a required context that must report on every head"


class DetectTests(unittest.TestCase):
    def test_the_tree_passes(self) -> None:
        self.assertEqual(router.detect(ROOT), [])

    def test_an_unfiltered_workflow_without_a_reason_fails(self) -> None:
        with Fixture({"x.yml": OPEN}) as root:
            problems = router.detect(root)
        self.assertEqual(len(problems), 1)
        self.assertIn("x.yml starts a run on every pull request", problems[0])

    def test_paths_ignore_alone_is_not_a_filter(self) -> None:
        with Fixture({"x.yml": IGNORE_ONLY}) as root:
            self.assertEqual(len(router.detect(root)), 1)

    def test_a_reason_or_a_filter_passes(self) -> None:
        with Fixture({"x.yml": OPEN, "y.yml": FILTERED, "z.yml": PUSH_ONLY},
                     every={".github/workflows/x.yml": REASON}) as root:
            self.assertEqual(router.detect(root), [])

    def test_a_stale_or_empty_reason_fails(self) -> None:
        with Fixture({"y.yml": FILTERED, "z.yml": PUSH_ONLY},
                     every={".github/workflows/y.yml": REASON, ".github/workflows/z.yml": REASON,
                            ".github/workflows/gone.yml": "x"}) as root:
            problems = "\n".join(router.detect(root))
        self.assertIn("y.yml is under every_pr but filters", problems)
        self.assertIn("z.yml has no pull_request trigger", problems)
        self.assertIn("gone.yml, which does not exist", problems)
        self.assertIn("every_pr .github/workflows/gone.yml needs a reason", problems)

    def test_pull_request_target_counts(self) -> None:
        with Fixture({"x.yml": "on:\n  pull_request_target:\n    types: [opened]\njobs: {}\n"}) as root:
            self.assertEqual(len(router.detect(root)), 1)

    def test_inline_triggers(self) -> None:
        with Fixture({"x.yml": "on: [push, pull_request]\njobs: {}\n", "y.yml": "on: pull_request\njobs: {}\n"}) as root:
            self.assertEqual(len(router.detect(root)), 2)


class TriggerParserTests(unittest.TestCase):
    def test_matches_yaml_on_every_workflow(self) -> None:
        """The YAML-free reader agrees with PyYAML on every workflow's PR events and their filters."""
        for path in sorted((ROOT / ".github/workflows").glob("*.y*ml")):
            text = path.read_text(encoding="utf-8")
            loaded = yaml.safe_load(text)
            on = loaded.get("on", loaded.get(True))
            if isinstance(on, str):
                on = {on: None}
            elif isinstance(on, list):
                on = dict.fromkeys(on)
            want = {event: {key: (list(value) if isinstance(value, list) else [value])
                            for key, value in (settings or {}).items()
                            if key in ("paths", "paths-ignore", "branches", "types")}
                    for event, settings in (on or {}).items() if event in router.PR_EVENTS}
            have = {event: {key: value for key, value in settings.items()
                            if key in ("paths", "paths-ignore", "branches", "types")}
                    for event, settings in router.pr_events(text).items()}
            self.assertEqual(have, want, path.name)


class FilterTests(unittest.TestCase):
    def test_github_glob_semantics(self) -> None:
        self.assertTrue(router.starts(["**/*.md"], ["README.md"]))
        self.assertTrue(router.starts(["web/**"], ["web/a/b.ts"]))
        self.assertFalse(router.starts(["web/*"], ["web/a/b.ts"]))
        self.assertTrue(router.starts(["web/app/**", "!**/*.test.ts"], ["web/app/x.ts"]))
        self.assertFalse(router.starts(["web/app/**", "!**/*.test.ts"], ["web/app/x.test.ts"]))
        self.assertTrue(router.starts(["web/app/**", "!**/*.test.ts", "web/app/keep.test.ts"],
                                      ["web/app/keep.test.ts"]))

    def test_would_start_reads_branches_types_and_paths(self) -> None:
        text = ("on:\n  pull_request:\n    branches: [main]\n    types: [opened, synchronize]\n"
                "    paths:\n      - \"a/**\"\njobs: {}\n")
        self.assertTrue(router.would_start(text, "main", ["a/x"]))
        self.assertFalse(router.would_start(text, "feat-cmux-next", ["a/x"]))
        self.assertFalse(router.would_start(text, "main", ["b/x"]))
        closed = "on:\n  pull_request:\n    types: [closed]\njobs: {}\n"
        self.assertFalse(router.would_start(closed, "main", ["a/x"]))


class DerivedTests(unittest.TestCase):
    def test_each_derived_workflow_filters_exactly_what_its_decider_derives(self) -> None:
        self.assertEqual(router.check(ROOT), [])

    def test_the_classic_filters_agree_with_their_guards_on_every_tracked_file(self) -> None:
        api = router._load(ROOT / "scripts/ci/classic_api_guard.py", "test_classic_api_guard")
        frozen = router._load(ROOT / "scripts/ci/classic_frozen_guard.py", "test_classic_frozen_guard")
        config = api.load_config(ROOT / "scripts/ci/classic-auto-deploy.json")
        rules = frozen.load(ROOT / ".github/classic-frozen.txt")
        api_globs = router.pr_events((ROOT / ".github/workflows/classic-api-guard.yml").read_text())["pull_request"]["paths"]
        frozen_globs = router.pr_events(
            (ROOT / ".github/workflows/classic-frozen-guard.yml").read_text())["pull_request_target"]["paths"]
        for path in sorted(router.tracked(ROOT)):
            if api.guarded_hits(config, [path]):
                self.assertTrue(router.starts(api_globs, [path]), path)
            if frozen.frozen(rules, "main", [path]):
                self.assertTrue(router.starts(frozen_globs, [path]), path)

    def test_a_stale_block_fails_and_write_mends_it(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for relative in (router.MAP, "scripts/ci/classic-auto-deploy.json", "scripts/ci/classic_api_guard.py",
                             ".github/workflows/classic-api-guard.yml"):
                (root / relative).parent.mkdir(parents=True, exist_ok=True)
                shutil.copy(ROOT / relative, root / relative)
            data = json.loads((root / router.MAP).read_text())
            data["derived"] = {".github/workflows/classic-api-guard.yml": data["derived"][
                ".github/workflows/classic-api-guard.yml"]}
            (root / router.MAP).write_text(json.dumps(data))
            git_fixture_env.init_repo(root)
            git(root, "add", ".")
            self.assertEqual(router.check(root), [])
            config = json.loads((root / "scripts/ci/classic-auto-deploy.json").read_text())
            next(d for d in config["deploys"] if d.get("guarded"))["paths"].append("web/app/new-api/**")
            (root / "scripts/ci/classic-auto-deploy.json").write_text(json.dumps(config))
            problems = router.check(root)
            self.assertEqual(len(problems), 1)
            self.assertIn("missing ['web/app/new-api/**']", problems[0])
            self.assertTrue(router.write(root, ".github/workflows/classic-api-guard.yml", "classic_api"))
            self.assertEqual(router.check(root), [])
            self.assertFalse(router.write(root, ".github/workflows/classic-api-guard.yml", "classic_api"))
            yaml.safe_load((root / ".github/workflows/classic-api-guard.yml").read_text())

    def test_a_decider_glob_github_reads_differently_is_refused(self) -> None:
        saved = router.DECIDERS["classic_api"]
        router.DECIDERS["classic_api"] = lambda root, files: (["web/a?.ts"], [])
        try:
            with self.assertRaises(ValueError):
                router.derive(ROOT, ".github/workflows/classic-api-guard.yml", "classic_api")
        finally:
            router.DECIDERS["classic_api"] = saved


if __name__ == "__main__":
    unittest.main()
