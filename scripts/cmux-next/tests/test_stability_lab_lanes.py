#!/usr/bin/env python3
"""stability-lab.py lanes and signatures (p10-stability-196): the update, skew and restore lanes.

The registry must declare the skew and restore fast lanes and the update feed lane on one lab mini within the
fast-lane window, and each lane's output must become a verdict with one finding per failing check, the same
signature across runs.

    python3 -I scripts/cmux-next/tests/test_stability_lab_lanes.py
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import os
import re
import shlex
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parents[1]
SCRIPT = HERE / "stability-lab.py"
REPO = HERE.parents[1]
REGISTRY = HERE / "stability-lanes.json"
NEW_LANES = ("skew-matrix", "restore-journey", "update-e2e")
TIP_LANES = ("skew-matrix", "restore-journey")
SLOT_SCRIPT = HERE / "restore-journey-slot.sh"


def load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


lab = load("stability_lab_lanes", SCRIPT)
issues = load("stability_issues_for_lanes", HERE / "stability_issues.py")


def registry() -> dict:
    return json.loads(REGISTRY.read_text(encoding="utf-8"))


def lane(lane_id: str) -> dict:
    return next(entry for entry in lab.lane_entries(registry()) if entry["id"] == lane_id)


def update_output(rows: list[list[str]], run: str) -> str:
    lines = [f"[{state}] {check}" + (f": {detail}" if detail else "") for check, state, detail in rows]
    failed = any(state == "FAIL" for _, state, _ in rows)
    return "\n".join([f"scratch /tmp/update-e2e-{run}", *lines,
                      json.dumps({"results": rows, "ok": not failed}, indent=1)]) + "\n"


def skew_output(rows: list[tuple[str, str, str, str]]) -> str:
    failed = sum(verdict == "FAIL" for *_, verdict, _ in rows)
    table = ["direction            case  verdict  detail"]
    table += [f"{direction}  {case}  {verdict}  {detail}" for direction, case, verdict, detail in rows]
    return "\n".join([
        "skew-matrix: 2 cases, 0 skipped; platform darwin (an unbundled CLI never re-execs: pass = works or fix)",
        *table, f"skew-matrix: {len(rows) - failed} pass, {failed} FAIL",
    ]) + "\n"


class Run:
    def __init__(self, test: unittest.TestCase) -> None:
        self._dir = tempfile.TemporaryDirectory()
        test.addCleanup(self._dir.cleanup)
        self.out = Path(self._dir.name)

    def write(self, name: str, text: str) -> None:
        path = self.out / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")

    def result(self, lane_id: str, exit_code: int | None) -> dict:
        return lab.lane_result(lane(lane_id), self.out, exit_code)


class RegistryTests(unittest.TestCase):
    def test_registry_has_no_problems(self) -> None:
        self.assertEqual(lab.lane_problems(registry(), REPO), [])

    def test_skew_and_restore_are_fast_lanes_on_one_lab_mini(self) -> None:
        reg = registry()
        lanes = {entry["id"]: entry for entry in lab.lane_entries(reg)}
        for lane_id in NEW_LANES:
            entry = lanes[lane_id]
            self.assertEqual(entry["host_class"], "dedicated", lane_id)
            self.assertEqual(entry["host_group"], "lab-mini-fast", lane_id)
            self.assertIn("bench", entry["never_with"], lane_id)
            self.assertIn(entry["result"]["parser"], lab.RESULT_PARSERS, lane_id)
        for lane_id in TIP_LANES:
            self.assertEqual(lanes[lane_id]["tier"], "fast", lane_id)
            self.assertEqual(lanes[lane_id]["needs_build"], "dev", lane_id)
        group = reg["host_groups"]["lab-mini-fast"]
        self.assertEqual(group["hosts"], 1)
        self.assertEqual(sorted(group["order"]), sorted(NEW_LANES))
        self.assertLessEqual(sum(lanes[lane_id]["minutes"] for lane_id in TIP_LANES), lab.FAST_GROUP_MINUTES)
        self.assertEqual(sorted(lab.fast_lanes(reg)), sorted(TIP_LANES))

    def test_update_lane_tests_the_feed_and_never_decides_tip_coverage(self) -> None:
        # A DEV build cannot take a Sparkle update, so the lane installs published builds only; it must not
        # count as evidence for a lab tip.
        entry = lane("update-e2e")
        self.assertEqual((entry["tier"], entry["subject"], entry["needs_build"]), ("feed", "feed", "none"))
        self.assertNotIn("update-e2e", lab.fast_lanes(registry()))

    def test_a_tip_lane_that_does_not_build_the_tip_is_refused(self) -> None:
        bad = registry()
        update = next(entry for entry in bad["lanes"] if entry["id"] == "update-e2e")
        update["tier"] = "fast"
        update.pop("subject")
        problems = "\n".join(lab.lane_problems(bad, REPO))
        self.assertIn("update-e2e: a tip lane must run the tip's build", problems)
        update["subject"] = "feed"
        self.assertIn("update-e2e: a feed lane has tier feed and subject feed",
                      "\n".join(lab.lane_problems(bad, REPO)))

    def test_check_refuses_a_lane_the_runner_cannot_run(self) -> None:
        bad = registry()
        bad["lanes"][0] = {**bad["lanes"][0], "minutes": 0, "never_with": [], "args": ["{nope}"],
                           "result": {"parser": "unknown", "path": "{out}/x"}, "script": "scripts/missing.py"}
        bad["lanes"][1] = {**bad["lanes"][1], "minutes": 40}
        problems = "\n".join(lab.lane_problems(bad, REPO))
        for expected in ("minutes must be a positive integer", "never_with must include bench",
                         "unknown placeholder nope", "result parser must be one of", "is not in the checkout",
                         "over 30"):
            self.assertIn(expected, problems)

    def test_previous_build_placeholder_needs_the_flag(self) -> None:
        bad = registry()
        skew = next(entry for entry in bad["lanes"] if entry["id"] == "skew-matrix")
        skew.pop("needs_previous_build")
        self.assertIn("skew-matrix: uses {previous_app} without needs_previous_build",
                      lab.lane_problems(bad, REPO))

    def test_lanes_check_command(self) -> None:
        with contextlib.redirect_stdout(io.StringIO()) as printed:
            self.assertEqual(lab.main(["lanes", "--check"]), 0)
        self.assertIn("update-e2e", printed.getvalue())


class UpdateLaneTests(unittest.TestCase):
    def test_pass(self) -> None:
        run = Run(self)
        run.write("update-e2e.txt", update_output([["staged", "PASS", ""], ["rollback", "PENDING", "not built"]], "1"))
        result = run.result("update-e2e", 0)
        self.assertEqual(result["status"], "passed")
        self.assertEqual(result["checks"], {"passed": 1, "failed": [], "pending": 1})
        self.assertEqual(result["findings"], [])

    def test_failed_check_is_one_signature_stable_across_runs(self) -> None:
        hashes = []
        for run_id, pid in (("1700000000", "4121"), ("1700009999", "8803")):
            run = Run(self)
            run.write("update-e2e.txt", update_output([
                ["relaunched", "PASS", ""],
                ["terminal shell process survived (daemon kept it)", "FAIL", f"pid {pid}"],
                ["click path: older build launched", "FAIL", ""],
            ], run_id))
            result = run.result("update-e2e", 1)
            self.assertEqual(result["status"], "failed")
            self.assertEqual(len(result["findings"]), 2)
            finding = result["findings"][0]
            self.assertEqual(finding["kind"], "lab-check")
            self.assertEqual(finding["exception"], "update-e2e")
            self.assertEqual(finding["lane"], "update-e2e")
            self.assertEqual(finding["frames"], ["terminal shell process survived (daemon kept it)"])
            self.assertEqual(finding["message"], f"pid {pid}")
            hashes.append([f["hash12"] for f in result["findings"]])
        self.assertEqual(hashes[0], hashes[1])
        self.assertNotEqual(hashes[0][0], hashes[0][1])

    def test_refused_host_is_infra(self) -> None:
        run = Run(self)
        run.write("update-e2e.txt", "refused: a cmux NEXT runs here:\n123 /Applications/cmux NEXT.app/...\n")
        result = run.result("update-e2e", 1)
        self.assertEqual(result["status"], "infra")
        self.assertEqual(result["findings"], [])
        self.assertIn("refused", result["reason"])
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(lab.main(["signatures", "--lane", "update-e2e", "--out", str(run.out),
                                       "--exit-code", "1"]), lab.EXIT_INFRA)

    def test_feed_download_error_is_infra_but_a_harness_bug_is_a_finding(self) -> None:
        run = Run(self)
        run.write("update-e2e.txt", "Traceback (most recent call last):\n  File \"u.py\", line 9\n"
                                    "urllib.error.URLError: <urlopen error timed out>\n")
        self.assertEqual(run.result("update-e2e", 1)["status"], "infra")
        run.write("update-e2e.txt", "Traceback (most recent call last):\n  File \"u.py\", line 9\n"
                                    "    item = items[1]\nIndexError: list index out of range\n")
        result = run.result("update-e2e", 1)
        self.assertEqual(result["status"], "failed")
        self.assertEqual(result["findings"][0]["frames"], ["lane script error IndexError"])

    def test_crash_report_in_the_run_is_its_own_signature(self) -> None:
        run = Run(self)
        run.write("update-e2e.txt", update_output([["relaunched", "PASS", ""]], "1"))
        panic = {"message": "index out of bounds", "backtrace": "   0: cmux_core::grid::Grid::row\n"
                 "             at /src/cmux-tui/crates/cmux-core/src/grid.rs:10:5\n",
                 "process": "cmux-tui", "thread": "main"}
        run.write("crashes/panic.jsonl", json.dumps(panic) + "\n")
        result = run.result("update-e2e", 0)
        self.assertEqual(result["status"], "failed")
        self.assertEqual([f["kind"] for f in result["findings"]], ["rust-panic"])
        self.assertEqual(result["findings"][0]["source"], "crashes/panic.jsonl")
        self.assertEqual(result["findings"][0]["lane"], "update-e2e")

    def test_findings_name_the_feed_builds_not_the_tip(self) -> None:
        run = Run(self)
        rows = [["relaunched", "PASS", ""], ["agent turn finished", "FAIL", "no after-gate"]]
        run.write("update-e2e.txt", "feed https://x/appcast.xml: 12 items; 1700 -> 1702\n" + update_output(rows, "1"))
        result = run.result("update-e2e", 1)
        self.assertEqual((result["subject"], result["builds"]), ("feed", {"from": "1700", "to": "1702"}))
        self.assertEqual((result["findings"][0]["subject"], result["findings"][0]["build"]), ("feed", "1702"))
        skew = Run(self)
        skew.write("skew-matrix.txt", skew_output([("cli=new daemon=old", "browser-list", "works", "exit 0")]))
        self.assertEqual(skew.result("skew-matrix", 0)["subject"], "tip")

    def test_a_crash_report_that_gives_no_signature_still_fails_the_lane(self) -> None:
        run = Run(self)
        run.write("update-e2e.txt", update_output([["relaunched", "PASS", ""]], "1"))
        run.write("crashes/a.ips", '{"app_name":"cmux DEV lab-tip-7","bug_type":"309"}\n{"threads": [')
        result = run.result("update-e2e", 0)
        self.assertEqual(result["status"], "failed")
        finding = result["findings"][0]
        self.assertEqual((finding["kind"], finding["process"], finding["frames"]),
                         ("unparsed-crash", "cmux DEV", ["ips", "cmux DEV"]))
        self.assertEqual(finding["source"], "crashes/a.ips")
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(lab.main(["signatures", "--lane", "update-e2e", "--out", str(run.out),
                                       "--exit-code", "0"]), 1)

    def test_empty_or_test_only_panic_logs_are_not_findings(self) -> None:
        run = Run(self)
        run.write("update-e2e.txt", update_output([["relaunched", "PASS", ""]], "1"))
        run.write("crashes/empty.jsonl", "")
        run.write("crashes/tests.jsonl", json.dumps({"message": "assert", "backtrace": "", "test": True}) + "\n")
        self.assertEqual(run.result("update-e2e", 0)["status"], "passed")


class SkewLaneTests(unittest.TestCase):
    def test_fail_rows_become_signatures(self) -> None:
        run = Run(self)
        run.write("skew-matrix.txt", skew_output([
            ("cli=new daemon=old", "browser-list", "works", "exit 0"),
            ("cli=new daemon=old", "pane-zoom", "FAIL", "raw capability error: unknown method pane.zoom"),
            ("cli=old daemon=new", "pane-zoom", "fix", "one fix command"),
        ]))
        result = run.result("skew-matrix", 1)
        self.assertEqual(result["status"], "failed")
        self.assertEqual(result["checks"], {"passed": 2, "failed": ["cli=new daemon=old pane-zoom"], "pending": 0})
        self.assertEqual(result["findings"][0]["frames"], ["cli=new daemon=old pane-zoom"])

    def test_a_daemon_that_does_not_start_is_one_signature_per_direction(self) -> None:
        run = Run(self)
        start = "daemon did not start: Command '['/x/cmux-tui', '--session', 'skm{n}new']' timed out after 30 seconds"
        run.write("skew-matrix.txt", skew_output([
            ("cli=old daemon=new", "server-stats", "FAIL", start.format(n=1)),
            ("cli=old daemon=new", "chief-pipe", "FAIL", start.format(n=2)),
        ]))
        result = run.result("skew-matrix", 1)
        self.assertEqual(len(result["checks"]["failed"]), 2)
        self.assertEqual(len(result["signatures"]), 1)
        self.assertEqual([f["frames"] for f in result["findings"]], [["cli=old daemon=new daemon did not start"]] * 2)

    def test_repeated_signature_counts_each_occurrence_in_issue_sync(self) -> None:
        run = Run(self)
        start = "daemon did not start: timed out after 30 seconds"
        run.write("skew-matrix.txt", skew_output([
            ("cli=old daemon=new", "server-stats", "FAIL", start),
            ("cli=old daemon=new", "chief-pipe", "FAIL", start),
        ]))
        result = run.result("skew-matrix", 1)
        sync_run = {"schema": issues.RUN_SCHEMA, "run": "lab-1", "tip": "a" * 40,
                    "lanes": [{"lane": "skew-matrix", "major": "27"}],
                    "findings": [{**finding, "major": "27"} for finding in result["findings"]]}
        tracked, _ = issues.plan_sync([], sync_run, lambda fix, sha: None)
        self.assertEqual(len(tracked), 1)
        self.assertEqual(tracked[0].state["count"], 2)
        self.assertEqual(tracked[0].state["per_major"], {"27": 2})

    def test_missing_previous_cli_is_infra(self) -> None:
        run = Run(self)
        run.write("skew-matrix.txt", "skew-matrix: --old /x/cmux-tui is not an executable cmux-tui\n")
        self.assertEqual(run.result("skew-matrix", 2)["status"], "infra")

    def test_missing_bundled_cli_of_the_tip_is_a_finding(self) -> None:
        run = Run(self)
        run.write("skew-matrix.txt",
                  "skew-matrix: --new /lab/cmux DEV t.app/Contents/Resources/bin/cmux-tui is not an executable cmux-tui\n")
        result = run.result("skew-matrix", 2)
        self.assertEqual(result["status"], "failed")
        self.assertEqual(result["findings"][0]["frames"], ["bundled cmux-tui missing"])

    def test_green_matrix_passes(self) -> None:
        run = Run(self)
        run.write("skew-matrix.txt", skew_output([("cli=new daemon=old", "browser-list", "works", "exit 0")]))
        self.assertEqual(run.result("skew-matrix", 0)["status"], "passed")


class RestoreLaneTests(unittest.TestCase):
    def test_failed_rows_are_findings_and_na_rows_do_not_count(self) -> None:
        run = Run(self)
        run.write("report.json", json.dumps([
            {"item": "quit: window[0].frame", "ok": True, "detail": "", "area": "windows"},
            {"item": "crash: window[1].display", "ok": "n/a", "detail": "one display", "area": "windows"},
            {"item": "update: rj-term counter pid 51234 alive", "ok": False, "detail": "gone", "area": "terminal"},
        ]))
        result = run.result("restore-journey", 1)
        self.assertEqual(result["status"], "failed")
        self.assertEqual(result["checks"]["pending"], 1)
        self.assertEqual(result["findings"][0]["frames"], ["update: rj-term counter pid N alive"])

    def test_app_that_never_opens_its_socket_is_a_finding(self) -> None:
        run = Run(self)
        run.write("restore-journey.txt", "lease slot-3 host cmux16 slot 3\nthe app never opened its control socket\n")
        result = run.result("restore-journey", 1)
        self.assertEqual(result["status"], "failed")
        self.assertEqual(result["findings"][0]["frames"], ["app never opened its control socket"])

    def test_harness_usage_error_is_a_finding_not_infra(self) -> None:
        run = Run(self)
        run.write("restore-journey.txt", "lease slot-3 host cmux16 slot 3\n"
                  "usage: restore-journey.py [-h] --socket SOCKET [--variants VARIANTS]\n"
                  "                          [--out OUT]\n"
                  "restore-journey.py: error: unrecognized arguments: \nresults in /tmp/rj (exit 2)\n")
        result = run.result("restore-journey", 2)
        self.assertEqual(result["status"], "failed")
        self.assertEqual(result["findings"][0]["frames"], ["lane harness usage error: unrecognized arguments:"])

    def test_declared_args_reach_the_journey_through_the_slot_script(self) -> None:
        # The slot script's own argument reading, as the runner calls it; the journey must get exactly the
        # args after `--`, with no empty argv entry (`printf '%q '` of nothing is '').
        declared = [arg.replace("{job}", "job-1").replace("{out}", "/tmp/rj-out") for arg in lane("restore-journey")["args"]]
        journey = declared[declared.index("--") + 1:]
        source = (HERE / "restore-journey.py").read_text(encoding="utf-8")
        options = set(re.findall(r'parser\.add_argument\("(--[a-z-]+)"', source))
        self.assertTrue(journey, "the lane names the journey's variants")
        self.assertLessEqual({arg for arg in journey if arg.startswith("--")}, options)
        for argv, expected in ((declared, journey), (["job-1", "/tmp/rj-out", "--"], []), (["job-1"], [])):
            printed = subprocess.run(["bash", str(SLOT_SCRIPT), *argv], capture_output=True, text=True, check=True,
                                     env={**os.environ, "RESTORE_JOURNEY_SLOT_PRINT_ARGS": "1"}).stdout
            fields = dict(line.split("=", 1) for line in printed.splitlines())
            self.assertEqual(fields["job"], "job-1")
            self.assertEqual(shlex.split(fields["args"]), expected, argv)

    def test_no_lease_is_infra(self) -> None:
        run = Run(self)
        run.write("restore-journey.txt", "capture-host: no free slot\n")
        result = run.result("restore-journey", 1)
        self.assertEqual(result["status"], "infra")
        self.assertIn("no free slot", result["reason"])

    def test_nonzero_exit_with_a_green_report_is_still_a_failure(self) -> None:
        run = Run(self)
        run.write("report.json", json.dumps([{"item": "quit: window[0].frame", "ok": True, "detail": "", "area": "w"}]))
        result = run.result("restore-journey", 1)
        self.assertEqual(result["status"], "failed")
        self.assertEqual(result["findings"][0]["frames"], ["exit status without a failing check"])


class CheckFrameTests(unittest.TestCase):
    def test_run_specific_parts_are_removed(self) -> None:
        self.assertEqual(lab.check_frame("seed /tmp/rj-1700000000/out: tip 0123abcd9 in 4.5 s"),
                         "seed <path>: tip <hex> in N s")


if __name__ == "__main__":
    unittest.main()
