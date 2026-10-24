import json
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from integrations import DryRunTransport, IntegrationEvent, IntegrationRouter  # noqa: E402


class IntegrationTests(unittest.TestCase):
    def test_event_ids_are_stable_and_credentials_are_redacted(self):
        value = {"token": "do-not-copy", "commit": "abc123", "nested": {"api_key": "also-private"}}
        first = IntegrationEvent("preview.ready", "cmux-next", "pv_1", value, occurred_at=1700000000)
        second = IntegrationEvent("preview.ready", "cmux-next", "pv_1", value, occurred_at=1700000000)
        self.assertEqual(first.event_id, second.event_id)
        self.assertEqual(first.payload["token"], "[redacted]")
        self.assertEqual(first.payload["nested"]["api_key"], "[redacted]")
        self.assertNotIn("do-not-copy", json.dumps(first.as_json()))

    def test_preview_fans_out_to_github_linear_slack_and_preview(self):
        event = IntegrationEvent("preview.ready", "acpmux", "feature/demo", {"preview_id": "pv_1", "url": "https://pv.example", "branch_alias": "demo.example", "agent_alias": "agent-1.example", "commit": "abc123"}, occurred_at=1700000000)
        transport = DryRunTransport()
        requests = IntegrationRouter(transport).dispatch(event)
        self.assertEqual([request.target for request in requests], ["github", "linear", "slack", "preview"])
        self.assertEqual(len(transport.requests), 4)
        self.assertTrue(all(request.headers == {} for request in requests))
        self.assertEqual(next(r for r in requests if r.target == "preview").body["deployment_id"], "pv_1")

    def test_machine_lifecycle_maps_to_cloud_receipt(self):
        event = IntegrationEvent("machine.suspended", "cmux-next", "machine-1", {"machine_id": "machine-1", "provider": "gcp", "generation": 4, "receipt": "receipt-4", "expires_at": "2030-01-01T00:00:00Z"}, occurred_at=1700000000)
        requests = IntegrationRouter(DryRunTransport()).dispatch(event)
        self.assertEqual({request.target for request in requests}, {"cloud", "slack"})
        cloud = next(request for request in requests if request.target == "cloud")
        self.assertEqual(cloud.body["operation"], "suspended")
        self.assertEqual(cloud.body["provider"], "gcp")

    def test_unknown_event_is_a_noop(self):
        self.assertEqual(IntegrationRouter(DryRunTransport()).dispatch(IntegrationEvent("terminal.output", "acpmux", "session-1", {})), [])


if __name__ == "__main__":
    unittest.main()
