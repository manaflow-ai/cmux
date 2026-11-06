"""auto_triage --event: the issues event already carries the issue, so the run spends no GET of it.

Every workflow's GITHUB_TOKEN shares one hourly REST budget; the issue read on every
issues event spent about 60 calls an hour of it. No network: request() is faked.
"""

import importlib.util
import json
import pathlib
import shutil
import sys
import tempfile
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/auto-triage.yml"
sys.path.insert(0, str(ROOT / "scripts/ci"))
SPEC = importlib.util.spec_from_file_location("auto_triage", ROOT / "scripts/ci/auto_triage.py")
AUTO = importlib.util.module_from_spec(SPEC)
sys.modules["auto_triage"] = AUTO
SPEC.loader.exec_module(AUTO)

class EventPayloadTests(unittest.TestCase):
    """The issues event already carries the issue: no GET of it on the shared token budget."""

    def setUp(self):
        self.dir = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.dir, True)
        self.calls = []

    def fake_request(self, method, url, token, payload=None):
        self.calls.append((method, url))
        if method == "GET":
            return {"number": 7, "state": "open", "title": "Crash when closing the last split",
                    "body": "", "labels": []}
        return {}

    def run_main(self, event):
        path = self.dir / "event.json"
        path.write_text(json.dumps(event))
        with mock.patch.object(AUTO, "request", self.fake_request), \
                mock.patch.dict("os.environ", {"GH_TOKEN": "t"}):
            return AUTO.main(["--repo", "o/r", "--issue", "7", "--event", str(path)])

    def test_the_payload_issue_is_used_without_a_read(self):
        event = {"issue": {"number": 7, "state": "open", "title": "Crash when closing the last split",
                           "body": "", "labels": []}}
        self.assertEqual(self.run_main(event), 0)
        self.assertEqual([method for method, _ in self.calls], ["POST", "POST"])
        self.assertTrue(self.calls[0][1].endswith("/issues/7/labels"))

    def test_an_already_triaged_payload_issue_makes_no_call(self):
        event = {"issue": {"number": 7, "state": "open", "title": "Crash", "body": "",
                           "labels": [{"name": "S2: major"}]}}
        self.assertEqual(self.run_main(event), 0)
        self.assertEqual(self.calls, [])

    def test_a_pull_request_or_closed_payload_is_left_alone(self):
        for issue in ({"number": 7, "state": "open", "pull_request": {}, "labels": []},
                      {"number": 7, "state": "closed", "labels": []}):
            with self.subTest(issue=issue):
                self.calls.clear()
                self.assertEqual(self.run_main({"issue": issue}), 0)
                self.assertEqual(self.calls, [])

    def test_another_issue_or_an_unreadable_event_falls_back_to_the_read(self):
        for event in ({"issue": {"number": 8, "state": "open", "labels": []}}, {}, "not json"):
            with self.subTest(event=event):
                self.calls.clear()
                path = self.dir / "event.json"
                path.write_text(event if isinstance(event, str) else json.dumps(event))
                with mock.patch.object(AUTO, "request", self.fake_request), \
                        mock.patch.dict("os.environ", {"GH_TOKEN": "t"}):
                    self.assertEqual(AUTO.main(["--repo", "o/r", "--issue", "7", "--event", str(path)]), 0)
                self.assertEqual(self.calls[0], ("GET", f"{AUTO.API}/repos/o/r/issues/7"))

    def test_the_workflow_passes_the_event(self):
        text = WORKFLOW.read_text()
        self.assertIn('--issue "$ISSUE_NUMBER" --event "$GITHUB_EVENT_PATH"', text)


if __name__ == "__main__":
    unittest.main()
