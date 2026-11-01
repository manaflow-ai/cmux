#!/usr/bin/env python3
"""Nightly paid overflow needs a matching, expired fleet admission lease."""
from __future__ import annotations

import datetime as dt
import json
import io
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/ci"))
sys.path.insert(0, str(ROOT / "tests"))
import nightly_linux_admission as admission
import fleet_admission_transport as transport
from test_nightly_trusted_routing import evaluate, parse_expression

ENV = {"GITHUB_REPOSITORY": "manaflow-ai/cmux", "GITHUB_RUN_ID": "123",
       "GITHUB_RUN_ATTEMPT": "1", "GITHUB_SHA": "a" * 40,
       "JOBS": "control", "SIDE_LABEL": "glaeda-side-std-xcode-26.6",
       "OVERFLOW_LINUX": "blacksmith-16vcpu-ubuntu-2404"}
ENV["JOBS"] = " ".join(sorted(admission.JOBS))
REQUEST = admission.identity(ENV)
LEASE = "b" * 24
CREATED = dt.datetime.now(dt.timezone.utc) - dt.timedelta(seconds=180)


def receipt(status="pending"):
    value = {**REQUEST, "lease_id": LEASE, "status": status,
             "created_at": CREATED.isoformat(),
             "expires_at": (CREATED + dt.timedelta(seconds=180)).isoformat()}
    if status == "fleet":
        value.update(decided_at=(CREATED + dt.timedelta(seconds=15)).isoformat(),
                     runners={job: f"cmux-nightly-{LEASE}-{job}" for job in REQUEST["jobs"]})
    elif status == "overflow":
        value.update(decided_at=value["expires_at"], no_start_seconds=180, runners={})
    return value


def expected_fallback(job):
    return ENV["OVERFLOW_LINUX"] if job == "build-nightly-inputs" else "ubuntu-24.04"


