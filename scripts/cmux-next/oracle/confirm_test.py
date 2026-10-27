#!/usr/bin/env python3
"""Tests for confirm.py and route.py: a synthetic real, flaky and base-red set through the real
oracle.py runner, diff.py and the OWNERS.md parser of guardrails.py.

Run: python3 -I scripts/cmux-next/oracle/confirm_test.py (stdlib unittest). A scripted driver stands in
for the product; a launcher double turns each rerun request into `oracle.py run` options with oracle.py's
own parser, so the options confirm.py builds are the ones a real rerun would get.
"""

from __future__ import annotations

import io
import json
import sys
import tempfile
import unittest
import unittest.mock
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import confirm  # noqa: E402
import oracle  # noqa: E402
import route  # noqa: E402

BASE_SHA = "a" * 40
HEAD_SHA = "b" * 40


def quiet(fn, *args, **kwargs):
    with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
        return fn(*args, **kwargs)


class Script:
    """(side, stage, case) -> (status, value); stage is orig, retry or alone. Missing entries: Pass, "v-<case>"."""

    def __init__(self, table: Dict[Tuple[str, str, str], Tuple[str, str]]) -> None:
        self.table = table

    def answer(self, side: str, stage: str, cid: str) -> Tuple[str, str]:
        for key in ((side, stage, cid), (side, "*", cid)):
            if key in self.table:
                return self.table[key]
        return "Pass", "v-" + cid


class ScriptSession:
    def __init__(self, script: Script, side: str, stage: str) -> None:
        self.script, self.side, self.stage = script, side, stage

    def run_case(self, case, ctx):
        status, value = self.script.answer(self.side, self.stage, ctx["case_id"])
        return {"status": status, "checkpoints": [
            {"step": "s1", "checkpoint": "before", "snapshot": {"panes": 1}},
            {"step": "s1", "checkpoint": "settled", "snapshot": {"panes": 1, "value": value}},
        ]}

    def close(self) -> None:
        pass


def opener(script: Script, side: str, stage: str):
    return lambda ctx: ScriptSession(script, side, stage)


def write_corpus(root: Path, ids: List[str]) -> Path:
    for cid in ids:
        path = root / f"{cid}.json"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps({"id": cid, "steps": [{"id": "s1", "op": "snapshot"}]}))
    return root


def run_options(tmp: Path, out: Path, run_id: str, sha: str, **overrides) -> oracle.RunOptions:
    base = dict(
        product="daemon", suites=("all",), filters=(), shard=(0, 1), jobs=4, batch_limit=1, repeat=1,
        retry_limit=3, seed=None, platform="linux", build="debug", switch=None, arm=None, switches={},
        ref=sha, tag=None, binary=None, corpus=tmp / "corpus", out=out, state_base=Path("/tmp/o"),
        run_id=run_id, expectations_root=tmp / "expectations", isolation="none",
    )
    base.update(overrides)
    return oracle.RunOptions(**base)


class ScriptLauncher:
    """A rerun through oracle.py's parser and runner, answered by the script for its side and stage."""

    def __init__(self, tmp: Path, script: Script, fail_labels=()) -> None:
        self.tmp, self.script, self.fail_labels = tmp, script, set(fail_labels)
        self.requests: List[confirm.RunRequest] = []
        self.argv: List[List[str]] = []

    def run(self, request: confirm.RunRequest) -> Path:
        self.requests.append(request)
        if request.label in self.fail_labels:
            raise confirm.LaunchError(f"{request.label}: the build failed")
        side = request.side
        argv = ["run", "--suite", request.suites(), *side.arm_args(), "--out", str(request.out),
                *request.selection_args(), "--corpus", str(self.tmp / "corpus"),
                "--expectations-root", str(self.tmp / "expectations")]
        self.argv.append(argv)
        args = oracle.build_parser().parse_args(argv)
        options = oracle.options_from_args(args, retry_default=None, out=request.out, run_id=args.run_id,
                                           switch=args.switch, arm=args.arm, switches={}, ref=side.sha or None,
                                           binary=None)
        cases, _ = oracle.load_corpus(self.tmp / "corpus")
        stage = "retry" if request.label.startswith("retry") else "alone"
        who = "head" if side.label == "head" else "base"
        quiet(oracle.perform_run, options, cases, opener(self.script, who, stage), None, {})
        return request.out


