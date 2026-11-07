#!/usr/bin/env python3
"""Tests of the judge goldens runner (judge_goldens.py; REWRITE R-HARNESS stage S1, rule R8). No app, no fleet.

    /work/tmp/bv-venv/bin/python -I scripts/journeys/test_judge_goldens.py

Each test makes a small store of films in a temporary folder and a stand-in judges folder (three judge modules with
the real call signatures), so the runner is tested without the real judges' run time. The last test runs the real
video_judge.py on one film made from a fixture, so the real judge goes through the runner once.
"""
import contextlib
import io
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import judge_goldens as jg  # noqa: E402

# Stand-in judges: the real modules' names and call signatures; each result depends on the film's files only.
STUB_VIDEO = '''
import json
from pathlib import Path
SHIFT = 0
def judge(base, movie=True):
    frames = json.loads(Path(str(base) + ".mov.frames.json").read_text())["frames"]
    n = len(frames) + SHIFT
    return {"case": Path(str(base)).name, "base": str(base), "frames": n, "dropped": n % 3, "motion": [[0.0, 1.0]],
            "findings": [{"check": "dropped frames", "severity": "defect", "frames": [1, 2], "t": [0.1234567891, 0.2]}],
            "notes": [], "pacing": {"trace": False}}
'''
STUB_TRACE = '''
import json
def load_trace(path):
    return json.loads(open(path).read())
def judge(trace, frames=None, scale=2.0, events=None):
    return {"counts": {"dropped": len(trace.get("samples", []))}, "defects": [], "motions": [], "split": None,
            "scale_seen": scale}
'''
STUB_KEYS = '''
def judge(base):
    return {"case": base.rsplit("/", 1)[-1], "presses": 0, "items": [], "faults": [], "no_motion": []}
'''
STUB_SCAN = '''
import argparse, json, sys
ap = argparse.ArgumentParser()
ap.add_argument("scan"); ap.add_argument("--trace"); ap.add_argument("--scale"); ap.add_argument("--json")
o = ap.parse_args()
json.dump({"frames": len(open(o.scan, "rb").read()), "counts": {}, "defects": [], "scale": o.scale}, open(o.json, "w"))
sys.exit(0)
'''


def write_judges(root, video=STUB_VIDEO, trace=STUB_TRACE, keys=STUB_KEYS, scan=STUB_SCAN):
    root = Path(root)
    (root / "video-cases").mkdir(parents=True, exist_ok=True)
    (root / "video_judge.py").write_text(textwrap.dedent(video))
    (root / "video-cases" / "judge_trace.py").write_text(textwrap.dedent(trace))
    (root / "video-cases" / "judge_keys.py").write_text(textwrap.dedent(keys))
    (root / "video-cases" / "judge_scan.py").write_text(textwrap.dedent(scan))
    # The judges' unit tests run with every `run` (the TRUTH tier): stand-in judges carry one passing test.
    (root / "test_video_judge.py").write_text("import unittest\nclass T(unittest.TestCase):\n"
                                              "    def test_ok(self): self.assertTrue(True)\n"
                                              "if __name__ == '__main__':\n    unittest.main()\n")
    return root


def write_film(folder, name, frames=4, scale=2, samples=3):
    folder = Path(folder)
    folder.mkdir(parents=True, exist_ok=True)
    base = folder / name
    (folder / f"{name}.mov.frames.json").write_text(json.dumps({"frames": [[100.0 + i / 120, "complete", True]
                                                                           for i in range(frames)]}))
    (folder / f"{name}.trace.json").write_text(json.dumps({"t0_s": 100.0, "refresh_ms": 8.33,
                                                            "samples": [{"t": i * 8.33} for i in range(samples)]}))
    (folder / f"{name}.events.json").write_text(json.dumps({"hid": [], "journal": []}))
    (folder / f"{name}.meta.json").write_text(json.dumps({"start": {"scale": scale}}))
    (folder / f"{name}.mov.scan").write_bytes(b'{"width": 1, "height": 1, "rows": [0], "columns": []}\n' + bytes(frames))
    (folder / f"{name}.view.mp4").write_bytes(b"derived media: not judged, not copied")
    return base