class Receipts(unittest.TestCase):
    def test_future_receipt_cannot_authorize_overflow(self):
        value = receipt("overflow")
        future = dt.datetime.now(dt.timezone.utc) + dt.timedelta(seconds=10)
        value.update(created_at=future.isoformat(),
                     expires_at=(future + dt.timedelta(seconds=180)).isoformat(),
                     decided_at=(future + dt.timedelta(seconds=180)).isoformat())
        with self.assertRaises(ValueError):
            admission.validate(value, REQUEST)

    def test_plain_public_http_cannot_supply_an_admission_receipt(self):
        with mock.patch("urllib.request.urlopen", return_value=io.BytesIO(b"{}")):
            with self.assertRaises(ValueError):
                admission.exchange("http://203.0.113.1/v1/nightly-linux-admission")

    def test_reserved_runners_are_bound_to_each_job(self):
        value = receipt("fleet")
        self.assertEqual(admission.routes(ENV, REQUEST, value), value["runners"])
        self.assertNotIn("blacksmith", json.dumps(value["runners"]))

    def test_overflow_needs_all_180_seconds(self):
        for seconds in (0, 179, 180):
            with self.subTest(seconds=seconds):
                value = receipt("overflow")
                value["no_start_seconds"] = seconds
                if seconds < 180:
                    with self.assertRaises(ValueError):
                        admission.validate(value, REQUEST)
                else:
                    self.assertEqual(admission.validate(value, REQUEST), "overflow")

    def test_invalid_or_stale_receipts_never_authorize_routing(self):
        mutations = [
            {"run_id": 124}, {"run_attempt": 2}, {"source_sha": "c" * 40},
            {"repository": "another/repo"}, {"jobs": ["unknown-control"]},
            {"lease_id": "../bad"}, {"no_start_seconds": 999}, {"no_start_seconds": True}, {"no_start_seconds": float("nan")},
            {"created_at": "2026-11-01T00:00:00"},
            {"expires_at": (CREATED + dt.timedelta(seconds=179)).isoformat()},
            {"decided_at": (CREATED + dt.timedelta(seconds=179)).isoformat()},
            {"status": "unknown"}, {"runners": {"unknown-control": admission.FLEET_LINUX}},
        ]
        for mutation in mutations:
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                admission.validate({**receipt("overflow"), **mutation}, REQUEST)

    def test_late_or_foreign_fleet_receipt_is_rejected(self):
        for mutation in ({"decided_at": receipt()["expires_at"]},
                         {"runners": {job: "blacksmith-16vcpu-ubuntu-2404" for job in REQUEST["jobs"]}},
                         {"runners": {job: admission.FLEET_LINUX for job in REQUEST["jobs"]}}):
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                admission.validate({**receipt("fleet"), **mutation}, REQUEST)

    def test_committed_fleet_decision_survives_delayed_delivery(self):
        # Decision at 179s, response at 181s: reserved listeners remain bound to
        # this parent/job while its dependencies run. The 180s limit governs
        # admission, not delivery of an already committed fleet decision.
        delivered = dt.datetime.now(dt.timezone.utc)
        value = receipt("fleet")
        value.update(created_at=(delivered - dt.timedelta(seconds=181)).isoformat(),
                     expires_at=(delivered - dt.timedelta(seconds=1)).isoformat(),
                     decided_at=(delivered - dt.timedelta(seconds=2)).isoformat())
        self.assertEqual(admission.routes(ENV, REQUEST, value), value["runners"])

    def test_missing_admission_uses_measured_overflow_without_live_capacity(self):
        selected = admission.routes(ENV, REQUEST, None)
        for job in admission.JOBS:
            self.assertEqual(selected[job], expected_fallback(job))

    def test_unconfigured_mini_and_reruns_use_measured_overflow(self):
        for config in ({**ENV, "SIDE_LABEL": ""}, {**ENV, "GITHUB_RUN_ATTEMPT": "3"}):
            self.assertEqual(set(admission.routes(config, admission.identity(config), None).values()),
                             {ENV["OVERFLOW_LINUX"], "ubuntu-24.04"} if config.get("GITHUB_RUN_ATTEMPT") == "1"
                             else {ENV["OVERFLOW_LINUX"]})

    def test_live_mini_precedes_hosted_light_fallback(self):
        job = "resolve-nightly-cmux-tui-client"
        placed = admission.portable.Placement(mini_runner=ENV["SIDE_LABEL"], mini_jobs=(job,))
        with mock.patch.object(admission.portable, "decide", return_value=placed):
            selected = admission.routes(ENV, REQUEST, receipt("overflow"), [], {})
        self.assertEqual(selected[job], ENV["SIDE_LABEL"])
        self.assertEqual(selected["find-nightly-next-recovery"], "ubuntu-24.04")
        self.assertEqual(selected["build-nightly-inputs"], ENV["OVERFLOW_LINUX"])

    def test_recorded_overflow_only_uses_declared_paid_set(self):
        selected = admission.routes({**ENV, "SIDE_LABEL": ""}, REQUEST, receipt("overflow"))
        self.assertEqual(set(selected.values()), {ENV["OVERFLOW_LINUX"], "ubuntu-24.04"})
        for label in ("ubuntu-24.04", "untrusted", "glaeda-side-std-xcode-26.6"):
            with self.subTest(label=label), self.assertRaises(ValueError):
                admission.routes({**ENV, "OVERFLOW_LINUX": label}, REQUEST, receipt("overflow"))

    def test_long_poll_consumes_same_lease_and_stops_at_terminal(self):
        with mock.patch.object(admission, "exchange", side_effect=[receipt(), receipt("fleet")]) as exchange:
            value = admission.admit({**ENV, "CMUX_CI_CONTROLLER": "http://controller"}, REQUEST)
        self.assertEqual(value["status"], "fleet")
        self.assertEqual(exchange.call_args.args, (f"http://controller/v1/nightly-linux-admission/{LEASE}?wait=30",))
        self.assertEqual(exchange.call_count, 2)

    def test_changed_lease_during_wait_is_rejected(self):
        changed = receipt("overflow")
        changed["lease_id"] = "c" * 24
        with mock.patch.object(admission, "exchange", side_effect=[receipt(), changed]):
            with self.assertRaises(ValueError):
                admission.admit({**ENV, "CMUX_CI_CONTROLLER": "http://controller"}, REQUEST)

    def test_long_poll_has_a_client_deadline(self):
        with mock.patch.object(admission, "exchange", return_value=receipt()), \
             mock.patch.object(admission.time, "monotonic", side_effect=[0, 241]):
            with self.assertRaises(TimeoutError):
                admission.admit({**ENV, "CMUX_CI_CONTROLLER": "http://controller"}, REQUEST)

    def test_capacity_deadline_is_cleared_and_handler_restored(self):
        previous = admission.signal.getsignal(admission.signal.SIGALRM)
        with mock.patch.object(admission.portable, "read", side_effect=admission.portable.Deadline), \
             mock.patch.object(admission.signal, "setitimer") as timer:
            with self.assertRaises(admission.portable.Deadline):
                admission.read_minis(ENV)
        self.assertEqual(timer.call_args.args, (admission.signal.ITIMER_REAL, 0))
        self.assertEqual(admission.signal.getsignal(admission.signal.SIGALRM), previous)

    def test_unavailable_controller_writes_overflow_without_forging_receipt(self):
        with tempfile.TemporaryDirectory() as scratch:
            output, record = Path(scratch) / "output", Path(scratch) / "receipt.json"
            config = {**ENV, "GITHUB_OUTPUT": str(output), "ADMISSION_RECEIPT_PATH": str(record)}
            with mock.patch.object(admission, "admit", side_effect=TimeoutError), \
                 mock.patch.object(admission, "read_minis", return_value=(None, None)), \
                 mock.patch.object(admission.time, "monotonic", side_effect=[0, 30, 180]), \
                 mock.patch.object(admission.time, "sleep") as wait:
                self.assertEqual(admission.main(config), 0)
            wait.assert_called_once_with(150)
            self.assertIn(ENV["OVERFLOW_LINUX"], output.read_text())
            self.assertNotIn("signer_build_runner", output.read_text())
            recorded = json.loads(record.read_text())
            self.assertIsNone(recorded["receipt"])
            observation = recorded["client_observation"]
            self.assertEqual(observation["source"], "client")
            self.assertEqual(observation["no_start_seconds"], 180)
            self.assertLessEqual(admission.timestamp(observation["started_at"]),
                                 admission.timestamp(observation["ended_at"]))