IDS = ["alpha/real", "alpha/flaky", "alpha/elsewhere", "alpha/order", "alpha/crash", "alpha/same"]

# The synthetic set: one case per class confirm.py tells apart.
SET = Script({
    # A real regression: the head answers v-new every time; the base answers its own value alone too.
    ("head", "*", "alpha/real"): ("Pass", "v-new"),
    # Flaky head: the first head run differs, the retry matches the base.
    ("head", "orig", "alpha/flaky"): ("Pass", "v-glitch"),
    # A head that changes its answer: diverges on retry, but at another value.
    ("head", "orig", "alpha/elsewhere"): ("Pass", "v-one"),
    ("head", "retry", "alpha/elsewhere"): ("Pass", "v-two"),
    # An order-dependent base: in its run the base answered v-polluted, alone it answers the head's value.
    ("head", "*", "alpha/order"): ("Pass", "v-clean"),
    ("base", "orig", "alpha/order"): ("Pass", "v-polluted"),
    ("base", "alone", "alpha/order"): ("Pass", "v-clean"),
    # A red base: it crashes every time; the head passes.
    ("base", "*", "alpha/crash"): ("Crash", "v-alpha/crash"),
})
CLASSES = {"alpha/real": "confirmed", "alpha/flaky": "flake", "alpha/elsewhere": "flake",
           "alpha/order": "base-red", "alpha/crash": "base-red"}


class Fixture:
    def __init__(self, tmp: Path, script: Script = SET, shards: int = 1, seed: Optional[int] = None) -> None:
        self.tmp = tmp
        write_corpus(tmp / "corpus", IDS)
        cases, errors = oracle.load_corpus(tmp / "corpus")
        assert not errors, errors
        sides = []
        for side, sha in (("base", BASE_SHA), ("head", HEAD_SHA)):
            dirs = []
            for index in range(shards):
                out = tmp / f"{side}{index}"
                quiet(oracle.perform_run, run_options(tmp, out, f"{side}-s{index}", sha, shard=(index, shards), seed=seed),
                      cases, opener(script, side, "orig"), None, {})
                dirs.append(out)
            sides.append(dirs)
        argv = ["diff", "--out", str(tmp / "cmp"), "--expectations-root", str(tmp / "expectations")]
        argv += [a for d in sides[0] for a in ("--base-run", str(d))]
        argv += [a for d in sides[1] for a in ("--head-run", str(d))]
        self.diff_code = quiet(oracle.main, argv)
        self.comparison = json.loads((tmp / "cmp" / "comparison.json").read_text())

    def confirm(self, launcher, *extra: str) -> Tuple[int, List[Dict[str, Any]], Dict[str, Any]]:
        argv = ["--diff", str(self.tmp / "cmp"), "--flaky-out", str(self.tmp / "q" / "flaky.jsonl"),
                "--base-red-out", str(self.tmp / "q" / "base-red.jsonl"), "--route-out", str(self.tmp / "q" / "route.jsonl"),
                *extra]
        with unittest.mock.patch.object(route, "git_changed_files",
                                        lambda repo: lambda base, head: ["scripts/cmux-next/oracle/diff.py", "nobody/owns.txt"]):
            code = quiet(confirm.main, argv, launcher=launcher)
        out = self.tmp / "cmp" / "confirm"
        rows = [json.loads(line) for line in (out / "confirmed.jsonl").read_text().splitlines()] \
            if (out / "confirmed.jsonl").is_file() else []
        summary = json.loads((out / "confirm.json").read_text()) if (out / "confirm.json").is_file() else {}
        return code, rows, summary

    def queue(self, name: str) -> List[Dict[str, Any]]:
        path = self.tmp / "q" / name
        return [json.loads(line) for line in path.read_text().splitlines()] if path.is_file() else []


