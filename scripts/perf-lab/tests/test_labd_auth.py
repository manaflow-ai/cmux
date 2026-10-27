#!/usr/bin/env python3
"""labd.py: tailnet-only bind, full-name whois allowlist on the write endpoints, the local socket, body cap, read
endpoints, the scheduler and backup workers, the launchd job and deploy.sh's pinned sha.

  python3 -m unittest scripts/perf-lab/tests/test_labd_auth.py
"""
from __future__ import annotations

import hashlib
import http.client
import importlib.util
import json
import os
import plistlib
import shutil
import socket
import sqlite3
import subprocess
import sys
import tempfile
import threading
import types
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest import mock

PERF_LAB = Path(__file__).resolve().parent.parent
DEPLOY = PERF_LAB / "deploy.sh"


def load(name: str, path: Path):
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


labd = load("perf_lab_labd", PERF_LAB / "labd.py")
store, ingest = labd.store, labd.ingest
pr = ingest.perf_result

NOW = datetime(2026, 10, 25, 12, 0, tzinfo=timezone.utc)
SHA = "a" * 40
DOMAIN = "tail1.ts.net"
SELF = labd.Node("cmux-lawrence", f"cmux-lawrence.{DOMAIN}")
LAB_HOST = labd.Node("cmux15", f"cmux15.{DOMAIN}")
STRANGER = labd.Node("someones-laptop", f"someones-laptop.{DOMAIN}")
FOREIGN_CONTROLLER = labd.Node("cmux-lawrence", "cmux-lawrence.evil.ts.net")
FOREIGN_LAB_HOST = labd.Node("cmux15", "cmux15.other.ts.net")
CHIP = "Apple M4 Pro"
HOST = pr.Host(fingerprint="f" * 64, host_class=store.host_class(chip=CHIP, memory_gb=24, display_hz=120), chip=CHIP,
               macos="26.1", macos_build="25B78", display_hz=120)
JOB_BODY = b'{"job_id": "j1", "state": "succeeded"}'


def result_body(directory: Path, run_id: str = "run1") -> bytes:
    result = pr.Result(story="terminal.key-frame.light", metric="key_to_frame_ms", unit="ms", better="lower",
                       samples=[4.0, 5.0, 6.0], build=pr.Build(sha=SHA, config="bench", measure_version=1),
                       host=HOST, engine="webkit", session="light",
                       run=pr.Run(id=run_id, started_at="2026-10-25T12:00:00.000001Z"),
                       features={"perfPath.x": pr.Feature(state="on", source="default")}, features_hash="fh1",
                       safe_mode="inactive")
    return pr.write_ndjson(directory, [result]).read_bytes()


def runs(db_path: Path) -> list[tuple[str, str]]:
    with sqlite3.connect(db_path) as db:
        return db.execute("SELECT u.run_uuid, h.name FROM runs u JOIN hosts h ON h.id = u.host_id").fetchall()


class FakePlan:
    mode, jobs, builds, gaps, skipped, problems = "every-batch", ("job",), (), (), (), ("shard m6/1: no owner",)

    def to_document(self):
        return {"mode": self.mode}


class FakeDriver:
    """scheduler.Driver's surface (task 011): tick(hosts, builds, submit=) -> Plan, job_finished(job_id), tip."""

    def __init__(self, fail: Exception | None = None) -> None:
        self.tip, self.calls, self.fail = SHA, [], fail

    def job_finished(self, job_id: str) -> None:
        self.calls.append(("finished", job_id))

    def tick(self, hosts, builds, *, submit, lanes=()):
        self.calls.append(("tick", tuple(hosts), builds))
        if self.fail is not None:
            raise self.fail
        plan = FakePlan()
        submit(plan)
        return plan


def worker(name: str, step, *, stale=timedelta(minutes=10), clock=lambda: NOW) -> "labd.Worker":
    return labd.Worker(name, step, lambda now: 3600.0, stale, clock)


def make_app(directory: Path, *, whois, plan=None, workers=None, commit_positions=None,
             scheduler_off=None) -> "labd.Labd":
    db_path = directory / "lab.sqlite3"
    db = store.Store(db_path)
    db.migrate()
    db.close()
    position = ingest.CommitPosition(100, mainline=True)
    return labd.Labd(db_path=db_path, allowlist=labd.Allowlist.of(["cmux-lawrence"], ["cmux15"], domain=DOMAIN),
                     whois=whois, self_fqdn=SELF.fqdn,
                     commit_positions=commit_positions or (lambda: (lambda sha: position)), plan=plan,
                     workers=workers or {}, clock=lambda: NOW, version=SHA, scheduler_off=scheduler_off)


class UnixConnection(http.client.HTTPConnection):
    def __init__(self, path: Path) -> None:
        super().__init__("localhost", timeout=10)
        self._path = str(path)

    def connect(self) -> None:
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(self._path)


