#!/usr/bin/env python3
"""scripts/measure/daemon-registry-start.py: the order of its untimed runs, the warm start's guard and
the reads of the b-trees. No fleet, no cmux-tui: a fake binary and a fake generator in a temp folder. Run: python3 -I scripts/measure/tests/daemon-registry-start.test.py"""
import json, os, subprocess, sys, tempfile, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.normpath(os.path.join(HERE, "..", "daemon-registry-start.py"))

# Records each run's arguments. `--headless` serves identify as ready until `server stop`,
# except the warm start's session (drs-warm) when FAKE_WARM_EXITS is set: it exits at once.
FAKE = r'''#!/usr/bin/env python3
import json, os, socket, sys
args = sys.argv[1:]
with open(os.environ["FAKE_CALLS"], "a") as calls:
    calls.write(json.dumps(args) + "\n")
with open(os.environ["FAKE_CALLS"] + ".env", "a") as envs:
    envs.write(json.dumps({key: os.environ.get(key) for key in ("ACPMUX_HOME", "ACPMUX_SOCKET", "HOME")}) + "\n")
def arg(name):
    return args[args.index(name) + 1]
if args[:1] == ["--version"]:
    sys.exit(0)
if args[:2] == ["server", "stop"]:
    open(arg("--socket") + ".stop", "w").close()
    sys.exit(0)
if "--headless" in args:
    if arg("--session") == "drs-warm" and os.environ.get("FAKE_WARM_EXITS"):
        print("cmux-tui: the fake warm owner gave up", file=sys.stderr)
        sys.exit(3)
    path = arg("--socket")
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(path)
    server.listen(8)
    server.settimeout(0.05)
    while not os.path.exists(path + ".stop"):
        try:
            conn, _ = server.accept()
        except socket.timeout:
            continue
        with conn:
            conn.recv(65536)
            conn.sendall(json.dumps({"id": 1, "ok": True, "data": {"lifecycle_ready": True}}).encode() + b"\n")
    os.unlink(path)
    os.unlink(path + ".stop")
    sys.exit(0)
sys.exit(0)
'''

# The generator's `--trees`: 14 b-trees, the largest first; it fails when FAKE_TREES_FAIL is set.
# Its runs go into the same file as the fake binary's, so the file has the order of both.
FAKE_SYNTH = r'''#!/usr/bin/env python3
import json, os, sys
with open(os.environ["FAKE_CALLS"], "a") as calls:
    calls.write(json.dumps(["synth"] + sys.argv[1:]) + "\n")
if os.environ.get("FAKE_TREES_FAIL"):
    print("the fake generator could not read the trees", file=sys.stderr)
    sys.exit(3)
trees = [{"name": f"tree_{n}", "pages": 20 - n, "bytes": (20 - n) * 4096} for n in range(14)]
print(json.dumps({"page_size": 4096, "page_count": 240, "freelist_count": 2, "trees": trees}))
'''