class Workspace:
    """A gallery, a store and a manifest folder in one temporary folder."""

    def __init__(self):
        self.tmp = tempfile.mkdtemp(prefix="judge-goldens-test-")
        self.root = Path(self.tmp)
        self.gallery = self.root / "gallery"
        self.store = self.root / "store"
        self.manifest = self.root / "manifest"
        self.judges = write_judges(self.root / "judges")
        write_film(self.gallery / "build-a-120x2", "col-drag", frames=5)
        write_film(self.gallery / "build-a-120x2", "col-drag-slow", frames=7)
        write_film(self.gallery / "build-b-120x1", "rk-held", frames=9, scale=1)

    def close(self):
        for path, dirs, files in os.walk(self.tmp):
            os.chmod(path, 0o755)
            for name in files:
                os.chmod(os.path.join(path, name), 0o644)
        shutil.rmtree(self.tmp, ignore_errors=True)

    def cli(self, *args):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = jg.guarded_main([args[0], "--store", str(self.store), "--manifest", str(self.manifest), *args[1:]])
        return code, out.getvalue() + err.getvalue()

    def snapshot(self):
        code, out = self.cli("snapshot", "--source", str(self.gallery), "--settled-minutes", "0")
        truth = self.manifest / "truth.json"
        if self.manifest.is_dir() and not truth.exists():  # a manifest has its TRUTH tier, empty or not
            truth.write_text(json.dumps({"v": 1, "facts": []}))
        return code, out

    def bless(self, judges=None, reason="test bless"):
        return self.cli("bless", "--judges", str(judges or self.judges), "--reason", reason, "--jobs", "2",
                        "--no-git-check")

    def run(self, judges=None, *extra):
        return self.cli("run", "--judges", str(judges or self.judges), "--jobs", "2", *extra)


class NormalizeTests(unittest.TestCase):
    def test_paths_are_rooted_and_floats_rounded(self):
        got = jg.normalize({"base": "/store/a/b", "t": [0.1234567891, -0.0], "n": 3, "s": "/store/x/y", "nested": {"v": 1.5}},
                           roots=["/store"])
        self.assertEqual(got["base"], "<root>/a/b")
        self.assertEqual(got["t"], [0.123457, 0.0])
        self.assertEqual(got["s"], "<root>/x/y")
        self.assertEqual(got["nested"], {"v": 1.5})

    def test_the_digest_does_not_depend_on_key_order(self):
        self.assertEqual(jg.digest({"a": 1, "b": [1, 2]}), jg.digest({"b": [1, 2], "a": 1}))
        self.assertNotEqual(jg.digest({"a": 1}), jg.digest({"a": 2}))

    def test_nan_and_infinity_are_named(self):
        got = jg.normalize({"x": float("nan"), "y": float("inf")}, roots=[])
        self.assertEqual(got, {"x": "NaN", "y": "Infinity"})


class SnapshotTests(unittest.TestCase):
    def setUp(self):
        self.w = Workspace()

    def tearDown(self):
        self.w.close()

    def test_snapshot_copies_the_judged_files_read_only_and_records_their_hashes(self):
        code, out = self.w.snapshot()
        self.assertEqual(code, 0, out)
        films = json.loads((self.w.manifest / "films.json").read_text())
        self.assertEqual(sorted(films["films"]), ["build-a-120x2/col-drag", "build-a-120x2/col-drag-slow",
                                                  "build-b-120x1/rk-held"])
        copied = self.w.store / "films" / "build-a-120x2" / "col-drag.mov.frames.json"
        self.assertTrue(copied.is_file())
        self.assertFalse(os.stat(copied).st_mode & (stat.S_IWUSR | stat.S_IWGRP | stat.S_IWOTH))
        self.assertFalse((self.w.store / "films" / "build-a-120x2" / "col-drag.view.mp4").exists())
        files = jg.files_table(self.w.store, films)["build-a-120x2"]
        self.assertEqual(files["col-drag.mov.frames.json"][1], jg.sha256_file(copied))

    def test_a_second_snapshot_of_the_same_films_changes_nothing(self):
        self.assertEqual(self.w.snapshot()[0], 0)
        before = (self.w.manifest / "films.json").read_text()
        code, out = self.w.snapshot()
        self.assertEqual(code, 0, out)
        self.assertEqual((self.w.manifest / "films.json").read_text(), before)

    def test_a_folder_a_round_still_writes_is_taken_later(self):
        code, out = self.w.cli("snapshot", "--source", str(self.w.gallery), "--settled-minutes", "60")
        self.assertEqual(code, 0, out)
        self.assertIn("later: build-a-120x2", out)
        self.assertEqual(json.loads((self.w.manifest / "films.json").read_text())["films"], {})

    def test_a_new_film_in_a_recorded_folder_is_added_and_the_old_files_stay(self):
        self.assertEqual(self.w.snapshot()[0], 0)
        write_film(self.w.gallery / "build-a-120x2", "col-drag-fast", frames=3)
        code, out = self.w.snapshot()
        self.assertEqual(code, 0, out)
        films = json.loads((self.w.manifest / "films.json").read_text())
        self.assertIn("build-a-120x2/col-drag-fast", films["films"])
        self.assertIn("col-drag.trace.json", jg.files_table(self.w.store, films)["build-a-120x2"])

    def test_a_changed_source_film_is_refused_the_store_is_immutable(self):
        self.assertEqual(self.w.snapshot()[0], 0)
        src = self.w.gallery / "build-a-120x2" / "col-drag.trace.json"
        src.write_text(json.dumps({"t0_s": 1.0, "samples": []}))
        code, out = self.w.snapshot()
        self.assertEqual(code, 2, out)
        self.assertIn("immutable", out)


