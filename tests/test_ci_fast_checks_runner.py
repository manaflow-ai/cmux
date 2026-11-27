#!/usr/bin/env python3
"""Live admission and bounded overflow for the fast-checks picker."""

from __future__ import annotations

import base64
import contextlib
import datetime as dt
import email.message
import gzip
import importlib.util
import http.server
import io
import json
import os
import pathlib
import socketserver
import sys
import threading
import time
import unittest
import urllib.error
from unittest import mock


ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
# Imported by name, never loaded by path: one module object per file, so a test that patches it
# patches what every other test reads (tests/test_script_module_loads.py).
import fast_checks_runner as picker  # noqa: E402


class _DripHandler(http.server.BaseHTTPRequestHandler):
    stop = threading.Event()

    def do_GET(self) -> None:  # noqa: N802 - stdlib handler API
        if self.path == "/artifact":
            self.send_response(302)
            host, port = self.server.server_address
            self.send_header("Location", f"http://{host}:{port}/blob")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", "100000")
        self.end_headers()
        try:
            self.wfile.write(b"{")
            self.wfile.flush()
            # Bounded: a client that ignores its deadline sees the body end early (an
            # IncompleteRead, not the TimeoutError the tests demand) instead of hanging.
            for _ in range(300):
                if self.stop.wait(0.01):
                    break
                self.wfile.write(b" ")
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, _format: str, *_args: object) -> None:
        return


class _DripServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = False
    block_on_close = True


