#!/usr/bin/env python3
"""scripts/ci/fleet_ios_build.py has the build fleet build an iOS output through the controller's public OIDC route
and keeps `cmux-ci ios-build`'s exit codes (0 pass with every output, 1 a failed build, 2 no answer). The kit's
link-ffi-fleet job calls it from a Linux runner, so no Mac sits idle waiting for the build."""
from __future__ import annotations

import contextlib
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

    def __init__(self, submit, statuses, archive=b"", bearer="tok", queue=(400, None, b'op must be "submit" or "status"')):
        self.submit, self.statuses, self.archive = submit, list(statuses), archive
        self.bodies, self.bearer = [], bearer
        # The queue op (asked once, before the submit), kept out of `bodies`. By default an older controller's
        # answer, which the script reads as no answer and submits anyway.
        self.queue, self.queue_asks = queue, 0

    def __call__(self, req, timeout=None):
        if req.full_url == "https://store.example/out.tgz":
            # The store sits behind the route's CDN: urllib's default agent got 403 there (run 45932893553).
            if req.get_header("User-agent") != fib.USER_AGENT:
                raise urllib.error.HTTPError(req.full_url, 403, "Forbidden", {}, io.BytesIO(b"error code: 1010"))
            assert req.get_header("Authorization") is None, "the presigned URL is its own credential"
            return Resp(self.archive)
        assert req.full_url == fib.ROUTE, req.full_url
        if req.get_header("Authorization") != f"Bearer {self.bearer}":
            self.bodies.append("refused")
            raise urllib.error.HTTPError(fib.ROUTE, 401, "x", {}, io.BytesIO(b"token refused: expired"))
        # urllib's default agent gets HTTP 403 "error code: 1010" from the CDN (run 45898219170).
        assert req.get_header("User-agent") == fib.USER_AGENT, req.get_header("User-agent")
        body = json.loads(req.data)
        if body["op"] == "queue":
            self.queue_asks += 1
            ans = self.queue
        else:
            self.bodies.append(body)
        if body["op"] == "queue":
            pass
        elif body["op"] == "submit":
            ans = self.submit.pop(0) if isinstance(self.submit, list) else self.submit
        else:
            ans = self.statuses.pop(0)
        if isinstance(ans, tuple):
            code, retry, text = (ans + (b"not enabled",))[:3]
            raise urllib.error.HTTPError(fib.ROUTE, code, "x", {"Retry-After": retry} if retry else {},
                                         io.BytesIO(text))
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

    def test_failed_build_prints_each_compiler_error_as_an_annotation(self):
        errors = [
            {"file": "cmux-next-ios/CmuxMobileKit/Tests/CmuxMobileModelTests/WorkspaceGroupTests.swift", "line": 476,
             "col": 1, "message": "unexpected conditional compilation block terminator"},
            {"file": "Packages/Shared/A.swift", "line": 3, "col": 9, "message": "50% of\nit, here: x"},
            {"file": "/etc/passwd", "line": 1, "col": 1, "message": "no"},
            {"file": "cmux-next-ios/../x.swift", "line": 1, "col": 1, "message": "no"},
            {"file": "cmux-next-ios/B.swift", "line": "1", "message": "no"},
            "not a dict",
        ]
        route = Route({"job": "j1"}, [{"state": "failed", "verdict": "fail", "reason": "build", "errors": errors}])
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(run(route, self.out), 1)
        self.assertEqual(out.getvalue().splitlines(), [
            "::error file=cmux-next-ios/CmuxMobileKit/Tests/CmuxMobileModelTests/WorkspaceGroupTests.swift,line=476,col=1,"
            "title=build fleet::unexpected conditional compilation block terminator",
            "::error file=Packages/Shared/A.swift,line=3,col=9,title=build fleet::50%25 of%0Ait, here: x",
        ])

    def test_failed_build_without_errors_prints_none(self):
        route = Route({"job": "j1"}, [{"state": "failed", "verdict": "fail", "reason": "build"}])
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(run(route, self.out), 1)
        self.assertEqual(out.getvalue(), "")

    def test_route_not_enabled_is_2(self):
        route = Route((503, "10"), [])
        self.assertEqual(run(route, self.out), 2)
        self.assertEqual(len(route.bodies), 1)  # "not enabled" does not change on a retry

    def test_submit_to_a_starting_controller_is_retried(self):
        # Kit run 45926512987 (2026-11-27): the first submit got 503 "the controller is starting; retry" and the
        # client gave up after 20 s, so the Mac built the simulator tests instead.
        starting = (503, None, b"the controller is starting; retry")
        route = Route([starting, starting, {"job": "j1"}],
                      [{"state": "done", "verdict": "pass", "get_url": "https://store.example/out.tgz"}], tgz(FFI))
        self.assertEqual(run(route, self.out), 0)
        self.assertEqual([b["op"] for b in route.bodies], ["submit", "submit", "submit", "status"])

    def test_submit_to_a_controller_that_stays_down_is_2(self):
        route = Route([(503, None, b"the controller is starting; retry")] * 100, [])
        self.assertEqual(run(route, self.out), 2)
        self.assertLess(len(route.bodies), 15)

    def test_submit_refused_is_not_retried(self):
        route = Route([(403, None, b"workflow not allowed"), {"job": "j1"}], [])
        self.assertEqual(run(route, self.out), 2)
        self.assertEqual(len(route.bodies), 1)

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

    def test_refused_download_names_its_reason(self):
        def store(req, timeout=None):
            if req.full_url == "https://store.example/out.tgz":
                raise urllib.error.HTTPError(req.full_url, 403, "Forbidden", {}, io.BytesIO(
                    b"<?xml version='1.0'?><Error><Code>SignatureDoesNotMatch</Code></Error>"))
            return route(req, timeout)
        route = Route({"job": "j1"}, [{"state": "done", "verdict": "pass", "get_url": "https://store.example/out.tgz"}])
        err = io.StringIO()
        with contextlib.redirect_stderr(err), contextlib.redirect_stdout(err):
            code = fib.run("ffi", self.out, 1500, 600, "tok", opener=store, clock=Clock(), sleep=lambda s: None)
        self.assertEqual(code, 2)
        self.assertIn("output unreadable: HTTP 403 SignatureDoesNotMatch", err.getvalue())

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

    def test_expired_token_is_minted_again(self):
        # A job's OIDC token lives ~5 min; the poll got 401 "expired" at 344 s in run 45915442830.
        route = Route({"job": "j1", "state": "queued"}, [{"state": "running"}, {"verdict": "fail", "reason": "x"}])
        tokens = iter(["tok", "tok2"])
        clock = Clock()

        def sleep(s):
            clock.sleep(s)
            route.bearer = "tok2"  # past the first poll the first token has expired

        rc = fib.run("ffi", self.out, 1500, 600, lambda: next(tokens), opener=route, clock=clock, sleep=sleep)
        self.assertEqual(rc, 1)
        self.assertEqual([b if b == "refused" else b["op"] for b in route.bodies],
                         ["submit", "status", "refused", "status"])

    def test_expired_token_without_a_minter_is_2(self):
        route = Route({"job": "j1", "state": "queued"}, [{"state": "running"}], bearer="other")
        self.assertEqual(run(route, self.out), 2)

    def test_no_token_is_2(self):
        clock = Clock()
        self.assertEqual(fib.run("ffi", self.out, 1500, 600, lambda: None, opener=Route({}, []), clock=clock,
                                 sleep=clock.sleep), 2)

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

    def test_kit_sim_fleet_builds_on_linux_through_the_route(self):
        job = self.jobs["kit-sim-fleet"]
        self.assertEqual(job["runs-on"], "cmux-linux")
        self.assertEqual(job["permissions"].get("id-token"), "write")
        self.assertIn("CMUX_IOS_KIT_SIM_FLEET", job["if"])
        build = next(s for s in job["steps"] if s.get("id") == "build")
        self.assertIn("scripts/ci/fleet_ios_build.py --what kit-products", build["run"])
        self.assertNotIn("cmux-ci", build["run"])
        self.assertEqual(fib.OUTPUTS["kit-products"], fib.OUTPUTS["sim-products"][:2])

    def test_the_mac_builds_the_simulator_tests_only_as_the_fallback(self):
        steps = {s.get("id"): s for s in self.jobs["kit-tests"]["steps"] if s.get("id")}
        self.assertIn("vars.CMUX_IOS_KIT_SIM_FLEET == 'on'", steps["sim-fleet"]["if"])
        self.assertIn("kit-sim-fleet-products-", steps["sim-fleet"]["env"]["ARTIFACT"])
        self.assertEqual(steps["sim-fleet"]["env"]["JOB"], self.jobs["kit-sim-fleet"]["name"])
        self.assertIn("steps.sim-fleet.outputs.hit != 'true'", steps["sim-pack"]["if"])
        self.assertEqual(steps["sim-fleet"]["run"].strip(), "bash scripts/ci/kit_sim_fleet.sh wait")
        # The pool reads the fleet's artifact by its own name: no download, no second upload under the Mac's name.
        self.assertNotIn("sim-fleet", steps["sim-upload"]["if"])
        self.assertIn("steps.sim-products.outputs.name", steps["sim-linux-start"]["env"]["PRODUCTS"])
        self.assertIn("steps.sim-products.outputs.ready", steps["sim-linux-start"]["if"])
        self.assertIn("steps.sim-products.outputs.name", self.jobs["kit-tests"]["outputs"]["sim_products"])
        pool_steps = {s.get("id"): s for s in self.jobs["kit-sim-pool"]["steps"] if s.get("id")}
        # The pool job's wait step names the products (#60129); the pool run reads that name from it.
        self.assertIn("needs.kit-tests.outputs.sim_products", pool_steps["wait"]["env"]["PRODUCTS"])
        self.assertIn("steps.wait.outputs.products", pool_steps["pool"]["env"]["PRODUCTS"])

    def test_a_shadow_job_never_fails_the_workflow(self):
        steps = {s.get("id"): s for s in self.jobs["kit-sim-fleet"]["steps"] if s.get("id")}
        for name in ("upload", "pool"):
            self.assertTrue(steps[name].get("continue-on-error"), name)
        self.assertIn("|| status=$?", steps["build"]["run"])
        self.assertEqual(steps["pool"]["run"].strip(), "bash scripts/ci/kit_sim_fleet.sh pool")

    def test_every_pool_submit_selects_its_bundle_mode(self):
        for job_name, job in self.jobs.items():
            for step in job["steps"]:
                if step.get("run", "").strip() != "bash scripts/ci/kit_sim_fleet.sh pool":
                    continue
                with self.subTest(job=job_name):
                    # The build comparison always runs all bundles. Production submits
                    # must preserve the cutover split, including the owned-Mac fallback.
                    expected = "shadow" if job_name == "kit-sim-fleet" else "${{ vars.CMUX_IOS_SIM_LINUX || 'shadow' }}"
                    self.assertEqual(step.get("env", {}).get("CMUX_IOS_SIM_LINUX"), expected)

    def test_no_pool_step_reads_an_exit_after_a_bare_command(self):
        # A step is bash -e: `cmd; status=$?` never reads a failure, and `grep -c || echo 0` prints "0\n0".
        text = WORKFLOW.read_text()
        self.assertNotRegex(text, r"\n\s*status=\$\?\n")
        self.assertNotIn("|| echo 0)", text)

    def test_kit_tests_waits_without_the_gateway_variable(self):
        for step in self.jobs["kit-tests"]["steps"]:
            self.assertNotIn("CI_EVAL_STEP_GATEWAY", str(step.get("if", "")))