class Transport(unittest.TestCase):
    def test_http_requires_an_online_peer_of_the_running_tailnet(self):
        peer = {"BackendState": "Running", "Peer": {
            "controller": {"Online": True, "TailscaleIPs": ["100.64.0.8"]}}}
        with mock.patch.object(transport.shutil, "which", return_value="/bin/tailscale"), \
             mock.patch.object(transport.subprocess, "run") as run:
            run.return_value.stdout = json.dumps(peer)
            transport.verify_authority("http://100.64.0.8:18765/v1/admission")
            for bad in ({**peer, "BackendState": "Stopped"},
                        {**peer, "Peer": {}},
                        {**peer, "Peer": {"controller": {"Online": False, "TailscaleIPs": ["100.64.0.8"]}}}):
                run.return_value.stdout = json.dumps(bad)
                with self.subTest(status=bad), self.assertRaises(ValueError):
                    transport.verify_authority("http://100.64.0.8:18765/v1/admission")
            self.assertEqual(run.call_args.kwargs["timeout"], 5)

    def test_no_plain_dns_public_http_credentials_or_other_protocol(self):
        for url in ("http://controller/v1", "http://127.0.0.1/v1", "http://203.0.113.1/v1",
                    "https://user:password@controller/v1", "file:///tmp/receipt", "https://controller/v1#other"):
            with self.subTest(url=url), self.assertRaises(ValueError):
                transport.verify_authority(url)

    def test_https_uses_certificate_transport_without_tailnet_probe(self):
        with mock.patch.object(transport.subprocess, "run") as run:
            transport.verify_authority("https://controller.example/v1/admission")
            run.assert_not_called()

    def test_redirect_is_never_followed(self):
        with self.assertRaises(ValueError):
            transport.NoRedirect().redirect_request(None, None, 302, "redirect", {}, "https://other.example/")

    def test_exchange_disables_environment_proxies(self):
        with mock.patch.object(transport.urllib.request, "build_opener") as build:
            build.return_value.open.return_value = io.BytesIO(b'{"status": "pending"}')
            self.assertEqual(transport.exchange("https://controller.example/v1"), {"status": "pending"})
            self.assertEqual(build.call_args.args[0].proxies, {})
            self.assertIsInstance(build.call_args.args[1], transport.NoRedirect)