class AddressPolicy(unittest.TestCase):
    def test_refuses_every_non_tailnet_bind(self):
        for address in ("0.0.0.0", "::", "127.0.0.1", "::1", "10.0.0.5", "192.168.1.2", "100.63.255.255",
                        "100.128.0.1", "localhost", ""):
            with self.subTest(address=address), self.assertRaises(labd.LabdError):
                labd.tailnet_address(address)
        self.assertEqual(labd.tailnet_address("100.89.225.106"), "100.89.225.106")
        self.assertEqual(labd.tailnet_address("fd7a:115c:a1e0::d36:352b"), "fd7a:115c:a1e0::d36:352b")

    def test_server_never_binds_all_interfaces(self):
        with tempfile.TemporaryDirectory() as scratch:
            app = make_app(Path(scratch), whois=lambda address: None)
            for address in ("0.0.0.0", "::", ""):
                with self.subTest(address=address), self.assertRaises(labd.LabdError):
                    labd.LabServer(address, 0, app)

    def test_serve_refuses_a_wildcard_bind_flag(self):
        with tempfile.TemporaryDirectory() as scratch, mock.patch.object(labd, "load_scheduler") as loaded:
            code = labd.main(["serve", "--data-dir", scratch, "--bind", "0.0.0.0", "--port", "0",
                              "--controller", "cmux-lawrence"])
        self.assertEqual(code, 2)
        loaded.assert_not_called()

    def test_this_host_comes_from_tailscale_status(self):
        status = {"Self": {"DNSName": "CMUX-Lawrence.tail1.ts.net.", "TailscaleIPs": ["fd7a:115c:a1e0::1",
                                                                                    "100.89.225.106"]}}
        done = subprocess.CompletedProcess([], 0, json.dumps(status), "")
        self.assertEqual(labd.tailnet_self(run=lambda *a, **k: done), ("100.89.225.106", SELF.fqdn))
        with self.assertRaises(labd.LabdError):
            labd.tailnet_self(run=lambda *a, **k: subprocess.CompletedProcess([], 1, "", "not running"))


class Identity(unittest.TestCase):
    def test_whois_answer_names_the_peer_node(self):
        answer = json.dumps({"Node": {"Name": "CMUX15.tail1.ts.net.", "Tags": ["tag:lab"]}})
        self.assertEqual(labd.node_from_whois(answer), LAB_HOST)
        self.assertIsNone(labd.node_from_whois("not json"))
        self.assertIsNone(labd.node_from_whois(json.dumps({"Node": {}})))
        calls = []
        self.assertIsNone(labd.tailscale_whois("127.0.0.1", run=lambda *a, **k: calls.append(a)))
        self.assertEqual(calls, [], "a non-tailnet peer is never looked up")

    def test_allowlist_matches_the_full_name_in_this_tailnet_only(self):
        allowlist = labd.Allowlist.of(["cmux-lawrence"], ["cmux15", f"cmux16.{DOMAIN}."], domain=DOMAIN)
        self.assertEqual(allowlist.lab_hosts, {f"cmux15.{DOMAIN}", f"cmux16.{DOMAIN}"})
        self.assertEqual(allowlist.role(SELF), "controller")
        self.assertEqual(allowlist.role(LAB_HOST), "lab-host")
        for node in (FOREIGN_CONTROLLER, FOREIGN_LAB_HOST, labd.Node("cmux15", "cmux15"), STRANGER, None):
            with self.subTest(node=node):
                self.assertIsNone(allowlist.role(node))
        with self.assertRaises(labd.LabdError):
            labd.Allowlist.of(["cmux-lawrence.evil.ts.net"], [], domain=DOMAIN)


