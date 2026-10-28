#!/usr/bin/env python3
"""Tests for walks_scale.py: chunks, both arms, failure signatures, ddmin hand-off, the
re-check of each minimized walk, and no report before every failure is minimized.

Run: python3 -I scripts/cmux-next/oracle/walks_scale_test.py (stdlib unittest). A fake oracle.py
seam stands in for gen_walks.py, diff --switch and minimize.py (tasks 098 and 111), so the tests
run before those land; it writes the run-directory files the real ones write. linux_run.sh walks is
tested in linux_run_test.py (WalksTests).
"""

from __future__ import annotations

import io
import json
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import walks_scale as ws  # noqa: E402


def walk_case(seed: int, length: int, ops: Optional[List[str]] = None) -> Dict[str, Any]:
    ops = ops or [f"op{(seed * 7 + i) % 5}" for i in range(length)]
    return {
        "corpusVersion": 1, "id": f"seed-{seed:06d}", "suite": "walks",
        "fixture": {"seed": f"walk-{seed}", "network": "offline", "clock": "virtual"},
        "steps": [{"id": f"s{i}", "op": "resource.call", "args": {"method": op}} for i, op in enumerate(ops)],
    }


class FakeOracle:
    """gen writes one case per seed; diff fails a walk that has `bad` in it (on one arm, or on
    both as a divergence); minimize keeps only the `bad` steps (the ddmin result)."""

    def __init__(self, *, bad_seeds: Sequence[int] = (), unexpected_seeds: Sequence[int] = (),
                 minimize_fails: bool = False, minimized_loses_failure: bool = False, check_fails: bool = False,
                 hits: bool = True) -> None:
        self.bad_seeds = set(bad_seeds)
        self.unexpected_seeds = set(unexpected_seeds)
        self.minimize_fails = minimize_fails
        self.minimized_loses_failure = minimized_loses_failure
        self.check_fails = check_fails
        self.hits = hits
        self.calls: List[tuple] = []
        # Every case a predicate diff (no retries) ran, as the diff read it.
        self.predicate_cases: List[Dict[str, Any]] = []

    def gen(self, corpus: Path, *, first_seed: int, count: int, length: int) -> int:
        self.calls.append(("gen", first_seed, count, length))
        for seed in range(first_seed, first_seed + count):
            ops = None
            if seed in self.bad_seeds or seed in self.unexpected_seeds:
                ops = [f"op{i % 5}" for i in range(length)]
                ops[length // 2] = "bad"
            case = walk_case(seed, length, ops)
            ws.write_json(corpus / "walks" / f"{case['id']}.json", case)
        return 0

    def diff(self, *, switch: str, corpus: Path, binary: str, out: Path, jobs: int, sha: Optional[str],
             retry_limit: Optional[int] = None, repeat: int = 1, flaky_out: Optional[Path] = None) -> int:
        self.calls.append(("diff", switch, str(corpus), retry_limit, repeat))
        cases = ws.corpus_cases(corpus)
        if retry_limit == 0:
            self.predicate_cases.extend(json.loads(path.read_text()) for path in cases.values())
        divergences, unexpected = [], []
        for cid, path in cases.items():
            case = json.loads(path.read_text())
            if not any(s["args"]["method"] == "bad" for s in case["steps"]):
                continue
            seed = int(case["fixture"]["seed"].split("-")[1]) if case["fixture"]["seed"].startswith("walk-") else -1
            if seed in self.unexpected_seeds or "unexpected" in case.get("title", ""):
                unexpected.append(cid)
            else:
                bad_at = next(i for i, s in enumerate(case["steps"]) if s["args"]["method"] == "bad")
                divergences.append({"journey": cid, "pointer": f"/daemon/workspaces/{bad_at}/title"})
        for arm in ws.ARMS:
            receipt = {
                "order": sorted(cases), "counts": {"expected": len(cases)}, "duration_s": 1.0,
                "unexpected": unexpected if arm == "new" else [],
                "cases": {cid: {"status": "Crash" if cid in unexpected and arm == "new" else "Pass"} for cid in cases},
                "switch_hits": {switch: {arm: len(cases)}} if self.hits else {}, "flaky": [],
            }
            ws.write_json(out / arm / "receipt.json", receipt)
        refused = None if self.hits else "arm-not-exercised"
        ws.write_json(out / "comparison.json", {"compared": len(cases), "refused": refused, "flaky_excluded": []})
        ws.write_json(out / "divergence.json", {"divergences": divergences})
        if refused:
            return ws.DIFF_REFUSED
        return ws.DIFF_DIVERGENT if (divergences or unexpected) else ws.DIFF_OK

    def minimize(self, case: Path, out: Path, *, jobs: int, test: Sequence[str]) -> int:
        self.calls.append(("minimize", str(case), list(test)))
        if self.minimize_fails:
            return 1
        data = json.loads(case.read_text())
        keep = [s for s in data["steps"] if s["args"]["method"] == "bad"]
        if self.minimized_loses_failure:
            keep = [{"id": "s0", "op": "resource.call", "args": {"method": "op0"}}]
        ws.write_json(out, {**data, "steps": keep})
        return 0

    def check(self, path: Path) -> int:
        self.calls.append(("check", str(path)))
        return 1 if self.check_fails else 0


class WalksScaleTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="walks-test-"))
        self.registry = self.tmp / "registry"
        ws.write_json(self.registry / "holder.json", {"name": "holder", "daemon_key": "terminal.host-model"})
        ws.write_json(self.registry / "layer-hosting.json", {"name": "layer-hosting", "app_key": "browserResize.layerHosting"})

    def run_main(self, fake: FakeOracle, *extra: str, seeds: int = 25, chunk: int = 10) -> tuple:
        work = self.tmp / "work"
        commit = self.tmp / "commit"
        argv = ["run", "--binary", "/bin/true", "--sha", "abc", "--seeds", str(seeds), "--chunk", str(chunk),
                "--length", "8", "--work", str(work), "--commit-dir", str(commit), "--registry", str(self.registry),
                *extra]
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            code = ws.main(argv, cli=fake, environ={"RUNNERD_JOB": "test"})
        return code, work, commit, out.getvalue() + err.getvalue()

    def test_every_seed_runs_on_both_arms_of_each_daemon_switch(self) -> None:
        fake = FakeOracle()
        code, work, _, output = self.run_main(fake)
        self.assertEqual(code, 0, output)
        gens = [c for c in fake.calls if c[0] == "gen"]
        self.assertEqual([(g[1], g[2]) for g in gens], [(1, 10), (11, 10), (21, 5)])
        diffs = [c for c in fake.calls if c[0] == "diff"]
        self.assertEqual({d[1] for d in diffs}, {"holder"}, "the app switch is not walked on the daemon")
        receipt = json.loads((work / "receipt.json").read_text())
        arms = receipt["switches"]["holder"]["arms"]
        self.assertEqual({arm: arms[arm]["cases"] for arm in ws.ARMS}, {"old": 25, "new": 25})
        self.assertEqual(arms["old"]["switch_hits"], {"old": 25})
        self.assertTrue(receipt["ok"])
        self.assertTrue((work / "index.md").is_file())

    def test_failures_are_minimized_and_committed_before_the_report(self) -> None:
        fake = FakeOracle(bad_seeds=[3, 14], unexpected_seeds=[22])
        code, work, commit, output = self.run_main(fake)
        self.assertEqual(code, 1, output)
        receipt = json.loads((work / "receipt.json").read_text())
        self.assertEqual(len(receipt["failures"]), 3)
        committed = sorted(p.name for p in commit.glob("*.json"))
        # seeds 3 and 14 diverge at the same generalized pointer: one group, one minimized walk.
        self.assertEqual(committed, ["holder-walk-22.json", "holder-walk-3.json"])
        case = json.loads((commit / "holder-walk-3.json").read_text())
        self.assertEqual(case["id"], "holder-walk-3")
        self.assertEqual(case["suite"], "walks")
        self.assertEqual(case["switches"], ["holder"])
        self.assertEqual([s["args"]["method"] for s in case["steps"]], ["bad"])
        by_seed = {f["seed"]: f for f in receipt["failures"]}
        self.assertEqual(by_seed["walk-14"]["duplicateOf"], str(commit / "holder-walk-3.json"))
        self.assertEqual(by_seed["walk-22"]["signature"], {"kind": "unexpected", "arms": {"new": "Crash"}})
        self.assertEqual(by_seed["walk-3"]["signature"], {"kind": "divergent", "pointer": "/daemon/workspaces/*/title"})
        # every committed case went through oracle.py check
        checked = {Path(c[1]).name for c in fake.calls if c[0] == "check"}
        self.assertEqual(checked, set(committed))

    def test_minimize_all_minimizes_every_failure(self) -> None:
        fake = FakeOracle(bad_seeds=[3, 14])
        code, _, commit, output = self.run_main(fake, "--minimize-all")
        self.assertEqual(code, 1, output)
        self.assertEqual(sorted(p.name for p in commit.glob("*.json")), ["holder-walk-14.json", "holder-walk-3.json"])

    def test_no_report_when_a_failure_is_not_minimized(self) -> None:
        for kwargs in ({"minimize_fails": True}, {"minimized_loses_failure": True}, {"check_fails": True}):
            with self.subTest(**kwargs):
                self.setUp()
                fake = FakeOracle(bad_seeds=[3], **kwargs)
                code, work, commit, output = self.run_main(fake)
                self.assertEqual(code, ws.EXIT_REFUSED, output)
                self.assertFalse((work / "receipt.json").exists())
                self.assertFalse((work / "index.md").exists())
                pending = json.loads((work / "unminimized.json").read_text())
                self.assertEqual([f["seed"] for f in pending["failures"]], ["walk-3"])
                self.assertEqual(list(commit.glob("*.json")), [])
                self.assertIn("no report", output)

    def test_a_minimized_walk_is_rechecked_with_the_original_signature(self) -> None:
        fake = FakeOracle(bad_seeds=[3])
        self.run_main(fake)
        predicate_diffs = [c for c in fake.calls if c[0] == "diff" and c[3] == 0]
        self.assertEqual(len(predicate_diffs), 1, "the verify pass runs the minimized walk once more")
        self.assertEqual(predicate_diffs[0][4], 2, "the predicate repeats the walk twice, no retries")
        [minimize] = [c for c in fake.calls if c[0] == "minimize"]
        test = minimize[2]
        self.assertEqual(test[2:4], [str(HERE / "walks_scale.py"), "interesting"])
        signature_file = Path(test[test.index("--signature-file") + 1])
        self.assertEqual(json.loads(signature_file.read_text()),
                         {"kind": "divergent", "pointer": "/daemon/workspaces/*/title"})

    def test_minimized_walks_list_the_switch_from_the_first_candidate(self) -> None:
        """ddmin starts from a walk that lists the switch, and the re-check runs the committed content."""
        fake = FakeOracle(bad_seeds=[3])
        _, _, commit, _ = self.run_main(fake)
        [minimize] = [c for c in fake.calls if c[0] == "minimize"]
        self.assertEqual(json.loads(Path(minimize[1]).read_text())["switches"], ["holder"])
        [verified] = fake.predicate_cases
        committed = json.loads((commit / "holder-walk-3.json").read_text())
        self.assertEqual({**verified, "id": committed["id"]}, committed)

    def test_run_refuses_outside_a_runnerd_job_on_linux(self) -> None:
        fake = FakeOracle()
        argv = ["run", "--binary", "/bin/true", "--seeds", "1", "--work", str(self.tmp / "w"),
                "--registry", str(self.registry)]
        with redirect_stderr(io.StringIO()) as err:
            code = ws.main(argv, cli=fake, environ={})
        if sys.platform.startswith("linux"):
            self.assertEqual(code, 2)
            self.assertIn("linux_run.sh walks", err.getvalue())
            self.assertEqual(fake.calls, [])
        self.assertFalse(ws.outside_queue_job({"RUNNERD_JOB": "j"}))

    def test_arm_not_exercised_is_refused(self) -> None:
        code, work, _, output = self.run_main(FakeOracle(hits=False))
        self.assertEqual(code, ws.EXIT_REFUSED, output)
        receipt = json.loads((work / "receipt.json").read_text())
        self.assertFalse(receipt["ok"])
        self.assertIn("holder", receipt["refused"])

    def test_interesting_predicate(self) -> None:
        fake = FakeOracle()
        work = self.tmp / "pred"
        sig = {"kind": "divergent", "pointer": "/daemon/workspaces/*/title"}
        bad = self.tmp / "bad.json"
        ws.write_json(bad, walk_case(1, 3, ["op1", "op2", "bad"]))
        good = self.tmp / "good.json"
        ws.write_json(good, walk_case(1, 3, ["op1", "op2", "op3"]))
        empty = self.tmp / "empty.json"
        ws.write_json(empty, {**walk_case(1, 1), "steps": []})
        broken = self.tmp / "broken.json"
        broken.write_text("{", encoding="utf-8")
        kw = dict(switch="holder", binary="/bin/true", sha=None, work=work)
        self.assertEqual(ws.interesting(fake, case_path=bad, signature=sig, **kw), ws.INTERESTING)
        self.assertEqual(ws.interesting(fake, case_path=good, signature=sig, **kw), ws.NOT_INTERESTING)
        self.assertEqual(ws.interesting(fake, case_path=bad, signature={"kind": "divergent", "pointer": "/x"}, **kw),
                         ws.NOT_INTERESTING, "a different failure is not the one being minimized")
        self.assertEqual(ws.interesting(fake, case_path=empty, signature=sig, **kw), ws.NOT_INTERESTING)
        self.assertEqual(ws.interesting(fake, case_path=broken, signature=sig, **kw), ws.NOT_INTERESTING)
        self.assertEqual(list(work.iterdir()), [], "the predicate removes its scratch dir")

    def test_predicate_errors_are_not_read_as_not_interesting(self) -> None:
        class Broken(FakeOracle):
            def diff(self, **kwargs: Any) -> int:
                return ws.DIFF_INTERNAL

        case = self.tmp / "c.json"
        ws.write_json(case, walk_case(1, 3, ["bad"] * 3))
        sig_file = self.tmp / "sig.json"
        ws.write_json(sig_file, {"kind": "divergent", "pointer": "/p"})
        argv = ["interesting", "--binary", "/bin/true", "--switch", "holder", "--signature-file", str(sig_file),
                "--work", str(self.tmp / "w"), str(case)]
        self.assertEqual(ws.main(argv, cli=Broken()), ws.PREDICATE_ERROR)
        missing = argv[:]
        missing[missing.index(str(sig_file))] = str(self.tmp / "nope.json")
        with redirect_stderr(io.StringIO()):
            self.assertEqual(ws.main(missing, cli=FakeOracle()), ws.PREDICATE_ERROR)

    def test_usage_errors(self) -> None:
        for extra, message in ((("--switch", "layer-hosting"), "app switch"), (("--switch", "nope"), "no "),
                               (("--seeds", "0"), "--seeds must be >= 1")):
            with self.subTest(extra=extra):
                self.setUp()
                code, _, _, output = self.run_main(FakeOracle(), *extra)
                self.assertEqual(code, 2)
                self.assertIn(message, output)
        empty = self.tmp / "empty-registry"
        empty.mkdir()
        self.registry = empty
        code, _, _, output = self.run_main(FakeOracle())
        self.assertEqual(code, 2)
        self.assertIn("p15-oracle-232", output)

    def test_work_dir_is_outside_the_checkout_and_fresh(self) -> None:
        with self.assertRaises(ws.UsageError):
            ws.resolve_work(ws.REPO / "tmp-walks")
        code, work, _, _ = self.run_main(FakeOracle(), seeds=2)
        self.assertEqual(code, 0)
        code, _, _, output = self.run_main(FakeOracle(), seeds=2)
        self.assertEqual(code, 2)
        self.assertIn("earlier run", output)

    def test_signature_and_names(self) -> None:
        self.assertEqual(ws.generalize_pointer("/daemon/workspaces/12/panes/0/title"), "/daemon/workspaces/*/panes/*/title")
        self.assertEqual(ws.generalize_pointer(None), "")
        self.assertEqual(ws.committed_id("holder", "Walk_00042", "x"), "holder-walk-00042")
        long_id = ws.committed_id("holder", "s" * 100, "content")
        self.assertLessEqual(len(long_id), ws.CASE_ID_MAX)
        self.assertRegex(long_id, r"^[a-z0-9][a-z0-9-]{0,63}$")

    def test_argv_contracts(self) -> None:
        self.assertEqual(ws.gen_argv(Path("/c"), first_seed=5, count=3, length=30),
                         ["gen", "--suite", "walks", "--corpus", "/c", "--first-seed", "5", "--count", "3", "--length", "30"])
        argv = ws.diff_argv(switch="holder", corpus=Path("/c"), binary="/b", out=Path("/o"), jobs=200, sha="abc",
                            retry_limit=0, repeat=2)
        self.assertEqual(argv[:4], ["diff", "--switch", "holder", "--product"])
        for flag, value in (("--suite", "walks"), ("--binary", "/b"), ("--ref", "abc"), ("--retry-limit", "0"),
                            ("--repeat", "2"), ("--jobs", "200")):
            self.assertEqual(argv[argv.index(flag) + 1], value)

    def test_oracle_diff_accepts_the_argv(self) -> None:
        """The diff argv parses with oracle.py's own parser (the --switch run then needs 111's registry)."""
        import oracle

        argv = ws.diff_argv(switch="holder", corpus=self.tmp, binary="/b", out=self.tmp / "o", jobs=4, sha="abc",
                            retry_limit=0, repeat=2, flaky_out=self.tmp / "f.jsonl")
        args = oracle.build_parser().parse_args(argv)
        self.assertEqual((args.switch, args.product, args.suite, args.retry_limit, args.repeat),
                         ("holder", "daemon", ["walks"], 0, 2))


if __name__ == "__main__":
    unittest.main()
