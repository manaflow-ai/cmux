#!/usr/bin/env python3
"""labd.py: tailnet-only bind, whois allowlist on the write endpoints, body cap, read endpoints, tip watcher,
backup, the launchd job and deploy.sh's pinned sha.

  python3 -m unittest scripts/perf-lab/tests/test_labd_auth.py
"""
from __future__ import annotations

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
import unittest
from datetime import datetime, timezone
from pathlib import Path

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
store, ingest, r2 = labd.store, labd.ingest, labd.r2
pr = ingest.perf_result

NOW = datetime(2026, 10, 25, 12, 0, tzinfo=timezone.utc)
SHA = "a" * 40
CONTROLLER = labd.Node("cmux-lawrence", "cmux-lawrence.tail1.ts.net")
LAB_HOST = labd.Node("cmux15", "cmux15.tail1.ts.net")
STRANGER = labd.Node("someones-laptop", "someones-laptop.tail1.ts.net")
CHIP = "Apple M4 Pro"
HOST = pr.Host(fingerprint="f" * 64, host_class=store.host_class(chip=CHIP, memory_gb=24, display_hz=120), chip=CHIP,
               macos="26.1", macos_build="25B78", display_hz=120)


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


class RecordingDriver:
    name = "recording"

    def __init__(self) -> None:
        self.tips: list[str] = []
        self.jobs: list[tuple[str, str]] = []

    def tip_changed(self, sha: str) -> None:
        self.tips.append(sha)

    def job_finished(self, controller_job_id: str, state: str) -> None:
        self.jobs.append((controller_job_id, state))


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
        with tempfile.TemporaryDirectory() as scratch:
            code = labd.main(["serve", "--data-dir", scratch, "--bind", "0.0.0.0", "--port", "0",
                              "--controller", "cmux-lawrence"])
        self.assertEqual(code, 2)

    def test_whois_answer_names_the_peer_node(self):
        answer = json.dumps({"Node": {"Name": "CMUX15.tail1.ts.net.", "Tags": ["tag:lab"]}})
        self.assertEqual(labd.node_from_whois(answer), labd.Node("cmux15", "cmux15.tail1.ts.net"))
        self.assertIsNone(labd.node_from_whois("not json"))
        self.assertIsNone(labd.node_from_whois(json.dumps({"Node": {}})))
        calls = []
        self.assertIsNone(labd.tailscale_whois("127.0.0.1", run=lambda *a, **k: calls.append(a)))
        self.assertEqual(calls, [], "a non-tailnet peer is never looked up")


def make_app(directory: Path, *, whois, driver=None, tip=None) -> "labd.Labd":
    db_path = directory / "lab.sqlite3"
    db = store.Store(db_path)
    db.migrate()
    db.close()
    position = ingest.CommitPosition(100, mainline=True)
    return labd.Labd(db_path=db_path, allowlist=labd.Allowlist.of(["cmux-lawrence"], ["cmux15"]), whois=whois,
                     commit_positions=lambda: (lambda sha: position), driver=driver or labd.IdleDriver(), tip=tip,
                     backup=None, clock=lambda: NOW, version=SHA)


