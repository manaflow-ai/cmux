#!/usr/bin/env python3
"""Offline tests for fleet.py: step keys and commands, rejoining without resubmitting, the per-shard same-host
check (task p15-oracle-008) and the merged comparison through oracle.py and diff.py.

Run: python3 -I scripts/cmux-next/oracle/fleet_test.py (or fleet.py --selftest). A fake cmux-ci stands in for
the fleet; the run directories come from oracle.perform_run with oracle_cli_test's fake driver.
"""

from __future__ import annotations

import argparse
import io
import json
import re
import sys
import tarfile
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from typing import Callable, Dict, List, Optional, Sequence

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import fleet  # noqa: E402
import oracle  # noqa: E402
from oracle_cli_test import FakeDriver, options, write_corpus  # noqa: E402

BASE, HEAD = "a" * 40, "b" * 40
FIVE = {"name": "aws-m4pro-5", "os": "Darwin", "osVersion": "26.1", "arch": "arm64",
        "display": "1920 x 1080 @ 60.00Hz (3840 x 2160 px), 1 display"}
SIX = {**FIVE, "name": "aws-m4pro-6"}


def RESOLVE(ref: str) -> str:
    return {"base": BASE, "head": HEAD}.get(ref, HEAD)


def diff_args(*argv: str) -> argparse.Namespace:
    return fleet.build_parser().parse_args(["diff", *argv])


def request(*argv: str) -> fleet.Request:
    return fleet.request_from_args(diff_args(*argv), resolve_ref=RESOLVE)


class FakeCi:
    """cmux-ci: `run` prints a step line and exits with `codes[i]`; `artifact` writes shard i's tarball."""

    def __init__(self, tarballs: Dict[int, Path], codes: Optional[Dict[int, int]] = None) -> None:
        self.tarballs = tarballs
        self.codes = codes or {}
        self.calls: List[List[str]] = []

    def __call__(self, command: Sequence[str], on_line: Callable[[str], None]) -> int:
        command = list(command)
        self.calls.append(command)
        verb = command[1]
        if verb == "run":
            key = command[command.index("--key") + 1]
            index = int(re.search(r"-s(\d+)of\d+$", key).group(1))
            on_line(f"cmux-ci: step step-{index} (isolated, key {key})")
            on_line("oracle.sh: side a ...")
            return self.codes.get(index, 0)
        if verb == "wait":
            return self.codes.get(int(command[2].split("-")[1]), 0)
        if verb == "artifact":
            index = int(command[2].split("-")[1])
            Path(command[3]).write_bytes(self.tarballs[index].read_bytes())
            return 0
        raise AssertionError(f"unexpected cmux-ci {command}")

    def verbs(self) -> List[str]:
        return [call[1] for call in self.calls]


def make_shards(tmp: Path, total: int, hosts: Dict[int, tuple], value_of=None) -> Dict[int, Path]:
    """Shard i's step artifact: a/ and b/ run dirs of shard i/total, with receipt hosts hosts[i] = (a, b)."""
    write_corpus(tmp / "corpus", suites=("alpha",), per_suite=6)
    cases, _ = oracle.load_corpus(tmp / "corpus")
    tarballs = {}
    for index in range(total):
        root = tmp / "src" / str(index)
        for side, host, driver in (("a", hosts[index][0], FakeDriver()), ("b", hosts[index][1], FakeDriver(value_of=value_of))):
            out = root / side
            with redirect_stdout(io.StringIO()):
                oracle.perform_run(options(tmp, shard=(index, total), out=out, run_id=f"{side}{index}"), cases,
                                   driver.open_session, None, {})
            path = out / "receipt.json"
            receipt = json.loads(path.read_text())
            receipt["host"] = host
            path.write_text(json.dumps(receipt))
        (root / "pair.json").write_text("{}")
        tarballs[index] = tmp / f"shard{index}.tgz"
        with tarfile.open(tarballs[index], "w:gz") as tar:
            for name in ("a", "b", "pair.json"):
                tar.add(root / name, arcname=name)
    return tarballs


def run_diff(tmp: Path, ci: FakeCi, *argv: str) -> int:
    out = tmp / "out"
    args = ["diff", "--base", "base", "--head", "head", "--out", str(out), "--expectations-root",
            str(tmp / "expectations"), *argv]
    with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
        return fleet.main(args, fleet=fleet.Fleet(runner=ci, emit=lambda line: None, resolve_ref=RESOLVE))


