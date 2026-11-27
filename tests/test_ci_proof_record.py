#!/usr/bin/env python3
"""scripts/ci/proof_record.py and scripts/ci/ios_verify.py: the proof record a pre-PR verify loop posts, the
`cmux/ios-fast` gate that requires one at the PR's current head, and the loop's plan. Run: python3 -I THIS.
"""
import copy
import json
import pathlib
import re
import sys
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/ci"))
import ios_verify  # noqa: E402
import proof_record as pr  # noqa: E402

HEAD = "a" * 40
OTHER = "b" * 40
RECORD = {
    "kind": "cmux-proof-record", "version": 1, "suite": "ios-flows", "repo": "manaflow-ai/cmux", "pr": 7,
    "head_sha": HEAD, "base_ref": "feat-cmux-next", "base_sha": OTHER,
    "selection": {"flows": ["smoke-launch-sign-in", "terminal-first-attach"]},
    "runs": [{"name": "sim 1/1", "result": "pass", "worker": "cmux23", "step": "abc12345", "seconds": 140}],
    "captures": [{"name": "a.png", "sha256": "0" * 64, "verdict": "same"}],
    "verdict": "pass", "timing": {"push_to_proof_s": 212}, "tool": "scripts/ci/ios_verify.py@x",
}


def comment(body, assoc="COLLABORATOR", login="someone", kind="User", at="2026-11-27T02:00:00Z"):
    return {"body": body, "author_association": assoc, "user": {"login": login, "type": kind},
            "created_at": at, "html_url": "u"}


class Record(unittest.TestCase):
    def test_round_trip(self):
        body = pr.render(RECORD, "summary")
        self.assertTrue(body.startswith(f"<!-- cmux-proof-record ios-flows {HEAD} -->"))
        self.assertEqual(pr.parse(body), RECORD)

    def test_problems(self):
        self.assertEqual(pr.problems(RECORD), [])
        bad = copy.deepcopy(RECORD)
        bad["runs"][0]["result"] = "fail"
        self.assertIn("verdict is pass but a run failed", pr.problems(bad))
        bad = dict(RECORD, runs=[])
        self.assertIn("verdict is pass with no run", pr.problems(bad))
        self.assertIn("head_sha is not a full commit id", pr.problems(dict(RECORD, head_sha="abc")))
        with self.assertRaises(ValueError):
            pr.render(dict(RECORD, suite="nope"))

    def test_marker_must_match_record(self):
        body = pr.render(RECORD).replace(f"ios-flows {HEAD}", f"ios-flows {OTHER}")
        self.assertIsNone(pr.parse(body))

    def test_schema_names_every_required_field(self):
        schema = json.loads((ROOT / "ci/proof-record/schema.json").read_text())
        self.assertEqual(set(schema["required"]), set(pr.REQUIRED))
        self.assertEqual(schema["properties"]["suite"]["enum"], list(pr.SUITES))


class Gate(unittest.TestCase):
    def test_needs_a_record_at_the_current_head(self):
        self.assertIsNone(pr.find([comment(pr.render(dict(RECORD, head_sha=OTHER)))], "ios-flows", HEAD))
        state, desc = pr.gate(None, "ios-flows")
        self.assertEqual(state, "pending")
        self.assertIn("cmux ios verify", desc)
        self.assertLessEqual(len("Build passed; " + desc), 140)

    def test_untrusted_authors_do_not_count(self):
        body = pr.render(RECORD)
        self.assertIsNone(pr.find([comment(body, assoc="NONE")], "ios-flows", HEAD))
        self.assertIsNone(pr.find([comment(body, assoc="NONE", login="evil[bot]", kind="Bot")], "ios-flows", HEAD,
                                  pr.DEFAULT_BOTS.split(",")))
        got = pr.find([comment(body, assoc="NONE", login="quota-goblin-9004[bot]", kind="Bot")], "ios-flows", HEAD,
                      pr.DEFAULT_BOTS.split(","))
        self.assertIsNotNone(got)

    def test_newest_record_wins(self):
        failed = copy.deepcopy(RECORD)
        failed["runs"][0]["result"] = "fail"
        failed["verdict"] = "fail"
        comments = [comment(pr.render(RECORD), at="2026-11-27T01:00:00Z"),
                    comment(pr.render(failed), at="2026-11-27T02:00:00Z")]
        self.assertEqual(pr.gate(pr.find(comments, "ios-flows", HEAD), "ios-flows")[0], "failure")
        self.assertEqual(pr.gate(pr.find(comments[:1], "ios-flows", HEAD), "ios-flows")[0], "success")

    def test_missing_env_is_an_error_not_a_pass(self):
        import io
        from contextlib import redirect_stdout
        import os
        saved = {k: os.environ.pop(k, None) for k in ("REPO", "PR", "SHA", "GH_TOKEN", "GITHUB_TOKEN")}
        try:
            out = io.StringIO()
            with redirect_stdout(out):
                pr.main(["gate", "--suite", "ios-flows"])
            self.assertTrue(out.getvalue().startswith("error\t"))
        finally:
            os.environ.update({k: v for k, v in saved.items() if v is not None})

    def test_router_gate_requires_the_proof(self):
        wf = (ROOT / ".github/workflows/pr-router.yml").read_text()
        job = wf[wf.index("  ios-fast-status:"):wf.index("  pipeline-fail-fast:")]
        self.assertIn("scripts/ci/proof_record.py", job)
        self.assertIn("proof_record.py gate --suite ios-flows", job)
        self.assertIn("pull-requests: read", job)
        self.assertIn("vars.CI_IOS_VERIFY_PROOF", job)
        self.assertIn(ios_verify.GATE_JOB, wf)


