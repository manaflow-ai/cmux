#!/usr/bin/env python3
"""Only the controller App's exact terminal lease can route a nightly job."""
import copy
import io
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
import nightly_admission_receipt as reader
import nightly_linux_admission as admission
from test_nightly_trusted_routing import evaluate, parse_expression

ENV = {"GITHUB_REPOSITORY": "manaflow-ai/cmux", "GITHUB_RUN_ID": "41276832605",
       "GITHUB_RUN_ATTEMPT": "1", "GITHUB_SHA": "cfb07455959e2391c0001bcee71d02102ea43317",
       "JOBS": " ".join(sorted(admission.JOBS)), "CHECK_RECEIPTS": "1",
       "SNAPSHOT_TOKEN": "test-token", "OVERFLOW_LINUX": "blacksmith-16vcpu-ubuntu-2404"}
REQUEST = admission.identity(ENV)


def check(state="fleet"):
    lease = reader.lease_id(REQUEST)
    projection = {**REQUEST, "schema": 1, "lease_id": lease, "state": state,
                  "created_at": "2026-01-01T00:00:00.000000999Z",
                  "expires_at": "2026-01-01T00:03:00.000000999Z",
                  "decided_at": "2026-01-01T00:00:15.000000999Z"}
    if state == "fleet":
        projection["runner_keys"] = {job: f"cmux-nightly-{lease}-{job}" for job in REQUEST["jobs"]}
    else:
        projection.update(decided_at="2026-01-01T00:03:00.000000999Z", no_start_seconds=180)
    return {"id": 42, "app": {"id": reader.APP_ID}, "name": reader.CHECK_NAME,
            "head_sha": REQUEST["source_sha"], "external_id": lease, "status": "completed",
            "conclusion": "success" if state == "fleet" else "failure",
            "output": {"summary": json.dumps(projection)}}


def payload(*checks):
    return {"total_count": len(checks), "check_runs": list(checks)}


def projected(value, **changes):
    result = copy.deepcopy(value)
    summary = json.loads(result["output"]["summary"])
    summary.update(changes)
    result["output"]["summary"] = json.dumps(summary)
    return result