class ConfirmTests(unittest.TestCase):
    def test_synthetic_real_flaky_and_base_red_set_is_classified(self):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            fixture = Fixture(tmp)
            self.assertEqual(fixture.diff_code, 1)
            self.assertEqual(sorted(fixture.comparison["divergent"]), sorted(CLASSES))
            launcher = ScriptLauncher(tmp, SET)
            code, rows, summary = fixture.confirm(launcher)
            self.assertEqual(code, confirm.EXIT_CONFIRMED)
            self.assertEqual({row["case"]: row["class"] for row in rows}, CLASSES)
            self.assertEqual(summary["counts"], {"confirmed": 1, "flake": 2, "base-red": 2, "unconfirmed": 0})
            by_case = {row["case"]: row for row in rows}
            # Every line carries three verdicts; the routed one fail, fail, pass with three run ids.
            for row in rows:
                self.assertEqual(set(row["verdicts"]), {"head", "head_retry", "base"})
            real = by_case["alpha/real"]["verdicts"]
            self.assertEqual([real[k]["verdict"] for k in ("head", "head_retry", "base")], ["fail", "fail", "pass"])
            self.assertEqual(real["head"]["run_id"], "head-s0")
            self.assertIn("retry-s0of1", real["head_retry"]["run_id"])
            self.assertIn("alone-s0of1", real["base"]["run_id"])
            self.assertEqual(real["head"]["sha"], HEAD_SHA)
            self.assertEqual(real["base"]["sha"], BASE_SHA)
            # The changed-value flake names both places; the flakes needed no base run.
            self.assertEqual(by_case["alpha/elsewhere"]["verdicts"]["head_retry"]["verdict"], "flaky")
            self.assertIn("v-two", by_case["alpha/elsewhere"]["verdicts"]["head_retry"]["detail"])
            self.assertEqual(by_case["alpha/flaky"]["verdicts"]["head_retry"]["verdict"], "pass")
            self.assertEqual(by_case["alpha/flaky"]["verdicts"]["base"]["verdict"], "not-run")
            self.assertIn("v-polluted", by_case["alpha/order"]["verdicts"]["base"]["detail"])
            self.assertIn("not an expected one", by_case["alpha/crash"]["verdicts"]["base"]["detail"])
            # Queues: flakes to MQ-flakes, base reds to base-red, only the confirmed one to route.
            self.assertEqual(sorted(r["case"] for r in fixture.queue("flaky.jsonl")), ["alpha/elsewhere", "alpha/flaky"])
            self.assertEqual(sorted(r["case"] for r in fixture.queue("base-red.jsonl")), ["alpha/crash", "alpha/order"])
            routed = fixture.queue("route.jsonl")
            self.assertEqual([r["case"] for r in routed], ["alpha/real"])
            self.assertEqual(summary["route"]["skipped"], {"base-red": 2, "flake": 2})
            line = routed[0]
            self.assertEqual([line["verdicts"][k]["verdict"] for k in ("head", "head_retry", "base")], ["fail", "fail", "pass"])
            self.assertTrue(all(line["verdicts"][k]["run_id"] for k in ("head", "head_retry", "base")))
            self.assertTrue(any(o["owner"].startswith("PL-oracle") for o in line["owners"]))
            self.assertEqual(line["unowned_files"], ["nobody/owns.txt"])
            self.assertIn(f"--base {BASE_SHA} --head {HEAD_SHA}", line["replay"]["oracle"])
            self.assertIn("--filter alpha/real", line["replay"]["oracle"])
            self.assertIn("diff.py", line["replay"]["diff"])
            # A second confirm of the same diff reruns into its own dir; the route queue keeps one line per divergence.
            again = ScriptLauncher(tmp, SET)
            code, rows, _ = fixture.confirm(again)
            self.assertEqual({row["case"]: row["class"] for row in rows}, CLASSES)
            self.assertTrue({r.out for r in again.requests}.isdisjoint({r.out for r in launcher.requests}))
            self.assertEqual([r["case"] for r in fixture.queue("route.jsonl")], ["alpha/real"])

    def test_head_retry_reruns_the_divergent_shards_with_their_seeds_and_the_base_alone(self):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            fixture = Fixture(tmp, shards=3, seed=4242)
            launcher = ScriptLauncher(tmp, SET)
            code, rows, _ = fixture.confirm(launcher, "--no-route")
            self.assertEqual(code, confirm.EXIT_CONFIRMED)
            self.assertEqual({row["case"]: row["class"] for row in rows}, CLASSES)
            retries = [r for r in launcher.requests if r.label.startswith("retry")]
            divergent_shards = sorted({oracle.shard_of(cid, 3) for cid in CLASSES})
            self.assertEqual(sorted(r.shard[0] for r in retries), divergent_shards)
            for request in retries:
                self.assertEqual(request.shard[1], 3)
                self.assertEqual(request.seed, 4242)
                self.assertEqual((request.batch_limit, request.repeat, request.retry_limit), (1, 1, 3))
                self.assertEqual(request.side.label, "head")
            # The head verdict names the shard run the case was in.
            for row in rows:
                self.assertEqual(row["verdicts"]["head"]["run_id"], f"head-s{oracle.shard_of(row['case'], 3)}")
            alone = [r for r in launcher.requests if r.label.startswith("alone")]
            self.assertTrue(alone)
            for request in alone:
                self.assertEqual(request.side.label, "base")
                self.assertEqual((request.shard, request.batch_limit, request.retry_limit, request.seed), ((0, 1), 1, 0, None))
            alone_cases = sorted(f for r in alone for f in r.filters)
            self.assertEqual(alone_cases, ["alpha/crash", "alpha/order", "alpha/real"])
            self.assertFalse((tmp / "q" / "route.jsonl").exists())

    def test_a_rerun_without_a_receipt_leaves_the_cases_unconfirmed(self):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            fixture = Fixture(tmp)
            code, rows, summary = fixture.confirm(ScriptLauncher(tmp, SET, fail_labels={"alone-s0of1"}))
            self.assertEqual(code, confirm.EXIT_INCOMPLETE)
            by_case = {row["case"]: row for row in rows}
            for cid in ("alpha/real", "alpha/order", "alpha/crash"):
                self.assertEqual(by_case[cid]["class"], "unconfirmed")
                self.assertEqual(by_case[cid]["verdicts"]["base"]["verdict"], "not-comparable")
                self.assertIn("the build failed", by_case[cid]["verdicts"]["base"]["detail"])
            self.assertEqual(fixture.queue("route.jsonl"), [])
            self.assertEqual(summary["counts"]["unconfirmed"], 3)

    def test_a_clean_comparison_confirms_nothing(self):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            fixture = Fixture(tmp, script=Script({}))
            self.assertEqual(fixture.diff_code, 0)
            launcher = ScriptLauncher(tmp, SET)
            code, rows, _ = fixture.confirm(launcher)
            self.assertEqual((code, rows, launcher.requests), (confirm.EXIT_NONE, [], []))

    def test_refused_and_old_comparisons_are_refused(self):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            fixture = Fixture(tmp)
            path = tmp / "cmp" / "comparison.json"
            refused = {**fixture.comparison, "refused": "host-mismatch: name"}
            path.write_text(json.dumps(refused))
            code, _, _ = fixture.confirm(ScriptLauncher(tmp, SET))
            self.assertEqual(code, confirm.EXIT_INCOMPLETE)
            old = {k: v for k, v in fixture.comparison.items() if k not in ("a_dir", "b_dir", "expected_files")}
            path.write_text(json.dumps(old))
            code, _, _ = fixture.confirm(ScriptLauncher(tmp, SET))
            self.assertEqual(code, confirm.EXIT_USAGE)


