import json
from datetime import datetime, timezone
from decimal import Decimal
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from machine_runtime import FakeProvider, MachineManager, MachineSpec, gcloud_command  # noqa: E402


T0 = datetime(2026, 10, 24, tzinfo=timezone.utc)


class MachineRuntimeTests(unittest.TestCase):
    def setUp(self):
        self.provider = FakeProvider()
        self.manager = MachineManager(self.provider)
        self.spec = MachineSpec(ttl_hours=4, idle_minutes=15, owner="research-owner", purpose="machine-demo")

    def test_allocate_is_idempotent_and_receipt_has_attach_urls(self):
        first = self.manager.allocate(self.spec, T0, "m-1")
        second = self.manager.allocate(self.spec, T0, "m-1")
        self.assertIs(first, second)
        receipt = first.receipt()
        self.assertEqual(receipt["state"], "running")
        self.assertEqual(receipt["attach"]["acpmux"], "acpmux://machine/m-1")
        self.assertEqual(len([c for c in self.provider.calls if c[0] == "allocate"]), 1)

    def test_attach_detach_idle_stop_and_meter(self):
        machine = self.manager.allocate(self.spec, T0, "m-2")
        self.manager.attach("m-2", "session-1", T0)
        self.assertEqual(machine.state, "attached")
        self.assertEqual(self.manager.stop_idle(T0.replace(minute=20)), [])
        self.manager.detach("m-2", "session-1", T0.replace(minute=20))
        stopped = self.manager.stop_idle(T0.replace(minute=36))
        self.assertEqual(stopped[0]["state"], "stopped")
        self.assertEqual(stopped[0]["billing"]["running_seconds"], 2160)
        self.assertEqual(self.provider.calls[-1][0], "stop")
        self.assertGreater(Decimal(stopped[0]["billing"]["total"]), 0)

    def test_stopped_machine_can_attach_again_without_double_allocation(self):
        self.manager.allocate(self.spec, T0, "m-3")
        self.manager.stop_idle(T0.replace(minute=16))
        receipt = self.manager.attach("m-3", "session-2", T0.replace(minute=17))
        self.assertEqual(receipt["state"], "attached")
        self.assertEqual(len([c for c in self.provider.calls if c[0] == "allocate"]), 1)

    def test_gcp_command_contains_ttl_idle_and_owner_labels(self):
        machine = self.manager.allocate(self.spec, T0, "m-4")
        command = " ".join(gcloud_command(machine))
        self.assertIn("--project=example-project", command)
        self.assertIn("owner=research-owner", command)
        self.assertIn("purpose=machine-demo", command)
        self.assertIn("idle-autostop=true", command)
        self.assertIn("ttl=", command)
        self.assertNotIn("TOKEN", json.dumps(machine.receipt()))


if __name__ == "__main__":
    unittest.main()