class RequestTests(unittest.TestCase):
    def test_key_is_stable_and_names_the_request(self):
        one, two = request("--base", "base", "--head", "head"), request("--base", "base", "--head", "head")
        self.assertEqual([one.key(i) for i in range(6)], [two.key(i) for i in range(6)])
        self.assertTrue(one.key(2).endswith("-s2of6"))
        self.assertLessEqual(len(one.key(5)), 120)
        self.assertNotEqual(one.key(0), request("--base", "base", "--head", "head", "--suite", "actions").key(0))
        self.assertNotEqual(one.key(0), request("--base", "base", "--head", "head", "--attempt", "2").key(0))
        self.assertNotEqual(one.key(0), request("--base", "base", "--head", "head", "--shards", "3").key(0))

    def test_shuffle_seed_is_one_per_request(self):
        one = request("--base", "base", "--head", "head", "--shuffle")
        self.assertEqual(one.selection, request("--base", "base", "--head", "head", "--shuffle").selection)
        self.assertTrue(any(arg.startswith("--seed=") for arg in one.selection))
        self.assertIn("--seed=7", request("--base", "base", "--head", "head", "--shuffle", "--seed", "7").selection)

    def test_step_command_runs_both_sides_in_one_isolated_step(self):
        req = request("--base", "base", "--head", "head", "--suite", "actions", "--shards", "3")
        command = fleet.run_command_line(req, fleet.Shard(1, req.key(1), Path("/tmp/x")))
        self.assertEqual(command[:6], ["cmux-ci", "run", "--class", "isolated", "--script", "scripts/measure/oracle.sh"])
        self.assertEqual(command[command.index("--ref") + 1], HEAD)
        self.assertIn("--no-supersede", command)
        self.assertEqual(command[command.index("--artifact") + 1], "artifacts/oracle/shard.tgz")
        self.assertEqual([a for a in command if a.startswith("--arg=")],
                         ["--arg=pair", f"--arg=--base={BASE}", "--arg=--shard=1/3", "--arg=--build=bench",
                          "--arg=--suite=actions"])
        self.assertNotIn("maclease", " ".join(command))

    def test_switch_and_launch_config_build_one_ref(self):
        lc = request("--arm", "launch-config", "--ref", "head")
        self.assertEqual((lc.mode, lc.labels, lc.base), ("launch-config", ("default", "launch-config"), None))
        self.assertIn("--arm=launch-config", lc.step_args(0))

    def test_bad_requests_are_refused(self):
        for argv in (["--base", "base"], ["--base", "base", "--head", "head", "--arm", "launch-config"],
                     ["--product", "daemon", "--base", "base", "--head", "head"], [],
                     ["--switch", "no-such-switch-p15-oracle-008"]):
            with self.assertRaises(fleet.FleetError, msg=argv):
                request(*argv)

    def test_oracle_options_that_cannot_apply_are_refused(self):
        with redirect_stderr(io.StringIO()) as err:
            code = fleet.main(["diff", "--product", "app", "--base", "x", "--head", "y", "--base-binary=/tmp/a"])
        self.assertEqual(code, fleet.EXIT_FAILED)
        self.assertIn("--base-binary", err.getvalue())