class Service(unittest.TestCase):
    def setUp(self):
        self.scratch = Path(tempfile.mkdtemp(prefix="labd-test-"))
        self.addCleanup(shutil.rmtree, self.scratch, True)
        quiet = mock.patch.object(labd.Handler, "log_message")
        quiet.start()
        self.addCleanup(quiet.stop)
        self.caller: labd.Node | None = None
        self.driver = FakeDriver()
        self.plan = labd.PlanLoop(self.driver, hosts=lambda: ["host"], builds=lambda: "builds",
                                  submit=lambda plan: None)
        self.scheduler = worker("scheduler", self.plan.step)
        self.app = make_app(self.scratch, whois=lambda address: self.caller, plan=self.plan,
                            workers={"scheduler": self.scheduler})
        # Loopback only in this test: the fake whois stands in for tailscale, so the policy is the identity.
        self.server = labd.LabServer("127.0.0.1", 0, self.app, bind_policy=lambda address: address)
        self.socket_path = self.scratch / labd.SOCKET_NAME
        self.local = labd.LocalServer(self.socket_path, self.app)
        for server in (self.server, self.local):
            threading.Thread(target=server.serve_forever, daemon=True).start()
            self.addCleanup(server.server_close)
            self.addCleanup(server.shutdown)
        self.port = self.server.server_address[1]

    def request(self, method: str, path: str, body: bytes | None = None, *, local: bool = False):
        connection = UnixConnection(self.socket_path) if local else http.client.HTTPConnection(
            "127.0.0.1", self.port, timeout=10)
        try:
            connection.request(method, path, body=body)
            response = connection.getresponse()
            return response.status, json.loads(response.read())
        finally:
            connection.close()

    def raw(self, data: bytes) -> tuple[int, bytes]:
        with socket.create_connection(("127.0.0.1", self.port), timeout=10) as connection:
            connection.sendall(data)
            answer = b""
            while chunk := connection.recv(65536):
                answer += chunk
        return int(answer.split(b" ")[1]), answer

    def body(self) -> bytes:
        return result_body(self.scratch / "results")

    def test_writes_from_a_node_off_the_allowlist_are_forbidden(self):
        for caller in (STRANGER, FOREIGN_CONTROLLER, FOREIGN_LAB_HOST, None):
            self.caller = caller
            for path, body in (("/ingest", self.body()), ("/hooks/job-finished", JOB_BODY)):
                with self.subTest(caller=caller, path=path):
                    status, answer = self.request("POST", path, body)
                    self.assertEqual(status, 403)
                    self.assertIn("allowlist", answer["error"])
        self.assertEqual(runs(self.app.db_path), [])
        self.assertTrue(self.plan._finished.empty())

    def test_this_hosts_own_tailnet_address_is_refused(self):
        self.caller = SELF  # any OS user on cmux-lawrence reaches labd from its own tailnet address
        for path, body in (("/ingest", self.body()), ("/hooks/job-finished", JOB_BODY)):
            with self.subTest(path=path):
                status, answer = self.request("POST", path, body)
                self.assertEqual(status, 403)
                self.assertIn("Unix socket", answer["error"])

    def test_local_socket_is_the_controller_and_only_its_owner_may_connect(self):
        self.assertEqual(self.socket_path.stat().st_mode & 0o777, 0o600)
        status, answer = self.request("POST", "/ingest?host=cmux16&kind=waterfall&tier=T0", self.body(), local=True)
        self.assertEqual((status, answer["added_runs"]), (200, 1), answer)
        status, answer = self.request("POST", "/ingest?host=cmux16&kind=waterfall&tier=T0", self.body(), local=True)
        self.assertEqual((status, answer["added_runs"], answer["unchanged_runs"]), (200, 0, 1), answer)
        self.assertEqual(runs(self.app.db_path), [("run1/terminal.key-frame.light", "cmux16")])
        self.assertEqual(self.request("GET", "/api/jobs", local=True)[0], 200)

    def test_lab_host_ingests_under_its_own_node_name_only(self):
        self.caller = LAB_HOST
        status, answer = self.request("POST", "/ingest", self.body())
        self.assertEqual(status, 200, answer)
        self.assertEqual(answer["added_runs"], 1)
        self.assertEqual(runs(self.app.db_path), [("run1/terminal.key-frame.light", "cmux15")])
        status, answer = self.request("POST", "/ingest?host=cmux16", result_body(self.scratch / "r2", "run2"))
        self.assertEqual(status, 403)
        self.assertEqual(len(runs(self.app.db_path)), 1)

    def test_results_of_a_canary_lanes_commits_go_to_the_lane_store_only(self):
        lane_store = self.scratch / "canary" / "run" / "lab.sqlite3"
        lane_store.parent.mkdir(parents=True)
        lane = types.SimpleNamespace(name="canary/run", commits=frozenset({SHA}), mainline="refs/perf-lab/canary/run",
                                     store=lane_store)
        mainlines = []
        self.app.lanes = lambda: [lane]
        self.app.lane_positions = lambda mainline: mainlines.append(mainline) or (
            lambda sha: ingest.CommitPosition(7, mainline=True))
        self.caller = LAB_HOST
        status, answer = self.request("POST", "/ingest?kind=waterfall&tier=T0", self.body())
        self.assertEqual((status, answer["added_runs"]), (200, 1), answer)
        self.assertEqual(runs(self.app.db_path), [], "the lab's own store never gets a canary point")
        self.assertEqual(runs(lane_store), [("run1/terminal.key-frame.light", "cmux15")])
        self.assertEqual(mainlines, ["refs/perf-lab/canary/run"])
        lane.commits = frozenset({"b" * 40})
        status, answer = self.request("POST", "/ingest", result_body(self.scratch / "r2", "run2"))
        self.assertEqual(status, 200, answer)
        self.assertEqual(len(runs(self.app.db_path)), 1, "another commit goes to the lab's store")

    def test_a_body_mixing_lane_and_other_commits_is_refused(self):
        lane = types.SimpleNamespace(name="canary/run", commits=frozenset({"b" * 40}), mainline="m",
                                     store=self.scratch / "lane.sqlite3")
        self.app.lanes = lambda: [lane]
        first, second = result_body(self.scratch / "r1", "run1"), result_body(self.scratch / "r2", "run2")
        other = second.replace(SHA.encode(), b"b" * 40)
        self.caller = LAB_HOST
        status, answer = self.request("POST", "/ingest", first + other)
        self.assertEqual(status, 400, answer)
        self.assertIn("mixes commits of lane canary/run", answer["error"])
        self.assertEqual(runs(self.app.db_path), [])

    def test_a_bad_result_is_rejected_with_its_reason(self):
        self.caller = LAB_HOST
        status, answer = self.request("POST", "/ingest", b'{"story": 1}\n')
        self.assertEqual(status, 422)
        self.assertEqual(answer["rejected"][0]["source"], "body")
        self.assertEqual(runs(self.app.db_path), [])

    def test_body_over_one_mib_is_refused_unread(self):
        self.caller = LAB_HOST
        head = (f"POST /ingest HTTP/1.1\r\nHost: x\r\nContent-Length: {labd.MAX_BODY_BYTES + 1}\r\n\r\n").encode()
        self.assertEqual(self.raw(head)[0], 413)
        self.assertEqual(self.raw(b"POST /ingest HTTP/1.1\r\nHost: x\r\n\r\n")[0], 411)
        self.assertEqual(self.raw(b"POST /ingest HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n")[0],
                         411)

    def test_unicode_digits_are_a_400_not_a_dropped_connection(self):
        self.caller = LAB_HOST
        self.assertEqual(self.request("GET", "/api/jobs?limit=%C2%B2")[0], 400)
        # Headers are Latin-1, where 0xB2 is '²': str.isdigit() takes it, int() does not.
        self.assertEqual(self.raw(b"POST /ingest HTTP/1.1\r\nHost: x\r\nContent-Length: \xb2\r\n\r\n")[0], 400)

    def test_an_unexpected_failure_is_a_500_with_its_text(self):
        def broken():
            raise RuntimeError("git is gone")

        self.app.commit_positions = broken
        self.caller = LAB_HOST
        status, answer = self.request("POST", "/ingest", self.body())
        self.assertEqual(status, 500)
        self.assertEqual(answer["error"], "RuntimeError: git is gone")

    def test_job_finished_records_the_end_and_hands_it_to_the_scheduler(self):
        db = store.Store(self.app.db_path)
        db._write(lambda: db._db.execute(
            "INSERT INTO jobs (controller_job_id, kind, state, created_at, updated_at) VALUES ('j1', 'bisect', "
            "'running', 'x', 'x')"))
        db.close()
        self.caller = LAB_HOST
        status, _ = self.request("POST", "/hooks/job-finished", JOB_BODY)
        self.assertEqual(status, 403, "only the controller sends job callbacks")
        status, answer = self.request("POST", "/hooks/job-finished",
                                      b'{"job_id": "j1", "state": "succeeded", "result": {"exit": 0}}', local=True)
        self.assertEqual((status, answer["known"], answer["scheduler"]), (200, True, True))
        status, answer = self.request("POST", "/hooks/job-finished", b'{"job_id": "other", "state": "failed"}',
                                      local=True)
        self.assertEqual((status, answer["known"]), (200, False))
        self.assertTrue(self.scheduler._wake.is_set(), "a callback wakes the scheduler worker")
        self.scheduler.run_once()
        self.assertEqual(self.driver.calls, [("finished", "j1"), ("finished", "other"), ("tick", ("host",), "builds")])
        status, answer = self.request("GET", "/api/jobs")
        self.assertEqual(answer["jobs"][0]["state"], "succeeded")
        for bad in (b"[]", b"{}", b'{"job_id": "j1", "state": "Bad State"}', b"nope"):
            with self.subTest(body=bad):
                self.assertEqual(self.request("POST", "/hooks/job-finished", bad, local=True)[0], 400)

    def test_a_failing_scheduler_never_loses_a_recorded_callback_reply(self):
        self.driver.fail = RuntimeError("plan broke")
        status, answer = self.request("POST", "/hooks/job-finished", JOB_BODY, local=True)
        self.assertEqual(status, 200, answer)
        self.scheduler.run_once()
        status, answer = self.request("GET", "/status")
        self.assertEqual(status, 503)
        self.assertEqual(answer["workers"]["scheduler"]["error"], "RuntimeError: plan broke")
        self.assertIn("scheduler: RuntimeError: plan broke", answer["problems"])

    def test_read_endpoints_are_open_to_any_tailnet_caller(self):
        self.caller = LAB_HOST
        self.request("POST", "/ingest", self.body())
        self.caller = None
        self.scheduler.run_once()
        status, answer = self.request("GET", "/status")
        self.assertEqual(status, 200, answer)
        self.assertEqual((answer["version"], answer["schema_version"], answer["ok"]), (SHA, len(store.MIGRATIONS), True))
        self.assertEqual(answer["workers"]["scheduler"]["detail"]["problems"], ["shard m6/1: no owner"])
        self.assertEqual(answer["workers"]["scheduler"]["detail"]["tip"], SHA)
        status, answer = self.request("GET", "/api/series")
        self.assertEqual((status, len(answer["series"]), answer["series"][0]["points"]), (200, 1, 1))
        key = answer["series"][0]["series_key"]
        status, answer = self.request("GET", f"/api/series?key={key}")
        self.assertEqual([point["samples"] for point in answer["points"]], [[4.0, 5.0, 6.0]])
        status, answer = self.request("GET", "/api/coverage")
        self.assertEqual(answer["coverage"][0]["story"], "terminal.key-frame.light")
        self.assertEqual(self.request("GET", "/api/alerts")[0], 200)
        self.assertEqual(self.request("GET", "/api/alerts?state=bogus")[0], 400)
        self.assertEqual(self.request("GET", "/api/jobs?limit=0")[0], 400)
        self.assertEqual(self.request("GET", "/nope")[0], 404)
        self.assertEqual(self.request("POST", "/status", b"{}")[0], 404)


