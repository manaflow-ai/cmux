#!/usr/bin/env python3
"""The fleet-client action names a runner with no route to the controller.

The controller answers on the tailnet only, and the cmux-runner-pool-* VMs behind `cmux-linux` are not tailnet
members. On 2026-11-28 every fleet-client job on those VMs (c1a-0174, c1a-0182, w4b-0106-2, e4a-0280-2, w3c-0207-2)
spent 2 min on three 30 s timeouts and ended "could not be fetched after 3 tries", which names no cause. The step now
tells "no route" (every connect failed) apart from a controller that answered with an error.
cmuxterm-hq docs/handbook/fleet-waiter-job-holds-its-mini.md, "The cmux-linux pool is off the tailnet".
"""

from __future__ import annotations

import http.server
import os
import socket
import subprocess
import tempfile
import threading
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
ACTION = ROOT / ".github" / "actions" / "fleet-client" / "action.yml"


def fetch_step() -> str:
    steps = yaml.safe_load(ACTION.read_text(encoding="utf-8"))["runs"]["steps"]
    return next(s for s in steps if s.get("name") == "Fetch the fleet client")["run"]


def closed_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class NotFound(http.server.BaseHTTPRequestHandler):
    def do_GET(self) -> None:  # noqa: N802
        self.send_error(404)

    def log_message(self, *args) -> None:
        pass


class FleetClientNoRouteTests(unittest.TestCase):
    def run_step(self, controller: str) -> subprocess.CompletedProcess:
        tmp = Path(self.enterContext(tempfile.TemporaryDirectory()))
        bin_dir = tmp / "bin"
        bin_dir.mkdir()
        (bin_dir / "sleep").write_text("#!/bin/sh\nexit 0\n")  # the retry backoff, not under test
        (bin_dir / "sleep").chmod(0o755)
        env = dict(os.environ, CONTROLLER=controller, RUNNER_TEMP=str(tmp), GITHUB_ENV=str(tmp / "env"),
                   RUNNER_NAME="cmux-runner-pool-c1a-0182", PATH=f"{bin_dir}:{os.environ['PATH']}", HOME=str(tmp))
        return subprocess.run(["bash", "--noprofile", "--norc", "-e", "-o", "pipefail", "-c", fetch_step()],
                              env=env, capture_output=True, text=True, timeout=120)

    def test_a_runner_with_no_route_is_named(self) -> None:
        out = self.run_step(f"http://127.0.0.1:{closed_port()}")
        self.assertEqual(out.returncode, 1, out.stdout + out.stderr)
        self.assertIn("runner cmux-runner-pool-c1a-0182 has no route to the controller", out.stdout)
        self.assertIn("the-cmux-linux-pool-is-off-the-tailnet", out.stdout)
        self.assertNotIn("127.0.0.1", out.stdout)  # the controller's address stays out of a public log

    def test_a_controller_that_answers_an_error_is_not_called_no_route(self) -> None:
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), NotFound)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        out = self.run_step(f"http://127.0.0.1:{server.server_address[1]}")
        self.assertEqual(out.returncode, 1, out.stdout + out.stderr)
        self.assertNotIn("no route", out.stdout)
        self.assertIn("could not be fetched after 3 tries", out.stdout)


if __name__ == "__main__":
    unittest.main()
