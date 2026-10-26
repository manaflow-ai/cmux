#!/usr/bin/env python3
"""done_checks: the table matches p12-perf-process.md section 6, and the runner judges fake outputs.

Run: python3 -m unittest scripts/perf-lab/tests/test_done_checks.py
"""
from __future__ import annotations

import importlib.util
import io
import json
import re
import shlex
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

HERE = Path(__file__).resolve().parent
LAB = HERE.parent
REPO = LAB.parent.parent
SPEC = REPO / "plans/cmux-next/chrome-parity/p12-perf-process.md"
DESIGN = REPO / "plans/cmux-next/chrome-parity/design-result.json"

_spec = importlib.util.spec_from_file_location("perf_lab_done_checks_under_test", LAB / "done_checks.py")
dc = importlib.util.module_from_spec(_spec)
sys.modules[_spec.name] = dc
_spec.loader.exec_module(dc)


def spec_items() -> dict[int, str]:
    """Section 6's numbered items, each joined with the design JSON's done-check line of the same number and the
    section 7 definition of each machine queue (MQn) the item names."""
    text = SPEC.read_text(encoding="utf-8")
    section = text.split("## 6. Done checks", 1)[1].split("\n## ", 1)[0]
    queues = text.split("## 7. Machine queues", 1)[1].split("\n## ", 1)[0]
    definitions = {match.group(1): match.group(0) for match in
                   re.finditer(r"^- \*\*(MQ\d+):.*(?:\n  .*)*", queues, re.M)}
    items: dict[int, str] = {}
    current = None
    for line in section.splitlines():
        match = re.match(r"^(\d+)\. ", line)
        if match:
            current = int(match.group(1))
            items[current] = line
        elif current is not None:
            items[current] += "\n" + line
    program_checks = json.loads(DESIGN.read_text(encoding="utf-8"))["programs"]["p12-perf-process"]["done_checks"]
    for number, line in enumerate(program_checks[1:], start=1):
        items[number] = items.get(number, "") + "\n" + line
    for number, item in items.items():
        for mq in sorted(set(re.findall(r"\bMQ\d+\b", item))):
            items[number] += "\n" + definitions.get(mq, "")
    return items


def spec_form(argv: str) -> str:
    """The command as section 6 writes it: lab.py (and sheriff.py, `lab.py sheriff`) by its short name, without the
    runner's --json."""
    return (argv.replace("python3 scripts/perf-lab/lab.py", "lab.py")
            .replace("python3 scripts/perf-lab/sheriff.py", "lab.py sheriff").replace(" --json", ""))


def threshold_values(value: object):
    if isinstance(value, (tuple, list)):
        for item in value:
            yield from threshold_values(item)
    elif value != "":
        yield value


WORDS = {2: ("twice", "2")}


def appears(value: object, text: str) -> bool:
    if isinstance(value, bool):
        return True
    if isinstance(value, str):
        return value in text
    forms = {str(value), f"{value:g}"} | set(WORDS.get(value, ()))
    return any(re.search(rf"(?<![\d.]){re.escape(form)}(?![\d])", text) for form in forms)