class Service(unittest.TestCase):
    def setUp(self):
        self.scratch = Path(tempfile.mkdtemp(prefix="labd-test-"))
        self.addCleanup(shutil.rmtree, self.scratch, True)
        self.caller: labd.Node | None = None
        self.driver = RecordingDriver()
        self.tip = labd.TipWatcher(tip=lambda: SHA, fetch=lambda sha: None, driver=self.driver, clock=lambda: NOW)
        self.app = make_app(self.scratch, whois=lambda address: self.caller, driver=self.driver, tip=self.tip)
        # Loopback only in this test: the fake whois stands in for tailscale, so the policy is the identity.
        self.server = labd.LabServer("127.0.0.1", 0, self.app, bind_policy=lambda address: address)
        thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        self.port = self.server.server_address[1]

    def request(self, method: str, path: str, body: bytes | None = None, headers: dict | None = None):
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        try:
            connection.request(method, path, body=body, headers=headers or {})
            response = connection.getresponse()
            return response.status, json.loads(response.read())
        finally:
            connection.close()

    def raw(self, data: bytes) -> int:
        with socket.create_connection(("127.0.0.1", self.port), timeout=10) as connection:
            connection.sendall(data)
            return int(connection.recv(4096).split(b" ")[1])

    def body(self) -> bytes:
        return result_body(self.scratch / "results")

    def test_ingest_from_a_node_off_the_allowlist_is_forbidden(self):
        for caller in (STRANGER, None):
            self.caller = caller
            with self.subTest(caller=caller):
                status, answer = self.request("POST", "/ingest", self.body())
                self.assertEqual(status, 403)
                self.assertIn("allowlist", answer["error"])
        self.assertEqual(runs(self.app.db_path), [])

    def test_job_finished_from_a_node_off_the_allowlist_is_forbidden(self):
        self.caller = STRANGER
        status, _ = self.request("POST", "/hooks/job-finished", b'{"job_id": "j1", "state": "succeeded"}')
        self.assertEqual(status, 403)
        self.assertEqual(self.driver.jobs, [])

    def test_lab_host_ingests_under_its_own_node_name_only(self):
        self.caller = LAB_HOST
        status, answer = self.request("POST", "/ingest", self.body())
        self.assertEqual(status, 200, answer)
        self.assertEqual(answer["added_runs"], 1)
        self.assertEqual(runs(self.app.db_path), [("run1/terminal.key-frame.light", "cmux15")])
        status, answer = self.request("POST", "/ingest?host=cmux16", result_body(self.scratch / "r2", "run2"))
        self.assertEqual(status, 403)
        self.assertEqual(len(runs(self.app.db_path)), 1)

    def test_controller_may_ingest_for_a_named_host_and_again_is_a_no_op(self):
        self.caller = CONTROLLER
        body = self.body()
        status, answer = self.request("POST", "/ingest?host=cmux16&kind=waterfall&tier=T0", body)
        self.assertEqual((status, answer["added_runs"]), (200, 1), answer)
        status, answer = self.request("POST", "/ingest?host=cmux16&kind=waterfall&tier=T0", body)
        self.assertEqual((status, answer["added_runs"], answer["unchanged_runs"]), (200, 0, 1), answer)
        self.assertEqual(runs(self.app.db_path), [("run1/terminal.key-frame.light", "cmux16")])

    def test_a_bad_result_is_rejected_with_its_reason(self):
        self.caller = LAB_HOST
        status, answer = self.request("POST", "/ingest", b'{"story": 1}\n')
        self.assertEqual(status, 422)
        self.assertEqual(answer["rejected"][0]["source"], "body")
        self.assertEqual(runs(self.app.db_path), [])

    def test_body_over_one_mib_is_refused_unread(self):
        self.caller = CONTROLLER
        head = (f"POST /ingest HTTP/1.1\r\nHost: x\r\nContent-Length: {labd.MAX_BODY_BYTES + 1}\r\n\r\n").encode()
        self.assertEqual(self.raw(head), 413)
        self.assertEqual(self.raw(b"POST /ingest HTTP/1.1\r\nHost: x\r\n\r\n"), 411)
        self.assertEqual(self.raw(b"POST /ingest HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n"),
                         411)

    def test_job_finished_records_the_end_and_wakes_the_scheduler(self):
        db = store.Store(self.app.db_path)
        db._write(lambda: db._db.execute(
            "INSERT INTO jobs (controller_job_id, kind, state, created_at, updated_at) VALUES ('j1', 'bisect', "
            "'running', 'x', 'x')"))
        db.close()
        self.caller = LAB_HOST
        status, _ = self.request("POST", "/hooks/job-finished", b'{"job_id": "j1", "state": "succeeded"}')
        self.assertEqual(status, 403, "only the controller sends job callbacks")
        self.caller = CONTROLLER
        status, answer = self.request("POST", "/hooks/job-finished",
                                      b'{"job_id": "j1", "state": "succeeded", "result": {"exit": 0}}')
        self.assertEqual((status, answer["known"]), (200, True))
        status, answer = self.request("POST", "/hooks/job-finished", b'{"job_id": "other", "state": "failed"}')
        self.assertEqual((status, answer["known"]), (200, False))
        self.assertEqual(self.driver.jobs, [("j1", "succeeded"), ("other", "failed")])
        self.assertTrue(self.tip._wake.is_set())
        status, answer = self.request("GET", "/api/jobs")
        self.assertEqual(answer["jobs"][0]["state"], "succeeded")
        for bad in (b"[]", b"{}", b'{"job_id": "j1", "state": "Bad State"}', b"nope"):
            with self.subTest(body=bad):
                self.assertEqual(self.request("POST", "/hooks/job-finished", bad)[0], 400)

    def test_read_endpoints_are_open_to_any_tailnet_caller(self):
        self.caller = LAB_HOST
        self.request("POST", "/ingest", self.body())
        self.caller = None
        status, answer = self.request("GET", "/status")
        self.assertEqual(status, 200)
        self.assertEqual((answer["version"], answer["schema_version"], answer["driver"]),
                         (SHA, len(store.MIGRATIONS), "recording"))
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


class TipWatcherTest(unittest.TestCase):
    def test_fetches_and_reports_only_a_moved_tip(self):
        tips, fetched, driver = iter([SHA, SHA, "b" * 40]), [], RecordingDriver()
        watcher = labd.TipWatcher(tip=lambda: next(tips), fetch=fetched.append, driver=driver, clock=lambda: NOW)
        for _ in range(3):
            watcher.check()
        self.assertEqual(fetched, [SHA, "b" * 40])
        self.assertEqual(driver.tips, [SHA, "b" * 40])

    def test_a_failed_fetch_keeps_the_old_tip(self):
        driver = RecordingDriver()

        def fetch(sha):
            raise labd.LabdError("network down")

        watcher = labd.TipWatcher(tip=lambda: SHA, fetch=fetch, driver=driver, clock=lambda: NOW)
        state = watcher.check()
        self.assertEqual((state.sha, state.error), (None, "network down"))
        self.assertEqual(driver.tips, [])


