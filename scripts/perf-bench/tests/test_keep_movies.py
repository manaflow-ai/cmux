#!/usr/bin/env python3
"""`parity_appclock.py run --keep-movies` keeps the movie of the first and of the worst run of each entry, so a
person can open what the numbers measured; a movie that is neither goes when its round ends. Without the flag
each movie is removed after its scan, as before.
On the tool before the flag each test ends in an error (no such function or attribute; `stop_recording` removed
each movie).
Run: python3 -I scripts/perf-bench/tests/test_keep_movies.py"""
import json, os, sys, tempfile, types, unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
# procs.py loads /usr/lib/libproc.dylib at import (macOS only). No test here reads a process, so an empty module
# stands in for it when the real one does not load, and the tool imports on Linux too. The stub is for this import
# only: left in sys.modules, a later test's `import procs` gets it in place of the real module.
_PROCS_STUB = None
try:
    import procs  # noqa: F401
except OSError:
    _PROCS_STUB = sys.modules["procs"] = types.ModuleType("procs")
try:
    import parity_appclock as pa  # noqa: E402
finally:
    if _PROCS_STUB is not None and sys.modules.get("procs") is _PROCS_STUB:
        del sys.modules["procs"]


class FirstAndWorst(unittest.TestCase):
    def test_the_first_run_and_the_run_with_the_largest_latency_stay(self):
        takes = [("a.mov", [30.0, 31.0]), ("b.mov", [29.0, 52.0]), ("c.mov", [33.0])]
        self.assertEqual(pa.first_and_worst(takes), {"a.mov": "first", "b.mov": "worst"})

    def test_one_movie_stays_when_the_first_run_is_the_worst(self):
        self.assertEqual(pa.first_and_worst([("a.mov", [60.0]), ("b.mov", [40.0])]), {"a.mov": "first and worst"})

    def test_of_equal_worst_runs_the_earliest_stays(self):
        takes = [("a.mov", [10.0]), ("b.mov", [50.0]), ("c.mov", [50.0])]
        self.assertEqual(pa.first_and_worst(takes), {"a.mov": "first", "b.mov": "worst"})

    def test_a_run_with_no_movie_is_not_the_first_and_a_run_with_no_sample_is_not_the_worst(self):
        takes = [(None, [90.0]), ("b.mov", []), ("c.mov", [20.0])]
        self.assertEqual(pa.first_and_worst(takes), {"b.mov": "first", "c.mov": "worst"})

    def test_no_run_no_movie(self):
        self.assertEqual(pa.first_and_worst([]), {})
        self.assertEqual(pa.first_and_worst([(None, [1.0])]), {})


class Files(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)

    def movie(self, name):
        path = os.path.join(self.folder.name, name)
        with open(path, "w") as f:
            f.write("movie")
        return path

    def test_prune_removes_each_movie_that_is_not_the_first_or_the_worst(self):
        a, b, c, d = (self.movie(n) for n in ("a.mov", "b.mov", "c.mov", "d.mov"))
        kept = pa.prune_movies([(a, [30.0]), (b, [31.0]), (c, [70.0]), (d, [32.0])])
        self.assertEqual(kept, {a: "first", c: "worst"})
        self.assertEqual(sorted(os.listdir(self.folder.name)), ["a.mov", "c.mov"])

    def test_a_run_gets_its_last_movie_and_an_earlier_one_of_the_same_run_goes(self):
        a, b = self.movie("a.mov"), self.movie("b.mov")
        self.assertEqual(pa.row_movie({"row": "tab-switch"}, [a, b]), {"row": "tab-switch", "movie": b})
        self.assertEqual(os.listdir(self.folder.name), ["b.mov"])
        self.assertEqual(pa.row_movie({"row": "tab-switch"}, []), {"row": "tab-switch"})


class Rounds(unittest.TestCase):
    """`run` gives each round of a (row, load) to `filmed_round` when the round ends."""

    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)

    def round(self, takes, name, samples, status="measured"):
        path = os.path.join(self.folder.name, name)
        with open(path, "w") as f:
            f.write("movie")
        return pa.filmed_round(takes, {"status": status, "movie": path, "samples": samples})

    def movies(self):
        return sorted(name for name in os.listdir(self.folder.name) if name.endswith(".mov"))

    def test_after_each_round_the_disk_holds_the_first_and_the_worst_only(self):
        takes = []
        on_disk = []
        for name, worst in (("a.mov", 30.0), ("b.mov", 40.0), ("c.mov", 35.0), ("d.mov", 90.0), ("e.mov", 90.0)):
            self.round(takes, name, [worst])
            on_disk.append(self.movies())
        self.assertEqual(on_disk, [["a.mov"], ["a.mov", "b.mov"], ["a.mov", "b.mov"], ["a.mov", "d.mov"], ["a.mov", "d.mov"]])

    def test_the_rounds_keep_what_one_prune_of_all_rounds_keeps(self):
        rounds = [("a.mov", [30.0]), ("b.mov", [70.0]), ("c.mov", [31.0]), ("d.mov", [70.0]), ("e.mov", [12.0])]
        takes = []
        for name, samples in rounds:
            kept = self.round(takes, name, samples)
        at_once = pa.first_and_worst([(os.path.join(self.folder.name, name), samples) for name, samples in rounds])
        self.assertEqual(kept, at_once)
        self.assertEqual(self.movies(), ["a.mov", "b.mov"])

    def test_a_round_that_is_not_measured_is_not_the_worst(self):
        takes = []
        self.round(takes, "a.mov", [30.0])
        self.round(takes, "b.mov", [45.0])
        self.round(takes, "c.mov", [400.0], status="invalid")
        self.round(takes, "d.mov", [], status="not run")
        self.assertEqual(self.movies(), ["a.mov", "b.mov"])

    def test_a_first_round_that_is_not_measured_stays_as_the_first(self):
        takes = []
        self.round(takes, "a.mov", [400.0], status="invalid")
        kept = self.round(takes, "b.mov", [45.0])
        self.assertEqual(sorted(kept.values()), ["first", "worst"])
        self.assertEqual(self.movies(), ["a.mov", "b.mov"])

    def test_the_list_on_disk_names_the_kept_movies_after_each_round(self):
        filmed = {}
        for row, name, worst in (("tab-switch", "a.mov", 30.0), ("tab-switch", "b.mov", 20.0), ("typing", "c.mov", 9.0)):
            self.round(filmed.setdefault((row, "light"), []), name, [worst])
            listed = pa.list_movies(self.folder.name, filmed)
            with open(os.path.join(self.folder.name, "movies.json")) as f:
                self.assertEqual(json.load(f), listed)
        path = lambda name: os.path.join(self.folder.name, name)  # noqa: E731
        self.assertEqual(listed, [{"row": "tab-switch", "load": "light", "which": "first and worst", "movie": path("a.mov")},
                                  {"row": "typing", "load": "light", "which": "first and worst", "movie": path("c.mov")}])
        self.assertEqual(self.movies(), ["a.mov", "c.mov"])


