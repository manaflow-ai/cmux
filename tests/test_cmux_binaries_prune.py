#!/usr/bin/env python3
"""The cmux-binaries pruner deletes only unpinned, old branch-head prefixes, metadata first."""
import datetime as dt
import json
from pathlib import Path
import sys
import tempfile
import unittest
import urllib.error

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/ci"))
import cmux_binaries_prune as prune  # noqa: E402

NOW = dt.datetime(2026, 10, 11, 12, tzinfo=dt.timezone.utc)
TRUNK = {f"{n:040x}" for n in range(1, prune.MIN_TRUNK_COMMITS + 1)}
MAIN = f"{1:040x}"


def sha(n):
    return f"{0xb0000 + n:040x}"


def stamp(days):
    return (NOW - dt.timedelta(days=days)).strftime("%Y-%m-%dT%H:%M:%S.000Z")


class FakeBucket:
    def __init__(self, files=None, bodies=None, complete=True):
        self.objects = []
        self.bodies = dict(bodies or {})
        self.complete = complete
        self.deleted = []
        for key, days in (files or {}).items():
            self.objects.append({"key": key, "size": 10, "last_modified": stamp(days)})
        for key in self.bodies:
            if not any(item["key"] == key for item in self.objects):
                self.objects.append({"key": key, "size": 1, "last_modified": stamp(30)})

    def add_build(self, family, commit, days):
        for name in ("cmux-tui-x86_64-unknown-linux-musl", "manifest.json"):
            self.objects.append({"key": f"{family}/{commit}/{name}", "size": 10, "last_modified": stamp(days)})

    def list(self):
        return list(self.objects), self.complete

    def read(self, key):
        if key not in self.bodies:
            raise urllib.error.HTTPError(key, 404, "Not Found", {}, None)
        return self.bodies[key]

    def delete(self, key):
        self.deleted.append(key)


def run(bucket, delete=True, pins=()):
    return prune.prune(bucket, NOW, trunk=TRUNK, pins=set(pins), delete=delete)


