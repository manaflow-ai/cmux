#!/usr/bin/env python3
"""scripts/measure/daemon-stop-swap.sh summary_of=DIR: which daemon log is the stopped daemon's, the
count of the lines that say that a thread did not end, the clock pairs, a round that gave no stop,
and the exit. No fleet, no build, no daemon: made round folders in a temp folder.
Run: python3 -I scripts/measure/tests/daemon-stop-swap.test.py"""
import json, os, subprocess, tempfile, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.normpath(os.path.join(HERE, "..", "daemon-stop-swap.sh"))

SHUTDOWN = "cmux-tui: shutdown began at {at} (unix ms), {took} ms with 26 surfaces; slowest: a 3 ms"
WRITER = ("cmux-tui: stop session journal writer during shutdown: session journal writer did not stop "
          "before the shutdown deadline")
CLEANUP = "cmux-tui: output cleanup: the worker did not stop within 2.0 s; shutdown goes on without it"
KEEPS = "cmux-tui: this daemon keeps its session until it exits: the journal writer did not end in 2000 ms"


def phase(name, old, new, stop_wall, exit_s, answers, swap, passed=True):
    return {"phase": name, "passed": passed, "old_binary": f"/s/bin-{old}/cmux-tui",
            "new_binary": f"/s/bin-{new}/cmux-tui", "old_daemon_exit_secs": exit_s,
            "new_daemon_answers_secs": answers, "swap_secs": swap, "marks_wall": {"stop": stop_wall, "ready": 0},
            "new_daemon_start": {"old_daemon_stop": {"after_shutdown_to_exit_secs": 0.021},
                                 "load_at_stop": [3.5, 2.0, 1.0]}}


def make_round(root, number, report, logs, code=0, said="daemon-swap-check: PASS"):
    folder = os.path.join(root, f"w{number}")
    terminals = os.path.join(folder, "cmux-swap-abcdefgh", "terminals")
    os.makedirs(terminals)
    with open(os.path.join(folder, "report.json"), "w") as file:
        file.write(report if isinstance(report, str) else json.dumps(report, indent=2))
    with open(os.path.join(folder, "exit"), "w") as file:
        file.write(f"{code}\n")
    with open(os.path.join(folder, "check.err"), "w") as file:
        file.write(f"typist-shell (reported, not a failure): {{}}\n{said}\n")
    for started_ms, lines in logs.items():
        with open(os.path.join(terminals, f"daemon-{started_ms}.log"), "w") as file:
            file.write("\n".join(lines) + "\n")


def whole_round(root, number, first="old", second="new", first_lines=(), second_lines=()):
    """A round of two stops: the daemon of FIRST started at 1000.000 s and got its SIGTERM at 1010.5 s,
    the daemon of SECOND started at 1011.200 s and got its SIGTERM at 1020.25 s, FIRST's started again."""
    make_round(root, number, {"passed": True, "phases": [
        phase("terminals", first, second, 1010.5, 0.412, 1.012, 2.5),
        phase("terminals-swap-2", second, first, 1020.25, 0.3, 0.75, 2.0),
    ]}, {
        1000000: ["cmux-tui: started", *first_lines, SHUTDOWN.format(at=1010600, took=180)],
        1011200: [*second_lines, SHUTDOWN.format(at=1020300, took=95)],
        1021000: [SHUTDOWN.format(at=1030000, took=40)],
    })


def run(root, *args):
    done = subprocess.run(["bash", SCRIPT, f"summary_of={root}", *args], capture_output=True, text=True, timeout=120)
    rows = {}
    for line in done.stdout.splitlines():
        tag, _, rest = line.partition(" ")
        rows.setdefault(tag, []).append(json.loads(rest) if rest.startswith("{") else rest)
    return done, rows