class RunTests(unittest.TestCase):
    def setUp(self):
        self.w = Workspace()
        self.assertEqual(self.w.snapshot()[0], 0)
        code, out = self.w.bless()
        self.assertEqual(code, 0, out)

    def tearDown(self):
        self.w.close()

    def test_unchanged_judges_reproduce_every_golden(self):
        code, out = self.w.run()
        self.assertEqual(code, 0, out)
        self.assertIn("reproduced 12 of 12", out)

    def test_a_changed_judge_result_is_a_difference_with_the_film_and_the_judge(self):
        changed = write_judges(self.w.root / "judges-changed", video=STUB_VIDEO.replace("SHIFT = 0", "SHIFT = 1"))
        code, out = self.w.run(changed)
        self.assertEqual(code, 1, out)
        self.assertIn("reproduced 9 of 12", out)
        self.assertIn("video_judge build-a-120x2/col-drag", out)
        self.assertIn("dropped", out)

    def test_a_judge_that_raises_is_a_result_not_a_crash_of_the_runner(self):
        broken = write_judges(self.w.root / "judges-broken", keys="def judge(base):\n    raise ValueError('boom')\n")
        code, out = self.w.run(broken)
        self.assertEqual(code, 1, out)
        self.assertIn("ValueError: boom", out)

    def test_a_judge_module_that_does_not_load_is_no_verdict_not_a_difference(self):
        broken = write_judges(self.w.root / "judges-unloadable", video="raise ImportError('half a file')\n")
        code, out = self.w.run(broken)
        self.assertEqual(code, 2, out)
        self.assertIn("NO VERDICT", out)
        self.assertIn("ImportError: half a file", out)

    def test_a_worker_that_dies_is_no_verdict_not_a_difference(self):
        dying = write_judges(self.w.root / "judges-dying", trace="import os\ndef load_trace(p):\n    os._exit(9)\n"
                                                                  "def judge(*a):\n    return {}\n")
        code, out = self.w.run(dying)
        self.assertEqual(code, 2, out)
        self.assertIn("NO VERDICT", out)
        self.assertIn("ended with code 9 and no result", out)

    def test_a_changed_store_file_is_no_verdict(self):
        f = self.w.store / "films" / "build-b-120x1" / "rk-held.events.json"
        os.chmod(f, 0o644)
        f.write_text(json.dumps({"hid": [], "journal": [{"seq": 1}]}))
        code, out = self.w.run()
        self.assertEqual(code, 2, out)
        self.assertIn("NO VERDICT", out)
        self.assertIn("rk-held.events.json", out)

    def test_a_missing_store_file_is_no_verdict(self):
        f = self.w.store / "films" / "build-a-120x2" / "col-drag.meta.json"
        os.chmod(f.parent, 0o755)
        os.remove(f)
        code, out = self.w.run()
        self.assertEqual(code, 2, out)
        self.assertIn("NO VERDICT", out)

    def test_a_changed_files_table_is_no_verdict(self):
        films = json.loads((self.w.manifest / "films.json").read_text())
        table = self.w.store / "tables" / f"{films['files_table']}.json"
        os.chmod(table, 0o644)
        table.write_text(table.read_text().replace('"build-b-120x1"', '"build-c-120x1"'))
        code, out = self.w.run()
        self.assertEqual(code, 2, out)
        self.assertIn("does not hash to its name", out)

    def test_a_changed_blessed_result_is_not_read_as_the_blessed_one(self):
        expected = json.loads((self.w.manifest / "expected.json").read_text())
        sha = expected["films"]["build-a-120x2/col-drag"]["video_judge"]["sha256"]
        with self.assertRaises(ValueError):
            path = self.w.store / "expected" / f"{sha}.json"
            os.chmod(path, 0o644)
            path.write_text(path.read_text().replace('"dropped"', '"dropped_x"'))
            jg.load_expected(self.w.store, sha)

    def test_another_toolchain_is_no_verdict(self):
        expected = json.loads((self.w.manifest / "expected.json").read_text())
        expected["toolchain"]["numpy"] = "0.0.0"
        (self.w.manifest / "expected.json").write_text(json.dumps(expected))
        code, out = self.w.run()
        self.assertEqual(code, 2, out)
        self.assertIn("toolchain", out)

    def test_the_trace_judge_gets_the_scale_the_film_was_recorded_at(self):
        expected = json.loads((self.w.manifest / "expected.json").read_text())
        full = jg.load_expected(self.w.store, expected["films"]["build-b-120x1/rk-held"]["judge_trace"]["sha256"])
        self.assertEqual(full["scale_seen"], 1)

    def test_only_selects_films(self):
        code, out = self.w.run(None, "--only", "build-b-120x1/*")
        self.assertEqual(code, 0, out)
        self.assertIn("reproduced 4 of 4", out)

    def test_a_bless_records_its_reason_and_the_changed_films(self):
        changed = write_judges(self.w.root / "judges-changed", video=STUB_VIDEO.replace("SHIFT = 0", "SHIFT = 1"))
        code, out = self.w.bless(changed, reason="the drop count fix")
        self.assertEqual(code, 0, out)
        expected = json.loads((self.w.manifest / "expected.json").read_text())
        last = expected["history"][-1]
        self.assertEqual(last["reason"], "the drop count fix")
        self.assertEqual(sorted(last["changed"]), ["build-a-120x2/col-drag", "build-a-120x2/col-drag-slow",
                                                   "build-b-120x1/rk-held"])
        self.assertEqual(self.w.run(changed)[0], 0)