class FastChecksRunnerTests(unittest.TestCase):
    def test_busy_fleet_in_the_shared_document_keeps_the_fleet_without_waiting(self) -> None:
        idle = dict(id=1, name="synthetic-fast-check", os="Linux", status="online", busy=False,
                    labels=[{"name": picker.FLEET}])
        doc = dict(schema="runner-state/v1", repository="manaflow-ai/cmux", complete=True,
                   generated_at=dt.datetime.now(dt.timezone.utc).isoformat(), repository_runners=[],
                   runner_groups={"glaeda-minis": [], "cmux-fleet-linux": [dict(idle, busy=True)]}, scale_sets={})
        env = dict(ROUTE_TOKEN="synthetic-token", GITHUB_REPOSITORY="manaflow-ai/cmux",
                   CI_RUNNER_STATE=base64.b64encode(gzip.compress(json.dumps(doc).encode())).decode())
        paths, clock = [], [0.0]

        def api(path):
            paths.append(path)
            if "visible_to_repository" in path:
                return {"runner_groups": [{"name": "glaeda-minis", "id": 9},
                                          {"name": "cmux-fleet-linux", "id": 10}]}
            return {"runners": [idle]} if "/10/runners" in path else {}

        with mock.patch.dict(os.environ, env, clear=True), \
             mock.patch.object(picker.pr_runner_pool.GitHub, "get_api", side_effect=api), \
             contextlib.redirect_stderr(io.StringIO()):
            selected = picker.choose(env, sleep=lambda s: clock.__setitem__(0, clock[0] + s), clock=lambda: clock[0])
        # One look decides: the fleet runner is online (busy), so the checks
        # queue on the fleet label, where the broker bounds the wait; no poll.
        self.assertEqual(selected, picker.FLEET)
        self.assertEqual(clock[0], 0.0)
        self.assertEqual(paths, [])

    def test_live_idle_linux_fleet_runner_is_selected(self) -> None:
        rows = [{"status": "online", "busy": False, "os": "Linux",
                 "labels": [{"name": "cmux-fleet-linux-x64"}]}]
        self.assertEqual(picker.idle_runner(rows), "cmux-fleet-linux-x64")

    def test_busy_or_unlabelled_runner_does_not_count_as_live_capacity(self) -> None:
        rows = [
            {"status": "online", "busy": True, "os": "Linux", "labels": ["cmux-fleet-linux-x64"]},
            {"status": "online", "busy": False, "os": "Linux", "labels": ["other"]},
        ]
        self.assertEqual(picker.idle_runner(rows), "")

    def test_no_live_runner_falls_back_to_smallest_measured_blacksmith(self) -> None:
        now = iter((0.0, 0.0, 181.0))
        sleeps = []
        selected = picker.choose({"REQUESTED_RUNNER": "", "ROUTE_TOKEN": "read", "GITHUB_REPOSITORY": "manaflow-ai/cmux"}, read=lambda _env, **_kwargs: [],
                                 sleep=lambda seconds: sleeps.append(seconds), clock=lambda: next(now))
        self.assertEqual(selected, "blacksmith-8vcpu-ubuntu-2404")
        self.assertEqual(sleeps, [])

    def test_one_census_read_decides_without_polling(self) -> None:
        # cmux run 41718897738: the picker polled 182 s for an idle fleet
        # runner, then took Blacksmith 8 vCPU. A readable census decides at once.
        base = {"REQUESTED_RUNNER": "", "ROUTE_TOKEN": "read", "GITHUB_REPOSITORY": "manaflow-ai/cmux"}
        busy = {"status": "online", "busy": True, "os": "Linux", "labels": [picker.FLEET]}
        for rows, expected in (
            ([busy], picker.FLEET),
            ([dict(busy, status="offline")], "blacksmith-8vcpu-ubuntu-2404"),
            ([dict(busy, os="macOS")], "blacksmith-8vcpu-ubuntu-2404"),
            ([dict(busy, labels=["other"])], "blacksmith-8vcpu-ubuntu-2404"),
        ):
            with self.subTest(rows=rows):
                reads, sleeps = [], []
                selected = picker.choose(base, read=lambda _env, **_kwargs: (reads.append(1), rows)[1],
                                         sleep=sleeps.append, clock=lambda: sum(sleeps))
                self.assertEqual((selected, len(reads), sleeps), (expected, 1, []))

    def test_an_unreadable_census_is_read_once_more_then_overflows(self) -> None:
        reads, sleeps = [], []
        selected = picker.choose(
            {"REQUESTED_RUNNER": "", "ROUTE_TOKEN": "read", "GITHUB_REPOSITORY": "manaflow-ai/cmux"},
            read=lambda _env, **_kwargs: reads.append(1), sleep=sleeps.append, clock=lambda: sum(sleeps))
        self.assertEqual((selected, len(reads), sleeps), ("blacksmith-8vcpu-ubuntu-2404", 2, [picker.POLL_SECONDS]))

    def test_live_fleet_runner_is_selected_without_waiting(self) -> None:
        rows = [{"status": "online", "busy": False, "os": "Linux",
                 "labels": ["cmux-fleet-linux-x64"]}]
        sleeps = []
        selected = picker.choose(
            {"REQUESTED_RUNNER": "", "ROUTE_TOKEN": "read", "GITHUB_REPOSITORY": "manaflow-ai/cmux"},
            read=lambda _env, **_kwargs: rows,
            sleep=lambda seconds: sleeps.append(seconds),
        )
        self.assertEqual(selected, "cmux-fleet-linux-x64")
        self.assertEqual(sleeps, [])

    def test_timed_out_fleet_request_uses_blacksmith_overflow(self) -> None:
        now = iter((0.0, 0.0, 181.0))
        selected = picker.choose(
            {"REQUESTED_RUNNER": "cmux-fleet-linux-x64", "ROUTE_TOKEN": "read", "GITHUB_REPOSITORY": "manaflow-ai/cmux"},
            read=lambda _env, **_kwargs: [],
            sleep=lambda _seconds: None,
            clock=lambda: next(now),
        )
        self.assertEqual(selected, "blacksmith-8vcpu-ubuntu-2404")

    def test_missing_route_credentials_fall_back_without_polling(self) -> None:
        sleeps = []
        selected = picker.choose(
            {"REQUESTED_RUNNER": "cmux-fleet-linux-x64"},
            read=lambda _env, **_kwargs: (_ for _ in ()).throw(AssertionError("reader must not run")),
            sleep=lambda seconds: sleeps.append(seconds),
        )
        self.assertEqual(selected, "blacksmith-8vcpu-ubuntu-2404")
        self.assertEqual(sleeps, [])

    def test_broker_requested_label_is_allowlisted(self) -> None:
        self.assertEqual(picker.choose({"REQUESTED_RUNNER": "blacksmith-16vcpu-ubuntu-2404"}, read=lambda _, **_kwargs: []),
                         "blacksmith-16vcpu-ubuntu-2404")
        self.assertEqual(picker.fallback({"REQUESTED_RUNNER": "ubuntu-latest"}), "blacksmith-8vcpu-ubuntu-2404")

    def test_github_token_alone_does_not_admit_fleet(self) -> None:
        reads = []
        selected = picker.choose(
            {"REQUESTED_RUNNER": "cmux-fleet-linux-x64", "GITHUB_TOKEN": "repository", "GITHUB_REPOSITORY": "manaflow-ai/cmux"},
            read=lambda _env, **_kwargs: reads.append(True),
        )
        self.assertEqual(selected, "blacksmith-8vcpu-ubuntu-2404")
        self.assertEqual(reads, [])

    def test_read_live_uses_snapshot_token_for_snapshot_client(self) -> None:
        calls = []

        class FakeClient:
            def __init__(self, token, repo, *, deadline=None):
                calls.append((token, repo, deadline))

            def runners(self, *, use_state=True):
                return []

            def snapshot(self, *, now):
                return {"generated_at": now.isoformat()}

        with mock.patch.object(picker.pr_runner_pool, "GitHub", FakeClient), mock.patch.object(picker, "fresh_snapshot", return_value=True):
            rows = picker.read_live(
                {"ROUTE_TOKEN": "route", "SNAPSHOT_TOKEN": "snapshot", "GITHUB_REPOSITORY": "manaflow-ai/cmux"},
                deadline=42.0,
            )
        self.assertEqual(rows, [])
        self.assertEqual(calls, [
            ("route", "manaflow-ai/cmux", 42.0),
            ("snapshot", "manaflow-ai/cmux", 42.0),
        ])

    def test_choose_passes_one_deadline_to_each_census_read(self) -> None:
        deadlines = []
        now = iter((0.0, 181.0))
        selected = picker.choose(
            {"REQUESTED_RUNNER": "cmux-fleet-linux-x64", "ROUTE_TOKEN": "route", "GITHUB_REPOSITORY": "manaflow-ai/cmux"},
            read=lambda _env, *, deadline: (deadlines.append(deadline) or []),
            sleep=lambda _seconds: None,
            clock=lambda: next(now),
        )
        self.assertEqual(selected, "blacksmith-8vcpu-ubuntu-2404")
        self.assertEqual(deadlines, [180.0])

    def test_github_client_caps_each_request_to_shared_deadline(self) -> None:
        client = picker.pr_runner_pool.GitHub("route", "manaflow-ai/cmux", deadline=10.0)
        with mock.patch.object(picker.pr_runner_pool.time, "monotonic", return_value=9.25):
            self.assertEqual(client._timeout(15.0), 0.75)
        with mock.patch.object(picker.pr_runner_pool.time, "monotonic", return_value=10.0):
            with self.assertRaises(TimeoutError):
                client._timeout(15.0)

    def test_github_deadline_interrupts_a_byte_dripping_response(self) -> None:
        _DripHandler.stop.clear()
        server = _DripServer(("127.0.0.1", 0), _DripHandler)
        thread = threading.Thread(target=server.serve_forever, name="fast-check-drip-server")
        thread.start()
        api = picker.pr_runner_pool.API
        picker.pr_runner_pool.API = f"http://127.0.0.1:{server.server_address[1]}"
        started = time.monotonic()
        try:
            client = picker.pr_runner_pool.GitHub(
                "route", "manaflow-ai/cmux", deadline=started + 0.08,
            )
            with self.assertRaises(TimeoutError):
                client.get_api("/drip")
        finally:
            picker.pr_runner_pool.API = api
            _DripHandler.stop.set()
            server.shutdown()
            server.server_close()
            thread.join(1.0)
            self.assertFalse(thread.is_alive())

    def test_github_deadline_interrupts_a_byte_dripping_artifact(self) -> None:
        _DripHandler.stop.clear()
        server = _DripServer(("127.0.0.1", 0), _DripHandler)
        thread = threading.Thread(target=server.serve_forever, name="fast-check-artifact-drip-server")
        thread.start()
        api = picker.pr_runner_pool.API
        picker.pr_runner_pool.API = f"http://127.0.0.1:{server.server_address[1]}"
        started = time.monotonic()
        try:
            client = picker.pr_runner_pool.GitHub(
                "route", "manaflow-ai/cmux", deadline=started + 0.08,
            )
            with self.assertRaises(TimeoutError):
                client.download({"archive_download_url": f"{picker.pr_runner_pool.API}/artifact"})
        finally:
            picker.pr_runner_pool.API = api
            _DripHandler.stop.set()
            server.shutdown()
            server.server_close()
            thread.join(1.0)
            self.assertFalse(thread.is_alive())


    @staticmethod
    def _refusal(path: str, code: int, headers: dict[str, str]) -> "urllib.error.HTTPError":
        message = email.message.Message()
        for name, value in headers.items():
            message[name] = value
        return urllib.error.HTTPError(f"https://api.github.com{path}", code, "Forbidden", message,
                                      io.BytesIO(b'{"message": "API rate limit exceeded"}'))

    def _choose_with_api(self, api) -> tuple[str, list[float], list[str]]:
        env = dict(ROUTE_TOKEN="synthetic-token", GITHUB_REPOSITORY="manaflow-ai/cmux")
        sleeps, paths, clock = [], [], [0.0]

        def record(path):
            paths.append(path)
            return api(path)

        def sleep(seconds):
            sleeps.append(seconds)
            clock[0] += seconds

        with mock.patch.dict(os.environ, env, clear=True), \
             mock.patch.object(picker.pr_runner_pool.GitHub, "get_api", side_effect=record), \
             contextlib.redirect_stderr(io.StringIO()):
            selected = picker.choose(env, sleep=sleep, clock=lambda: clock[0])
        return selected, sleeps, paths

    def test_spent_quota_on_repository_runners_overflows_without_polling(self) -> None:
        # cmux runs 41614121649, 41614232965 and 41614590891: every census read was
        # a 403 with X-RateLimit-Remaining=0, and the picker asked again every 15 s
        # for the whole 180 s before taking the overflow it could have taken at once.
        def api(path):
            raise self._refusal(path, 403, {"X-RateLimit-Remaining": "0", "X-RateLimit-Resource": "core"})

        selected, sleeps, paths = self._choose_with_api(api)
        self.assertEqual(selected, "blacksmith-8vcpu-ubuntu-2404")
        self.assertEqual(sleeps, [])
        self.assertEqual(len(paths), 1)

    def test_spent_quota_on_org_runner_groups_overflows_without_polling(self) -> None:
        def api(path):
            if "/orgs/" in path:
                raise self._refusal(path, 403, {"X-RateLimit-Remaining": "0"})
            return {"runners": []}

        selected, sleeps, paths = self._choose_with_api(api)
        self.assertEqual(selected, "blacksmith-8vcpu-ubuntu-2404")
        self.assertEqual(sleeps, [])
        self.assertEqual(len(paths), 2)

    def test_secondary_limit_and_429_count_as_spent_quota(self) -> None:
        for code, headers in ((429, {}), (403, {"Retry-After": "60"})):
            with self.subTest(code=code):
                selected, sleeps, _ = self._choose_with_api(
                    lambda path, code=code, headers=headers: (_ for _ in ()).throw(self._refusal(path, code, headers)))
                self.assertEqual(selected, "blacksmith-8vcpu-ubuntu-2404")
                self.assertEqual(sleeps, [])

    def test_permission_403_looks_once_more_then_overflows(self) -> None:
        def api(path):
            raise self._refusal(path, 403, {"X-RateLimit-Remaining": "4321"})

        selected, sleeps, _ = self._choose_with_api(api)
        self.assertEqual(selected, "blacksmith-8vcpu-ubuntu-2404")
        self.assertEqual(sleeps, [picker.POLL_SECONDS])

    def test_slow_runner_pages_cannot_push_admission_past_its_deadline(self) -> None:
        # Every census page drips: without one deadline across read_live's
        # page reads, each request would take its own 15 s timeout.
        _DripHandler.stop.clear()
        server = _DripServer(("127.0.0.1", 0), _DripHandler)
        thread = threading.Thread(target=server.serve_forever, name="fast-check-admission-drip-server")
        thread.start()
        api = picker.pr_runner_pool.API
        picker.pr_runner_pool.API = f"http://127.0.0.1:{server.server_address[1]}"
        env = dict(ROUTE_TOKEN="synthetic-token", GITHUB_REPOSITORY="manaflow-ai/cmux")
        started = time.monotonic()
        try:
            with mock.patch.dict(os.environ, env, clear=True), \
                 mock.patch.object(picker, "WAIT_SECONDS", 0.3), \
                 mock.patch.object(picker, "POLL_SECONDS", 0.05), \
                 contextlib.redirect_stderr(io.StringIO()):
                selected = picker.choose(env)
            elapsed = time.monotonic() - started
        finally:
            picker.pr_runner_pool.API = api
            _DripHandler.stop.set()
            server.shutdown()
            server.server_close()
            thread.join(1.0)
        self.assertEqual(selected, "blacksmith-8vcpu-ubuntu-2404")
        self.assertLess(elapsed, 0.3 + 0.5)

if __name__ == "__main__":
    unittest.main()
