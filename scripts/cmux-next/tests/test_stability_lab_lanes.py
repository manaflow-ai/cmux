#!/usr/bin/env python3
"""stability-lab.py lanes and signatures (p10-stability-196): the update, skew and restore fast lanes.

The registry must declare the three lanes on one lab mini within the fast-lane window, and each lane's
output must become a verdict with one signature per failing check, the same id across runs.

    python3 -I -m unittest scripts/cmux-next/tests/test_stability_lab_lanes.py
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parents[1]
SCRIPT = HERE / "stability-lab.py"
REPO = HERE.parents[1]
REGISTRY = HERE / "stability-lanes.json"
NEW_LANES = ("skew-matrix", "restore-journey", "update-e2e")


def load_lab():
    spec = importlib.util.spec_from_file_location("stability_lab_lanes", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


lab = load_lab()


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

    def test_update_skew_restore_are_fast_lanes_on_one_lab_mini(self) -> None:
        reg = registry()
        lanes = {entry["id"]: entry for entry in lab.lane_entries(reg)}
        for lane_id in NEW_LANES:
            entry = lanes[lane_id]
            self.assertEqual(entry["tier"], "fast", lane_id)
            self.assertEqual(entry["host_class"], "dedicated", lane_id)
            self.assertEqual(entry["host_group"], "lab-mini-fast", lane_id)
            self.assertIn("bench", entry["never_with"], lane_id)
            self.assertIn(entry["result"]["parser"], lab.RESULT_PARSERS, lane_id)
        group = reg["host_groups"]["lab-mini-fast"]
        self.assertEqual(group["hosts"], 1)
        self.assertEqual(sorted(group["order"]), sorted(NEW_LANES))
        self.assertLessEqual(sum(lanes[lane_id]["minutes"] for lane_id in NEW_LANES), lab.FAST_GROUP_MINUTES)
        self.assertIn("update-e2e", lab.fast_lanes(reg))

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
        self.assertEqual(len(result["findings"]), 1)
        self.assertEqual(result["findings"][0]["frames"], ["cli=old daemon=new daemon did not start"])
        self.assertEqual(result["findings"][0]["count"], 2)

    def test_bad_binary_is_infra(self) -> None:
        run = Run(self)
        run.write("skew-matrix.txt", "skew-matrix: --old /x/cmux-tui is not an executable cmux-tui\n")
        self.assertEqual(run.result("skew-matrix", 2)["status"], "infra")

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
