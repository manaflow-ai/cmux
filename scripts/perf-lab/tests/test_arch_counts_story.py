#!/usr/bin/env python3
"""The arch-counts lab story (scripts/perf-lab/stories/arch_counts.py) with git real in temporary repositories.

Covered: one valid result-v1 per row of the cron report's own count (same rows, same numbers, read back by
perf_result.read_dir); lower-is-better counts with one sample; the count's method version is the measure version;
only a ratcheted row with a total references the ratchet file (path + /totals/<row>, never a copied number); a
commit without arch_counts.py or with a count that breaks the contract writes nothing and exits 1; --sha falls back
to PERF_LAB_SHA, then CMUX_CI_SHA; a bad --run-id is a usage error; the story file names this script; and on this
checkout the story's metrics are exactly the rows the real arch_counts.py counts.

Run: python3 -I scripts/perf-lab/tests/test_arch_counts_story.py (not a CI job).
"""
import contextlib
import importlib.util
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

LAB = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ROOT = os.path.dirname(os.path.dirname(LAB))


def _load(name, path):
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


story = _load("arch_counts_story", os.path.join(LAB, "stories", "arch_counts.py"))
report = story.report
perf_result = story.perf_result

# Follows the pinned contract: --repo --rev --json, reads the commit from git objects, prints one record.
FAKE_COUNTS = r'''import argparse, json, subprocess
ap = argparse.ArgumentParser()
ap.add_argument("--repo", required=True)
ap.add_argument("--rev", required=True)
ap.add_argument("--json", action="store_true")
a = ap.parse_args()
def git(*args):
    return subprocess.run(["git", "-C", a.repo, *args], capture_output=True, check=True, text=True).stdout
sha = git("rev-parse", "--verify", a.rev + "^{commit}").strip()
value = json.loads(git("show", sha + ":plans/cmux-next/fake-counts.json"))
print("counting...")
print(json.dumps({"method": "arch_counts", "measured_sha": value.pop("measured_sha", sha), **value}))
'''
ROWS = {"layer_hard": {"title": "hard layer edges", "ratchet": True},
        "stateful_singletons": {"title": "stateful singletons", "ratchet": True},
        "observer_sites": {"title": "observer sites", "ratchet": True},
        "app_lines": {"title": "CmuxNextApp Swift lines", "ratchet": False}}


def counts(version=3, singletons=6, **extra):
    totals = {"layer_hard": 4, "stateful_singletons": singletons, "observer_sites": 0, "app_lines": 1200}
    return {"method_version": version, "rows": ROWS, "totals": totals,
            "packages": {"CmuxNextApp": dict(totals)}, **extra}


def ratchet():
    # observer_sites is ratcheted but has no total here: it is counted, never referenced.
    value = counts(singletons=5)
    value["totals"] = {k: v for k, v in value["totals"].items() if k != "observer_sites"}
    return {"method": "arch_counts", "measured_sha": "0" * 40, "exceptions": [], **value}


class ArchCountsStoryTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.dir = tmp.name
        self.repo = os.path.join(self.dir, "repo")
        self.out = os.path.join(self.dir, "out")
        gitconfig = os.path.join(self.dir, "gitconfig")
        open(gitconfig, "w").close()
        env = mock.patch.dict(os.environ, {"GIT_CONFIG_GLOBAL": gitconfig, "GIT_CONFIG_NOSYSTEM": "1",
                                           "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.com",
                                           "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.com"})
        env.start()
        self.addCleanup(env.stop)
        subprocess.run(["git", "init", "-q", "-b", "feat-cmux-next", self.repo], check=True)
        self.write("Packages/macOS/CmuxNext/Package.swift", "// swift-tools-version:6.0\n")

    def write(self, rel, text):
        path = os.path.join(self.repo, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            f.write(text)

    def commit(self, value=None, with_script=True, with_ratchet=True):
        if with_script:
            self.write(report.COUNTS_SCRIPT, FAKE_COUNTS)
        if value is not None:
            self.write("plans/cmux-next/fake-counts.json", json.dumps(value))
        if with_ratchet:
            self.write(report.RATCHET_PATH, json.dumps(ratchet()))
        subprocess.run(["git", "-C", self.repo, "add", "-A"], check=True)
        subprocess.run(["git", "-C", self.repo, "commit", "-q", "--allow-empty", "-m", "c"], check=True)
        return subprocess.run(["git", "-C", self.repo, "rev-parse", "HEAD"], capture_output=True, text=True,
                              check=True).stdout.strip()

    def main(self, *argv, environ=None):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = story.main(["--out", self.out, "--root", self.repo, *argv], environ=environ or {})
        return code, out.getvalue(), err.getvalue()

    def results(self):
        return {r.metric: r for r in perf_result.read_dir(self.out)} if os.path.isdir(self.out) else {}

    def test_one_valid_result_per_row_of_the_cron_reports_count(self):
        sha = self.commit(counts())
        code, out, err = self.main("--sha", sha, "--run-id", "job-7.attempt-1")
        self.assertEqual(code, 0, err)
        dl = report.Deadline(60)
        expected = report.counts_at(dl, self.repo, sha, report.count_files(dl, self.repo, sha))["totals"]
        results = self.results()
        self.assertEqual({m: r.samples for m, r in results.items()},
                         {f"arch.{row}": [n] for row, n in expected.items()})
        for result in results.values():
            result.validate()
            self.assertEqual((result.story, result.unit, result.better, result.engine, result.session),
                             ("arch-counts", "count", "lower", "none", "light"))
            self.assertEqual((result.build.sha, result.build.config, result.build.measure_version),
                             (sha, "release", 3))
            self.assertEqual(result.run.id, "job-7.attempt-1")
            self.assertEqual(result.host.host_class, "linux-static")
            self.assertIsNone(result.host.macos)
        self.assertIn("arch.stateful_singletons 6", out)

    def test_only_a_ratcheted_row_with_a_total_references_the_ratchet_file(self):
        sha = self.commit(counts())
        self.assertEqual(self.main("--sha", sha)[0], 0)
        refs = {m: r.target_ref and r.target_ref.to_dict() for m, r in self.results().items()}
        self.assertEqual(refs, {
            "arch.layer_hard": {"path": report.RATCHET_PATH, "key": "/totals/layer_hard"},
            "arch.stateful_singletons": {"path": report.RATCHET_PATH, "key": "/totals/stateful_singletons"},
            "arch.observer_sites": None, "arch.app_lines": None})

    def test_no_ratchet_file_counts_with_no_reference(self):
        sha = self.commit(counts(), with_ratchet=False)
        self.assertEqual(self.main("--sha", sha)[0], 0)
        self.assertEqual(len(self.results()), 4)
        self.assertTrue(all(r.target_ref is None for r in self.results().values()))

    def test_a_commit_without_arch_counts_writes_nothing(self):
        sha = self.commit(counts(), with_script=False, with_ratchet=False)
        code, _, err = self.main("--sha", sha)
        self.assertEqual(code, 1)
        self.assertIn("is not in the commit", err)
        self.assertEqual(self.results(), {})

    def test_a_count_that_breaks_the_contract_writes_nothing(self):
        for bad in (counts(measured_sha="1" * 40), {"method_version": 3, "rows": {}, "totals": {}, "packages": {}}):
            with self.subTest(bad=bad):
                sha = self.commit(bad)
                code, _, err = self.main("--sha", sha)
                self.assertEqual(code, 1)
                self.assertIn("arch_counts", err)
                self.assertEqual(self.results(), {})

    def test_an_unknown_sha_writes_nothing(self):
        self.commit(counts())
        code, _, err = self.main("--sha", "f" * 40)
        self.assertEqual(code, 1, err)
        self.assertEqual(self.results(), {})

    def test_sha_comes_from_the_runner_environment(self):
        first = self.commit(counts(singletons=6))
        self.commit(counts(singletons=9))
        for environ in ({"PERF_LAB_SHA": first, "CMUX_CI_SHA": "0" * 40}, {"CMUX_CI_SHA": first}):
            with self.subTest(environ=environ):
                for name in os.listdir(self.out) if os.path.isdir(self.out) else ():
                    os.remove(os.path.join(self.out, name))
                self.assertEqual(self.main(environ=environ)[0], 0)
                self.assertEqual(self.results()["arch.stateful_singletons"].build.sha, first)
        self.assertEqual(story.default_sha({}), None)

    def test_usage_errors(self):
        self.commit(counts())
        self.assertEqual(self.main("--run-id", "../x")[0], 2)
        self.assertEqual(self.main("--seconds", "0")[0], 2)
        self.assertEqual(self.results(), {})

    def test_story_file_names_this_script_and_the_result_shape(self):
        with open(os.path.join(LAB, "stories.d", "arch-counts.json")) as f:
            spec = json.load(f)
        self.assertEqual(spec["id"], story.STORY)
        self.assertEqual(spec["tier"], "linux")
        self.assertEqual(spec["command"][0], os.path.relpath(story.__file__, ROOT))
        self.assertIn("{out}", spec["command"])
        self.assertEqual((spec["config"], spec["engine"], spec["session"]), (story.CONFIG, story.ENGINE, story.SESSION))
        [metric] = spec["metrics"]
        self.assertEqual((metric["unit"], metric["better"]), (story.UNIT, story.BETTER))
        self.assertRegex("arch.stateful_singletons", "^" + metric["name"] + "$")
        for need in spec["needs"]:
            self.assertTrue(os.path.isfile(os.path.join(ROOT, need.split(":", 1)[1])), need)


@unittest.skipUnless(os.path.isfile(os.path.join(ROOT, report.COUNTS_SCRIPT)), "no arch_counts.py in this checkout")
class ThisCheckoutTests(unittest.TestCase):
    def test_metrics_are_exactly_the_rows_of_the_real_count(self):
        head = subprocess.run(["git", "-C", ROOT, "rev-parse", "HEAD"], capture_output=True, text=True,
                              check=True).stdout.strip()
        direct = subprocess.run([sys.executable, "-I", os.path.join(ROOT, report.COUNTS_SCRIPT), "--repo", ROOT,
                                 "--rev", head, "--json"], capture_output=True, text=True, check=True)
        totals = report.last_json_object(direct.stdout)["totals"]
        with tempfile.TemporaryDirectory() as out:
            path = story.measure(out, head)
            got = {r.metric: r.samples[0] for r in perf_result.read_file(path)}
        self.assertEqual(got, {f"arch.{row}": n for row, n in totals.items()})


class SubscriptionTests(unittest.TestCase):
    """subscriptions.json makes the arch.* series alert, so the lab replaces the cron report's issue."""

    @classmethod
    def setUpClass(cls):
        cls.alerts = _load("perf_lab_alerts", os.path.join(LAB, "alerts.py"))
        cls.subscriptions = cls.alerts.Subscriptions.load(os.path.join(LAB, "subscriptions.json"))
        with open(os.path.join(ROOT, report.RATCHET_PATH)) as f:
            cls.rows = json.load(f)["rows"]

    def owner(self, row):
        series = self.alerts.SeriesInfo(id=1, key=f"k-{row}", story=story.STORY, metric=story.METRIC_PREFIX + row,
                                        engine=story.ENGINE, host_class=story.HOST_CLASS, macos_major=0,
                                        build_config=story.CONFIG, unit=story.UNIT, better=story.BETTER)
        return self.subscriptions.match(series)

    def test_every_row_is_monitored_and_only_ratcheted_rows_alert_on_a_step_of_one(self):
        self.assertTrue(self.rows)
        for row, spec in self.rows.items():
            subscription = self.owner(row)
            self.assertIsNotNone(subscription, row)
            self.assertEqual(subscription.owner, "PL-arch", row)
            self.assertEqual(subscription.name == "arch-ratcheted", bool(spec.get("ratchet")), row)

    def test_a_ratcheted_row_alerts_on_one_more_and_an_unratcheted_row_does_not(self):
        detector = self.alerts.CatapultDetector()
        ratcheted = next(row for row, spec in self.rows.items() if spec.get("ratchet"))
        changes = detector.change_points([33.0] * 8 + [34.0] * 8, self.owner(ratcheted).anomaly_config)
        self.assertEqual([(c.median_before, c.median_after) for c in changes], [(33.0, 34.0)])
        self.assertEqual(detector.change_points([33.0] * 16, self.owner(ratcheted).anomaly_config), [])
        unratcheted = next(row for row, spec in self.rows.items() if not spec.get("ratchet"))
        self.assertEqual(detector.change_points([159296.0] * 8 + [159297.0] * 8,
                                                self.owner(unratcheted).anomaly_config), [])


if __name__ == "__main__":
    unittest.main()