class LauncherTests(unittest.TestCase):
    def request(self, tmp: Path, receipt_extra=None, **overrides) -> confirm.RunRequest:
        receipt = {"schema": oracle.RUN_SCHEMA, "runId": "h", "sha": HEAD_SHA, "product": "daemon", "platform": "linux",
                   "isolation": {"mode": "netns"}, "seeds": {"2": 7}, "shards": [2],
                   "config": {"suites": ["alpha", "beta"], "filters": [], "shard_total": 4, "batch_limit": 1,
                              "repeat": 1, "retry_limit": 3, "build": "debug", "switch": "holder", "arm": "new",
                              "tag": None, "binary": "/tmp/cmux-tui"}}
        receipt.update(receipt_extra or {})
        side = confirm.SideRun("new", tmp / "head", receipt)
        fields = dict(confirm_id="confirm-x", label="retry-s2of4", side=side, shard=(2, 4), seed=side.seed(2), filters=(),
                      batch_limit=1, repeat=1, retry_limit=3, out=tmp / "out")
        fields.update(overrides)
        return confirm.RunRequest(**fields)

    def test_queue_command_rebuilds_the_sha_fresh_with_the_same_config(self):
        with tempfile.TemporaryDirectory() as raw:
            command = confirm.QueueLauncher().command(self.request(Path(raw)))
            self.assertEqual(command[2:9], ["run", HEAD_SHA, "--suite", "alpha,beta", "--arm", "holder=new", "--side"])
            self.assertIn("--fresh", command)
            after = command[command.index("--") + 1:]
            for flag, value in (("--shard", "2/4"), ("--seed", "7"), ("--retry-limit", "3"), ("--batch-limit", "1"),
                                ("--isolation", "netns"), ("--run-id", "confirm-x-retry-s2of4")):
                self.assertEqual(after[after.index(flag) + 1], value)
            # linux_run.sh refuses these after `--`: it sets them itself.
            for refused in ("--out", "--binary", "--ref", "--suite", "--switch", "--arm"):
                self.assertNotIn(refused, after)
            # oracle.py's own parser takes the forwarded options.
            oracle.build_parser().parse_args(["run", *after])

    def test_local_command_runs_the_recorded_binary(self):
        with tempfile.TemporaryDirectory() as raw:
            command = confirm.LocalLauncher().command(self.request(Path(raw)))
            args = oracle.build_parser().parse_args(command[3:])
            self.assertEqual((args.switch, args.arm, args.binary, args.ref, args.shard, args.seed),
                             ("holder", "new", "/tmp/cmux-tui", HEAD_SHA, "2/4", 7))

    def test_queue_refuses_a_receipt_without_a_sha(self):
        with tempfile.TemporaryDirectory() as raw:
            with self.assertRaises(confirm.LaunchError):
                confirm.QueueLauncher().command(self.request(Path(raw), {"sha": ""}))

    def test_fleet_step_repeats_the_shard_on_its_worker(self):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            pin = tmp / "fleet" / "shards" / "new" / "2" / "unpacked" / "run"
            pin.mkdir(parents=True)
            (pin.parent.parent / "step.json").write_text(json.dumps({"worker": "cmux17"}))
            request = self.request(tmp, {"product": "app"}, pin=pin)
            launcher = confirm.FleetLauncher(client="/usr/bin/true")
            seen = []

            def complete(fleet_self, shard):
                seen.append(shard)
                shard.run_dir = tmp / "got"
                return shard

            with unittest.mock.patch.object(launcher.fleet_module.Fleet, "complete", complete):
                self.assertEqual(launcher.run(request), tmp / "got")
            shard = seen[0]
            self.assertEqual((shard.index, shard.total, shard.sha, shard.target_worker), (2, 4, HEAD_SHA, "cmux17"))
            for arg in ("--shard=2/4", "--seed=7", "--retry-limit=3", "--switch=holder", "--arm=new", "--config=debug"):
                self.assertIn(arg, shard.args)


