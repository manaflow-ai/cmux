#!/usr/bin/env python3
"""stories/qos_static.py: guardrails' task-priority and thread-doc rules over a whole fixture tree, and its result-v1.

  python3 -m unittest scripts/perf-lab/tests/test_qos_static.py
"""
from __future__ import annotations

import importlib.util
import json
import os
import plistlib
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
LAB = HERE.parent
ROOT = LAB.parent.parent

_SPEC = importlib.util.spec_from_file_location("perf_lab_qos_static_under_test", LAB / "stories" / "qos_static.py")
qos_static = importlib.util.module_from_spec(_SPEC)
sys.modules[_SPEC.name] = qos_static
_SPEC.loader.exec_module(qos_static)
g = qos_static.g

SOURCES = g.SOURCES
DOC = """# Threading model

## Registered threads and queues

- `cmux.listed` serial utility queue.

## Next section
"""
SWIFT = """import Foundation

final class Worker {
    let unlisted = DispatchQueue(label: "cmux.unlisted")
    let listed = DispatchQueue(label: "cmux.listed", qos: .utility)
    let stated = DispatchQueue(label: "cmux.listed", target: .global())
    // qos-allow: nothing ever waits for this sweep
    let sweep = Task.detached { }
    let pool = DispatchQueue.global()
}
"""


class QosStaticTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = Path(self.tmp.name)
        env = {**os.environ, "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1"}
        self.git = lambda *args: subprocess.run(["git", "-C", str(self.repo), *args], check=True, env=env,
                                                capture_output=True, text=True).stdout.strip()
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.email", "t@example.com")
        self.git("config", "user.name", "t")

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def commit(self, files: dict[str, str]) -> str:
        for path, text in files.items():
            target = self.repo / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(text, encoding="utf-8")
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "fixture")
        return self.git("rev-parse", "HEAD")

    def fixture(self) -> str:
        return self.commit({g.THREADING_DOC: DOC, SOURCES + "CmuxNextFoo/Worker.swift": SWIFT,
                            SOURCES + "CmuxNextFoo/Notes.md": "DispatchQueue(label: \"x\")\n",
                            "Packages/macOS/Other/Sources/X.swift": "let q = DispatchQueue(label: \"other\")\n"})

    def test_counts_each_refused_line_once_in_path_and_line_order(self) -> None:
        sha = self.fixture()
        report = qos_static.count(self.repo)
        self.assertEqual(report.sha, sha)
        path = SOURCES + "CmuxNextFoo/Worker.swift"
        self.assertEqual([(s.path, s.line, s.rules) for s in report.sites],
                         [(path, 4, ("task-priority", "thread-doc")), (path, 9, ("task-priority",))])
        self.assertEqual(report.count, 2)
        self.assertEqual(report.per_rule, {"task-priority": 2, "thread-doc": 1})
        self.assertEqual(report.sites[0].text, 'let unlisted = DispatchQueue(label: "cmux.unlisted")')

    def test_the_list_is_the_same_on_every_run(self) -> None:
        self.fixture()
        first = json.dumps(qos_static.count(self.repo).record(), sort_keys=True)
        self.assertEqual(json.dumps(qos_static.count(self.repo).record(), sort_keys=True), first)

    def test_counts_the_named_revision_not_the_working_tree(self) -> None:
        old = self.fixture()
        self.commit({SOURCES + "CmuxNextFoo/Worker.swift": "import Foundation\n"})
        self.assertEqual(qos_static.count(self.repo).count, 0)
        self.assertEqual(qos_static.count(self.repo, old).count, 2)

    def test_refuses_without_the_threading_doc(self) -> None:
        self.commit({SOURCES + "CmuxNextFoo/Worker.swift": SWIFT})
        with self.assertRaisesRegex(qos_static.StoryError, "threading-model.md"):
            qos_static.count(self.repo)

    def test_refuses_an_unknown_revision(self) -> None:
        self.fixture()
        with self.assertRaises(qos_static.StoryError):
            qos_static.count(self.repo, "no-such-rev")

    def test_writes_a_valid_result_claiming_qos_swift_and_the_sites_beside_it(self) -> None:
        sha = self.fixture()
        report = qos_static.count(self.repo)
        with tempfile.TemporaryDirectory() as out:
            path = qos_static.write(report, Path(out), self.repo)
            [result] = qos_static.perf_result.read_file(path)
            self.assertEqual((result.story, result.metric, result.unit, result.samples),
                             ("qos-static", "qos.undeclared_swift", "count", [2]))
            self.assertEqual(result.target_ref.target, "qos.swift")
            self.assertEqual((result.build.sha, result.build.config, result.engine), (sha, "release", "none"))
            sites = json.loads((Path(out) / qos_static.SITES_FILE).read_text(encoding="utf-8"))
            self.assertEqual(sites["count"], 2)
            self.assertEqual([s["line"] for s in sites["sites"]], [4, 9])
            self.assertEqual(sorted(p.name for p in Path(out).iterdir()),
                             sorted([path.name, qos_static.SITES_FILE]))

    def test_the_story_file_claims_the_metric_it_writes(self) -> None:
        story = json.loads((LAB / "stories.d" / "qos-static.json").read_text(encoding="utf-8"))
        self.assertEqual(story["id"], qos_static.STORY)
        self.assertEqual(story["config"], qos_static.STATIC_CONFIG)
        [metric] = story["metrics"]
        self.assertRegex(qos_static.METRIC, "^" + metric["name"] + "$")
        self.assertEqual(metric["target_ref"], {"target": qos_static.TARGET_ROW})

    def test_matches_the_threading_inventory_line_for_line(self) -> None:
        self.fixture()
        tree = qos_static.inventory.read_tree(self.repo, "HEAD")
        lines = {(rule, hit.path, hit.number) for rule, hit in qos_static.inventory.judge(tree, qos_static.RULE_IDS,
                                                                                          lambda path: True)}
        report = qos_static.count(self.repo)
        self.assertEqual({(rule, s.path, s.line) for s in report.sites for rule in s.rules}, lines)

    def runner_env(self, **extra: str) -> dict[str, str]:
        env = {k: v for k, v in os.environ.items() if not k.startswith("PERF_LAB_")}
        return {**env, "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1", **extra}

    def run_as_runner(self, env: dict[str, str], *extra: str) -> tuple[subprocess.CompletedProcess, Path]:
        """The story's catalog command with the runner's `--app --tag --out` (run_story.story_argv), in the checkout."""
        story = json.loads((LAB / "stories.d" / "qos-static.json").read_text(encoding="utf-8"))
        out = Path(self.tmp.name) / "run-out"
        app = Path(self.tmp.name) / "cmux DEV t.app"
        argv = [sys.executable, str(ROOT / story["command"][0]), *story["command"][1:],
                "--app", str(app), "--tag", "t", "--out", str(out), *extra]
        done = subprocess.run(argv, cwd=self.repo, env=env, capture_output=True, text=True)
        return done, out

    def results(self, out: Path) -> list:
        return [r for path in sorted(out.glob("*.ndjson")) for r in qos_static.perf_result.read_file(path)]

    def test_runs_with_the_runner_argv_and_counts_the_measured_sha_not_head(self) -> None:
        measured = self.fixture()
        head = self.commit({SOURCES + "CmuxNextFoo/Worker.swift": "import Foundation\n"})
        self.assertNotEqual(head, measured)
        done, out = self.run_as_runner(self.runner_env(PERF_LAB_SHA=measured, PERF_LAB_SESSION="light"), "light")
        self.assertEqual(done.returncode, 0, done.stderr)
        [result] = self.results(out)
        self.assertEqual((result.build.sha, result.samples, result.session), (measured, [2], "light"))

    def test_takes_the_measured_sha_from_the_app_when_the_runner_sets_none(self) -> None:
        measured = self.fixture()
        self.commit({SOURCES + "CmuxNextFoo/Worker.swift": "import Foundation\n"})
        contents = Path(self.tmp.name) / "cmux DEV t.app" / "Contents"
        contents.mkdir(parents=True)
        (contents / "Info.plist").write_bytes(plistlib.dumps({"CMUXCommit": measured}))
        done, out = self.run_as_runner(self.runner_env(), "--session", "light")
        self.assertEqual(done.returncode, 0, done.stderr)
        [result] = self.results(out)
        self.assertEqual((result.build.sha, result.samples), (measured, [2]))

    def test_refuses_an_app_with_no_commit_and_another_session(self) -> None:
        self.fixture()
        done, out = self.run_as_runner(self.runner_env())
        self.assertEqual(done.returncode, 2)
        self.assertIn("Info.plist", done.stderr)
        self.assertFalse(out.exists())
        done, out = self.run_as_runner(self.runner_env(PERF_LAB_SHA="HEAD", PERF_LAB_SESSION="stress"))
        self.assertEqual(done.returncode, 2)
        self.assertIn("stress", done.stderr)

    def test_a_manual_run_counts_head(self) -> None:
        self.assertEqual(qos_static.measured_rev(None, None, {}), "HEAD")
        self.assertEqual(qos_static.measured_rev("abc", None, {"PERF_LAB_SHA": "def"}), "abc")
        self.assertEqual(qos_static.measured_rev(None, None, {"PERF_LAB_SHA": "def"}), "def")


if __name__ == "__main__":
    unittest.main()
