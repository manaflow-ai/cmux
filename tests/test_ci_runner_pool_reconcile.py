"""Integration contract: feat reconciler with main's unchanged runner policy.

Set RUNNER_POOL_POLICY_ROOT to the main checkout used by the workflow.
"""
import datetime as dt
import json
import os
import re
from pathlib import Path
import sys
import unittest
import tempfile
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts/ci"))
import runner_pool_reconcile as reconcile

POLICY_ROOT = os.environ.get("RUNNER_POOL_POLICY_ROOT")
NOW = dt.datetime(2026, 11, 1, 12, tzinfo=dt.timezone.utc)
SMALL = "blacksmith-4vcpu-ubuntu-2404"
LARGE = "blacksmith-16vcpu-ubuntu-2404"


class SecretRouteBoundary(unittest.TestCase):
    def test_routing_keys_never_follow_the_secretless_pool(self):
        root = Path(__file__).resolve().parents[1]
        for name, job in (("ci.yml", "changes"), ("cmux-next-ios-kit.yml", "runner")):
            with self.subTest(workflow=name, job=job):
                text = (root / ".github/workflows" / name).read_text()
                block = text.split(f"\n  {job}:\n", 1)[1]
                route = next(line for line in block.splitlines() if line.startswith("    runs-on:"))
                self.assertNotIn("RUNNER_POOLS", route)
                self.assertIn("github.event.pull_request.head.repo.full_name != github.repository", route)
                match = re.search(r"contains\(fromJSON\('([^']+)'\), vars.LINUX_RUNNER\) && vars.LINUX_RUNNER", route)
                self.assertIsNotNone(match)
                self.assertEqual(set(json.loads(match[1])), {SMALL, LARGE, "blacksmith-8vcpu-ubuntu-2404"})
                self.assertTrue(route.endswith("|| 'blacksmith-8vcpu-ubuntu-2404' }}"))