class TableMatchesSpec(unittest.TestCase):
    def test_every_spec_item_has_a_row(self):
        self.assertEqual(sorted({c.number for c in dc.CHECKS}), sorted(spec_items()))

    def test_commands_are_the_spec_commands(self):
        items = spec_items()
        for check in dc.CHECKS:
            for command in check.commands:
                if command.spec:
                    with self.subTest(check=check.number, command=command.argv):
                        self.assertIn(spec_form(command.argv), items[check.number])

    def test_every_threshold_is_in_the_spec_text(self):
        items = spec_items()
        for check in dc.CHECKS:
            for key, value in check.threshold.items():
                for part in threshold_values(value):
                    with self.subTest(check=check.number, key=key, value=part):
                        self.assertTrue(appears(part, items[check.number]), f"{part!r} not in item {check.number}")

    def test_each_number_is_written_once(self):
        """Judges own no thresholds: no comparison in done_checks.py against a numeric literal other than 0."""
        source = (LAB / "done_checks.py").read_text(encoding="utf-8")
        judges = source.split("# --- judges", 1)[1].split("# --- the table", 1)[0]
        literals = re.findall(r"[<>]=?\s*(\d+(?:\.\d+)?)\b", judges)
        self.assertEqual([n for n in literals if float(n) != 0], [])

    def test_only_field_and_stability_are_reported_only(self):
        self.assertEqual({c.name for c in dc.CHECKS if c.reported_only}, {"field", "stability"})

    def test_queries_come_from_queues(self):
        names = {q for c in dc.CHECKS for q in c.queries}
        self.assertEqual(names, {"MQ1", "MQ2", "MQ5", "MQ6"})
        queues = dc._load_module("perf_lab_queues", LAB / "queues.py")
        self.assertTrue(all(queues.find(name).mq == name for name in names))


TARGETS_TEXT = "ok launch\nok idle-wakeups\ntargets mapped: 12/12\n"
GOOD_TARGETS = [
    dc.TargetMap("idle-wakeups", True, ("chromium", "webkit"), True, ("idle-tabs",)),
    dc.TargetMap("launch", False, (), True, ("launch-cold", "launch-warm")),
]


def aa_report(**summary):
    base = {"waterfall_hosts": ["m6-a"], "aa_runs_by_host": {"m6-a": 3, "m6-c": 0}, "series_days": 400,
            "false_alerts": 3, "false_alerts_per_100_series_days": 0.75, "latency_series_judged": 10,
            "median_cv_share_within": 0.9, "p99_cv_share_within": 0.8,
            "thresholds": {"median_cv": 0.05, "p99_cv": 0.1, "min_aa_runs_per_host": 3, "min_pairs": 3}}
    return {"summary": {**base, **summary}, "series": []}


GOOD_OUTPUTS = {
    "coverage --tier T0": {"planned": 144, "covered": 132, "batch_minutes": 10, "window_minutes": 60},
    "coverage --tier T1": {"newest_complete_age_hours": 1.5, "missing_families": []},
    "targets --check": TARGETS_TEXT,
    "runs --since 24h --json": [{"story": s, "kind": "waterfall"} for s in ("idle-tabs", "launch-cold", "launch-warm")],
    "stories --lint --format=paths": "scripts/perf-lab/perf_result.py\n",
    "--config debug": [],
    "--story bench-parity": [
        {"started": "2026-10-25T01:00:00Z", "results": [{"metric": "bench_parity.action_commit_delta_pct", "p50": 9}]},
        {"started": "2026-10-25T03:00:00Z", "results": [{"metric": "bench_parity.action_commit_delta_pct", "p50": 2.1}]}],
    "stories --orphans": [],
    "aa --since-live": aa_report(),
    "canary --last 3": [{"injected_sha": s, "culprit_sha": s, "alert_batches": 7, "alert_to_culprit_hours": 2.5,
                         "verification": "different"} for s in ("a1", "b2", "c3")],
    "sheriff.py --slo": {"groups": 4, "triage": {"missed": [], "pct": 100.0, "slo_hours": 1.0},
                      "culprit": {"median_hours": 3.0}, "stale": []},
    "play.py": [{"story": f"s{i}", "replays": 2, "digests_identical": True, "key_frame_p50_cv": 0.03,
                 "wpr_misses": 0} for i in range(6)],
    "field --since": {"builds": 2},
    "stability --since": {"crash_free": 0.998},
}


class FakeRunner:
    def __init__(self, outputs: dict[str, object], codes: dict[str, int] | None = None):
        self.outputs, self.codes, self.calls = outputs, codes or {}, []

    def __call__(self, argv, cwd, timeout_s):
        text = shlex.join(argv)
        self.calls.append(text)
        code = next((c for key, c in self.codes.items() if key in text), 0)
        for key, value in self.outputs.items():
            if key in text:
                return dc.CommandResult(text, code, value if isinstance(value, str) else json.dumps(value), "")
        return dc.CommandResult(text, code, "", "")


