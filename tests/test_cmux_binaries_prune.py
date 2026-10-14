#!/usr/bin/env python3
"""The cmux-binaries pruner deletes only unpinned, old branch-head prefixes, metadata first."""
import datetime as dt
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock
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

    def read_bytes(self, key):
        return self.bodies.get(key, f"bytes of {key}").encode()

    def delete(self, key):
        self.deleted.append(key)


def run(bucket, delete=True, pins=(), windows=(), cold_out=None):
    return prune.prune(bucket, NOW, trunk=TRUNK, pins=set(pins), delete=delete, windows=list(windows),
                       cold_out=cold_out, signer=lambda method, key: f"https://signed/{method}/{key}")


def trunk(n):
    return f"{n:040x}"


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
        bucket.add_build("cmux-tui", MAIN, 20)
        bucket.add_build("cmux-tui", sha(2), 90)
        bucket.add_build("cmux-tui", sha(3), 13)
        bucket.add_build("cmux-tui", sha(4), 90)
        bucket.add_build("cmux-tui", sha(5), 90)
        bucket.add_build("cmux-tui-windows", sha(5), 90)
        bucket.add_build("cmux-tui-windows", sha(9), 90)
        run(bucket, pins=[sha(2)])
        self.assertEqual(bucket.deleted, [])

    def test_a_kept_relay_keeps_its_cmux_tui_prefix(self):
        # chatmux-relay's manifest names its commit only as sourceCommit.
        bucket = FakeBucket(bodies={"chatmux-relay/latest/manifest.json": json.dumps(
            {"schemaVersion": 1, "sourceCommit": sha(6), "version": f"0.0.0-r2.sha-{sha(6)}"})})
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


class TrunkRule(unittest.TestCase):
    def test_old_trunk_builds_keep_one_snapshot_a_day_and_the_rest_go(self):
        bucket = FakeBucket()
        bucket.add_build("cmux-tui", trunk(10), 40.2)   # same UTC day, older
        bucket.add_build("cmux-tui", trunk(11), 40.1)   # that day's newest: cold
        bucket.add_build("cmux-tui", trunk(12), 29)     # under 30 days: kept
        summary = run(bucket)
        self.assertEqual({key.split("/")[1] for key in bucket.deleted}, {trunk(10)})
        self.assertEqual(summary["cold"]["cmux-tui"][0], 1)

    def test_the_newest_published_commits_behind_a_shipped_build_stay(self):
        bucket = FakeBucket()
        for n in range(20, 26):
            bucket.add_build("cmux-tui", trunk(n), 60 + n / 100)
        # A shipped nightly-next build's window, newest first; 21 was never published.
        window = [trunk(30), trunk(21 + 100), trunk(25), trunk(24), trunk(23), trunk(22)]
        run(bucket, windows=[window])
        deleted = {key.split("/")[1] for key in bucket.deleted}
        self.assertTrue({trunk(25), trunk(24), trunk(23)}.isdisjoint(deleted))
        self.assertIn(trunk(22), deleted)  # fourth in the window, not the day's snapshot

    def test_cold_prefixes_are_queued_with_sha256_and_a_private_delete_list_only_when_deleting(self):
        bucket = FakeBucket()
        bucket.add_build("cmux-tui", trunk(40), 50)
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp, "cold")
            run(bucket, delete=False, cold_out=out)
            self.assertFalse(out.exists())
            summary = run(bucket, cold_out=out)
            queue = json.loads((out / "queue.json").read_text())
            deletes = json.loads((out / "deletes.json").read_text())
            mode = (out / "deletes.json").stat().st_mode & 0o777
        self.assertEqual(summary["cold_queued"][0], 1)
        objects = queue["groups"][0]["objects"]
        self.assertEqual(objects[0]["key"], f"cmux-tui/{trunk(40)}/manifest.json")
        key = objects[0]["key"]
        self.assertEqual(objects[0]["sha256"], hashlib.sha256(f"bytes of {key}".encode()).hexdigest())
        self.assertEqual(deletes[key], f"https://signed/DELETE/{key}")
        self.assertNotIn("signed", json.dumps(queue))
        self.assertEqual(mode, 0o600)
        self.assertEqual(bucket.deleted, [])  # cold prefixes stay until the host has both copies

    def test_presigned_urls_are_scoped_to_one_object_and_expire(self):
        env = {"AWS_ACCESS_KEY_ID": "AK", "AWS_SECRET_ACCESS_KEY": "SK"}
        with mock.patch.dict(prune.os.environ, env):
            url = prune.presign("DELETE", "https://acct.r2.cloudflarestorage.com", "cmux-binaries",
                                "cmux-tui/abc/manifest.json", now=NOW)
        self.assertTrue(url.startswith("https://acct.r2.cloudflarestorage.com/cmux-binaries/cmux-tui/abc/manifest.json?"))
        self.assertIn("X-Amz-Expires=604800", url)
        self.assertIn("X-Amz-SignedHeaders=host", url)
        self.assertRegex(url, r"X-Amz-Signature=[0-9a-f]{64}$")
        self.assertNotIn("SK", url)


