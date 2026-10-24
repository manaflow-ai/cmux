import importlib.util
import pathlib
import sys
import unittest


_PATH = pathlib.Path(__file__).parents[1] / "scripts" / "agent_scale_sim.py"
_SPEC = importlib.util.spec_from_file_location("agent_scale_sim", _PATH)
_MOD = importlib.util.module_from_spec(_SPEC)
assert _SPEC.loader
sys.modules[_SPEC.name] = _MOD
_SPEC.loader.exec_module(_MOD)


class AgentScaleSimulationTests(unittest.TestCase):
    def setUp(self):
        self.shape = _MOD.Shape(2, 4)
        self.image = "sha256:test"
        self.gcp = _MOD.Offer("gcp", "us-central1", "gcp-a", self.shape, self.image, 0.20, 10)
        self.spot = _MOD.Offer("aws", "us-east-1", "aws-spot", self.shape, self.image, 0.05, 5, True, 0.2)
        self.scheduler = _MOD.Scheduler(
            [self.gcp, self.spot],
            {"team": _MOD.Quota(max_active=2, max_cpu=4, max_memory_gb=8, spend_usd=2)},
            global_quota=_MOD.Quota(max_active=2, spend_usd=2),
            lease_ttl_s=10,
        )

    def request(self, run_id, **kwargs):
        return _MOD.RunRequest(run_id, "team", self.image, self.shape, max_lifetime_s=300, **kwargs)

    def test_warm_slot_is_claimed_before_cold_offer(self):
        self.scheduler.add_warm_slot(self.gcp)
        self.scheduler.submit(self.request("warm"), 0)
        self.scheduler.reconcile(0)
        run = self.scheduler.runs["warm"]
        self.assertEqual(run.state, "running")
        self.assertEqual(run.ready_at, 0)
        self.assertTrue(any(event.kind == "run.claimed.warm" for event in self.scheduler.events))

    def test_spot_interrupt_requeues_checkpointable_run_and_fences_old_token(self):
        self.scheduler.submit(self.request("spot"), 0)
        self.scheduler.reconcile(0)
        self.scheduler.reconcile(5)
        run = self.scheduler.runs["spot"]
        self.assertEqual(run.lease.provider, "aws")
        old_token = run.lease.token
        self.scheduler.interrupt("spot", 6)
        self.assertEqual(run.state, "queued")
        self.assertFalse(self.scheduler.heartbeat("spot", old_token, 26))
        self.scheduler.reconcile(6)
        self.assertEqual(run.state, "provisioning")
        self.assertEqual(run.retry_count, 1)
        self.assertFalse(run.lease.preemptible)

    def test_quota_holds_then_dispatches_after_release(self):
        for run_id in ("a", "b", "c"):
            self.scheduler.submit(self.request(run_id), 0)
        self.scheduler.reconcile(0)
        self.assertEqual(self.scheduler.runs["c"].state, "queued")
        self.scheduler.reconcile(10)
        self.scheduler.finish("a", 11)
        self.scheduler.reconcile(11)
        self.assertIn(self.scheduler.runs["c"].state, {"provisioning", "running"})

    def test_fork_uses_snapshot_digest_and_idempotency(self):
        self.scheduler.add_warm_slot(self.gcp)
        parent = self.scheduler.submit(self.request("parent", idempotency_key="same"), 0)
        self.assertIs(parent, self.scheduler.submit(self.request("ignored", idempotency_key="same"), 0))
        self.scheduler.reconcile(0)
        snap = self.scheduler.snapshot("parent", 1, "abcdef1234567890")
        child = self.scheduler.fork("parent", "child", snap, 1)
        self.assertEqual(child.request.image_digest, snap)
        self.assertEqual(child.state, "queued")

    def test_cost_is_from_lease_segments(self):
        self.scheduler.add_warm_slot(self.gcp)
        self.scheduler.submit(self.request("cost"), 0)
        self.scheduler.reconcile(0)
        self.scheduler.finish("cost", 1800)
        self.assertAlmostEqual(self.scheduler.cost_usd(1800), 0.1)

    def test_budget_exhaustion_is_terminal_and_global_shape_quota_holds(self):
        budgeted = self.request("budget", budget_usd=0.0001)
        self.scheduler.submit(budgeted, 0)
        self.scheduler.reconcile(0)
        self.scheduler.heartbeat("budget", self.scheduler.runs["budget"].lease.token, 14)
        self.scheduler.reconcile(20)
        self.assertEqual(self.scheduler.runs["budget"].state, "failed")
        limited = _MOD.Scheduler([self.gcp], global_quota=_MOD.Quota(max_active=1, max_cpu=2, max_memory_gb=4, spend_usd=2))
        limited.submit(self.request("one"), 0)
        limited.submit(self.request("two"), 0)
        limited.reconcile(0)
        self.assertEqual(limited.runs["two"].state, "queued")


if __name__ == "__main__":
    unittest.main()