class DaemonStopSwapSummary(unittest.TestCase):
    def test_each_stop_reads_the_log_of_the_daemon_that_got_the_signal(self):
        with tempfile.TemporaryDirectory() as root:
            whole_round(root, 1, first_lines=[WRITER], second_lines=[WRITER, CLEANUP, KEEPS])
            done, rows = run(root, "old=aaa", "new=bbb")
            self.assertEqual(done.returncode, 0, done.stderr)
            first, second, end = rows["DSS-STOP"]
            self.assertEqual((first["kind"], first["build"], first["next_build"]), ("first", "old", "new"))
            self.assertEqual((first["alive"], first["alive_by"]), (1, {"journal_writer": 1}))
            self.assertEqual((first["shutdown_ms"], first["surfaces"], first["log"]), (180, 26, "daemon-1000000.log"))
            self.assertEqual((first["exit_s"], first["after_shutdown_s"], first["next_start_s"]), (0.412, 0.021, 0.6))
            self.assertEqual((first["swap_s"], first["passed"], first["killed_by_check"], first["load1"]),
                             (2.5, True, False, 3.5))
            self.assertEqual((second["kind"], second["build"], second["log"]), ("second", "new", "daemon-1011200.log"))
            self.assertEqual(second["alive"], 3)
            self.assertEqual(second["alive_by"], {"journal_writer": 1, "output_cleanup": 1, "keeps_session": 1})
            self.assertEqual((second["shutdown_ms"], second["next_start_s"]), (95, 0.45))
            # The round's last daemon is of the build that the round began with; no clock pair.
            self.assertEqual((end["kind"], end["build"], end["alive"], end["shutdown_ms"]), ("end", "old", 0, 40))
            self.assertNotIn("exit_s", end)
            self.assertEqual(len(rows["DSS-RAW"]), 4)
            self.assertTrue(rows["DSS-RAW"][0].startswith("round=1 kind=first build=old: cmux-tui: stop session"))
            self.assertEqual(rows["DSS-ROUND"][0]["stops"], 2)
            self.assertEqual(rows["DSS-ROUND"][0]["said"], "daemon-swap-check: PASS")

    def test_the_sums_count_each_build_and_keep_the_other_logs_apart(self):
        with tempfile.TemporaryDirectory() as root:
            whole_round(root, 1, second_lines=[KEEPS])
            whole_round(root, 2, first="new", second="old")
            whole_round(root, 3, first_lines=[CLEANUP])
            done, rows = run(root, "old=aaa", "new=bbb", "budget=2.2")
            self.assertEqual(done.returncode, 0, done.stderr)
            old, new = rows["DSS-SUM"]
            self.assertEqual((old["build"], old["commit"], old["stops"], old["stops_alive"]), ("old", "aaa", 3, 1))
            self.assertEqual(old["stops_alive_by"], {"output_cleanup": 1})
            self.assertEqual((new["build"], new["commit"], new["stops"], new["stops_alive"]), ("new", "bbb", 3, 1))
            self.assertEqual(new["stops_alive_by"], {"keeps_session": 1})
            # old was the first stop in rounds 1 and 3 (0.412 s, 180 ms) and the second in round 2.
            self.assertEqual(old["exit_s"], {"n": 3, "median": 0.412, "max": 0.412})
            self.assertEqual(old["shutdown_ms"], {"n": 3, "median": 180, "max": 180})
            self.assertEqual(new["next_start_s"], {"n": 3, "median": 0.45, "max": 0.6})
            # budget=2.2: the first swap of each round took 2.5 s.
            self.assertEqual((old["swaps_at_or_over_budget"], new["swaps_at_or_over_budget"]), (2, 1))
            self.assertEqual(rows["DSS-OTHER"][0], {"end": {"logs": 3, "alive": 0}, "unmatched": {"logs": 0, "alive": 0}})
            with open(os.path.join(root, "report.json")) as file:
                report = json.load(file)
            self.assertEqual((report["schema"], report["rounds_asked"], report["each_round_gave_two_stops"]),
                             ("daemon-stop-swap/v1", 3, True))
            self.assertEqual((len(report["stops"]), len(report["rounds"]), report["budget_s"]), (9, 3, 2.2))

    def test_a_round_that_gave_no_stop_is_said_and_the_exit_is_1(self):
        with tempfile.TemporaryDirectory() as root:
            whole_round(root, 1)
            make_round(root, 2, {"passed": False, "phases": [
                {"phase": "terminals", "passed": False, "error": "TimeoutError: daemon socket"}]},
                {2000000: [WRITER]}, code=1, said="daemon-swap-check: FAIL")
            make_round(root, 3, "Traceback (most recent call last):\n", {}, code=1, said="KeyError: 'x'")
            done, rows = run(root)
            self.assertEqual(done.returncode, 1, done.stderr)
            by_round = {row["round"]: row for row in rows["DSS-ROUND"]}
            self.assertEqual((by_round[2]["stops"], by_round[2]["exit"], by_round[2]["passed"]), (0, 1, False))
            self.assertEqual(by_round[2]["error"], "TimeoutError: daemon socket")
            self.assertEqual((by_round[3]["stops"], by_round[3]["logs"], by_round[3]["passed"]), (0, 0, None))
            unmatched = [row for row in rows["DSS-STOP"] if row["kind"] == "unmatched"]
            self.assertEqual([(row["round"], row["build"], row["alive"]) for row in unmatched], [(2, "unknown", 1)])
            self.assertEqual([total["stops"] for total in rows["DSS-SUM"]], [1, 1])
            self.assertEqual(rows["DSS-OTHER"][0]["unmatched"], {"logs": 1, "alive": 1})

    def test_a_phase_whose_daemon_did_not_end_in_the_checks_wait_is_marked(self):
        with tempfile.TemporaryDirectory() as root:
            make_round(root, 1, {"passed": False, "phases": [
                phase("terminals", "old", "new", 1010.5, 20.004, 20.9, 23.0, passed=False),
                phase("terminals-swap-2", "new", "old", 1040.0, 0.3, 0.7, 2.0),
            ]}, {1000000: ["cmux-tui: started"], 1031000: [SHUTDOWN.format(at=1040050, took=90)]}, code=1)
            done, rows = run(root)
            self.assertEqual(done.returncode, 0, done.stderr)
            first = rows["DSS-STOP"][0]
            self.assertEqual((first["killed_by_check"], first["shutdown_ms"], first["passed"]), (True, None, False))
            old = rows["DSS-SUM"][0]
            self.assertEqual((old["stops_killed_by_check"], old["stops_without_shutdown_line"], old["swaps_not_passed"]),
                             (1, 1, 1))
            self.assertEqual(old["shutdown_ms"], {"n": 0})

    def test_no_round_folder_is_not_a_whole_run(self):
        with tempfile.TemporaryDirectory() as root:
            done, rows = run(root)
            self.assertEqual(done.returncode, 1, done.stderr)
            self.assertEqual([total["stops"] for total in rows["DSS-SUM"]], [0, 0])

    def test_wrong_arguments_end_with_2_before_any_work(self):
        for args in (["rounds=0"], ["budget=fast"], ["workers=2"], ["summary_of=/nonexistent/dss"], []):
            done = subprocess.run(["bash", SCRIPT, *args], capture_output=True, text=True, timeout=60)
            self.assertEqual(done.returncode, 2, (args, done.stderr))
            self.assertIn("error:", done.stderr)


if __name__ == "__main__":
    unittest.main()
