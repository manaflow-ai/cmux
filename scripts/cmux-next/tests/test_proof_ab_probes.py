"""SCRATCH MEASUREMENT REF ONLY: the proof-ab "mechanism ran" rule, min and max (at most) probes.
Run: python3 -I scripts/cmux-next/tests/test_proof_ab_probes.py"""
import importlib.util, json, os, sys, tempfile, unittest

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
spec = importlib.util.spec_from_file_location("proof_ab", os.path.join(HERE, "proof-ab.py"))
pab = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pab)


def run_with(probe, reply, arm="on"):
    """One run_one probe evaluation over a fake features file holding `reply` for the probe's method."""
    tmp = tempfile.mkdtemp()
    opts = type("O", (), {})()
    opts.out, opts.tag, opts.app, opts.inner, opts.toggle, opts.run_timeout = tmp, "t", "/nonexistent.app", "x", "s", 1
    opts.probes_parsed, opts.validity_parsed, opts.keep_raw = [pab.parse_probe(probe)], [], 0
    method = probe["method"] if isinstance(probe, dict) else probe.split("|")[1]
    run_dir = os.path.join(tmp, "proof-ab", f"00-{arm}")
    os.makedirs(run_dir)
    with open(os.path.join(run_dir, "features.jsonl"), "w") as f:
        f.write(json.dumps({"where": "t", "features": {"s": {"state": arm}}}) + "\n")
        f.write(json.dumps({"where": "t", "probes": {method: reply}}) + "\n")
    with open(os.path.join(run_dir, "run.json"), "w") as f:
        f.write("{}")
    real_call = pab.subprocess.call
    pab.subprocess.call = lambda *a, **k: 0  # no bench and no teardown in the test
    try:
        row, _ = pab.run_one(opts, [], arm, 0)
    finally:
        pab.subprocess.call = real_call
    return row


class ProbeRule(unittest.TestCase):
    def test_min_probe_needs_a_value_at_or_over_min(self):
        p = "n|debug.x|{}|^a$|1"
        self.assertTrue(run_with(p, {"a": 3})["scenario_ran"])
        self.assertFalse(run_with(p, {"a": 0})["scenario_ran"])
        self.assertTrue(run_with(p, {"a": 0})["invalid_scenario"])

    def test_min_regex_may_hold_a_bar(self):
        p = "n|debug.x|{}|^(a|b)$|1"
        self.assertTrue(run_with(p, {"b": 2})["scenario_ran"])

    def test_max_probe_ran_when_every_value_is_at_most_max(self):
        p = {"name": "spares", "method": "debug.webui", "regex": r"^spares\.\*\.renderer_count$", "max": 0}
        self.assertTrue(run_with(p, {"spares": [{"renderer_count": 0}, {"renderer_count": 0}]})["scenario_ran"])
        self.assertFalse(run_with(p, {"spares": [{"renderer_count": 0}, {"renderer_count": 2}]})["scenario_ran"])

    def test_max_probe_with_no_value_is_not_ran_unless_absent_counts(self):
        p = {"name": "pid", "method": "debug.agent_pane", "regex": r"^pid$", "max": 0}
        self.assertFalse(run_with(p, {"pane": "p1", "error": "no WebContent process"})["scenario_ran"])
        q = dict(p, absent=True)
        self.assertTrue(run_with(q, {"pane": "p1", "engine_kind": 1})["scenario_ran"])
        self.assertFalse(run_with(q, {"probe_error": "OSError"})["scenario_ran"])


class RatioMetric(unittest.TestCase):
    def report(self, on, off):
        def run(arm, dropped, frames):
            return {"arm": arm, "valid": True, "arm_verified": True,
                    "raw": {"summary": [{"dropped": d, "frames": f} for d, f in zip(dropped, frames)]}}
        runs = [run("on", *x) for x in on] + [run("off", *x) for x in off]
        return {"runs": runs, "probes": ["p"]}

    def test_ratio_is_one_value_per_run(self):
        m = [pab.parse_metric(r"rate=ratio:^summary\.\*\.dropped$/^summary\.\*\.frames$")]
        rep = self.report([([2, 0], [100, 100])] * 5, [([3, 1], [100, 100])] * 5)
        out = pab.summarize(rep, m, 5)["rate"]
        self.assertEqual(out["on"]["per_run_p95"], [0.01] * 5)
        self.assertEqual(out["off"]["per_run_p95"], [0.02] * 5)

    def test_ratio_resolves_a_gain_an_integer_count_cannot(self):
        m = [pab.parse_metric(r"rate=ratio:^summary\.\*\.dropped$/^summary\.\*\.frames$")]
        on = [([2, 2, 2], [160, 160, 160])] * 5
        off = [([3, 3, 3], [160, 160, 160]), ([3, 3, 2], [160, 160, 160]), ([3, 3, 3], [160, 160, 160]),
               ([3, 2, 3], [160, 160, 160]), ([3, 3, 3], [160, 160, 160])]
        out = pab.summarize(self.report(on, off), m, 5)["rate"]
        self.assertEqual(out["verdict"], "proven")


if __name__ == "__main__":
    unittest.main()