class FakeBucket:
    def __init__(self) -> None:
        self.keys: dict[str, bytes] = {}

    def put_once(self, key, path, *, sha256=None):
        if key in self.keys:
            return False
        self.keys[key] = Path(path).read_bytes()
        return True


class BackupTest(unittest.TestCase):
    def test_backup_is_keyed_by_digest_and_unchanged_store_uploads_once(self):
        with tempfile.TemporaryDirectory() as scratch:
            app = make_app(Path(scratch), whois=lambda address: None)
            bucket = FakeBucket()
            backup = labd.NightlyBackup(db_path=app.db_path, directory=Path(scratch) / "backups", bucket=bucket,
                                        clock=lambda: NOW, tz=timezone.utc)
            first = backup.run_once()
            self.assertIsNone(first.error)
            self.assertEqual(first.key, f"{labd.BACKUP_PREFIX}/{first.sha256}.sqlite3.gz")
            self.assertTrue(first.uploaded)
            self.assertEqual(r2.sha256_file(Path(scratch) / "backups" / "latest.lab.sqlite3.gz"), first.sha256)
            second = backup.run_once()
            self.assertEqual((second.sha256, second.uploaded), (first.sha256, False))
            self.assertEqual(len(bucket.keys), 1)

    def test_next_backup_is_the_next_night(self):
        backup = labd.NightlyBackup(db_path=Path("x"), directory=Path("y"), bucket=None, clock=lambda: NOW,
                                    tz=timezone.utc)
        self.assertEqual(backup.next_due(NOW), datetime(2026, 10, 26, 3, 0, tzinfo=timezone.utc))
        self.assertEqual(backup.next_due(datetime(2026, 10, 25, 1, 0, tzinfo=timezone.utc)),
                         datetime(2026, 10, 25, 3, 0, tzinfo=timezone.utc))


class FakeResponse:
    def __init__(self, status):
        self.status = status

    def read(self, size=-1):
        return b""


class FakeConnection:
    def __init__(self, status):
        self.status, self.sent = status, None

    def request(self, method, path, body=None, headers=None):
        self.sent = (method, path, body.read(), headers)

    def getresponse(self):
        return FakeResponse(self.status)

    def close(self):
        pass


class R2Test(unittest.TestCase):
    def test_put_once_is_write_once_and_signed_with_the_digest(self):
        bucket = r2.R2Bucket("https://acct.r2.cloudflarestorage.com", "lab", "AKID", "SECRET")
        with tempfile.TemporaryDirectory() as scratch:
            blob = Path(scratch) / "blob"
            blob.write_bytes(b"lab")
            for status, wrote in ((200, True), (412, False)):
                connection = FakeConnection(status)
                self.assertEqual(bucket.put_once("k/1", blob, clock=lambda: NOW, connect=lambda host: connection),
                                 wrote)
                method, path, body, headers = connection.sent
                self.assertEqual((method, path, body), ("PUT", "/lab/k/1", b"lab"))
                self.assertEqual(headers["if-none-match"], "*")
                self.assertEqual(headers["x-amz-content-sha256"], r2.sha256_file(blob))
                self.assertIn("SignedHeaders=content-length;host;if-none-match;", headers["authorization"])
            with self.assertRaises(r2.R2Error):
                bucket.put_once("k/1", blob, clock=lambda: NOW, connect=lambda host: FakeConnection(403))

    def test_no_credentials_means_no_bucket(self):
        self.assertIsNone(r2.R2Bucket.from_env({"CMUX_PERF_LAB_R2_ENV_FILE": "/nonexistent"}))


class LaunchdJob(unittest.TestCase):
    def render(self, **overrides):
        options = dict(sha=SHA, release=Path("/lab/releases") / SHA, data_dir=Path("/lab"), repo=Path("/lab/repo"),
                       python="/opt/homebrew/bin/python3", controllers=["cmux-lawrence"], lab_hosts=["cmux15"],
                       branch="feat-cmux-next", log_dir=Path("/logs"))
        options.update(overrides)
        return plistlib.loads(labd.render_plist(labd.PLIST_TEMPLATE, **options))

    def test_job_runs_the_pinned_release_at_background_priority(self):
        job = self.render()
        self.assertEqual((job["ProcessType"], job["Nice"], job["Label"]), ("Background", 10, labd.LABEL))
        arguments = job["ProgramArguments"]
        self.assertEqual(arguments[:4], ["/opt/homebrew/bin/python3", "-I",
                                         f"/lab/releases/{SHA}/scripts/perf-lab/labd.py", "serve"])
        self.assertEqual(arguments[arguments.index("--version") + 1], SHA)
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

    def test_deploys_only_a_commit_merged_into_the_branch(self):
        with tempfile.TemporaryDirectory() as scratch:
            scratch = Path(scratch)
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


if __name__ == "__main__":
    unittest.main()