class StatusHealth(unittest.TestCase):
    def test_a_disabled_scheduler_or_a_stale_worker_is_a_503(self):
        with tempfile.TemporaryDirectory() as scratch:
            app = make_app(Path(scratch), whois=lambda address: None, scheduler_off="no --submit-command")
            reply = app.status({})
            self.assertEqual((reply.status, reply.body["problems"]), (503, ["scheduler: no --submit-command"]))
            now = [NOW]
            stale = worker("backup", lambda: {"key": "k"}, stale=timedelta(days=2), clock=lambda: now[0])
            app = make_app(Path(scratch), whois=lambda address: None, workers={"backup": stale})
            app.clock = lambda: now[0]
            self.assertEqual(app.status({}).status, 200)
            now[0] = NOW + timedelta(days=3)
            reply = app.status({})
            self.assertEqual(reply.status, 503)
            self.assertFalse(reply.body["workers"]["backup"]["healthy"])


class Workers(unittest.TestCase):
    def test_a_raising_step_is_reported_and_the_next_step_still_runs(self):
        outcomes = iter([RuntimeError("boom"), {"ok": 1}])

        def step():
            outcome = next(outcomes)
            if isinstance(outcome, Exception):
                raise outcome
            return outcome

        loop = worker("scheduler", step)
        loop.run_once()
        self.assertEqual((loop.error, loop.error_at, loop.ok_at), ("RuntimeError: boom", NOW, None))
        self.assertFalse(loop.report(NOW)["healthy"])
        loop.run_once()
        self.assertEqual((loop.error, loop.detail, loop.ok_at), (None, {"ok": 1}, NOW))

    def test_thread_survives_a_raising_step_and_wakes_coalesce(self):
        calls, done = [], threading.Event()

        def step():
            calls.append(len(calls))
            if len(calls) == 2:
                done.set()
            raise ValueError("again")

        loop = labd.Worker("scheduler", step, lambda now: 0.01, timedelta(minutes=10), lambda: NOW)
        thread = threading.Thread(target=loop.run, daemon=True)
        thread.start()
        self.assertTrue(done.wait(5), "a second step runs after the first one raised")
        loop.stop()
        thread.join(5)
        self.assertFalse(thread.is_alive())

    def test_plan_loop_ticks_after_applying_finished_jobs_and_submits(self):
        driver, submitted = FakeDriver(), []
        loop = labd.PlanLoop(driver, hosts=lambda: [], builds=lambda: "b", submit=submitted.append)
        loop.job_finished("j9")
        detail = loop.step()
        self.assertEqual(driver.calls, [("finished", "j9"), ("tick", (), "b")])
        self.assertEqual((len(submitted), detail["jobs"], detail["mode"]), (1, 1, "every-batch"))

    def test_command_submitter_hands_the_plan_on_stdin_and_returns_what_it_refused(self):
        rejected = lambda **parts: parts  # scheduler.Rejected(jobs=, arms=, builds=)
        with tempfile.TemporaryDirectory() as scratch:
            seen, program = Path(scratch) / "seen.json", Path(scratch) / "submit"
            program.write_text(f"#!/bin/sh\ncat > '{seen}'\nprintf '%s' \"$ANSWER\"\nexit ${{EXIT:-0}}\n")
            program.chmod(0o755)
            submit = labd.command_submitter(program, rejected)
            with mock.patch.dict(os.environ, {"ANSWER": ""}):
                self.assertEqual(submit(FakePlan()), {"jobs": frozenset(), "arms": frozenset(), "builds": frozenset()})
            self.assertEqual(json.loads(seen.read_text()), {"mode": "every-batch"})
            with mock.patch.dict(os.environ, {"ANSWER": '{"jobs": ["T0-1:m6/0"]}'}):
                self.assertEqual(submit(FakePlan())["jobs"], {"T0-1:m6/0"})
            with mock.patch.dict(os.environ, {"ANSWER": '{"builds": [["%s", "bench"]]}' % SHA}):
                self.assertEqual(submit(FakePlan())["builds"], {(SHA, "bench")})
            for answer, code, message in (("", "3", "exited 3"), ("[1]", "0", "not {jobs, arms, builds}"),
                                          ('{"builds": ["x"]}', "0", "not {jobs, arms, builds}")):
                with self.subTest(answer=answer), mock.patch.dict(os.environ, {"ANSWER": answer, "EXIT": code}), \
                        self.assertRaisesRegex(labd.LabdError, message):
                    submit(FakePlan())

    def test_missing_scheduler_fails_at_startup(self):
        with tempfile.TemporaryDirectory() as scratch, mock.patch.object(labd, "HERE", Path(scratch)), \
                mock.patch.dict(sys.modules):
            sys.modules.pop("perf_lab_scheduler", None)
            with self.assertRaisesRegex(labd.LabdError, "task 011"):
                labd.load_scheduler()

    @unittest.skipUnless((PERF_LAB / "scheduler.py").is_file(), "scheduler.py (task 011) is not on this branch yet")
    def test_real_scheduler_driver_runs_one_step(self):
        scheduler, _ = labd.load_scheduler()
        with tempfile.TemporaryDirectory() as scratch:
            driver = scheduler.Driver(Path(scratch) / "scheduler.json", ls_remote=lambda: SHA,
                                      first_parent=lambda anchor, tip: (tip,), stories=(),
                                      shard_map=scheduler.ShardMap.from_document({"classes": {}}))
            def refuse(plan):
                raise labd.LabdError("controller down")

            failing = worker("scheduler", labd.PlanLoop(driver, hosts=lambda: [], builds=scheduler.Builds,
                                                        submit=refuse).step)
            failing.run_once()
            self.assertIn("controller down", failing.error)
            self.assertFalse((Path(scratch) / "scheduler.json").exists(), "a failed submit keeps the old state")
            detail = labd.PlanLoop(driver, hosts=lambda: [], builds=scheduler.Builds,
                                   submit=lambda plan: scheduler.Rejected()).step()
            self.assertEqual(detail["tip"], SHA)
            self.assertTrue((Path(scratch) / "scheduler.json").is_file())

    def test_serve_driver_reads_expectations_for_every_plan(self):
        scheduler, _ = labd.load_scheduler()
        expectations = scheduler._load_sibling("expectations")
        entry = {"story": "t0-key", "host_class": "apple-m6/24gb/120hz", "reason": "crashes on the M6 driver",
                 "issue": "https://github.com/manaflow-ai/cmux/issues/25000", "added": "2026-10-24",
                 "expires": "2026-10-31"}
        with tempfile.TemporaryDirectory() as scratch:
            file = Path(scratch) / "expectations.json"
            write = lambda *items: file.write_text(json.dumps({"schema": expectations.SCHEMA,
                                                               "expectations": list(items)}))
            driver = labd.plan_driver(scheduler, Path(scratch) / "scheduler.json", ls_remote=lambda: SHA,
                                      first_parent=lambda anchor, tip: (tip,), clock=lambda: NOW)
            with mock.patch.object(expectations, "EXPECTATIONS_PATH", file):  # absolute: root / it is it
                write(entry)
                self.assertEqual(driver.expectations(NOW).pairs, {("t0-key", "apple-m6/24gb/120hz")})
                write({**entry, "added": "2026-10-17", "expires": "2026-10-24"})
                self.assertEqual(driver.expectations(NOW).pairs, frozenset(), "read again: the entry expired")
                file.write_text("{not json")
                detail = labd.PlanLoop(driver, hosts=lambda: [], builds=scheduler.Builds,
                                       submit=lambda plan: scheduler.Rejected()).step()
            self.assertEqual(detail["skipped"], 0)
            self.assertTrue(any("is not JSON" in p for p in detail["problems"]), detail["problems"])

    @unittest.skipUnless((PERF_LAB / "builds.py").is_file(), "builds.py (task 009) is not on this branch yet")
    def test_ledger_ok_records_are_ready_builds(self):
        builds = labd._sibling("builds", PERF_LAB / "builds.py")
        fake_scheduler = types.SimpleNamespace(Builds=lambda ready: ready)
        with tempfile.TemporaryDirectory() as scratch:
            ledger = builds.BuildLedger(scratch)
            ledger.record(builds.BuildRecord(sha=SHA, config="bench", status="ok", seconds=1, digest="d" * 64,
                                             app="cmux DEV perf-lab.app"))
            ledger.record(builds.BuildRecord(sha="b" * 40, config="bench", status="failed", seconds=1,
                                             reason="BUILD FAILED"))
            self.assertEqual(labd.ledger_builds(fake_scheduler, builds, Path(scratch)), {(SHA, "bench")})


