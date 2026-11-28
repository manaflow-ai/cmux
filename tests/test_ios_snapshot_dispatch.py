#!/usr/bin/env python3
"""The trusted snapshot dispatcher never searches runs or polls GitHub status."""
import importlib.util
import pathlib
import unittest
from unittest.mock import Mock

ROOT = pathlib.Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("snapshot", ROOT / "scripts/ci/ios_snapshot_dispatch.py")
snapshot = importlib.util.module_from_spec(spec)
spec.loader.exec_module(snapshot)
HEAD, PRODUCER = "a" * 40, "b" * 40


def run(*, controller=False, **changes):
    value = {"id": 42, "head_sha": PRODUCER, "head_branch": "main", "event": "workflow_dispatch",
             "path": snapshot.WORKFLOW, "status": "completed", "conclusion": "success"}
    value.update({"repo": snapshot.REPO, "attempt": 1} if controller else
                 {"repository": {"full_name": snapshot.REPO}, "run_attempt": 1})
    value.update(changes)
    return value


class DispatchTests(unittest.TestCase):
    def test_exact_dispatch_then_one_identity_read_and_condition_wait(self):
        reader = Mock(side_effect=[{"workflow_run_id": 42}, run()])
        waiter = Mock()
        result = snapshot.dispatch(HEAD, "90:2", PRODUCER, "http://fleet", "token", read=reader, waiter=waiter)
        self.assertEqual(result, {"producer_run": "42", "producer_sha": PRODUCER, "request_id": "90:2"})
        self.assertEqual(reader.call_count, 2)
        request = reader.call_args_list[0].kwargs["body"]
        self.assertEqual(request, {"ref": "main", "return_run_details": True, "inputs": {
            "op": "publication-snapshot", "head_sha": HEAD, "request_id": "90:2"}})
        self.assertTrue(reader.call_args_list[1].args[0].endswith("/actions/runs/42"))
        waiter.assert_called_once_with("http://fleet", 42, PRODUCER)

    def test_no_scan_or_retry_when_dispatch_has_no_exact_run(self):
        for response in ({}, {"workflow_run_id": True}, {"workflow_run_id": "42"}):
            reader = Mock(return_value=response)
            with self.subTest(response=response), self.assertRaises(snapshot.NoVerdict):
                snapshot.dispatch(HEAD, "90:2", PRODUCER, "http://fleet", "token", read=reader)
            self.assertEqual(reader.call_count, 1)

    def test_main_movement_or_other_run_identity_is_not_accepted(self):
        for changes in ({"id": 43}, {"head_sha": HEAD}, {"head_branch": "other"}, {"run_attempt": 2},
                        {"path": "other.yml"}, {"event": "pull_request"}, {"repository": {"full_name": "fork/cmux"}}):
            reader = Mock(side_effect=[{"workflow_run_id": 42}, run(**changes)])
            waiter = Mock()
            with self.subTest(changes=changes), self.assertRaises(snapshot.NoVerdict):
                snapshot.dispatch(HEAD, "90:2", PRODUCER, "http://fleet", "token", read=reader, waiter=waiter)
            waiter.assert_not_called()

    def test_no_authority_or_invalid_binding_never_dispatches(self):
        for args in ((HEAD, "90:2", PRODUCER, "http://fleet", ""),
                     (HEAD, "90:2", PRODUCER, "", "token"),
                     (HEAD[:8], "90:2", PRODUCER, "http://fleet", "token"),
                     (HEAD, "90:2\nmalicious", PRODUCER, "http://fleet", "token")):
            reader = Mock()
            with self.subTest(args=args), self.assertRaises(snapshot.NoVerdict):
                snapshot.dispatch(*args, read=reader)
            reader.assert_not_called()


class ConditionTests(unittest.TestCase):
    def test_intermediate_event_then_exact_terminal_success(self):
        reader = Mock(side_effect=[{"known": True, "terminal": False, "run": run(controller=True, status="in_progress")},
                                  {"known": True, "terminal": True, "run": run(controller=True)}])
        snapshot.wait_run("http://fleet", 42, PRODUCER, read=reader, clock=Mock(side_effect=[0, 0, 300]))
        self.assertEqual(reader.call_count, 2)
        for call in reader.call_args_list:
            self.assertEqual(call.args[0], "http://fleet/v1/github/runs/42?wait=300.000&attempt=1")
            self.assertNotIn("token", call.kwargs)

    def test_unknown_until_deadline_is_no_verdict(self):
        reader = Mock(return_value={"known": False, "terminal": False})
        with self.assertRaises(snapshot.NoVerdict):
            snapshot.wait_run("http://fleet", 42, PRODUCER, read=reader, clock=Mock(side_effect=[0, 0, 300, 600]))
        self.assertEqual(reader.call_count, 2)

    def test_fast_nonterminal_endpoint_cannot_spin(self):
        reader = Mock(return_value={"known": False, "terminal": False})
        with self.assertRaises(snapshot.NoVerdict):
            snapshot.wait_run("http://fleet", 42, PRODUCER, read=reader, clock=lambda: 0)
        self.assertEqual(reader.call_count, 3)

    def test_wrong_run_attempt_repository_and_failed_conclusion_stop(self):
        for changes in ({"id": 43}, {"attempt": 2}, {"repo": "fork/cmux"}, {"head_sha": HEAD},
                        {"conclusion": "failure"}, {"status": "queued"}):
            reader = Mock(return_value={"known": True, "terminal": True, "run": run(controller=True, **changes)})
            with self.subTest(changes=changes), self.assertRaises(snapshot.NoVerdict):
                snapshot.wait_run("http://fleet", 42, PRODUCER, read=reader)
            self.assertEqual(reader.call_count, 1)

    def test_auth_refusal_unreachable_or_rate_limit_never_falls_back(self):
        for code in (401, 403, 429, 503):
            error = snapshot.urllib.error.HTTPError("http://fleet", code, "refused", {}, None)
            reader = Mock(side_effect=error)
            with self.subTest(code=code), self.assertRaises(snapshot.urllib.error.HTTPError):
                snapshot.wait_run("http://fleet", 42, PRODUCER, read=reader)
            self.assertEqual(reader.call_count, 1)


if __name__ == "__main__":
    unittest.main()