class Prune(unittest.TestCase):
    def test_an_old_unpinned_branch_head_is_deleted_metadata_first(self):
        bucket = FakeBucket()
        bucket.add_build("cmux-tui", sha(1), 20)
        summary = run(bucket)
        self.assertEqual(bucket.deleted, [f"cmux-tui/{sha(1)}/manifest.json",
                                          f"cmux-tui/{sha(1)}/cmux-tui-x86_64-unknown-linux-musl"])
        self.assertEqual(summary["deleted_objects"], 2)

    def test_dry_run_deletes_nothing(self):
        bucket = FakeBucket()
        bucket.add_build("cmux-relay", sha(1), 20)
        summary = run(bucket, delete=False)
        self.assertEqual(bucket.deleted, [])
        self.assertEqual(summary["candidates"]["cmux-relay"][0], 1)

    def test_trunk_pinned_recent_latest_and_tree_source_commits_are_kept(self):
        bucket = FakeBucket(bodies={
            "cmux-tui/latest/manifest.json": json.dumps({"commit": sha(4)}),
            "cmux-tui/tree/v2-abc/source.json": json.dumps({"commit": sha(5), "family": "branch"}),
            "cmux-tui/tree/v2-abc/completion-windows.json": json.dumps({"sourceCommit": sha(9)}),
        })
        bucket.add_build("cmux-tui", MAIN, 400)
        bucket.add_build("cmux-tui", sha(2), 90)
        bucket.add_build("cmux-tui", sha(3), 13)
        bucket.add_build("cmux-tui", sha(4), 90)
        bucket.add_build("cmux-tui", sha(5), 90)
        bucket.add_build("cmux-tui-windows", sha(5), 90)
        bucket.add_build("cmux-tui-windows", sha(9), 90)
        run(bucket, pins=[sha(2)])
        self.assertEqual(bucket.deleted, [])

    def test_a_kept_relay_keeps_its_cmux_tui_prefix(self):
        bucket = FakeBucket(bodies={"chatmux-relay/latest/manifest.json": json.dumps({"commit": sha(6)})})
        bucket.add_build("chatmux-relay", sha(6), 90)
        bucket.add_build("cmux-tui", sha(6), 90)
        bucket.add_build("chatmux-relay", sha(7), 90)
        bucket.add_build("cmux-tui", sha(7), 90)
        run(bucket)
        self.assertEqual({key.split("/")[1] for key in bucket.deleted}, {sha(7)})

    def test_other_prefixes_and_trees_are_never_touched(self):
        bucket = FakeBucket(files={
            "mux/latest/cmux-mux-linux": 400, f"mux/{sha(8)}/cmux-mux-linux": 400,
            "cmux-next-web/abc/manifest.json": 400, "nightly/appcast.xml": 400,
            "cmux-tui/tree/v2-old/cmux-tui-aarch64-apple-darwin": 400,
            "cmux-tui/latest/cmux-tui-x86_64-unknown-linux-musl": 400,
        }, bodies={"cmux-tui/latest/manifest.json": json.dumps({"commit": MAIN})})
        run(bucket)
        self.assertEqual(bucket.deleted, [])

    def test_the_cap_takes_whole_prefixes_oldest_first(self):
        bucket = FakeBucket()
        for n, days in ((1, 20), (2, 40), (3, 30)):
            bucket.add_build("cmux-relay", sha(n), days)
        limit, prune.MAX_DELETES = prune.MAX_DELETES, 5
        try:
            summary = run(bucket)
        finally:
            prune.MAX_DELETES = limit
        self.assertEqual([key.split("/")[1] for key in bucket.deleted], [sha(2)] * 2 + [sha(3)] * 2)
        self.assertTrue(summary["capped"])

    def test_it_refuses_on_a_shallow_trunk_an_incomplete_listing_or_an_unreadable_latest(self):
        bucket = FakeBucket(complete=False)
        bucket.add_build("cmux-tui", sha(1), 20)
        with self.assertRaises(RuntimeError):
            run(bucket)
        with self.assertRaises(RuntimeError):
            prune.prune(FakeBucket(), NOW, trunk=set(list(TRUNK)[:10]), pins=set(), delete=True)
        broken = FakeBucket(bodies={"cmux-tui/latest/manifest.json": "{}"})
        broken.add_build("cmux-tui", sha(1), 20)
        with self.assertRaises(RuntimeError):
            run(broken)
        self.assertEqual(bucket.deleted + broken.deleted, [])


class Main(unittest.TestCase):
    def test_an_empty_pin_history_stops_the_run(self):
        with tempfile.TemporaryDirectory() as tmp:
            trunk, pins = Path(tmp, "trunk"), Path(tmp, "pins")
            trunk.write_text("\n".join(TRUNK))
            pins.write_text("")
            with self.assertRaises(SystemExit):
                prune.main(["--endpoint-url", "https://r2.invalid", "--trunk-commits", str(trunk),
                            "--pin-file", str(pins)])


class Workflow(unittest.TestCase):
    def test_only_main_prunes_and_only_on_an_explicit_opt_in(self):
        workflow = yaml.safe_load((ROOT / ".github/workflows/r2-binaries-prune.yml").read_text())
        triggers = workflow.get("on", workflow.get(True))
        self.assertEqual(set(triggers), {"schedule", "workflow_dispatch"})
        self.assertEqual(workflow["permissions"], {})
        job = workflow["jobs"]["prune"]
        self.assertIn("github.ref == 'refs/heads/main'", job["if"])
        self.assertEqual(job["environment"], "artifacts")
        run_step = next(step for step in job["steps"] if "cmux_binaries_prune.py" in str(step.get("run", "")))
        self.assertIn("--delete", run_step["run"])
        condition = run_step["env"]["PRUNE_DELETE"]
        pins_step = next(step for step in job["steps"] if "pins.txt" in str(step.get("run", "")))
        self.assertIn("git log -p", pins_step["run"])
        self.assertNotIn("|| true", pins_step["run"])
        self.assertIn("vars.R2_BINARIES_PRUNE_DELETE == '1'", condition)
        self.assertIn("inputs.delete", condition)


if __name__ == "__main__":
    unittest.main()