class BackupTest(unittest.TestCase):
    def test_backup_is_keyed_by_digest_and_a_failed_upload_does_not_stop_the_next(self):
        with tempfile.TemporaryDirectory() as scratch:
            app = make_app(Path(scratch), whois=lambda address: None)
            uploads, fail = [], [True]

            def upload(path, key):
                if fail.pop() if fail else False:
                    raise labd.LabdError("upload-r2-object.py exited 1: R2 upload failed: HTTP 503")
                uploads.append((key, path.read_bytes()))

            backup = worker("backup", labd.backup_step(app.db_path, Path(scratch) / "backups", upload),
                            stale=timedelta(days=2))
            backup.run_once()
            self.assertIn("HTTP 503", backup.error)
            backup.run_once()
            self.assertIsNone(backup.error)
            latest = (Path(scratch) / "backups" / "latest.lab.sqlite3.gz").read_bytes()
            digest = hashlib.sha256(latest).hexdigest()
            self.assertEqual(backup.detail["key"], f"{labd.BACKUP_PREFIX}/{digest}.sqlite3.gz")
            self.assertEqual(uploads, [(backup.detail["key"], latest)])

    def test_next_backup_is_the_next_night(self):
        self.assertEqual(labd.next_backup_delay(NOW, tz=timezone.utc), 15 * 3600)
        self.assertEqual(labd.next_backup_delay(datetime(2026, 10, 25, 1, 0, tzinfo=timezone.utc), tz=timezone.utc),
                         2 * 3600)

    def test_upload_uses_the_repo_uploader_write_once_with_keys_only_in_its_environment(self):
        config = {"CMUX_PERF_LAB_R2_ENDPOINT": "https://acct.r2.cloudflarestorage.com",
                  "CMUX_PERF_LAB_R2_BUCKET": "lab", "AWS_ACCESS_KEY_ID": "AKID", "AWS_SECRET_ACCESS_KEY": "SECRET"}
        calls = []

        def run(argv, **options):
            calls.append((argv, options))
            return subprocess.CompletedProcess(argv, 0, "", "")

        labd.r2_upload(Path("/tmp/x.gz"), "perf-lab/backups/sha256/d.sqlite3.gz", config, run=run)
        argv, options = calls[0]
        self.assertEqual(argv[2], str(labd.UPLOADER))
        self.assertTrue(labd.UPLOADER.is_file())
        self.assertIn("--write-once", argv)
        self.assertNotIn("SECRET", " ".join(argv))
        self.assertEqual(options["env"]["AWS_SECRET_ACCESS_KEY"], "SECRET")
        with self.assertRaises(labd.LabdError):
            labd.r2_upload(Path("/tmp/x.gz"), "k", config,
                           run=lambda argv, **o: subprocess.CompletedProcess(argv, 1, "", "HTTP 403"))

    def test_r2_settings_come_from_the_secrets_file(self):
        with tempfile.TemporaryDirectory() as scratch:
            path = Path(scratch) / "lab.env"
            self.assertIsNone(labd.read_r2_env(path))
            path.write_text("export CMUX_PERF_LAB_R2_ENDPOINT=https://e\nCMUX_PERF_LAB_R2_BUCKET='lab'\n"
                            "AWS_ACCESS_KEY_ID=a\nAWS_SECRET_ACCESS_KEY=\"s\"\nOTHER=x\n")
            self.assertEqual(labd.read_r2_env(path)["CMUX_PERF_LAB_R2_BUCKET"], "lab")
            self.assertNotIn("OTHER", labd.read_r2_env(path))


