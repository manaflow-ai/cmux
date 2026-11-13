#!/usr/bin/env python3
"""scripts/measure/daemon-registry-start.py: the order of its untimed runs and the warm start's guard.
No fleet, no cmux-tui: a fake binary in a temp folder. Run: python3 -I scripts/measure/tests/daemon-registry-start.test.py"""
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


class Harness(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="drs-test-")
        self.bin = os.path.join(self.tmp, "cmux-tui")
        with open(self.bin, "w") as f:
            f.write(FAKE)
        os.chmod(self.bin, 0o755)
        self.calls = os.path.join(self.tmp, "calls.jsonl")
        session = os.path.join(self.tmp, "scratch", "state", "drs-0123")
        os.makedirs(session)
        open(os.path.join(session, "workspace-registry.sqlite3"), "w").close()
        os.makedirs(os.path.join(self.tmp, "scratch", "home"))
        self.generate = os.path.join(self.tmp, "generate.json")
        with open(self.generate, "w") as f:
            json.dump({"registry_bytes": 0}, f)
        self.report = os.path.join(self.tmp, "report.json")

    def run_harness(self, warm_exits, extra_env=None):
        env = dict(os.environ, FAKE_CALLS=self.calls)
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
             "--report", self.report, "--rounds", "1", "--bump", "0", "--ready-timeout", "30"],
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


if __name__ == "__main__":
    unittest.main()
