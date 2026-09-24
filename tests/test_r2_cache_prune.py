#!/usr/bin/env python3
"""Pruning the CI cache bucket must never delete what a prefix restore reads."""
import datetime as dt
from pathlib import Path
import sys
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/ci"))
import r2_cache_prune as prune  # noqa: E402

NOW = dt.datetime(2026, 9, 24, tzinfo=dt.timezone.utc)
NS = "v1/macOS-ARM64"


def stamp(days):
    return (NOW - dt.timedelta(days=days)).strftime("%Y-%m-%dT%H:%M:%S.000Z")


class FakeBucket:
    def __init__(self, archives, pointers, complete=True):
        self.objects = [{"key": key, "size": size, "last_modified": stamp(age)} for key, size, age in archives]
        self.pointers = dict(pointers)
        self.objects += [{"key": key, "size": 64, "last_modified": stamp(90)} for key in self.pointers]
        self.complete = complete
        self.deleted = []
        self.on_first_delete = None

    def list(self):
        return list(self.objects), self.complete

    def read(self, key):
        return self.pointers[key] + "\n"

    def delete(self, key):
        if self.on_first_delete and not self.deleted:
            self.on_first_delete(self)
        self.deleted.append(key)


def archive(name, age, size=10, ext="tar.zst"):
    return (f"{NS}/objects/{name}.{ext}", size, age)


class Prune(unittest.TestCase):
    def test_dry_run_reports_and_deletes_nothing(self):
        bucket = FakeBucket([archive("spm-old", 40), archive("spm-new", 1)], {})
        summary = prune.prune(bucket, NOW, delete=False)
        self.assertEqual((summary["would_delete"], summary["would_delete_bytes"]), (1, 10))
        self.assertEqual(bucket.deleted, [])

    def test_each_family_ages_out_on_its_own_retention(self):
        bucket = FakeBucket([
            archive("admission-derived-data-v1-macOS-ARM64-fp-a", 2),
            archive("admission-derived-data-v1-macOS-ARM64-fp-b", 0.5),
            archive("xcode-compilation-test-macOS-ARM64-fp-a", 2),
            archive("xcode-compilation-test-macOS-ARM64-fp-b", 0.5),
            archive("spm-a", 31),
            archive("spm-b", 29),
            archive("spm-c", 2),
        ], {})
        prune.prune(bucket, NOW, delete=True)
        self.assertEqual(sorted(bucket.deleted), sorted([
            f"{NS}/objects/admission-derived-data-v1-macOS-ARM64-fp-a.tar.zst",
            f"{NS}/objects/xcode-compilation-test-macOS-ARM64-fp-a.tar.zst",
            f"{NS}/objects/spm-a.tar.zst",
        ]))

    def test_an_archive_a_pointer_names_is_kept_at_any_age_in_either_format(self):
        bucket = FakeBucket(
            [archive("spm-pinned", 400), archive("zig-pinned", 400, ext="tar.gz"), archive("spm-orphan", 400)],
            {f"{NS}/latest/spm-": "spm-pinned", f"{NS}/latest/zig-": "zig-pinned"},
        )
        summary = prune.prune(bucket, NOW, delete=True)
        self.assertEqual(bucket.deleted, [f"{NS}/objects/spm-orphan.tar.zst"])
        self.assertEqual(summary["families"]["other"]["kept_by_pointer"], 2)

    def test_pointers_and_foreign_keys_are_never_candidates(self):
        bucket = FakeBucket([("github/manaflow-ai/cmux/1/product.zip", 10, 400),
                             (f"{NS}/objects/nested/escape.tar.zst", 10, 400)],
                            {f"{NS}/latest/spm-": "spm-gone"})
        prune.prune(bucket, NOW, delete=True)
        self.assertEqual(bucket.deleted, [])

    def test_a_pointer_moved_onto_an_old_archive_mid_run_protects_it(self):
        bucket = FakeBucket([archive("spm-a", 40), archive("spm-b", 41)], {f"{NS}/latest/spm-": "spm-new"})
        # r2-cache.sh re-points latest/ at an existing key without re-uploading.
        bucket.on_first_delete = None
        original = bucket.read
        reads = []

        def read(key):
            reads.append(key)
            if len(reads) > 1:
                return "spm-a\n"
            return original(key)

        bucket.read = read
        prune.prune(bucket, NOW, delete=True)
        self.assertEqual(bucket.deleted, [f"{NS}/objects/spm-b.tar.zst"])

    def test_an_incomplete_listing_or_bad_pointer_deletes_nothing(self):
        bucket = FakeBucket([archive("spm-old", 400)], {}, complete=False)
        self.assertFalse(prune.prune(bucket, NOW, delete=True)["complete"])
        self.assertEqual(bucket.deleted, [])
        bucket = FakeBucket([archive("spm-old", 400)], {f"{NS}/latest/spm-": "../../etc"})
        with self.assertRaises(RuntimeError):
            prune.prune(bucket, NOW, delete=True)
        self.assertEqual(bucket.deleted, [])

    def test_one_run_is_bounded(self):
        limit = prune.MAX_DELETES
        try:
            prune.MAX_DELETES = 2
            bucket = FakeBucket([archive(f"spm-{i}", 40 + i) for i in range(5)], {})
            prune.prune(bucket, NOW, delete=True)
            # Oldest first.
            self.assertEqual(bucket.deleted, [f"{NS}/objects/spm-4.tar.zst", f"{NS}/objects/spm-3.tar.zst"])
        finally:
            prune.MAX_DELETES = limit


class Workflow(unittest.TestCase):
    def test_only_main_prunes_and_only_on_an_explicit_opt_in(self):
        workflow = yaml.safe_load((ROOT / ".github/workflows/r2-cache-prune.yml").read_text())
        triggers = workflow.get("on", workflow.get(True))
        self.assertEqual(set(triggers), {"schedule", "workflow_dispatch"})
        self.assertEqual(workflow["permissions"], {})
        job = workflow["jobs"]["prune"]
        self.assertIn("github.ref == 'refs/heads/main'", job["if"])
        self.assertEqual(job["permissions"], {"contents": "read"})
        self.assertNotIn("macos", str(job["runs-on"]).lower())
        run = next(step for step in job["steps"] if "r2_cache_prune.py" in str(step.get("run", "")))
        # Deletes need a dispatch that says so, or the repository variable.
        self.assertIn("--delete", run["run"])
        self.assertIn("PRUNE_DELETE", run["run"])
        condition = run["env"]["PRUNE_DELETE"]
        self.assertIn("vars.CI_R2_CACHE_PRUNE_DELETE == '1'", condition)
        self.assertIn("inputs.delete", condition)


if __name__ == "__main__":
    unittest.main()