class RouteTests(unittest.TestCase):
    def row(self, **overrides) -> Dict[str, Any]:
        verdicts = {key: {"verdict": v, "run_id": f"run-{key}", "dir": None, "sha": HEAD_SHA, "detail": ""}
                    for key, v in (("head", "fail"), ("head_retry", "fail"), ("base", "pass"))}
        row = {"schema": confirm.SCHEMA, "case": "alpha/real", "class": "confirmed", "reason": "", "mode": "base-head",
               "product": "daemon", "switch": None, "arm": None, "a_label": "base", "b_label": "head",
               "base_sha": BASE_SHA, "head_sha": HEAD_SHA, "verdicts": verdicts,
               "finding": {"step": "s1", "checkpoint": "settled", "pointer": "/value", "a": "x", "b": "y",
                           "replay": "python3 -I scripts/cmux-next/oracle/diff.py A B --case alpha/real"},
               "comparison": "/tmp/cmp/comparison.json"}
        row.update(overrides)
        return row

    def route(self, tmp: Path, rows, registry: Optional[Path] = None, changed=("scripts/cmux-next/oracle/diff.py",)):
        source = tmp / "confirmed.jsonl"
        source.write_text("".join(json.dumps(r) + "\n" for r in rows))
        options = route.Options(out=tmp / "route.jsonl", registry=registry or tmp / "no-registry",
                                changed_files=lambda base, head: list(changed))
        return route.route_files([source], options)

    def test_only_head_fails_twice_and_base_passes_is_routed(self):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            bad_base = self.row(case="alpha/b")
            bad_base["verdicts"] = {**bad_base["verdicts"], "base": {**bad_base["verdicts"]["base"], "verdict": "not-run"}}
            no_run_id = self.row(case="alpha/c")
            no_run_id["verdicts"] = {**no_run_id["verdicts"], "head_retry": {**no_run_id["verdicts"]["head_retry"], "run_id": None}}
            result = self.route(tmp, [self.row(), bad_base, no_run_id, self.row(case="alpha/d", **{"class": "flake"})])
            self.assertEqual(result["routed"], 1)
            self.assertEqual(sorted(r["case"] for r in result["refused"]), ["alpha/b", "alpha/c"])
            self.assertEqual(result["skipped"], {"flake": 1})
            lines = [json.loads(l) for l in (tmp / "route.jsonl").read_text().splitlines()]
            self.assertEqual([l["case"] for l in lines], ["alpha/real"])

    def test_queue_replaces_a_rerouted_divergence_and_drops_unverified_lines(self):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            (tmp / "route.jsonl").write_text(json.dumps({"schema": route.SCHEMA, "key": "old", "case": "x"}) + "\n")
            first = self.route(tmp, [self.row()])
            self.assertEqual(first["dropped"], ["old"])
            second = self.route(tmp, [self.row(), self.row(case="alpha/other")])
            self.assertEqual(second["queue"], 2)
            lines = [json.loads(l) for l in (tmp / "route.jsonl").read_text().splitlines()]
            self.assertEqual(sorted(l["case"] for l in lines), ["alpha/other", "alpha/real"])
            self.assertTrue(all(route.queued(l) for l in lines))

    def test_a_switch_divergence_maps_to_its_plan_and_owner(self):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            registry = tmp / "registry"
            registry.mkdir()
            (registry / "holder.json").write_text(json.dumps({
                "owner": "PL-holder", "plan": "plans/cmux-next/chrome-parity/p15-oracle.md#f6",
                "old_paths": ["cmux-tui/crates/cmux-tui-core/src/oracle_state.rs"]}))
            self.route(tmp, [self.row(mode="switch", switch="holder", arm="new", base_sha=HEAD_SHA)], registry=registry,
                       changed=("should/not/be/read",))
            line = json.loads((tmp / "route.jsonl").read_text())
            self.assertEqual(line["switch_owner"], "PL-holder")
            self.assertEqual(line["files"], ["plans/cmux-next/chrome-parity/p15-oracle.md",
                                             "cmux-tui/crates/cmux-tui-core/src/oracle_state.rs"])
            self.assertEqual([o["count"] for o in line["owners"] if o["owner"].startswith("PL-oracle")], [2])
            self.assertIn(f"--switch holder --ref {HEAD_SHA}", line["replay"]["oracle"])
            self.assertTrue(line["key"].endswith(":switch=holder"))

    def test_cli_exit_codes(self):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            source = tmp / "c.jsonl"
            source.write_text(json.dumps(self.row()) + "\n")
            changed = lambda base, head: []  # noqa: E731
            self.assertEqual(quiet(route.main, [str(source), "--out", str(tmp / "r.jsonl")], changed_files=changed), 0)
            bad = self.row()
            bad["verdicts"]["base"]["verdict"] = "fail"
            source.write_text(json.dumps(bad) + "\n")
            self.assertEqual(quiet(route.main, [str(source), "--out", str(tmp / "r.jsonl")], changed_files=changed), 1)
            self.assertEqual(quiet(route.main, [str(tmp / "missing.jsonl"), "--out", str(tmp / "r.jsonl")]), 2)


class DelegationTests(unittest.TestCase):
    def test_oracle_delegates_confirm_and_route(self):
        self.assertEqual(oracle.DELEGATES["confirm"][0], "confirm.py")
        self.assertEqual(oracle.DELEGATES["route"][0], "route.py")
        self.assertTrue((HERE / "confirm.py").is_file() and (HERE / "route.py").is_file())


if __name__ == "__main__":
    unittest.main()