@unittest.skipUnless(POLICY_ROOT, "set RUNNER_POOL_POLICY_ROOT to main's checked-out policy")
class Reconcile(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.policy = reconcile.load_policy(Path(POLICY_ROOT))

    def setUp(self):
        self.pools = self.policy.load_pools()
        self.pools.pop("linux_ephemeral", None)
        self.pools["linux"] = {"why": "Regression fixture: the previous declared pool", "members": [SMALL, LARGE]}
        mocked = patch.object(self.policy, "load_pools", return_value=self.pools)
        mocked.start()
        self.addCleanup(mocked.stop)
        self.value = {name: spec["members"][0] for name, spec in self.pools.items()}
        self.health = {"checked": self.policy.iso(NOW),
                       "labels": {SMALL: "stalled", LARGE: "started"}}

    class Switch:
        def __init__(self, variables):
            self.variables = variables
            self.writes = []

        def get_variable(self, name):
            return self.variables.get(name)

        def set_variable(self, name, value):
            self.variables[name] = value
            self.writes.append((name, value))

    def switch(self):
        return self.Switch({"RUNNER_POOLS": json.dumps(self.value),
                            "CI_CLOUD_LABEL_HEALTH": json.dumps(self.health), "LINUX_RUNNER": SMALL})

    def test_stale_stalled_probe_still_excludes_label(self):
        self.health["checked"] = self.policy.iso(NOW - dt.timedelta(hours=1))
        value, _ = reconcile.plan(self.policy, json.dumps(self.value), self.pools,
                                  self.health, None, now=NOW)
        self.assertEqual(value["linux"], LARGE)
        self.assertIn(SMALL, value["_dead"])

    def test_fresh_start_recovers_previously_stalled_label(self):
        self.value["_dead"] = {SMALL: self.policy.iso(NOW - dt.timedelta(hours=1))}
        self.health["labels"][SMALL] = "started"
        value, _ = reconcile.plan(self.policy, json.dumps(self.value), self.pools,
                                  self.health, None, now=NOW)
        self.assertEqual(value["linux"], SMALL)
        self.assertNotIn(SMALL, value["_dead"])

    def test_all_dead_refuses_publish_without_writes(self):
        self.health["labels"][LARGE] = "stalled"
        switch = self.switch()
        with self.assertRaisesRegex(ValueError, "every declared member is stalled"):
            reconcile.run(self.policy, {}, switch=switch, now=NOW)
        self.assertEqual(switch.writes, [])

    def test_reads_live_pools_and_preserves_new_promotion_pool(self):
        self.value["promotion"] = "blacksmith-2vcpu-ubuntu-2404"
        self.value["_dead"] = {"blacksmith-2vcpu-ubuntu-2404": self.policy.iso(NOW)}
        switch = self.switch()
        reconcile.run(self.policy, {"RUNNER_POOLS": "{}"}, switch=switch, now=NOW)
        updated = json.loads(switch.variables["RUNNER_POOLS"])
        self.assertEqual(updated["promotion"], self.value["promotion"])
        self.assertEqual(updated["_dead"]["blacksmith-2vcpu-ubuntu-2404"], self.policy.iso(NOW))
        self.assertEqual(updated["linux"], LARGE)
        self.assertEqual(switch.variables["LINUX_RUNNER"], LARGE)

    def test_unreadable_live_pools_never_falls_back_to_job_start(self):
        class Unreadable(self.Switch):
            def get_variable(self, name):
                raise RuntimeError("variable read failed")
        switch = Unreadable({})
        with self.assertRaisesRegex(RuntimeError, "variable read failed"):
            reconcile.run(self.policy, {"RUNNER_POOLS": json.dumps(self.value)}, switch=switch, now=NOW)
        self.assertEqual(switch.writes, [])

    def test_check_rejects_same_stalled_label_as_writer(self):
        switch = self.switch()
        self.assertEqual(reconcile.run(self.policy, {}, switch=switch, check=True, now=NOW), 1)
        self.assertEqual(switch.writes, [])
        reconcile.run(self.policy, {}, switch=switch, now=NOW)
        self.assertEqual(reconcile.run(self.policy, {}, switch=switch, check=True, now=NOW), 0)

    def test_future_health_is_not_evidence(self):
        self.health["checked"] = self.policy.iso(NOW + dt.timedelta(hours=1))
        value, _ = reconcile.plan(self.policy, json.dumps(self.value), self.pools,
                                  self.health, None, now=NOW)
        self.assertEqual(value["linux"], SMALL)
        self.assertEqual(value["_dead"], {})

    def test_linux_overflow_record_still_owns_mirror(self):
        switch = self.switch()
        switch.variables["CI_CLOUD_OVERFLOW_SAVED"] = json.dumps({"changed": {"LINUX_RUNNER": {}}})
        reconcile.run(self.policy, {}, switch=switch, now=NOW)
        self.assertFalse(any(name == "LINUX_RUNNER" for name, _ in switch.writes))

    def test_newer_live_writer_wins_without_any_mutation(self):
        class Changed(self.Switch):
            reads = 0

            def get_variable(self, name):
                if name == "RUNNER_POOLS":
                    self.reads += 1
                    if self.reads > 1:
                        return '{"linux":"newer-writer-value"}'
                return super().get_variable(name)
        switch = Changed(self.switch().variables)
        with self.assertRaisesRegex(ValueError, "changed during planning"):
            reconcile.run(self.policy, {}, switch=switch, now=NOW)
        self.assertEqual(switch.writes, [])

    def test_move_receipt_is_compatible_and_not_repeated(self):
        switch = self.switch()
        reconcile.run(self.policy, {}, switch=switch, now=NOW)
        first = json.loads(switch.variables["RUNNER_POOLS"])["_moved"]
        self.assertIn({"variable": "LINUX_RUNNER", "from": SMALL, "to": LARGE,
                       "at": self.policy.iso(NOW)}, first)
        reconcile.run(self.policy, {}, switch=switch, now=NOW + dt.timedelta(minutes=1))
        self.assertEqual(json.loads(switch.variables["RUNNER_POOLS"])["_moved"], first)

    def test_move_receipts_expire_and_stay_bounded(self):
        self.value["_moved"] = [
            {"variable": "LINUX_RUNNER", "from": f"old-{i}", "to": SMALL,
             "at": self.policy.iso(NOW - dt.timedelta(hours=7 if i == 0 else 1))}
            for i in range(30)]
        switch = self.switch()
        reconcile.run(self.policy, {}, switch=switch, now=NOW)
        moved = json.loads(switch.variables["RUNNER_POOLS"])["_moved"]
        self.assertEqual(len(moved), 16)
        self.assertNotIn("old-0", {entry["from"] for entry in moved})


@unittest.skipUnless(POLICY_ROOT, "set RUNNER_POOL_POLICY_ROOT to main's checked-out policy")
class FleetReconcile(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.policy = reconcile.load_policy(Path(POLICY_ROOT))

    def setUp(self):
        self.fleet = reconcile.FLEET_LINUX
        self.eight = "blacksmith-8vcpu-ubuntu-2404"
        self.pools = self.policy.load_pools()
        self.pools["linux_ephemeral"] = {"why": "Legacy secret-bearing routes", "members": [self.eight, LARGE, SMALL]}
        self.pools["linux"] = {"why": "Audited secretless routes", "members": [self.fleet, self.eight, LARGE, SMALL]}
        mocked = patch.object(self.policy, "load_pools", return_value=self.pools)
        mocked.start()
        self.addCleanup(mocked.stop)
        self.value = {name: spec["members"][0] for name, spec in self.pools.items()}
        self.value["linux"] = SMALL
        self.health = {"checked": self.policy.iso(NOW), "minutes": 3,
                       "labels": {self.fleet: "started", self.eight: "started", SMALL: "stalled", LARGE: "stalled"}}

    def switch(self):
        return Reconcile.Switch({"RUNNER_POOLS": json.dumps(self.value), "LINUX_RUNNER": SMALL,
                                 "CI_CLOUD_LABEL_HEALTH": json.dumps(self.health)})

    def test_actual_fleet_start_routes_pool_but_keeps_legacy_ephemeral(self):
        switch = self.switch()
        self.assertEqual(reconcile.run(self.policy, {}, switch=switch, now=NOW), 0)
        self.assertEqual(json.loads(switch.variables["RUNNER_POOLS"])["linux"], self.fleet)
        self.assertEqual(switch.variables["LINUX_RUNNER"], self.eight)

    def test_recorded_three_minute_fleet_no_start_uses_started_eight(self):
        self.health["labels"][self.fleet] = "stalled"
        switch = self.switch()
        reconcile.run(self.policy, {}, switch=switch, now=NOW)
        self.assertEqual(json.loads(switch.variables["RUNNER_POOLS"])["linux"], self.eight)
        self.health["minutes"] = 2
        with self.assertRaisesRegex(ValueError, "three-minute"):
            reconcile.run(self.policy, {}, switch=self.switch(), now=NOW)

    def test_unknown_or_503_is_not_a_fleet_start_or_overflow_receipt(self):
        self.health = {}
        with self.assertRaisesRegex(ValueError, "no fleet start"):
            reconcile.run(self.policy, {}, switch=self.switch(), now=NOW)

    def test_all_stalled_publishes_no_route(self):
        self.health["labels"] = {label: "stalled" for label in self.health["labels"]}
        switch = self.switch()
        with self.assertRaisesRegex(ValueError, "every declared member is stalled"):
            reconcile.run(self.policy, {}, switch=switch, now=NOW)
        self.assertEqual(switch.writes, [])

    def test_blacksmith_outage_does_not_block_started_fleet(self):
        self.health["labels"][self.eight] = "stalled"
        switch = self.switch()
        self.assertEqual(reconcile.run(self.policy, {}, switch=switch, now=NOW), 1)
        value = json.loads(switch.variables["RUNNER_POOLS"])
        self.assertEqual(value["linux"], self.fleet)
        self.assertIsNone(value["linux_ephemeral"])
        self.assertFalse(any(name == "LINUX_RUNNER" for name, _ in switch.writes))

    def test_existing_fleet_legacy_mirror_recovers_to_ephemeral(self):
        switch = self.switch()
        switch.variables["LINUX_RUNNER"] = self.fleet
        reconcile.run(self.policy, {}, switch=switch, now=NOW)
        self.assertEqual(switch.variables["LINUX_RUNNER"], self.eight)

    def test_only_audited_linux_pool_can_declare_fleet(self):
        self.assertEqual(reconcile.spec_problems(self.policy, self.pools), [])
        self.pools["linux_ephemeral"]["members"].insert(0, self.fleet)
        self.assertTrue(reconcile.spec_problems(self.policy, self.pools))

    def test_fleet_start_never_counts_as_blacksmith_recovery(self):
        import cloud_overflow_switch as cloud
        writes = []

        class Client:
            def __init__(self, token, repo):
                pass

            def set_variable(self, name, value):
                writes.append((name, json.loads(value)))

        def switch_main(argv, env):
            self.assertNotIn(self.fleet, cloud.PROBE_LABELS)
            self.assertEqual(tuple(self.pools["linux_ephemeral"]["members"]), cloud.PROBE_LABELS)
            self.assertEqual(env["PROBE_MINUTES"], "3")
            return 0

        with tempfile.TemporaryDirectory() as tmp, patch.object(cloud, "main", switch_main), \
                patch.object(cloud, "GitHub", Client), \
                patch.object(cloud, "wait_for_probe", return_value=("partial", [self.fleet])):
            output = Path(tmp) / "outputs"
            env = {"GH_TOKEN": "job-token", "SWITCH_TOKEN": "switch-token", "GH_REPO": "x/y",
                   "GITHUB_RUN_ID": "1", "GITHUB_OUTPUT": str(output)}
            self.assertEqual(reconcile.probe(self.policy, env), 0)
            self.assertEqual(writes[0][1]["labels"][self.fleet], "stalled")
            self.assertEqual(writes[0][1]["labels"][self.eight], "started")
            self.assertEqual(writes[0][1]["minutes"], 3)
            self.assertIn("outcome=partial", output.read_text())


if __name__ == "__main__":
    unittest.main()
