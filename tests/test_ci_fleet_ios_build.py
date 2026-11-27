#!/usr/bin/env python3
"""scripts/ci/fleet_ios_build.py has the build fleet build an iOS output through the controller's public OIDC route
and keeps `cmux-ci ios-build`'s exit codes (0 pass with every output, 1 a failed build, 2 no answer). The kit's
link-ffi-fleet job calls it from a Linux runner, so no Mac sits idle waiting for the build."""
from __future__ import annotations

import importlib.util
import io
import json
import sys
import tarfile
import tempfile
import unittest
import urllib.error
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/fleet_ios_build.py"
WORKFLOW = ROOT / ".github/workflows/cmux-next-ios-kit.yml"

spec = importlib.util.spec_from_file_location("fleet_ios_build", SCRIPT)
fib = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fib)


def tgz(files, extra=None):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tar:
        for name, data in files.items():
            info = tarfile.TarInfo(name)
            info.size = len(data)
            tar.addfile(info, io.BytesIO(data))
        if extra is not None:
            tar.addfile(extra)
    return buf.getvalue()


FFI = {"CmuxMobileLinkFFI.xcframework/Info.plist": b"<plist/>", "CmuxMobileLinkFFI.swift": b"// bindings\n"}


class Resp(io.BytesIO):
    def __init__(self, body, status=200):
        super().__init__(body if isinstance(body, bytes) else json.dumps(body).encode())
        self.status = status

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()


class Route:
    """A fake route: answers are consumed in order per op; a download URL serves `archive`."""

    def __init__(self, submit, statuses, archive=b""):
        self.submit, self.statuses, self.archive = submit, list(statuses), archive
        self.bodies = []

    def __call__(self, req, timeout=None):
        if req.full_url == "https://store.example/out.tgz":
            return Resp(self.archive)
        assert req.full_url == fib.ROUTE, req.full_url
        assert req.get_header("Authorization") == "Bearer tok"
        body = json.loads(req.data)
        self.bodies.append(body)
        ans = self.submit if body["op"] == "submit" else self.statuses.pop(0)
        if isinstance(ans, tuple):
            code, retry = ans
            raise urllib.error.HTTPError(fib.ROUTE, code, "x", {"Retry-After": retry} if retry else {},
                                         io.BytesIO(b"not enabled"))
        return Resp(ans)


class Clock:
    def __init__(self):
        self.t = 0.0

    def __call__(self):
        return self.t

    def sleep(self, s):
        self.t += s


def run(route, out, timeout=1500, queue_timeout=600):
    clock = Clock()
    return fib.run("ffi", out, timeout, queue_timeout, "tok", opener=route, clock=clock, sleep=clock.sleep)