class Harness(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="drs-test-")
        self.bin = os.path.join(self.tmp, "cmux-tui")
        with open(self.bin, "w") as f:
            f.write(FAKE)
        os.chmod(self.bin, 0o755)
        self.synth = os.path.join(self.tmp, "synth_registry")
        with open(self.synth, "w") as f:
            f.write(FAKE_SYNTH)
        os.chmod(self.synth, 0o755)
        self.calls = os.path.join(self.tmp, "calls.jsonl")
        session = os.path.join(self.tmp, "scratch", "state", "drs-0123")
        os.makedirs(session)
        open(os.path.join(session, "workspace-registry.sqlite3"), "w").close()
        os.makedirs(os.path.join(self.tmp, "scratch", "home"))
        self.generate = os.path.join(self.tmp, "generate.json")
        with open(self.generate, "w") as f:
            json.dump({"registry_bytes": 0}, f)
        self.report = os.path.join(self.tmp, "report.json")

    def run_harness(self, warm_exits, extra_env=None, extra_args=()):
        env = dict(os.environ, FAKE_CALLS=self.calls)
        env.pop("FAKE_TREES_FAIL", None)
        env.update(extra_env or {})
        env.pop("XDG_DATA_HOME", None)
        env.pop("FAKE_WARM_EXITS", None)
        if warm_exits:
            env["FAKE_WARM_EXITS"] = "1"
        scratch = os.path.join(self.tmp, "scratch")
        return subprocess.run(
            [sys.executable, "-I", SCRIPT, "--bin", self.bin, "--state", os.path.join(scratch, "state"),
             "--home", os.path.join(scratch, "home"), "--session", "drs",
             "--socket", os.path.join(self.tmp, "mux.sock"), "--generate", self.generate,
             "--report", self.report, "--rounds", "1", "--bump", "0", "--ready-timeout", "30",
             *extra_args],
            env=env, capture_output=True, text=True, timeout=120)

    def calls_made(self):
        with open(self.calls) as f:
            return [json.loads(line) for line in f]

    def test_the_first_exec_is_timed_before_anything_else_runs_the_binary(self):
        done = self.run_harness(warm_exits=False)
        self.assertEqual(done.returncode, 0, done.stderr)
        calls = self.calls_made()
        self.assertEqual(calls[0], ["--version"])
        self.assertEqual(calls[1], ["--version"])
        self.assertIn("--headless", calls[2])
        self.assertEqual(calls[2][calls[2].index("--session") + 1], "drs-warm")
        with open(self.report) as f:
            report = json.load(f)
        self.assertIsNotNone(report["warm_ready_ms"])
        self.assertTrue(all(item["ready_ms"] is not None for item in report["starts"]))

    def test_a_warm_start_that_exits_early_fails_the_run_with_its_last_line(self):
        done = self.run_harness(warm_exits=True)
        self.assertNotEqual(done.returncode, 0, "the run reported results without a warm start")
        self.assertIn("the warm start did not get ready", done.stderr)
        self.assertIn("the fake warm owner gave up", done.stderr)
        self.assertFalse(os.path.exists(self.report), "a report was written without a warm start")
        timed = [call for call in self.calls_made() if "--headless" in call
                 and call[call.index("--session") + 1] != "drs-warm"]
        self.assertEqual(timed, [], "timed starts ran without a warm start")


    def test_no_owner_it_starts_reaches_the_callers_acpmux_daemon(self):
        live = os.path.join(self.tmp, "live-acpmux")
        done = self.run_harness(warm_exits=False, extra_env={
            "ACPMUX_HOME": live, "ACPMUX_SOCKET": os.path.join(live, "acpmux.sock")})
        self.assertEqual(done.returncode, 0, done.stderr)
        with open(self.calls) as f:
            calls = [json.loads(line) for line in f]
        with open(self.calls + ".env") as f:
            envs = [json.loads(line) for line in f]
        owners = [env for call, env in zip(calls, envs) if "--headless" in call]
        self.assertTrue(owners)
        for env in owners:
            self.assertIsNone(env["ACPMUX_SOCKET"], env)
            self.assertNotEqual(env["ACPMUX_HOME"], live, env)

    def test_the_warm_report_names_the_warm_owners_data_home(self):
        done = self.run_harness(warm_exits=False)
        self.assertEqual(done.returncode, 0, done.stderr)
        warm = next(line for line in done.stdout.splitlines() if line.startswith("DRS-WARM "))
        self.assertIs(json.loads(warm[len("DRS-WARM "):])["xdg_data_home_set"], True, warm)

    def test_the_trees_are_read_before_the_first_start_and_after_each_start(self):
        done = self.run_harness(warm_exits=False, extra_args=[
            "--trees", "1", "--synth", self.synth, "--made-by", "0123abcd"])
        self.assertEqual(done.returncode, 0, done.stderr)
        # The generator's reads and the timed owner's starts and stops (not the warm one's), in order.
        order = []
        for call in self.calls_made():
            if call[0] == "synth":
                self.assertEqual(call[1:3], ["--trees", "--registry"], call)
                self.assertTrue(call[3].endswith("workspace-registry.sqlite3"), call)
                order.append("trees")
            elif "--session" in call and call[call.index("--session") + 1] == "drs":
                order.append("start" if "--headless" in call else "stop")
        self.assertEqual(order, ["trees", "start", "stop", "trees", "start", "stop", "trees"])
        with open(self.report) as f:
            report = json.load(f)
        self.assertEqual(report["made_by"], "0123abcd")
        self.assertEqual(report["trees_before"]["freelist_count"], 2)
        self.assertEqual(len(report["trees_before"]["trees"]), 14)
        self.assertEqual([item["label"] for item in report["starts"]], ["plain-0", "after"])
        for item in report["starts"]:
            self.assertEqual(len(item["trees_after"]["trees"]), 14, item["label"])
        lines = [json.loads(line[len("DRS-TREES "):]) for line in done.stdout.splitlines()
                 if line.startswith("DRS-TREES ")]
        self.assertEqual([line["when"] for line in lines], ["before", "plain-0", "after"])
        # A line has the 12 largest of the 14; the report has each one.
        self.assertEqual([(len(line["trees"]), line["trees_in_all"]) for line in lines], [(12, 14)] * 3)

    def test_a_trees_read_that_fails_is_in_the_report_and_the_run_goes_on(self):
        done = self.run_harness(warm_exits=False, extra_env={"FAKE_TREES_FAIL": "1"},
                                extra_args=["--trees", "1", "--synth", self.synth])
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn("DRS-TREES-FAILED before: the fake generator could not read the trees", done.stderr)
        with open(self.report) as f:
            report = json.load(f)
        self.assertEqual(report["trees_before"], {"error": "exit 3"})
        self.assertNotIn("made_by", report)
        self.assertTrue(all(item["ready_ms"] is not None for item in report["starts"]))
        self.assertTrue(all(item["trees_after"] == {"error": "exit 3"} for item in report["starts"]))

    def test_a_run_without_trees_reads_none_and_keeps_the_report(self):
        done = self.run_harness(warm_exits=False)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertNotIn("DRS-TREES", done.stdout)
        self.assertFalse([call for call in self.calls_made() if call[0] == "synth"])
        with open(self.report) as f:
            report = json.load(f)
        self.assertNotIn("trees_before", report)
        self.assertNotIn("made_by", report)
        for item in report["starts"]:
            self.assertNotIn("trees_after", item)
            self.assertIn("wal_bytes_after", item)


if __name__ == "__main__":
    unittest.main()