class PublishedReceipts(unittest.TestCase):
    def test_strict_routes_reject_missing_or_pending_admission(self):
        pending = {**reader.select(payload(check()), REQUEST), "status": "pending"}
        for value in (None, pending):
            with self.subTest(receipt=value), self.assertRaises(ValueError):
                admission.routes(ENV, REQUEST, value)

    def test_canonical_lease_matches_observed_controller_identity(self):
        self.assertEqual(reader.lease_id(REQUEST), "005e548441f6398c50ebf476")

    def test_authenticated_fleet_and_overflow_receipts(self):
        for state in ("fleet", "overflow"):
            receipt = reader.select(payload(check(state)), REQUEST)
            self.assertEqual(receipt["status"], state)
            self.assertEqual(receipt["publisher_app_id"], reader.APP_ID)
            self.assertEqual(receipt["check_run_id"], 42)
            routes = admission.routes(ENV, REQUEST, receipt)
            if state == "fleet":
                self.assertEqual(routes, receipt["runners"])
            else:
                self.assertEqual(set(routes.values()), {ENV["OVERFLOW_LINUX"]})

    def test_foreign_app_head_context_and_nonterminal_check_are_rejected(self):
        for field, value in (("app", {"id": 1}), ("app", {"id": str(reader.APP_ID)}),
                             ("head_sha", "a" * 40), ("name", "other-check"),
                             ("external_id", "a" * 24), ("status", "in_progress"),
                             ("conclusion", "neutral"), ("conclusion", "failure"), ("id", True)):
            with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                reader.validate_check({**check(), field: value}, REQUEST)

    def test_projection_cannot_change_run_attempt_source_or_jobs(self):
        for changes in ({"run_id": 123}, {"run_attempt": 2}, {"source_sha": "a" * 40},
                        {"repository": "another/repo"}, {"jobs": list(reversed(REQUEST["jobs"]))},
                        {"lease_id": "b" * 24}, {"schema": True}, {"schema": 2},
                        {"state": "pending"}, {"runner_keys": {"x": "unregistered"}},
                        {"private_host": "unexpected"}):
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                reader.select(payload(projected(check(), **changes)), REQUEST)

    def test_missing_duplicate_and_truncated_publications_fail_closed(self):
        for value in (payload(), payload(check(), check()), {"total_count": 101, "check_runs": [check()]},
                      {"total_count": True, "check_runs": [check()]}, payload(None), []):
            with self.subTest(value=value), self.assertRaises(ValueError):
                reader.select(value, REQUEST)

    def test_nanosecond_clock_requires_full_window_without_rounding(self):
        # Truncating the creation timestamp to Python microseconds would turn
        # 180.999999001 into 181 and reject this valid controller integer proof.
        value = projected(check("overflow"), decided_at="2026-01-01T00:03:01Z", no_start_seconds=180)
        self.assertEqual(reader.select(payload(value), REQUEST)["status"], "overflow")
        for changes in ({"decided_at": "2026-01-01T00:03:00.000000998Z"},
                        {"no_start_seconds": 179}, {"no_start_seconds": True},
                        {"no_start_seconds": 180.0}, {"no_start_seconds": 181},
                        {"created_at": "2099-01-01T00:00:00Z", "expires_at": "2099-01-01T00:03:00Z"},
                        {"expires_at": "2026-01-01T00:03:00Z"}):
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                reader.select(payload(projected(check("overflow"), **changes)), REQUEST)

    def test_malformed_and_duplicate_summary_keys_are_rejected(self):
        for summary in ("[]", "{", '{"schema":1,"schema":1}', "x" * 16385, None):
            with self.subTest(summary=str(summary)[:30]), self.assertRaises(ValueError):
                reader.validate_check({**check(), "output": {"summary": summary}}, REQUEST)

    def test_missing_receipt_gets_only_one_delayed_retry(self):
        with mock.patch.object(reader, "get", side_effect=[payload(), payload(check())]) as get, \
             mock.patch.object(reader.time, "monotonic", side_effect=[0, 5]), \
             mock.patch.object(reader.time, "sleep") as sleep:
            self.assertEqual(reader.read(REQUEST, "token")["status"], "fleet")
        self.assertEqual(get.call_count, 2)
        sleep.assert_called_once_with(reader.PUBLICATION_WAIT_SECONDS - 5)

    def test_invalid_receipt_never_retries_or_turns_into_overflow(self):
        with mock.patch.object(reader, "get", return_value=payload({**check(), "app": {"id": 9}})) as get, \
             mock.patch.object(reader.time, "sleep") as sleep, self.assertRaises(ValueError):
            reader.read(REQUEST, "token")
        self.assertEqual(get.call_count, 1)
        sleep.assert_not_called()

    def test_missing_publication_after_bounded_retry_is_not_a_no_start_receipt(self):
        with mock.patch.object(reader, "get", return_value=payload()) as get, \
             mock.patch.object(reader.time, "sleep") as sleep, self.assertRaises(reader.MissingReceipt):
            reader.read(REQUEST, "token")
        self.assertEqual(get.call_count, 2)
        self.assertEqual(sleep.call_count, 1)

    def test_get_is_authenticated_bounded_and_cannot_follow_redirects(self):
        opener = mock.Mock()
        opener.open.return_value = io.BytesIO(json.dumps(payload(check())).encode())
        with mock.patch.object(reader.urllib.request, "build_opener", return_value=opener):
            reader.get(REQUEST, "token")
        call = opener.open.call_args.args[0]
        self.assertEqual(call.headers["Authorization"], "Bearer token")
        self.assertTrue(call.full_url.startswith("https://api.github.com/repos/manaflow-ai/cmux/commits/"))
        self.assertIn("filter=all", call.full_url)
        self.assertEqual(opener.open.call_args.kwargs["timeout"], 15)
        with self.assertRaises(ValueError):
            reader.NoRedirect().redirect_request(None, None, 302, "", {}, "https://elsewhere.invalid")
        with self.assertRaises(ValueError):
            reader.get(REQUEST, "")

    def test_unpublished_admission_emits_no_runner_and_fails_the_step(self):
        with tempfile.TemporaryDirectory() as directory:
            output, record = Path(directory) / "out", Path(directory) / "receipt"
            env = {**ENV, "GITHUB_OUTPUT": str(output), "ADMISSION_RECEIPT_PATH": str(record)}
            with mock.patch.object(reader, "read", side_effect=reader.MissingReceipt), \
                 mock.patch.object(admission, "read_minis") as minis:
                self.assertEqual(admission.main(env), 1)
            minis.assert_not_called()
            self.assertEqual(output.read_text(), "admission_ready=false\n")
            self.assertEqual(json.loads(record.read_text())["runners"], {})

    def test_verified_overflow_survives_failed_optional_mini_read(self):
        receipt = reader.select(payload(check("overflow")), REQUEST)
        with mock.patch.object(reader, "read", return_value=receipt), \
             mock.patch.object(admission, "read_minis", side_effect=TimeoutError), \
             mock.patch.object(admission, "write") as write:
            self.assertEqual(admission.main(ENV), 0)
        self.assertEqual(set(write.call_args.args[1].values()), {ENV["OVERFLOW_LINUX"]})