class QueueFirst(unittest.TestCase):
    """Run 45996304968 (2026-11-27): the kit-sim-fleet job held a cmux-linux runner 604 s for a job that sat
    queued the whole --queue-timeout and built nothing. The script now asks for the queue first."""

    def test_a_full_queue_is_no_answer_at_once(self):
        route = Route({"job": "j1", "state": "queued"}, [], queue={"queued": 3, "oldest_queued_s": 612})
        clock = Clock()
        err = io.StringIO()
        with contextlib.redirect_stderr(err), contextlib.redirect_stdout(io.StringIO()):
            rc = fib.run("kit-products", "/nonexistent", 1500, 600, "tok", opener=route, clock=clock, sleep=clock.sleep)
        self.assertEqual(rc, 2)
        self.assertEqual(route.bodies, [], "it submitted into a full queue")
        self.assertEqual(clock.t, 0, "it waited before giving up")
        self.assertIn("queue full", err.getvalue())

    def test_a_short_queue_submits(self):
        route = Route({"job": "j1", "state": "queued"}, [{"job": "j1", "state": "done", "verdict": "fail", "reason": "build"}],
                      queue={"queued": 1, "oldest_queued_s": 40})
        clock = Clock()
        with contextlib.redirect_stderr(io.StringIO()), contextlib.redirect_stdout(io.StringIO()):
            rc = fib.run("kit-products", "/nonexistent", 1500, 600, "tok", opener=route, clock=clock, sleep=clock.sleep)
        self.assertEqual(rc, 1)
        self.assertEqual(route.queue_asks, 1)
        self.assertEqual([b["op"] for b in route.bodies], ["submit", "status"])

    def test_no_queue_answer_submits_as_before(self):
        for queue in ((400, None, b"op must be"), (503, "10", b"starting"), {"queued": 2}):
            route = Route({"job": "j1", "state": "queued"}, [{"job": "j1", "state": "done", "verdict": "fail"}], queue=queue)
            clock = Clock()
            with contextlib.redirect_stderr(io.StringIO()), contextlib.redirect_stdout(io.StringIO()):
                rc = fib.run("kit-products", "/nonexistent", 1500, 600, "tok", opener=route, clock=clock, sleep=clock.sleep)
            self.assertEqual(rc, 1, queue)
            self.assertEqual(route.bodies[0]["op"], "submit", queue)


if __name__ == "__main__":
    sys.exit(unittest.main())