class LaunchdJob(unittest.TestCase):
    def render(self, **overrides):
        options = dict(sha=SHA, release=Path("/lab/releases") / SHA, data_dir=Path("/lab"), repo=Path("/lab/repo"),
                       python="/opt/homebrew/bin/python3", controllers=["cmux-lawrence"], lab_hosts=["cmux15"],
                       branch="feat-cmux-next", log_dir=Path("/logs"))
        options.update(overrides)
        return plistlib.loads(labd.render_plist(labd.PLIST_TEMPLATE, **options))

    def test_job_runs_the_pinned_release_at_background_priority(self):
        job = self.render(submit_command=Path("/lab/submit"))
        self.assertEqual((job["ProcessType"], job["Nice"], job["Label"]), ("Background", 10, labd.LABEL))
        arguments = job["ProgramArguments"]
        self.assertEqual(arguments[:4], ["/opt/homebrew/bin/python3", "-I",
                                         f"/lab/releases/{SHA}/scripts/perf-lab/labd.py", "serve"])
        self.assertEqual(arguments[arguments.index("--version") + 1], SHA)
        self.assertEqual(arguments[arguments.index("--submit-command") + 1], "/lab/submit")
        limit = job["SoftResourceLimits"]["ResidentSetSize"]
        self.assertEqual(int(arguments[arguments.index("--max-rss-mb") + 1]), limit >> 20)
        self.assertNotIn("--bind", arguments, "labd finds its own tailnet address")

    def test_job_needs_a_full_sha_and_node_names(self):
        for overrides in ({"sha": "abc123"}, {"sha": "HEAD"}, {"controllers": ["bad name"]}):
            with self.subTest(overrides=overrides), self.assertRaises(labd.LabdError):
                self.render(**overrides)