class App:
    """What `cmux_row` reads of a launched bench app whose recordings kept `movies`."""

    def __init__(self, movies):
        self.movies = movies
        self.app = types.SimpleNamespace(gui_session=True)

    def launch(self):
        return self

    def quit(self):
        pass


class RowMovie(unittest.TestCase):
    """`cmux_row` gives each entry the movie of its run, whatever the run's status."""

    def entry(self, runner, fault=None):
        app = App(["/work/cmux-tab-switch-take1.mov"])
        with mock.patch.object(pa, "Cmux", lambda *args: app), mock.patch.object(pa, "pause", lambda *args: None), \
                mock.patch.dict(pa.RUNNERS, {"tab-switch": runner}), \
                mock.patch.object(pa, "screen_fault", lambda *args: fault), \
                mock.patch.object(pa.chrome_arm, "load1", lambda: 1.0):
            return pa.cmux_row("x.app", "/out", None, 1, 120, "tab-switch", "light", 0)

    def test_a_measured_an_invalid_and_a_not_run_entry_each_name_the_movie(self):
        def fails(*args):
            raise pa.NotRun("no frame")

        measured = self.entry(lambda *args: {"samples": [12.0]})
        invalid = self.entry(lambda *args: {"samples": [12.0]}, fault="60 Hz")
        not_run = self.entry(fails)
        self.assertEqual([e["status"] for e in (measured, invalid, not_run)], ["measured", "invalid", "not run"])
        self.assertEqual({e["movie"] for e in (measured, invalid, not_run)}, {"/work/cmux-tab-switch-take1.mov"})


class Recorder:
    """The app's side of one recording: `record_stop` and `record_read` of a recording that wrote its movie but got
    no frame from the screen, so `stop_recording` raises NotRun after its file work."""

    def rpc(self, method, params=None):
        return {"written": True, "callbacks": 0, "movie_status": "no frame"}


class StopRecording(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        self.addCleanup(setattr, pa.Cmux, "keep_movies", pa.Cmux.keep_movies)

    def cmux(self):
        cmux = object.__new__(pa.Cmux)
        cmux.app, cmux.out, cmux.movies = Recorder(), self.folder.name, []
        return cmux

    def stop(self, cmux, name="tab-switch"):
        path = os.path.join(self.folder.name, f"{name}.mov")
        for end in ("", ".scan", ".frames.json"):
            with open(path + end, "w") as f:
                f.write("[]")
        cmux.recording = {"path": path, "start": {}, "box": (0, 0, 10, 10), "lines": 0, "link": {}}
        with self.assertRaises(pa.NotRun):
            cmux.stop_recording(0)

    def test_without_the_flag_each_file_of_the_recording_goes(self):
        pa.Cmux.keep_movies = False
        cmux = self.cmux()
        self.stop(cmux)
        self.assertEqual(os.listdir(self.folder.name), [])
        self.assertEqual(cmux.movies, [])

    def test_with_the_flag_the_movie_stays_under_its_own_name_and_the_scan_files_go(self):
        pa.Cmux.keep_movies = True
        cmux = self.cmux()
        self.stop(cmux)
        self.stop(cmux)  # a second recording of the same name writes the same path again
        self.assertEqual(sorted(os.listdir(self.folder.name)), ["tab-switch-take1.mov", "tab-switch-take2.mov"])
        self.assertEqual(cmux.movies, [os.path.join(self.folder.name, f"tab-switch-take{n}.mov") for n in (1, 2)])


class Flag(unittest.TestCase):
    def parsed(self, *flags):
        seen = []
        with mock.patch.object(pa, "run", lambda args: seen.append(args) or 0), \
                mock.patch.object(sys, "argv", ["parity_appclock.py", "run", "--cmux", "x", "--out", "o", *flags]):
            self.assertEqual(pa.main(), 0)
        return seen[0]

    def test_run_takes_the_flag_and_it_is_off_by_default(self):
        self.assertFalse(self.parsed().keep_movies)
        self.assertTrue(self.parsed("--keep-movies").keep_movies)


if __name__ == "__main__":
    unittest.main()
