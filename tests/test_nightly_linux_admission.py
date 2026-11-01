#!/usr/bin/env python3
"""Nightly paid overflow needs a matching, expired fleet admission lease."""
from __future__ import annotations

import datetime as dt
import json
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
from test_nightly_trusted_routing import evaluate, parse_expression

ENV = {"GITHUB_REPOSITORY": "manaflow-ai/cmux", "GITHUB_RUN_ID": "123",
       "GITHUB_RUN_ATTEMPT": "1", "GITHUB_SHA": "a" * 40,
       "JOBS": "control", "SIDE_LABEL": "glaeda-side-std-xcode-26.6",
       "OVERFLOW_LINUX": "blacksmith-16vcpu-ubuntu-2404"}
ENV["JOBS"] = " ".join(sorted(admission.JOBS))
REQUEST = admission.identity(ENV)
LEASE = "b" * 24
CREATED = dt.datetime(2026, 11, 1, tzinfo=dt.timezone.utc)


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


class Receipts(unittest.TestCase):
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
            {"repository": "another/repo"}, {"jobs": ["signer-build"]},
            {"lease_id": "../bad"}, {"no_start_seconds": True},
            {"created_at": "2026-11-01T00:00:00"},
            {"expires_at": (CREATED + dt.timedelta(seconds=179)).isoformat()},
            {"decided_at": (CREATED + dt.timedelta(seconds=179)).isoformat()},
            {"status": "unknown"}, {"runners": {"signer-build": admission.FLEET_LINUX}},
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

    def test_missing_admission_keeps_controls_on_existing_owned_routes(self):
        selected = admission.routes(ENV, REQUEST, None)
        self.assertEqual(selected["signer-build"], admission.FLEET_LINUX)
        for job in admission.JOBS - {"signer-build"}:
            self.assertEqual(selected[job], ENV["SIDE_LABEL"])

    def test_unconfigured_mini_and_reruns_still_default_to_fleet_linux(self):
        for config in ({**ENV, "SIDE_LABEL": ""}, {**ENV, "GITHUB_RUN_ATTEMPT": "3"}):
            self.assertEqual(set(admission.routes(config, admission.identity(config), None).values()),
                             {admission.FLEET_LINUX})

    def test_recorded_overflow_preserves_linux_signer_and_only_uses_declared_paid_set(self):
        selected = admission.routes(ENV, REQUEST, receipt("overflow"))
        self.assertEqual(selected["signer-build"], ENV["OVERFLOW_LINUX"])
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

    def test_unavailable_controller_writes_fleet_outputs_and_no_overflow_receipt(self):
        with tempfile.TemporaryDirectory() as scratch:
            output, record = Path(scratch) / "output", Path(scratch) / "receipt.json"
            config = {**ENV, "GITHUB_OUTPUT": str(output), "ADMISSION_RECEIPT_PATH": str(record)}
            with mock.patch.object(admission, "admit", side_effect=TimeoutError):
                self.assertEqual(admission.main(config), 0)
            self.assertNotIn("blacksmith", output.read_text())
            self.assertIn(f"signer_build_runner={admission.FLEET_LINUX}", output.read_text())
            self.assertIsNone(json.loads(record.read_text())["receipt"])


class Workflow(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.jobs = yaml.safe_load((ROOT / ".github/workflows/nightly.yml").read_text())["jobs"]

    def test_missing_stale_or_quota_failed_picker_cannot_select_blacksmith_first(self):
        for name in admission.JOBS:
            source = self.jobs[name]["runs-on"].removeprefix("${{").removesuffix("}}")
            key = f"needs.decide.outputs.early_{name.replace('-', '_')}_runner"
            for attempt in (1, 2, 3):
                for overflow in admission.OVERFLOW:
                    context = {"github.repository_owner": "manaflow-ai", "github.run_attempt": attempt,
                               "needs.decide.outputs.early_attempt": "0", key: overflow,
                               "vars.LINUX_RUNNER": overflow}
                    with self.subTest(job=name, attempt=attempt, overflow=overflow):
                        self.assertEqual(evaluate(parse_expression(source), context), admission.FLEET_LINUX)

    def test_each_job_consumes_only_its_current_attempt_receipt(self):
        for name in admission.JOBS:
            source = self.jobs[name]["runs-on"].removeprefix("${{").removesuffix("}}")
            key = f"needs.decide.outputs.early_{name.replace('-', '_')}_runner"
            for label in (receipt("fleet")["runners"][name], ENV["OVERFLOW_LINUX"]):
                context = {"github.repository_owner": "manaflow-ai", "github.run_attempt": 2,
                           "needs.decide.outputs.early_attempt": "2", key: label}
                with self.subTest(job=name, label=label):
                    self.assertEqual(evaluate(parse_expression(source), context), label)


if __name__ == "__main__":
    unittest.main()