class Workflow(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workflow = yaml.safe_load((ROOT / ".github/workflows/nightly.yml").read_text())

    def context(self, **changes):
        context = {"github.repository": "manaflow-ai/cmux", "github.ref": "refs/heads/nightly-next",
                   "github.event_name": "push", "github.run_attempt": 1, "github.run_id": 123,
                   "github.sha": "a" * 40, "github.workflow": "Nightly macOS build",
                   "vars.CI_NIGHTLY_ADMISSION_CHECKS": "1", "inputs.nightly_next_unsigned_run": "",
                   "needs.decide.outputs.track": "nightly-next", "needs.decide.outputs.should_build": "true",
                   "needs.decide.outputs.should_publish": "true", "needs.decide.outputs.early_attempt": "1",
                   "needs.decide.outputs.early_admission_ready": "true"}
        context.update(changes)
        return context

    def evaluate(self, source, context):
        return evaluate(parse_expression(source.removeprefix("${{").removesuffix("}}")), context)

    def test_marker_binds_run_and_source_and_survives_dedicated_reruns(self):
        for attempt in (1, 2):
            values = self.context(**{"github.run_attempt": attempt,
                                     "vars.CI_NIGHTLY_ONLY_RUNNER": "glaeda-nightly-only-m4pro"})
            title = self.evaluate(self.workflow["run-name"], values)
            self.assertTrue(title.startswith("NEXT Linux admission v1: 123/" + "a" * 40 + " | "))
        for changes in ({"vars.CI_NIGHTLY_ADMISSION_CHECKS": ""}, {"github.ref": "refs/heads/main"},
                        {"github.repository": "another/repo"}, {"github.event_name": "pull_request"}):
            self.assertNotIn("NEXT Linux admission", self.evaluate(self.workflow["run-name"], self.context(**changes)))
            step = next(step for step in self.workflow["jobs"]["decide"]["steps"] if step.get("id") == "place-early")
            self.assertEqual(self.evaluate(step["env"]["CHECK_RECEIPTS"], self.context(**changes)), "")
            self.assertTrue(self.evaluate(step["continue-on-error"], self.context(**changes)))

    def test_unsigned_resume_title_and_mode_stay_compatible_with_main_parser(self):
        values = self.context(**{"inputs.nightly_next_unsigned_run": "456", "inputs.nightly_next_unsigned_attempt": "2"})
        self.assertEqual(self.evaluate(self.workflow["run-name"], values), "Resume nightly-next run 456 attempt 2")
        step = next(step for step in self.workflow["jobs"]["decide"]["steps"] if step.get("id") == "place-early")
        self.assertEqual(self.evaluate(step["env"]["CHECK_RECEIPTS"], values), "")
        self.assertTrue(self.evaluate(step["continue-on-error"], values))

    def test_receipt_mode_is_fatal_and_reads_only_existing_app_checks(self):
        job = self.workflow["jobs"]["decide"]
        self.assertEqual(job["permissions"], {"actions": "read", "checks": "read", "contents": "read"})
        step = next(step for step in job["steps"] if step.get("id") == "place-early")
        self.assertEqual(self.evaluate(step["env"]["CHECK_RECEIPTS"], self.context()), "1")
        self.assertFalse(self.evaluate(step["continue-on-error"], self.context()))
        self.assertEqual(step["env"]["SNAPSHOT_TOKEN"], "${{ github.token }}")
        sparse = next(step for step in job["steps"] if step.get("name") == "Check out NEXT decision and placement helpers")
        self.assertIn("/scripts/ci/nightly_admission_receipt.py", sparse["with"]["sparse-checkout"])

    def test_missing_or_stale_receipts_cannot_schedule_any_of_the_four_jobs(self):
        for name in admission.JOBS:
            condition = self.workflow["jobs"][name]["if"]
            self.assertTrue(self.evaluate(condition, self.context()), name)
            for changes in ({"needs.decide.outputs.early_admission_ready": ""},
                            {"needs.decide.outputs.early_admission_ready": "false"},
                            {"needs.decide.outputs.early_attempt": "0"},
                            {"github.run_attempt": 2}):
                with self.subTest(job=name, changes=changes):
                    self.assertFalse(self.evaluate(condition, self.context(**changes)))
            self.assertTrue(self.evaluate(condition, self.context(**{
                "vars.CI_NIGHTLY_ADMISSION_CHECKS": "", "needs.decide.outputs.early_admission_ready": ""})))
            self.assertTrue(self.evaluate(condition, self.context(**{
                "vars.CI_NIGHTLY_ONLY_RUNNER": "glaeda-nightly-only-m4pro",
                "needs.decide.outputs.early_admission_ready": ""})))


if __name__ == "__main__":
    unittest.main()