class ColdSnapshots(unittest.TestCase):
    def test_a_cold_relay_keeps_its_cmux_tui_beside_it(self):
        bucket = FakeBucket()
        # The relay of the day's newest cmux-tui commit landed earlier than another commit's relay.
        bucket.add_build("cmux-tui", trunk(50), 40.10)
        bucket.add_build("chatmux-relay", trunk(50), 40.30)
        bucket.add_build("cmux-tui", trunk(51), 40.20)
        bucket.add_build("chatmux-relay", trunk(51), 40.15)
        summary = run(bucket)
        self.assertEqual({key.split("/")[1] for key in bucket.deleted}, {trunk(51)})
        self.assertEqual((summary["cold"]["cmux-tui"][0], summary["cold"]["chatmux-relay"][0]), (1, 1))

    def test_a_prefix_without_a_manifest_takes_no_window_slot(self):
        bucket = FakeBucket()
        for n in (60, 61, 62, 63):
            bucket.add_build("cmux-tui", trunk(n), 70 + n / 1000)
        bucket.objects = [o for o in bucket.objects if o["key"] != f"cmux-tui/{trunk(60)}/manifest.json"]
        run(bucket, windows=[[trunk(60), trunk(61), trunk(62), trunk(63)]])
        self.assertNotIn(trunk(63), {key.split("/")[1] for key in bucket.deleted})


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
        self.assertIn("windows.txt", pins_step["run"])
        self.assertIn("nightly-next", pins_step["run"])
        # A shipped classic nightly also downloads its bundled cmux-tui build's
        # Linux SSH payloads at runtime, so its builds get the same window.
        self.assertIn("for release in nightly-next nightly", pins_step["run"])
        self.assertIn("cmux-nightly(-next)?-macos-", pins_step["run"])
        # The presigned deletes leave the runner only encrypted to the host's certificate.
        publish = next(step for step in job["steps"] if step.get("name") == "Publish the cold queue")
        script = publish["run"]
        self.assertLess(script.index("openssl smime -encrypt"), script.index("upload-r2-object.py"))
        self.assertLess(script.index('rm -f "$cold/deletes.json"'), script.index("upload-r2-object.py"))
        self.assertIn("for name in deletes.p7m queue.json", script)
        # A run that queues nothing replaces the last queue with an empty one.
        self.assertIn("always()", publish["if"])
        self.assertIn('"groups": []', script)
        self.assertIn("vars.R2_BINARIES_PRUNE_DELETE == '1'", condition)
        # A dispatch decides by its input alone: delete=false is a dry run even when the variable is on.
        self.assertIn("github.event_name == 'workflow_dispatch' && inputs.delete", condition)
        self.assertIn("github.event_name == 'schedule' && vars.R2_BINARIES_PRUNE_DELETE == '1'", condition)
        self.assertIn("inputs.delete", condition)


if __name__ == "__main__":
    unittest.main()