class Plan(unittest.TestCase):
    def selection(self, **kw):
        base = {"ios": True, "compile": False, "flows": ["smoke-launch-sign-in"], "kit": ["K1", "K2"],
                "ui": ["U1", "U2", "U3"], "swift": [], "scripts": []}
        base.update(kw)
        return base

    def test_shards_across_workers_with_video(self):
        steps = ios_verify.plan(self.selection(), [], ["cmux22", "cmux23"], "auto")
        self.assertEqual([s["worker"] for s in steps], ["cmux22", "cmux23"])
        self.assertTrue(all(s["args"][0] == "test" and s["args"][-1] == "video" for s in steps))
        joined = " ".join(" ".join(s["args"]) for s in steps)
        for t in ("K1", "K2", "U1", "U2", "U3"):
            self.assertIn(t, joined)

    def test_pair_e2e_follows_the_flows(self):
        flows = [{"id": "pairing", "pair_e2e": True}]
        sel = self.selection(flows=["pairing"])
        self.assertEqual(ios_verify.plan(sel, flows, ["cmux23"], "auto")[-1]["mode"], "pair-e2e")
        self.assertNotIn("pair-e2e", [s["mode"] for s in ios_verify.plan(sel, flows, ["cmux23"], "never")])
        self.assertNotIn("pair-e2e", [s["mode"] for s in ios_verify.plan(self.selection(), flows, ["cmux23"], "auto")])

    def test_never_on_leos_gui_macs(self):
        for bad in ("cosmic-gray", "air-blue.local"):
            with self.assertRaises(SystemExit):
                ios_verify.workers_from(f"cmux23,{bad}")

    def test_swift_is_named_as_delegated(self):
        got = ios_verify.delegated(self.selection(swift=[{"package": "P", "filter": "F"}]))
        self.assertEqual(got[0]["result"], "skipped")
        self.assertIn("pr pipeline / mac", got[0]["note"])

    def test_manifest_pairing_flows_ask_for_pair_e2e(self):
        flows = json.loads((ROOT / "cmux-next-ios/FlowSuite/flows.json").read_text())["flows"]
        self.assertTrue(any(f.get("pair_e2e") for f in flows))

    def test_visual_summary(self):
        caps = [{"name": "a.png", "verdict": "changed"}, {"name": "b.png", "verdict": "same"}]
        v = ios_verify.visual(caps, {"pr": 1, "sha": OTHER}, "v.mp4")
        self.assertEqual(v["changed"], ["a.png"])
        self.assertTrue(v["diffed"] and v["video"])
        self.assertFalse(ios_verify.visual(caps, None, None)["diffed"])


class Launcher(unittest.TestCase):
    def test_cmux_ios_verify_runs_this_script(self):
        dev = (ROOT / "cmux-tui/crates/cmux-tui/src/cli/dev.rs").read_text()
        self.assertRegex(dev, r'words: \["ios", "verify"\]')
        sh = (ROOT / "scripts/ci/ios-verify.sh").read_text()
        self.assertTrue(re.search(r"scripts/ci/ios_verify\.py", sh))


if __name__ == "__main__":
    unittest.main()