class BlessGitTests(unittest.TestCase):
    """A bless names the judges' commit: it refuses judge files with uncommitted changes."""

    def test_a_bless_refuses_uncommitted_judge_files(self):
        w = Workspace()
        try:
            self.assertEqual(w.snapshot()[0], 0)
            git = ["git", "-C", str(w.judges)]
            env = dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@t", GIT_COMMITTER_NAME="t",
                       GIT_COMMITTER_EMAIL="t@t")
            subprocess.run(git + ["init", "-q"], check=True, env=env)
            subprocess.run(git + ["add", "-A"], check=True, env=env)
            subprocess.run(git + ["commit", "-q", "-m", "judges"], check=True, env=env)
            (w.judges / "video_judge.py").write_text(STUB_VIDEO + "\n# an edit\n")
            code, out = w.cli("bless", "--judges", str(w.judges), "--reason", "x", "--jobs", "1")
            self.assertEqual(code, 2, out)
            self.assertIn("uncommitted", out)
        finally:
            w.close()


class RealJudgeTests(unittest.TestCase):
    """The real video_judge.py through the runner, on one film made from a kit fixture (the content-wait film)."""

    def test_the_real_video_judge_reproduces_its_own_bless(self):
        try:
            import numpy  # noqa: F401
        except ImportError:
            self.skipTest("numpy is not installed (run with the VM venv)")
        import test_video_judge_classes as classes
        w = Workspace()
        try:
            shutil.rmtree(w.gallery)
            classes.write_pacing_case(w.gallery)
            code, out = w.snapshot()
            self.assertEqual(code, 0, out)
            code, out = w.cli("bless", "--judges", str(HERE), "--reason", "real judge", "--jobs", "1", "--no-git-check")
            self.assertEqual(code, 0, out)
            code, out = w.cli("run", "--judges", str(HERE), "--jobs", "1")
            self.assertEqual(code, 0, out)
            self.assertIn("reproduced 4 of 4", out)
        finally:
            w.close()


if __name__ == "__main__":
    unittest.main()