def good_queries(name, root):
    return ["scripts/cmux-next/perf-budgets.py", "scripts/cmux-next/perf-cron.py"] if name == "MQ1" else []


def kill_switch_dir() -> Path:
    directory = Path(tempfile.mkdtemp(prefix="done-checks-"))
    (directory / "off.json").write_text(json.dumps(
        {"features": [{"name": "perfLabKillProbe", "state": "off", "source": "remote"}]}))
    (directory / "on.json").write_text(json.dumps([{"name": "perfLabKillProbe", "state": "on", "source": "remote"}]))
    (directory / "safe-mode.log").write_text("Suite 'FeatureSafeModeTests' passed at 2026-10-25.\n")
    return directory


def outcomes(outputs=GOOD_OUTPUTS, codes=None, queries=good_queries, evidence=None, only=None, targets=GOOD_TARGETS,
             root=REPO):
    found = []
    checks = dc.select(only)
    code = dc.run_checks(checks, root, emit=found.append, runner=FakeRunner(outputs, codes), queries=queries,
                         kill_switch_evidence=evidence if evidence is not None else kill_switch_dir(),
                         targets=lambda root: targets)
    return code, {(o.check.number, o.check.name): o for o in found}


class Runner(unittest.TestCase):
    def test_all_pass_exits_zero(self):
        code, found = outcomes()
        self.assertEqual({k: o.reason for k, o in found.items() if o.status == dc.FAIL}, {})
        self.assertEqual(code, 0)
        self.assertEqual(found[(4, "release-grade")].measured["bench_parity.action_commit_delta_pct"], 2.1)

    def test_one_line_per_check_as_json(self):
        out = io.StringIO()
        with redirect_stdout(out):
            dc.run_checks(dc.CHECKS, REPO, runner=FakeRunner(GOOD_OUTPUTS), queries=good_queries,
                          kill_switch_evidence=kill_switch_dir(),
                          emit=lambda o: print(json.dumps(o.as_json(), sort_keys=True)))
        lines = out.getvalue().splitlines()
        self.assertEqual(len(lines), len(dc.CHECKS))
        self.assertTrue(all(set(json.loads(line)) >= {"check", "name", "status", "threshold", "measured"}
                            for line in lines))

    def test_threshold_breaches_fail(self):
        cases = {
            (1, "coverage-t0"): ("coverage --tier T0", {**GOOD_OUTPUTS["coverage --tier T0"], "covered": 129}),
            (2, "coverage-t1"): ("coverage --tier T1", {"newest_complete_age_hours": 3.2, "missing_families": []}),
            (3, "targets-mapped"): ("targets --check", "targets mapped: 11/12\n"),
            (4, "release-grade"): ("--config debug", [{"started": "x", "results": []}]),
            (8, "no-orphan-benches"): ("stories --orphans", ["scripts/cmux-next/old-bench.py"]),
            (9, "noise"): ("aa --since-live", aa_report(false_alerts_per_100_series_days=1.25)),
            (10, "pipeline-proof"): ("canary --last 3", GOOD_OUTPUTS["canary --last 3"][:2]),
            (12, "sheriff-slo"): ("sheriff.py --slo", {**GOOD_OUTPUTS["sheriff.py --slo"],
                                                    "culprit": {"median_hours": 4.5}}),
            (15, "corpus"): ("play.py", GOOD_OUTPUTS["play.py"][:5]),
        }
        for key, (output, value) in cases.items():
            with self.subTest(check=key):
                code, found = outcomes({**GOOD_OUTPUTS, output: value}, only=str(key[0]))
                self.assertEqual(found[key].status, dc.FAIL)
                self.assertEqual(code, 1)

    def test_browser_target_without_a_webkit_row_fails(self):
        targets = [dc.TargetMap("idle-wakeups", True, ("chromium",), True, ("idle-tabs",)), GOOD_TARGETS[1]]
        _, found = outcomes(only="3", targets=targets)
        self.assertIn("webkit", found[(3, "targets-mapped")].reason)

    def test_mapped_story_without_a_stored_run_fails(self):
        runs = [{"story": "idle-tabs"}, {"story": "launch-cold"}]
        _, found = outcomes({**GOOD_OUTPUTS, "runs --since 24h --json": runs}, only="3")
        self.assertEqual(found[(3, "targets-mapped")].status, dc.FAIL)
        self.assertEqual(found[(3, "targets-mapped")].measured["stories_without_results"], ["launch-warm"])

    def test_unmapped_target_stories_need_no_run(self):
        targets = [*GOOD_TARGETS, dc.TargetMap("qos", False, (), False, ("qos-static",))]
        _, found = outcomes({**GOOD_OUTPUTS, "targets --check": "targets mapped: 12/12\n"}, only="3", targets=targets)
        self.assertEqual(found[(3, "targets-mapped")].status, dc.PASS)

    def test_targets_count_still_reports_without_the_store(self):
        code, found = outcomes({**GOOD_OUTPUTS, "targets --check": "targets mapped: 1/12\n",
                                "runs --since 24h --json": ""}, codes={"targets --check": 1}, only="3")
        reason = found[(3, "targets-mapped")].reason
        self.assertEqual(code, 1)
        self.assertIn("1/12 targets mapped", reason)
        self.assertIn("without JSON", reason)

    def test_mq4_lists_story_commands_without_a_result_writer(self):
        root = Path(tempfile.mkdtemp(prefix="done-checks-mq4-"))
        (root / "writes.py").write_text("from perf_result import Result\n")
        (root / "records.sh").write_text("bench.record(x)\n")
        (root / "silent.py").write_text("print(42)\n")
        listing = "writes.py\nrecords.sh\nsilent.py\n"
        _, found = outcomes({**GOOD_OUTPUTS, "stories --lint --format=paths": listing}, only="5", root=root)
        outcome = found[(5, "one-result-format")]
        self.assertEqual((outcome.status, outcome.measured["mq4"]), (dc.FAIL, ["silent.py"]))

    def test_mq4_without_story_paths_fails(self):
        _, found = outcomes({**GOOD_OUTPUTS, "stories --lint --format=paths": ""}, codes={"stories": 2}, only="5")
        self.assertIn("no story command paths", found[(5, "one-result-format")].reason)

    def test_noise_fails_when_aa_judges_other_limits(self):
        report = aa_report(thresholds={"median_cv": 0.08, "p99_cv": 0.1})
        _, found = outcomes({**GOOD_OUTPUTS, "aa --since-live": report}, only="9")
        self.assertIn("median_cv at 8 %", found[(9, "noise")].reason)

    def test_noise_shares_and_hosts(self):
        report = aa_report(p99_cv_share_within=0.75, aa_runs_by_host={"m6-a": 2})
        _, found = outcomes({**GOOD_OUTPUTS, "aa --since-live": report}, only="9")
        reason = found[(9, "noise")].reason
        self.assertIn("75.0 % of latency series within 10 % CV", reason)
        self.assertIn("m6-a=2", reason)
        _, found = outcomes({**GOOD_OUTPUTS, "aa --since-live": aa_report(median_cv_share_within=None)}, only="9")
        self.assertIn("0 judged latency series", found[(9, "noise")].reason)

    def test_each_outcome_is_one_line(self):
        def runner(argv, cwd, timeout_s):
            return dc.CommandResult(shlex.join(argv), 2, "", "usage: lab.py\nlab.py: error: no such command\n")
        found = []
        dc.run_checks(dc.select("1"), REPO, emit=found.append, runner=runner, queries=good_queries)
        self.assertNotIn("\n", found[0].as_line())
        self.assertIn("usage: lab.py / lab.py: error", found[0].reason)

    def test_query_hits_fail(self):
        def queries(name, root):
            return {"MQ1": ["scripts/cmux-next/perf-cron.py", "scripts/cmux-next/idle-budget.py"],
                    "MQ5": ["cefPump"]}.get(name, [])
        code, found = outcomes(queries=queries, only="5,6,7")
        self.assertEqual(code, 1)
        self.assertIn("idle-budget.py", found[(5, "one-result-format")].reason)
        self.assertEqual(found[(6, "self-launch-removed")].status, dc.PASS)
        self.assertIn("cefPump", found[(7, "signposts-live")].reason)

    def test_missing_output_fails_with_the_reason(self):
        code, found = outcomes({}, only="1,9")
        self.assertEqual(code, 1)
        self.assertIn("without JSON", found[(1, "coverage-t0")].reason)

    def test_missing_queues_module_fails_its_checks(self):
        queries = dc.QueuesModule(path=LAB / "no-such-queues.py")
        code, found = outcomes(queries=queries, only="6")
        self.assertEqual(code, 1)
        self.assertIn("does not exist", found[(6, "self-launch-removed")].reason)

    def test_kill_switch_needs_remote_off_and_suite_pass(self):
        directory = kill_switch_dir()
        (directory / "off.json").write_text(json.dumps([{"name": "perfLabKillProbe", "state": "off",
                                                          "source": "default"}]))
        _, found = outcomes(evidence=directory, only="13")
        self.assertIn("source=remote", found[(13, "kill-switch")].reason)
        directory = kill_switch_dir()
        (directory / "safe-mode.log").write_text("Suite 'FeatureSafeModeTests' failed.\n")
        _, found = outcomes(evidence=directory, only="13")
        self.assertIn("FeatureSafeModeTests", found[(13, "kill-switch")].reason)

    def test_exit_code_checks(self):
        code, found = outcomes(codes={"gen-features.py": 1, "env_audit.py": 1}, only="14,16")
        self.assertEqual(code, 1)
        self.assertEqual({o.status for o in found.values()}, {dc.FAIL})

    def test_workflow_diff_fails(self):
        def runner(argv, cwd, timeout_s):
            return dc.CommandResult(shlex.join(argv), 0, " .github/workflows/x.yml | 2 +\n", "")
        found = []
        code = dc.run_checks(dc.select("17"), REPO, emit=found.append, runner=runner, queries=good_queries)
        self.assertEqual((code, found[0].status), (1, dc.FAIL))

    def test_field_and_stability_never_fail_the_run(self):
        code, found = outcomes({k: v for k, v in GOOD_OUTPUTS.items() if "since 7d" not in k
                                and not k.startswith(("field", "stability"))}, only="18")
        self.assertEqual(code, 0)
        self.assertEqual({o.status for o in found.values()}, {dc.REPORTED})
        self.assertTrue(all(o.reason for o in found.values()))

    def test_only_rejects_unknown_numbers(self):
        with self.assertRaises(dc.DoneCheckError):
            dc.select("19")

    def test_real_queues_module_returns_item_keys(self):
        queries = dc.QueuesModule()
        hits = queries("MQ5", REPO)
        self.assertTrue(all(isinstance(hit, str) for hit in hits))
        with self.assertRaises(dc.DoneCheckError):
            queries("MQ99", REPO)

    def test_real_catalog_maps_the_twelve_targets(self):
        targets = dc.catalog_targets(REPO)
        self.assertEqual(len(targets), 12)
        browser = [t for t in targets if t.browser]
        self.assertTrue(browser)
        self.assertTrue(all({"chromium", "webkit"} <= set(t.engines) for t in browser))
        self.assertTrue(all(t.stories for t in targets if t.mapped))

    def test_lab_registry_names_the_command(self):
        self.assertEqual(list(dc.LAB_COMMANDS), ["done-checks"])


if __name__ == "__main__":
    unittest.main()
