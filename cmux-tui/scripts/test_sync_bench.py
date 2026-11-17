"""Tests of sync_bench.py's pure parts: the pinned spec, the seeded content, scenario c's put-back and the tables.

The pushes themselves need a Linux host with sudo (a mount and a network namespace); `sync-bench run` is the end-to-end
check, on the bench host.
"""
import importlib.util
import os
import random
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("sync_bench", HERE / "sync_bench.py")
sb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sb)


def record(commit, rows, tree=None, layout="projects", rtt=0):
    return {"commit": commit, "binary_source": "ci", "layout": layout, "rtt_ms": rtt, "tree": tree or sb.tree_id(),
            "started": "2026-11-17T08:00:00Z", "host": {"host": "bench"}, "scenarios": rows}


def pushed(wall, hashing, written, unchanged, cpu=1000):
    return {"exit": 0, "wall_ms": wall, "cpu_ms": cpu, "max_rss_mb": 50,
            "summary": {"written": written, "unchanged": unchanged, "bytes": 1 << 30, "skipped_counts": {}},
            "timings": {"list": 10, "hash": hashing, "prepare": 20, "small": 30, "large": 40, "finish": 50}}


class Spec(unittest.TestCase):
    def test_every_repository_is_pinned_by_a_full_sha(self):
        for name, url, commit, depth in sb.REPOS:
            self.assertRegex(commit, r"^[0-9a-f]{40}$", name)
            self.assertTrue(url.startswith("https://github.com/"), url)
            self.assertIn(depth, (1, None))

    def test_the_tree_goes_past_the_first_pass_limit(self):
        media = sum(size for _, size in sb.MEDIA)
        # The media alone are 16 GiB; the repositories and notes take the copy past 20 GiB (MAX_BYTES).
        self.assertGreaterEqual(media, 16 * sb.GIB)
        self.assertGreater(sb.NOTES + sb.WEB_SRC, 40_000)

    def test_the_tree_id_is_stable_and_follows_the_spec(self):
        self.assertEqual(sb.tree_id(), sb.tree_id())
        old = sb.NOTES
        try:
            sb.NOTES = old + 1
            changed = sb.tree_id()
        finally:
            sb.NOTES = old
        self.assertNotEqual(changed, sb.tree_id())

    def test_seeded_text_is_the_same_every_time(self):
        a = sb.text_bytes(random.Random(7), 5000)
        b = sb.text_bytes(random.Random(7), 5000)
        self.assertEqual(a, b)
        self.assertGreaterEqual(len(a), 4000)

    def test_small_files_land_where_the_edit_set_names_them(self):
        with tempfile.TemporaryDirectory() as tmp:
            top = Path(tmp)
            sb.write_small_files(top / "notes", 20, 1, 400)
            sb.write_small_files(top / "files", 25, 5, 2500)
            touch, edit = sb.edit_set("projects")
            for rel in touch + edit:
                if rel.startswith("notes/"):
                    self.assertTrue((top / rel).is_file(), rel)
            touch, edit = sb.edit_set("flat")
            self.assertEqual((len(touch), len(edit)), (sb.CHANGED, sb.CHANGED))
            for rel in touch + edit:
                self.assertTrue((top / rel).is_file(), rel)
            self.assertEqual(os.stat(top / touch[0]).st_mtime, sb.EPOCH)


class Changed(unittest.TestCase):
    def test_touches_and_edits_are_put_back_exactly(self):
        with tempfile.TemporaryDirectory() as tmp:
            top = Path(tmp)
            sb.write_small_files(top / "files", 25, 5, 2500)
            touch, edit = sb.edit_set("flat")
            before = {rel: ((top / rel).read_bytes(), (top / rel).stat().st_mtime_ns) for rel in touch + edit}
            with sb.changed(top, "flat") as counts:
                self.assertEqual(counts, (10, 10))
                self.assertNotEqual((top / edit[0]).read_bytes(), before[edit[0]][0])
                self.assertEqual((top / touch[0]).read_bytes(), before[touch[0]][0])
                self.assertNotEqual((top / touch[0]).stat().st_mtime_ns, before[touch[0]][1])
            after = {rel: ((top / rel).read_bytes(), (top / rel).stat().st_mtime_ns) for rel in touch + edit}
            self.assertEqual(before, after)


class Tables(unittest.TestCase):
    def test_a_run_table_has_a_row_per_scenario_and_says_what_was_not_run(self):
        text = sb.table(record("a" * 40, {"a": pushed(60_000, 20_000, 400_000, 0), "e": {"not_run": "no store"}}))
        self.assertIn("| a cold whole | ok | 60.0 |", text)
        self.assertIn("| e --store | not run |", text)
        self.assertNotIn("b nothing changed", text)

    def test_compare_gives_head_over_base(self):
        base = record("b" * 40, {"b": pushed(30_000, 25_000, 0, 400_000)})
        head = record("c" * 40, {"b": pushed(3_000, 0, 0, 400_000)})
        text = sb.compare(base, head)
        self.assertIn("| b nothing changed | 30.0 | 3.0 | 0.10x | 25.0 | 0.0 |", text)

    def test_runs_of_different_trees_do_not_compare(self):
        base = record("b" * 40, {}, tree="one")
        head = record("c" * 40, {}, tree="two")
        self.assertIn("not comparable", sb.compare(base, head))

    def test_a_failed_push_shows_its_exit(self):
        row = dict(pushed(1000, 0, 0, 0), exit=1)
        self.assertEqual(sb.row_cells(row)[0], "exit 1")


if __name__ == "__main__":
    unittest.main()