class PairingTests(unittest.TestCase):
    def test_paired_shards_on_two_minis_compare_and_pass(self):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            ci = FakeCi(make_shards(tmp, 3, {0: (FIVE, FIVE), 1: (SIX, SIX), 2: (FIVE, FIVE)}))
            self.assertEqual(run_diff(tmp, ci, "--shards", "3"), 0)
            self.assertEqual(sorted(ci.verbs()), ["artifact"] * 3 + ["run"] * 3)
            document = json.loads((tmp / "out" / "fleet.json").read_text())
            self.assertEqual(document["verdict"], "pass")
            self.assertEqual(document["shards"][1]["hosts"]["a"]["name"], "aws-m4pro-6")
            comparison = json.loads((tmp / "out" / "comparison.json").read_text())
            self.assertEqual((comparison["compared"], comparison["divergent"]), (6, []))

    def test_forced_cross_host_pair_is_refused(self):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            ci = FakeCi(make_shards(tmp, 2, {0: (FIVE, FIVE), 1: (FIVE, SIX)}))
            self.assertEqual(run_diff(tmp, ci, "--shards", "2"), oracle.EXIT_REFUSED)
            document = json.loads((tmp / "out" / "fleet.json").read_text())
            self.assertEqual(document["verdict"], "host-mismatch")
            self.assertEqual(list(document["mismatched"]), ["shard 1"])
            self.assertIn("name ('aws-m4pro-5' != 'aws-m4pro-6')", document["mismatched"]["shard 1"])
            self.assertFalse((tmp / "out" / "comparison.json").exists())

    def test_cross_os_and_cross_display_pairs_are_refused(self):
        for other in ({**FIVE, "osVersion": "27.0"}, {**FIVE, "display": "1600 x 1000 @ 120.00Hz (1600 x 1000 px), 2 displays"}):
            with tempfile.TemporaryDirectory() as raw:
                tmp = Path(raw)
                ci = FakeCi(make_shards(tmp, 1, {0: (FIVE, other)}))
                self.assertEqual(run_diff(tmp, ci, "--shards", "1"), oracle.EXIT_REFUSED, other)

    def test_diff_py_refuses_shards_paired_across_hosts_after_merge(self):
        # Each shard's own pair matches, but side B's shard 1 came from another mini than side A's: the merged
        # per-case hosts differ, and oracle.py's comparison (diff.py) refuses those cases.
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            make_shards(tmp, 2, {0: (FIVE, FIVE), 1: (SIX, SIX)})
            make_shards(tmp / "other", 2, {0: (FIVE, FIVE), 1: (FIVE, FIVE)})
            a_dirs = [tmp / "src" / str(i) / "a" for i in range(2)]
            b_dirs = [tmp / "other" / "src" / str(i) / "b" for i in range(2)]
            argv = ["diff", "--out", str(tmp / "cmp"), "--expectations-root", str(tmp / "expectations")]
            argv += [x for d in a_dirs for x in ("--base-run", str(d))] + [x for d in b_dirs for x in ("--head-run", str(d))]
            with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
                code = oracle.main(argv)
            self.assertEqual(code, oracle.EXIT_REFUSED)
            self.assertTrue(json.loads((tmp / "cmp" / "comparison.json").read_text())["refused"].startswith("host-mismatch"))

    def test_divergence_is_reported(self):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            ci = FakeCi(make_shards(tmp, 2, {0: (FIVE, FIVE), 1: (FIVE, FIVE)},
                                    value_of=lambda cid, n: "changed" if cid == "alpha/case-003" else "v-" + cid))
            self.assertEqual(run_diff(tmp, ci, "--shards", "2"), 1)
            comparison = json.loads((tmp / "out" / "comparison.json").read_text())
            self.assertEqual(comparison["divergent"], ["alpha/case-003"])


class WaitTests(unittest.TestCase):
    def test_rerun_waits_for_the_saved_step_and_never_resubmits(self):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            tarballs = make_shards(tmp, 2, {0: (FIVE, FIVE), 1: (FIVE, FIVE)})
            first = FakeCi(tarballs, codes={1: 130})
            self.assertEqual(run_diff(tmp, first, "--shards", "2"), fleet.EXIT_FAILED)
            self.assertEqual(json.loads((tmp / "out" / "shards" / "1" / "step.json").read_text())["step"], "step-1")
            again = FakeCi(tarballs)
            self.assertEqual(run_diff(tmp, again, "--shards", "2"), 0)
            self.assertEqual(again.calls, [["cmux-ci", "wait", "step-1"],
                                           ["cmux-ci", "artifact", "step-1", str(tmp / "out" / "shards" / "1" / "shard.tgz")]])

    def test_failed_step_is_reported_once(self):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            ci = FakeCi(make_shards(tmp, 1, {0: (FIVE, FIVE)}), codes={0: 124})
            self.assertEqual(run_diff(tmp, ci, "--shards", "1"), fleet.EXIT_FAILED)
            self.assertEqual(ci.verbs(), ["run"])
            document = json.loads((tmp / "out" / "fleet.json").read_text())
            self.assertEqual(document["verdict"], "failed")
            self.assertIn("ran past --timeout", document["shards"][0]["error"])

    def test_another_request_in_the_same_out_is_refused(self):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            ci = FakeCi(make_shards(tmp, 1, {0: (FIVE, FIVE)}))
            self.assertEqual(run_diff(tmp, ci, "--shards", "1"), 0)
            self.assertEqual(run_diff(tmp, ci, "--shards", "1", "--suite", "alpha"), fleet.EXIT_FAILED)

    def test_compare_again_offline(self):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            ci = FakeCi(make_shards(tmp, 2, {0: (FIVE, FIVE), 1: (SIX, SIX)}))
            self.assertEqual(run_diff(tmp, ci, "--shards", "2"), 0)
            with redirect_stdout(io.StringIO()):
                self.assertEqual(fleet.main(["compare", str(tmp / "out")]), 0)


class ExtractTests(unittest.TestCase):
    def test_member_outside_the_target_is_refused(self):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            (tmp / "evil").write_text("x")
            archive = tmp / "bad.tgz"
            with tarfile.open(archive, "w:gz") as tar:
                tar.add(tmp / "evil", arcname="../evil")
            with self.assertRaises(fleet.FleetError):
                fleet.extract(archive, tmp / "target")
            self.assertFalse((tmp / "target").exists())


def main() -> int:
    suite = unittest.defaultTestLoader.loadTestsFromModule(sys.modules[__name__])
    return 0 if unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful() else 1


if __name__ == "__main__":
    sys.exit(main())
