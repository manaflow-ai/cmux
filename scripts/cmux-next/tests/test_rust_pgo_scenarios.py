#!/usr/bin/env python3
"""rust_pgo_scenarios.py (p08-startup-056): the daemon scenario over a fake daemon (the app's request sequence, the
shutdown that lets an instrumented daemon write its profile, failures named), and the A/B summary (classes, p50 and
p95 change, the -5 % target) and the FFI coverage check. The FFI scenarios need the instrumented library and run in
rust-pgo.sh run.
Runs on any OS with Unix sockets: python3 -I scripts/cmux-next/tests/test_rust_pgo_scenarios.py"""

import importlib.util
import json
import os
import stat
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(os.path.dirname(HERE), "pgo", "rust_pgo_scenarios.py")

spec = importlib.util.spec_from_file_location("rust_pgo_scenarios", SCRIPT)
rps = importlib.util.module_from_spec(spec)
sys.modules["rust_pgo_scenarios"] = rps
spec.loader.exec_module(rps)

# A daemon that answers the scenario's requests and logs each `cmd`. FAKE_MODE: ok, no-surface, refuse-shutdown.
FAKE_DAEMON = r'''#!/usr/bin/env python3
import json, os, socket, sys
args = sys.argv[1:]
path = args[args.index("--socket") + 1]
log = open(os.environ["FAKE_LOG"], "a")
mode = os.environ.get("FAKE_MODE", "ok")
server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(path)
server.listen(16)
surfaces = 0
while True:
    conn, _ = server.accept()
    with conn:
        buffer = b""
        while b"\n" not in buffer:
            buffer += conn.recv(65536)
        request = json.loads(buffer.split(b"\n", 1)[0])
        cmd = request["cmd"]
        log.write(cmd + "\n"); log.flush()
        data = {}
        ok = True
        if cmd == "identify":
            data = {"pid": os.getpid(), "generation": "g1"}
        elif cmd == "new-tab" and mode != "no-surface":
            surfaces += 1
            data = {"surface": surfaces, "terminal_id": request["terminal_id"]}
        elif cmd == "shutdown-daemon":
            ok = mode != "refuse-shutdown" and request.get("pid") == os.getpid() and request.get("generation") == "g1" \
                and request.get("end_terminals") is True
        reply = {"id": request["id"], "ok": ok, "data": data} if ok else {"id": request["id"], "ok": False, "error": "refused"}
        conn.sendall((json.dumps(reply) + "\n").encode())
        if cmd == "shutdown-daemon" and ok:
            sys.exit(0)
'''


class FakeDaemonCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.binary = os.path.join(self.tmp.name, "fake-cmux-tui")
        with open(self.binary, "w") as handle:
            handle.write(FAKE_DAEMON.replace("#!/usr/bin/env python3", "#!" + sys.executable, 1))
        os.chmod(self.binary, os.stat(self.binary).st_mode | stat.S_IXUSR)
        self.log = os.path.join(self.tmp.name, "requests.log")
        os.environ["FAKE_LOG"] = self.log
        os.environ.pop("FAKE_MODE", None)

    def tearDown(self):
        os.environ.pop("FAKE_LOG", None)
        os.environ.pop("FAKE_MODE", None)
        self.tmp.cleanup()

    def requests(self):
        with open(self.log) as handle:
            return [line.strip() for line in handle if line.strip() != "ping"]

    def test_round_sends_the_app_sequence_and_ends_through_shutdown(self):
        samples, start_ms = rps.daemon_round(self.binary, tabs=2)
        sent = self.requests()
        expected = list(rps.CONNECT_READS)
        for _ in range(2):
            expected += ["new-tab", "send", "read-screen"] + list(rps.CHANGE_READS)
        expected += ["close-terminal", "list-terminals"] * 2 + ["identify", "shutdown-daemon"]
        self.assertEqual(sent, expected)
        self.assertEqual(len(samples["create"]), 2)
        self.assertEqual(len(samples["terminal_io"]), 4)
        self.assertEqual(len(samples["topology"]), 2)
        self.assertEqual(len(samples["query"]), len(rps.CONNECT_READS) + 2 * len(rps.CHANGE_READS) + 2)
        self.assertGreater(start_ms, 0)

    def test_new_tab_without_a_surface_fails_and_still_stops_the_daemon(self):
        os.environ["FAKE_MODE"] = "no-surface"
        with self.assertRaisesRegex(rps.ScenarioError, "new-tab named no surface"):
            rps.daemon_round(self.binary, tabs=1)
        self.assertEqual(self.requests()[-1], "shutdown-daemon")

    def test_a_refused_shutdown_fails_the_scenario(self):
        os.environ["FAKE_MODE"] = "refuse-shutdown"
        with self.assertRaisesRegex(rps.ScenarioError, "shutdown-daemon failed: refused"):
            rps.daemon_round(self.binary, tabs=1)

    def test_ab_alternates_builds_and_writes_the_summary(self):
        out = os.path.join(self.tmp.name, "ab.json")
        self.assertEqual(rps.main(["ab", "--base", self.binary, "--pgo", self.binary, "--rounds", "2", "--tabs", "1",
                                   "--json", out]), 0)
        with open(out) as handle:
            result = json.load(handle)
        # ABBA then BAAB: four daemon lives per build.
        self.assertEqual(result["summary"]["start"]["base"]["n"], 4)
        self.assertEqual(result["summary"]["start"]["pgo"]["n"], 4)
        self.assertEqual(self.requests().count("shutdown-daemon"), 8)


