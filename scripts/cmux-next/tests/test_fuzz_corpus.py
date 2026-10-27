#!/usr/bin/env python3
"""fuzz-corpus.py (p10-stability-183): the stored corpus per fuzz target, with gh faked.

1. pull copies the stored inputs and prints the count; push stores a merged corpus as the next generation, and
   a second pull starts from it.
2. A push after another run's push (the generation moved since this run's pull) adds to the stored inputs
   instead of replacing them, so neither run loses its finds.
3. History: push records libFuzzer cov/ft from the run's log; record-coverage records llvm-cov regions; quality
   lists a target whose last 3 measurements did not grow and files one issue per target, once per run, also after
   a push and a move to a fresh store; rows imported older than the store's own are read in time order.
4. regress checks in a crash input under 64 KiB and refuses a larger one; check finds an oversized tracked file.
5. export / import carry a store between hosts; import refuses an archive member outside the layout.
6. The lane carry (stability-lanes.json carry_merge): two steps that start from one carried store both keep their
   finds, whichever finishes last.

    python3 -I -m pytest scripts/cmux-next/tests/test_fuzz_corpus.py
    python3 -I -m unittest discover -s scripts/cmux-next/tests -p test_fuzz_corpus.py
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import subprocess
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest import mock

SCRIPT = Path(__file__).resolve().parents[1] / "fuzz-corpus.py"


def load():
    spec = importlib.util.spec_from_file_location("fuzz_corpus", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


fc = load()


def run(*argv: str, github=None) -> tuple[int, str, str]:
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        status = fc.main(list(argv), github=github)
    return status, out.getvalue(), err.getvalue()


def write_inputs(directory: Path, *inputs: bytes) -> None:
    directory.mkdir(parents=True, exist_ok=True)
    for data in inputs:
        (directory / fc.sha1_name(data)).write_bytes(data)


def stored(store: Path, target: str) -> set[bytes]:
    return {p.read_bytes() for p in (store / "inputs" / target).iterdir()}


FUZZ_LOG = """INFO: Seed: 1
#2\tINITED cov: 10 ft: 12 corp: 2/9b exec/s: 0 rss: 30Mb
#90\tNEW    cov: 14 ft: 20 corp: 3/12b lim: 4 exec/s: 0 rss: 31Mb
Done 100 runs in 2 second(s)
"""


def at(stamp: str):
    """Every timestamp the store writes inside the block is STAMP."""
    return mock.patch.object(fc, "now_iso", return_value=stamp)


def llvm_summary(covered: int, count: int = 100) -> str:
    totals = {"regions": {"covered": covered, "count": count}, "lines": {"covered": covered * 2, "count": count * 2}}
    return json.dumps({"data": [{"totals": totals}], "type": "llvm.coverage.json.export"})


class FakeGitHub:
    def __init__(self, issues: list[dict] | None = None) -> None:
        self.issues = issues or []
        self.calls: list[tuple] = []

    def list_quality_issues(self) -> list[dict]:
        self.calls.append(("list",))
        return self.issues

    def ensure_label(self) -> None:
        self.calls.append(("label",))

    def create_issue(self, title: str, body: str) -> int:
        number = 100 + len(self.issues)
        self.issues.append({"number": number, "title": title})
        self.calls.append(("create", title))
        return number

    def comment(self, number: int, body: str) -> None:
        self.calls.append(("comment", number))


class StoreRoundTrip(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="fuzz-corpus-test-"))
        self.store = self.tmp / "store"

    def tearDown(self) -> None:
        subprocess.run(["rm", "-rf", str(self.tmp)], check=False)

    def test_second_run_starts_from_the_first_runs_corpus(self) -> None:
        status, out, _ = run("pull", "--store", str(self.store), "--into", str(self.tmp / "run1"),
                             "--receipt", str(self.tmp / "r1.json"), "t")
        self.assertEqual(status, 0)
        self.assertIn("t: no stored corpus", out)
        merged = self.tmp / "merged"
        write_inputs(merged, b"a", b"bc")
        (self.tmp / "t.log").write_text(FUZZ_LOG)
        status, out, _ = run("push", "--store", str(self.store), "--target", "t", "--from", str(merged),
                             "--receipt", str(self.tmp / "r1.json"), "--run", "run1", "--fuzz-log",
                             str(self.tmp / "t.log"))
        self.assertEqual(status, 0, out)
        self.assertIn("2 inputs (3 bytes) stored, generation 1", out)

        status, out, _ = run("pull", "--store", str(self.store), "--into", str(self.tmp / "run2"),
                             "--receipt", str(self.tmp / "r2.json"), "t")
        self.assertIn("t: 2 stored inputs (3 bytes, generation 1)", out)
        self.assertEqual({p.read_bytes() for p in (self.tmp / "run2/t").iterdir()}, {b"a", b"bc"})
        self.assertEqual(json.loads((self.tmp / "r2.json").read_text())["t"]["generation"], 1)

        # The second run's merge dropped "a" (minimized away) and found "def": the store holds exactly that.
        merged2 = self.tmp / "merged2"
        write_inputs(merged2, b"bc", b"def")
        run("push", "--store", str(self.store), "--target", "t", "--from", str(merged2),
            "--receipt", str(self.tmp / "r2.json"), "--run", "run2")
        self.assertEqual(stored(self.store, "t"), {b"bc", b"def"})
        history = fc.Store(self.store).read_history("t")
        self.assertEqual([r["run"] for r in history], ["run1", "run2"])
        self.assertEqual((history[0]["edges"], history[0]["features"]), (14, 20))
        self.assertNotIn("edges", history[1])
        meta = fc.Store(self.store).read_meta("t")
        self.assertEqual((meta["generation"], meta["count"], meta["bytes"]), (2, 2, 5))

    def test_a_push_after_a_concurrent_push_adds_instead_of_replacing(self) -> None:
        write_inputs(self.tmp / "seed", b"old")
        run("push", "--store", str(self.store), "--target", "t", "--from", str(self.tmp / "seed"), "--run", "r0")
        for name in ("a", "b"):
            run("pull", "--store", str(self.store), "--into", str(self.tmp / name),
                "--receipt", str(self.tmp / f"{name}.json"), "t")
        write_inputs(self.tmp / "ma", b"old", b"from-a")
        write_inputs(self.tmp / "mb", b"from-b")
        run("push", "--store", str(self.store), "--target", "t", "--from", str(self.tmp / "ma"),
            "--receipt", str(self.tmp / "a.json"), "--run", "ra")
        status, out, _ = run("push", "--store", str(self.store), "--target", "t", "--from", str(self.tmp / "mb"),
                             "--receipt", str(self.tmp / "b.json"), "--run", "rb")
        self.assertEqual(status, 0)
        self.assertIn("added to the corpus another run pushed", out)
        self.assertEqual(stored(self.store, "t"), {b"old", b"from-a", b"from-b"})
        self.assertTrue(fc.Store(self.store).read_history("t")[-1]["merged_with_concurrent_run"])

    def test_bad_target_names_and_missing_sources_are_refused(self) -> None:
        status, _, err = run("pull", "--store", str(self.store), "--into", str(self.tmp / "x"), "../escape")
        self.assertEqual(status, 2)
        self.assertIn("not a fuzz target name", err)
        status, _, err = run("push", "--store", str(self.store), "--target", "t", "--from", str(self.tmp / "none"))
        self.assertEqual(status, 2)
        self.assertIn("nothing to push", err)


class Quality(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="fuzz-corpus-test-"))
        self.store = self.tmp / "store"

    def tearDown(self) -> None:
        subprocess.run(["rm", "-rf", str(self.tmp)], check=False)

    def record(self, target: str, run_id: str, covered: int) -> None:
        summary = self.tmp / f"{target}-{run_id}.json"
        summary.write_text(llvm_summary(covered))
        status, _, err = run("record-coverage", "--store", str(self.store), "--target", target, "--run", run_id,
                             "--llvm-cov-json", str(summary))
        self.assertEqual(status, 0, err)

    def test_flat_over_three_runs_files_one_issue_once_per_run(self) -> None:
        for run_id, flat, growing in (("w1", 40, 10), ("w2", 40, 11), ("w3", 39, 12)):
            self.record("flat", run_id, flat)
            self.record("growing", run_id, growing)
        self.record("young", "w3", 5)
        status, out, _ = run("quality", "--store", str(self.store), "--json")
        self.assertEqual(status, 1)
        self.assertEqual(json.loads(out), [{"target": "flat", "kind": "llvm-cov", "edges": 39,
                                            "runs": ["w1", "w2", "w3"]}])

        github = FakeGitHub()
        status, out, _ = run("quality", "--store", str(self.store), "--file-issues", "--dry-run", github=github)
        self.assertIn("would create issue for flat", out)
        self.assertEqual(github.calls, [("list",)])
        run("quality", "--store", str(self.store), "--file-issues", github=github)
        self.assertEqual(github.calls[1:], [("list",), ("label",),
                                            ("create", "fuzz-quality: flat coverage flat over 3 runs")])
        # The same window again writes nothing; a new flat run comments on the open issue.
        run("quality", "--store", str(self.store), "--file-issues", github=github)
        self.assertEqual(github.calls[-1], ("list",))
        self.record("flat", "w4", 39)
        run("quality", "--store", str(self.store), "--file-issues", github=github)
        self.assertEqual(github.calls[-1], ("comment", 100))

    def test_the_noted_run_survives_a_push_and_a_move_to_a_fresh_store(self) -> None:
        for run_id, stamp in (("w1", "2026-10-01T00:00:00Z"), ("w2", "2026-10-08T00:00:00Z"),
                              ("w3", "2026-10-15T00:00:00Z")):
            with at(stamp):
                self.record("flat", run_id, 40)
        github = FakeGitHub()
        run("quality", "--store", str(self.store), "--file-issues", github=github)
        self.assertEqual(github.calls[-1], ("create", "fuzz-quality: flat coverage flat over 3 runs"))
        # A fast-lane run stores its corpus; the next coverage step fails, so no llvm-cov row is added.
        write_inputs(self.tmp / "merged", b"x")
        with at("2026-10-16T00:00:00Z"):
            run("push", "--store", str(self.store), "--target", "flat", "--from", str(self.tmp / "merged"),
                "--run", "fast1")
        self.assertEqual(fc.Store(self.store).read_meta("flat")["quality_noted_run"], "w3")
        archive = self.tmp / "carry.tar.gz"
        run("export", "--store", str(self.store), "--out", str(archive))
        fresh = self.tmp / "fresh"
        status, _, err = run("import", "--store", str(fresh), "--in", str(archive))
        self.assertEqual(status, 0, err)
        calls = len(github.calls)
        run("quality", "--store", str(fresh), "--file-issues", github=github)
        self.assertEqual(github.calls[calls:], [("list",)])

    def test_rows_imported_older_than_the_stores_own_keep_the_verdict(self) -> None:
        older = self.tmp / "older"
        for run_id, stamp, flat, growing in (("w1", "2026-10-01T00:00:00Z", 40, 10),
                                             ("w2", "2026-10-08T00:00:00Z", 40, 11)):
            with at(stamp):
                for target, covered in (("flat", flat), ("growing", growing)):
                    summary = self.tmp / f"{target}-{run_id}.json"
                    summary.write_text(llvm_summary(covered))
                    run("record-coverage", "--store", str(older), "--target", target, "--run", run_id,
                        "--llvm-cov-json", str(summary))
        archive = self.tmp / "older.tar.gz"
        run("export", "--store", str(older), "--out", str(archive))
        with at("2026-10-15T00:00:00Z"):
            self.record("flat", "w3", 39)
            self.record("growing", "w3", 12)
        status, _, err = run("import", "--store", str(self.store), "--in", str(archive))
        self.assertEqual(status, 0, err)
        self.assertEqual([r["run"] for r in fc.Store(self.store).read_history("growing")], ["w1", "w2", "w3"])
        status, out, _ = run("quality", "--store", str(self.store), "--json")
        self.assertEqual(status, 1)
        self.assertEqual(json.loads(out), [{"target": "flat", "kind": "llvm-cov", "edges": 39,
                                            "runs": ["w1", "w2", "w3"]}])

    def test_bad_llvm_cov_summary_is_refused(self) -> None:
        (self.tmp / "bad.json").write_text("{}")
        status, _, err = run("record-coverage", "--store", str(self.store), "--target", "t", "--run", "r",
                             "--llvm-cov-json", str(self.tmp / "bad.json"))
        self.assertEqual(status, 2)
        self.assertIn("not an llvm-cov export summary", err)


class RegressionsAndSize(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="fuzz-corpus-test-"))

    def tearDown(self) -> None:
        subprocess.run(["rm", "-rf", str(self.tmp)], check=False)

    def test_regress_checks_in_small_inputs_and_refuses_large_ones(self) -> None:
        crash = self.tmp / "crash-1"
        crash.write_bytes(b"\x00boom")
        status, out, _ = run("regress", "--target", "t", "--input", str(crash), "--corpus-dir", str(self.tmp / "c"))
        self.assertEqual(status, 0)
        written = list((self.tmp / "c/t").iterdir())
        self.assertEqual([p.read_bytes() for p in written], [b"\x00boom"])
        self.assertTrue(written[0].name.startswith("regress-"))
        crash.write_bytes(b"x" * (fc.MAX_CHECKED_IN_BYTES + 1))
        status, _, err = run("regress", "--target", "t", "--input", str(crash), "--corpus-dir", str(self.tmp / "c"))
        self.assertEqual(status, 2)
        self.assertIn("--minimize-crash t", err)
        self.assertEqual(len(list((self.tmp / "c/t").iterdir())), 1)

    def test_check_finds_an_oversized_tracked_corpus_file(self) -> None:
        repo = self.tmp / "repo"
        subprocess.run(["git", "init", "-q", str(repo)], check=True)
        write_inputs(repo / "cmux-tui/fuzz/corpus/t", b"small")
        (repo / "Packages/X/Tests/FuzzRegressions/Suite.case").mkdir(parents=True)
        (repo / "Packages/X/Tests/FuzzRegressions/Suite.case/regress-a").write_bytes(b"y" * 10)
        (repo / "docs").mkdir()
        (repo / "docs/big.bin").write_bytes(b"z" * (fc.MAX_CHECKED_IN_BYTES + 1))
        subprocess.run(["git", "-C", str(repo), "add", "."], check=True)
        status, out, _ = run("check", "--repo", str(repo))
        self.assertEqual(status, 0, out)
        big = repo / "Packages/X/Tests/FuzzRegressions/Suite.case/regress-big"
        big.write_bytes(b"y" * (fc.MAX_CHECKED_IN_BYTES + 1))
        subprocess.run(["git", "-C", str(repo), "add", "."], check=True)
        status, _, err = run("check", "--repo", str(repo))
        self.assertEqual(status, 1)
        self.assertIn("regress-big", err)

    def test_the_repository_has_no_checked_in_corpus_file_over_64_kib(self) -> None:
        status, _, err = run("check")
        self.assertEqual(status, 0, err)


class ExportImport(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="fuzz-corpus-test-"))

    def tearDown(self) -> None:
        subprocess.run(["rm", "-rf", str(self.tmp)], check=False)

    def test_a_store_moves_between_hosts_and_joins_histories(self) -> None:
        host_a, host_b = self.tmp / "a", self.tmp / "b"
        write_inputs(self.tmp / "m", b"one", b"two")
        with at("2026-10-01T00:00:00Z"):
            run("push", "--store", str(host_a), "--target", "t", "--from", str(self.tmp / "m"), "--run", "ra")
        write_inputs(self.tmp / "n", b"three")
        with at("2026-10-02T00:00:00Z"):
            run("push", "--store", str(host_b), "--target", "t", "--from", str(self.tmp / "n"), "--run", "rb")
        archive = self.tmp / "store.tar.gz"
        status, out, _ = run("export", "--store", str(host_a), "--out", str(archive))
        self.assertEqual(status, 0)
        self.assertIn("sha256", out)
        status, out, _ = run("import", "--store", str(host_b), "--in", str(archive))
        self.assertEqual(status, 0)
        self.assertIn("t: 2 new inputs", out)
        self.assertEqual(stored(host_b, "t"), {b"one", b"two", b"three"})
        # ra was written first, so it comes first, although host_b's own row was there before the import.
        self.assertEqual([r["run"] for r in fc.Store(host_b).read_history("t")], ["ra", "rb"])
        self.assertEqual([json.loads(line)["run"] for line in (host_b / "meta/t.history.jsonl").read_text().splitlines()],
                         ["ra", "rb"])
        meta = fc.Store(host_b).read_meta("t")
        self.assertEqual((meta["generation"], meta["count"]), (2, 3))
        # Importing the same archive again adds nothing and keeps the generation.
        run("import", "--store", str(host_b), "--in", str(archive))
        self.assertEqual(fc.Store(host_b).read_meta("t")["generation"], 2)
        self.assertEqual(len(fc.Store(host_b).read_history("t")), 2)

    def test_import_refuses_members_outside_the_layout(self) -> None:
        archive = self.tmp / "evil.tar.gz"
        with tarfile.open(archive, "w:gz") as tar:
            data = b"x"
            info = tarfile.TarInfo("inputs/../../escape")
            info.size = len(data)
            tar.addfile(info, io.BytesIO(data))
        status, _, err = run("import", "--store", str(self.tmp / "s"), "--in", str(archive))
        self.assertEqual(status, 2)
        self.assertIn("is not inputs/<target>/<file>", err)
        self.assertFalse((self.tmp / "escape").exists())


class LaneCarry(unittest.TestCase):
    """stability-lanes.json's carry: two overlapping steps start from one carried store."""

    LANES = SCRIPT.parent / "stability-lanes.json"

    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="fuzz-corpus-test-"))
        self.lanes = {lane["id"]: lane for lane in json.loads(self.LANES.read_text())["lanes"]}

    def tearDown(self) -> None:
        subprocess.run(["rm", "-rf", str(self.tmp)], check=False)

    def step(self, name: str, carry: Path, *found: bytes) -> Path:
        """One lane step as rust-fuzz.sh runs it: a fresh --store, import, pull, push of the merge, export."""
        store, receipt, out = self.tmp / f"{name}-store", self.tmp / f"{name}.json", self.tmp / f"{name}.tar.gz"
        self.assertEqual(run("import", "--store", str(store), "--in", str(carry))[0], 0)
        run("pull", "--store", str(store), "--into", str(self.tmp / f"{name}-corpus"), "--receipt", str(receipt), "t")
        write_inputs(self.tmp / f"{name}-merged", *found)
        run("push", "--store", str(store), "--target", "t", "--from", str(self.tmp / f"{name}-merged"),
            "--receipt", str(receipt), "--run", name)
        self.assertEqual(run("export", "--store", str(store), "--out", str(out))[0], 0)
        return out

    def update_carry(self, lane: str, carry: Path, step_artifact: Path, name: str) -> Path:
        """The runner's carry update, run from the lane's own carry_merge command."""
        following = self.tmp / f"{name}.tar.gz"
        values = {"{corpus_in}": str(carry), "{step_artifact}": str(step_artifact), "{corpus_next}": str(following)}
        argv = [values.get(arg, arg) for arg in self.lanes[lane]["corpus"]["carry_merge"]]
        self.assertEqual(argv[:3], ["python3", "-I", "scripts/cmux-next/fuzz-corpus.py"])
        status, _, err = run(*argv[3:])
        self.assertEqual(status, 0, err)
        return following

    def unpacked(self, archive: Path) -> fc.Store:
        store = self.tmp / f"{archive.name}-unpacked"
        run("import", "--store", str(store), "--in", str(archive))
        return fc.Store(store)

    def test_two_steps_from_one_carry_both_keep_their_finds(self) -> None:
        origin = self.tmp / "origin"
        write_inputs(self.tmp / "seed", b"old")
        run("push", "--store", str(origin), "--target", "t", "--from", str(self.tmp / "seed"), "--run", "r0")
        carry = self.tmp / "carry0.tar.gz"
        run("export", "--store", str(origin), "--out", str(carry))

        # A fast step and a coverage step both start from carry0. Each step's merge minimized "old" away.
        fast = self.step("fast", carry, b"from-fast")
        coverage = self.step("coverage", carry, b"from-coverage")
        self.assertEqual(stored(self.unpacked(coverage).root, "t"), {b"from-coverage"},
                         "taking the last step's store alone would lose the fast step's find")

        carry = self.update_carry("rust-fuzz", carry, fast, "carry1")
        carry = self.update_carry("rust-fuzz-coverage", carry, coverage, "carry2")
        final = self.unpacked(carry)
        self.assertEqual(stored(final.root, "t"), {b"old", b"from-fast", b"from-coverage"})
        self.assertEqual({r["run"] for r in final.read_history("t")}, {"r0", "fast", "coverage"})

    def test_a_step_with_a_finding_updates_the_carry(self) -> None:
        for lane in ("rust-fuzz", "rust-fuzz-coverage"):
            self.assertEqual(self.lanes[lane]["corpus"]["carry_exit_codes"], [0, 1], lane)


class DefaultStore(unittest.TestCase):
    def test_environment_then_fleet_cache_then_user_cache(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.assertEqual(fc.default_store("cmux-tui", {"CMUX_FUZZ_CORPUS_STORE": str(root / "s")}),
                             root / "s/cmux-tui")
            fleet = root / "fleet"
            fleet.mkdir()
            self.assertEqual(fc.default_store("cmux-tui", {}, fleet_parent=fleet), fleet / "fuzz-corpus/cmux-tui")
            self.assertEqual(fc.default_store("cmux-tui", {"HOME": str(root)}, fleet_parent=root / "none"),
                             root / ".cache/cmux/fuzz-corpus/cmux-tui")


if __name__ == "__main__":
    unittest.main()