def git(repo: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True, text=True).stdout.strip()


class Deploy(unittest.TestCase):
    def deploy(self, *args: str, env: dict | None = None) -> subprocess.CompletedProcess:
        return subprocess.run(["bash", str(DEPLOY), *args], capture_output=True, text=True, timeout=120,
                              env={**os.environ, **(env or {})})

    def test_refuses_without_a_pinned_sha(self):
        for args in ((), ("--controller", "cmux-lawrence"), ("--sha", "abc123", "--controller", "x"),
                     ("--sha", "main", "--controller", "x"), ("--sha", SHA)):
            with self.subTest(args=args):
                done = self.deploy(*args)
                self.assertEqual(done.returncode, 2, done.stderr)
                self.assertIn("deploy.sh:", done.stderr)
        self.assertIn("--sha SHA is required", self.deploy("--controller", "x").stderr)

    def lab_repo(self, scratch: Path) -> tuple[Path, str, str]:
        origin, source, data = scratch / "origin.git", scratch / "source", scratch / "data"
        subprocess.run(["git", "init", "--quiet", "--bare", str(origin)], check=True)
        subprocess.run(["git", "init", "--quiet", "-b", "feat-cmux-next", str(source)], check=True)
        for name in ("user.email", "user.name"):
            git(source, "config", name, "lab@example.com")
        target = source / "scripts" / "perf-lab"
        target.mkdir(parents=True)
        for path in PERF_LAB.iterdir():
            if path.is_file() and path.suffix in (".py", ".json", ".plist"):
                shutil.copy(path, target / path.name)
        git(source, "add", ".")
        git(source, "commit", "--quiet", "-m", "lab")
        merged = git(source, "rev-parse", "HEAD")
        git(source, "checkout", "--quiet", "-b", "side")
        git(source, "commit", "--quiet", "--allow-empty", "-m", "unreviewed")
        side = git(source, "rev-parse", "HEAD")
        git(source, "remote", "add", "origin", str(origin))
        git(source, "push", "--quiet", "origin", "feat-cmux-next", "side")
        subprocess.run(["git", "clone", "--quiet", str(origin), str(data / "repo")], check=True)
        return data, merged, side

    def test_deploys_only_a_commit_merged_into_the_branch(self):
        with tempfile.TemporaryDirectory() as scratch:
            data, merged, side = self.lab_repo(Path(scratch))
            common = ("--data-dir", str(data), "--controller", "cmux-lawrence", "--lab-host", "cmux15",
                      "--python", sys.executable, "--dry-run")
            done = self.deploy("--sha", side, *common)
            self.assertEqual(done.returncode, 2, done.stderr)
            self.assertIn("is not on origin/feat-cmux-next", done.stderr)
            self.assertFalse((data / "releases" / side).exists())
            done = self.deploy("--sha", merged, *common)
            self.assertEqual(done.returncode, 0, done.stderr)
            job = plistlib.loads(done.stdout.encode())
            self.assertIn(merged, job["ProgramArguments"])
            self.assertEqual(git(data / "releases" / merged, "rev-parse", "HEAD"), merged)

    def test_waits_for_the_old_job_and_retries_bootstrap(self):
        with tempfile.TemporaryDirectory() as scratch:
            scratch = Path(scratch)
            data, merged, _ = self.lab_repo(scratch)
            bin_dir, log = scratch / "bin", scratch / "launchctl.log"
            bin_dir.mkdir()
            (bin_dir / "uname").write_text("#!/bin/sh\necho Darwin\n")
            # The old job stays listed for two prints after bootout; bootstrap fails once with launchd's EIO.
            (bin_dir / "launchctl").write_text(f"""#!/bin/sh
echo "$*" >> '{log}'
case "$1" in
  print) [ "$2" = "${{2%/com.cmux.perf-lab}}" ] && exit 0
         n=$(grep -c '^print .*/com.cmux.perf-lab' '{log}'); [ "$n" -le 2 ] && exit 0; exit 113 ;;
  bootstrap) [ "$(grep -c '^bootstrap' '{log}')" -ge 2 ] && exit 0
             echo 'Bootstrap failed: 5: Input/output error' >&2; exit 5 ;;
esac
""")
            for tool in ("uname", "launchctl"):
                (bin_dir / tool).chmod(0o755)
            env = {"PATH": f"{bin_dir}:{os.environ['PATH']}", "HOME": str(scratch / "home")}
            done = self.deploy("--sha", merged, "--data-dir", str(data), "--controller", "cmux-lawrence",
                               "--python", sys.executable, env=env)
            self.assertEqual(done.returncode, 0, done.stderr)
            calls = [line.split()[0] for line in log.read_text().splitlines()]
            first_bootstrap = calls.index("bootstrap")
            self.assertEqual(calls[calls.index("bootout") + 1:first_bootstrap], ["print"] * 3,
                             "bootstrap waits until the old job is gone")
            self.assertEqual(calls[first_bootstrap:], ["bootstrap", "bootstrap"])
            self.assertIn("deployed labd", done.stdout)


if __name__ == "__main__":
    unittest.main()