class FleetIOSBuild(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.out = Path(self.tmp.name) / "out"

    def tearDown(self):
        self.tmp.cleanup()

    def test_pass_unpacks_every_output(self):
        route = Route({"job": "j1", "state": "queued"},
                      [{"job": "j1", "state": "running"},
                       {"job": "j1", "state": "done", "verdict": "pass",
                        "get_url": "https://store.example/out.tgz"}], tgz(FFI))
        self.assertEqual(run(route, self.out), 0)
        self.assertTrue((self.out / "CmuxMobileLinkFFI.xcframework/Info.plist").is_file())
        self.assertEqual(route.bodies[0], {"op": "submit", "what": "ffi"})
        self.assertEqual(route.bodies[1], {"op": "status", "job": "j1"})

    def test_submit_names_no_ref(self):
        # The route reads the commit from the token; the reader never sends one it could choose.
        route = Route({"job": "j1"}, [{"state": "done", "verdict": "fail", "reason": "bindings"}])
        run(route, self.out)
        self.assertNotIn("ref", route.bodies[0])
        self.assertNotIn("sha", route.bodies[0])

    def test_failed_build_is_1(self):
        route = Route({"job": "j1"}, [{"state": "failed", "verdict": "fail", "reason": "bindings drifted"}])
        self.assertEqual(run(route, self.out), 1)

    def test_route_not_enabled_is_2(self):
        route = Route((503, "10"), [])
        self.assertEqual(run(route, self.out), 2)

    def test_ended_without_verdict_is_2(self):
        route = Route({"job": "j1"}, [{"state": "cancelled"}])
        self.assertEqual(run(route, self.out), 2)

    def test_queued_past_queue_timeout_is_2(self):
        route = Route({"job": "j1"}, [{"state": "queued"}] * 200)
        self.assertEqual(run(route, self.out, queue_timeout=60), 2)

    def test_running_past_timeout_is_2(self):
        route = Route({"job": "j1"}, [{"state": "running"}] * 500)
        self.assertEqual(run(route, self.out, timeout=120, queue_timeout=60), 2)

    def test_503_while_waiting_is_retried(self):
        route = Route({"job": "j1"}, [(503, "3"), {"state": "running"},
                                      {"state": "done", "verdict": "pass", "get_url": "https://store.example/out.tgz"}],
                      tgz(FFI))
        self.assertEqual(run(route, self.out), 0)

    def test_missing_output_is_2(self):
        route = Route({"job": "j1"}, [{"state": "done", "verdict": "pass", "get_url": "https://store.example/out.tgz"}],
                      tgz({"CmuxMobileLinkFFI.swift": b"x"}))
        self.assertEqual(run(route, self.out), 2)

    def test_unsafe_member_is_refused(self):
        link = tarfile.TarInfo("evil")
        link.type, link.linkname = tarfile.SYMTYPE, "/etc/passwd"
        route = Route({"job": "j1"}, [{"state": "done", "verdict": "pass", "get_url": "https://store.example/out.tgz"}],
                      tgz(FFI, extra=link))
        self.assertEqual(run(route, self.out), 2)
        self.assertFalse((self.out / "evil").exists())

    def test_no_token_without_id_token_permission(self):
        self.assertIsNone(fib.oidc_token(env={}))

    def test_token_asks_for_the_route_audience(self):
        seen = []

        def opener(req, timeout=None):
            seen.append((req.full_url, req.get_header("Authorization")))
            return Resp({"value": "tok"})

        env = {"ACTIONS_ID_TOKEN_REQUEST_URL": "https://t.example/?x=1", "ACTIONS_ID_TOKEN_REQUEST_TOKEN": "rt"}
        self.assertEqual(fib.oidc_token(env=env, opener=opener), "tok")
        self.assertEqual(seen, [("https://t.example/?x=1&audience=cmux-ios-build", "Bearer rt")])


class KitWorkflow(unittest.TestCase):
    def setUp(self):
        self.jobs = yaml.safe_load(WORKFLOW.read_text())["jobs"]

    def test_link_ffi_fleet_runs_on_linux(self):
        job = self.jobs["link-ffi-fleet"]
        runs_on = str(job["runs-on"])
        self.assertIn("cmux-linux", runs_on)
        self.assertNotIn("CI_EVAL_STEP_GATEWAY", runs_on)
        self.assertNotIn("macos", runs_on)
        self.assertNotIn("CI_EVAL_STEP_GATEWAY", job["if"])
        self.assertEqual(job["permissions"].get("id-token"), "write")

    def test_link_ffi_fleet_reads_the_route_not_the_client(self):
        steps = self.jobs["link-ffi-fleet"]["steps"]
        build = next(s for s in steps if s.get("id") == "build")
        self.assertIn("scripts/ci/fleet_ios_build.py --what ffi", build["run"])
        self.assertNotIn("cmux-ci", build["run"])
        checkout = steps[0]["with"]
        self.assertIn("scripts/ci", checkout["sparse-checkout"])

    def test_kit_tests_waits_without_the_gateway_variable(self):
        for step in self.jobs["kit-tests"]["steps"]:
            self.assertNotIn("CI_EVAL_STEP_GATEWAY", str(step.get("if", "")))


if __name__ == "__main__":
    sys.exit(unittest.main())