class Workflow(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.jobs = yaml.safe_load((ROOT / ".github/workflows/nightly.yml").read_text())["jobs"]

    def test_admitted_jobs_have_no_credentials_or_environment(self):
        for name in admission.JOBS:
            with self.subTest(job=name):
                self.assertNotIn("environment", self.jobs[name])
                self.assertNotIn("secrets.", yaml.safe_dump(self.jobs[name]))
        legacy = next(step for step in self.jobs["decide"]["steps"]
                      if step.get("id") == "place-early-mac")
        self.assertEqual(legacy["env"]["JOBS"], "pick-nightly-build-runner")
        self.assertEqual(legacy["env"]["FLEET_LINUX"], "")
        self.assertEqual(legacy["env"]["REQUIRE_LIVE_CAPACITY"], "1")
        sparse = next(step for step in self.jobs["decide"]["steps"]
                      if step.get("name") == "Check out NEXT decision and placement helpers")
        self.assertIn("/.github/runners.json", sparse["with"]["sparse-checkout"])

    def test_missing_stale_or_quota_failed_picker_uses_measured_overflow(self):
        for name in admission.JOBS:
            source = self.jobs[name]["runs-on"].removeprefix("${{").removesuffix("}}")
            key = f"needs.decide.outputs.early_{admission.output_key(name)}_runner"
            for attempt in (1, 2, 3):
                for overflow in admission.OVERFLOW:
                    context = {"github.repository_owner": "manaflow-ai", "github.run_attempt": attempt,
                               "needs.decide.outputs.track": "nightly-next",
                               "needs.decide.outputs.early_attempt": "0", key: overflow,
                               "vars.LINUX_RUNNER": overflow}
                    with self.subTest(job=name, attempt=attempt, overflow=overflow):
                        self.assertEqual(evaluate(parse_expression(source), context),
                                         overflow if name == "build-nightly-inputs" or attempt != 1 else "ubuntu-24.04")

    def test_light_resolvers_keep_hosted_first_only_for_nightly_next(self):
        for name in admission.JOBS - {"build-nightly-inputs"}:
            source = self.jobs[name]["runs-on"].removeprefix("${{").removesuffix("}}")
            key = f"needs.decide.outputs.early_{admission.output_key(name)}_runner"
            for attempt in (1, 2):
                context = {"github.repository_owner": "manaflow-ai", "github.run_attempt": attempt,
                           "needs.decide.outputs.track": "nightly-next",
                           "needs.decide.outputs.early_attempt": "0", key: "",
                           "vars.LINUX_RUNNER": "blacksmith-16vcpu-ubuntu-2404"}
                expected = "ubuntu-24.04" if attempt == 1 else "blacksmith-16vcpu-ubuntu-2404"
                self.assertEqual(evaluate(parse_expression(source), context), expected)

    def test_light_resolvers_on_other_tracks_keep_measured_blacksmith_overflow(self):
        for name in ("resolve-nightly-cmux-tui-client", "resolve-nightly-ghostty-cli-helper"):
            source = self.jobs[name]["runs-on"].removeprefix("${{").removesuffix("}}")
            for track in ("nightly", "rc"):
                with self.subTest(job=name, track=track):
                    context = {"github.repository_owner": "manaflow-ai", "github.run_attempt": 1,
                               "needs.decide.outputs.track": track,
                               "vars.LINUX_RUNNER": ENV["OVERFLOW_LINUX"]}
                    self.assertEqual(evaluate(parse_expression(source), context), "blacksmith-16vcpu-ubuntu-2404")

    def test_each_job_consumes_only_its_current_attempt_receipt(self):
        for name in admission.JOBS:
            source = self.jobs[name]["runs-on"].removeprefix("${{").removesuffix("}}")
            key = f"needs.decide.outputs.early_{admission.output_key(name)}_runner"
            for label in (receipt("fleet")["runners"][name], expected_fallback(name)):
                context = {"github.repository_owner": "manaflow-ai", "github.run_attempt": 2,
                           "needs.decide.outputs.track": "nightly-next",
                           "needs.decide.outputs.early_attempt": "2", key: label}
                with self.subTest(job=name, label=label):
                    self.assertEqual(evaluate(parse_expression(source), context), label)


if __name__ == "__main__":
    unittest.main()