class SummaryCase(unittest.TestCase):
    def test_change_and_target(self):
        base = {"query": [10.0] * 20, "create": [100.0] * 4, "all": [10.0] * 20 + [100.0] * 4, "start": [50.0]}
        pgo = {"query": [9.0] * 20, "create": [90.0] * 4, "all": [9.0] * 20 + [90.0] * 4, "start": [50.0]}
        table = rps.summarize({"base": base, "pgo": pgo})
        self.assertAlmostEqual(table["query"]["change_p50"], -10.0)
        self.assertAlmostEqual(table["all"]["change_p95"], -10.0)
        self.assertEqual(table["start"]["change_p50"], 0.0)
        self.assertIsNone(table["terminal_io"]["change_p50"])
        self.assertIsNone(rps.change(0, 1.0))

    def test_bad_counts_are_usage_errors(self):
        with self.assertRaises(SystemExit):
            rps.main(["daemon", "--binary", "x", "--rounds", "0"])


class CoverageCase(unittest.TestCase):
    """rust-pgo.sh run fails when a C ABI the app's Swift calls has no counts: PGO would compile it as cold code."""

    def setUp(self):
        import subprocess
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = os.path.join(self.tmp.name, "repo")
        os.makedirs(os.path.join(self.repo, "App"))
        with open(os.path.join(self.repo, "App", "Mirror.swift"), "w") as handle:
            handle.write("let m = cmux_sidebar_mirror_new()\ncmux_focus_send(m)\ncmux_iroh_endpoint_bind()\n")
        subprocess.run(["git", "init", "-q", self.repo], check=True)
        subprocess.run(["git", "-C", self.repo, "add", "-A"], check=True)
        self.tool = os.path.join(self.tmp.name, "llvm-profdata")
        # The library: exports the mirror and focus calls, not the iroh one (another library's).
        self.lib = type("Lib", (), {"cmux_sidebar_mirror_new": 1, "cmux_focus_send": 1})()

    def tearDown(self):
        self.tmp.cleanup()

    def covered(self, *names):
        with open(self.tool, "w") as handle:
            handle.write("#!/bin/sh\n[ \"$1 $2\" = 'show --covered' ] || exit 2\n")
            handle.write("".join(f"echo '{name}'\n" for name in names))
        os.chmod(self.tool, 0o755)

    def test_every_exported_app_call_with_counts_passes(self):
        self.covered("cmux_sidebar_mirror_new", "cmux_focus_send", "crate;_ZN4core3fmt")
        self.assertEqual(rps.rust_pgo_ffi.coverage(self.lib, self.repo, self.tool, "p.profdata"), 2)

    def test_an_app_call_without_counts_fails_and_is_named(self):
        self.covered("cmux_focus_send")
        with self.assertRaisesRegex(rps.ScenarioError, "cold code.*cmux_sidebar_mirror_new"):
            rps.rust_pgo_ffi.coverage(self.lib, self.repo, self.tool, "p.profdata")

    def test_no_exported_app_call_proves_nothing(self):
        self.covered("cmux_focus_send")
        with self.assertRaisesRegex(rps.ScenarioError, "would prove nothing"):
            rps.rust_pgo_ffi.coverage(type("Empty", (), {})(), self.repo, self.tool, "p.profdata")


if __name__ == "__main__":
    unittest.main()
