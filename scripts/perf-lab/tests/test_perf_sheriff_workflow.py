#!/usr/bin/env python3
""".claude/workflows/perf-sheriff.js: the dry run prints one plan per group, and the live pass routes each
group through the right agents with fake agents (node runs the script with stubbed workflow hooks).

  python3 -m unittest scripts/perf-lab/tests/test_perf_sheriff_workflow.py
"""
from __future__ import annotations

import json
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / ".claude" / "workflows" / "perf-sheriff.js"

# Runs the workflow body with the hooks the Workflow tool gives it. Each fake agent answer is picked by the
# label prefix (the part before ":"); a label with no answer fails the run, so the test sees every call.
HARNESS = r"""
const fs = require('fs')
const [scriptPath, specPath] = process.argv.slice(2)
const spec = JSON.parse(fs.readFileSync(specPath, 'utf8'))
const src = fs.readFileSync(scriptPath, 'utf8').replace(/^export const meta/m, 'const meta')
const calls = [], logs = []
const answers = spec.answers || {}
async function agent(prompt, opts) {
  const label = (opts && opts.label) || ''
  calls.push({ label, phase: opts && opts.phase, isolation: opts && opts.isolation, prompt })
  const key = label.split(':')[0]
  if (!(key in answers)) throw new Error('unexpected agent ' + label)
  const a = answers[key]
  return Array.isArray(a) ? a.shift() : a
}
async function parallel(thunks) { const out = []; for (const t of thunks) { try { out.push(await t()) } catch (e) { out.push(null) } } return out }
async function pipeline(items, ...stages) {
  return Promise.all(items.map(async (item, i) => { let r = item; for (const s of stages) { try { r = await s(r, item, i) } catch (e) { return null } } return r }))
}
const body = new Function('agent', 'parallel', 'pipeline', 'log', 'phase', 'args', 'budget', 'workflow',
  `return (async () => {\n${src}\nreturn undefined\n})()`)
body(agent, parallel, pipeline, m => logs.push(m), () => {}, spec.args, { total: null, spent: () => 0, remaining: () => Infinity }, null)
  .then(result => { process.stdout.write(JSON.stringify({ result, calls, logs })) })
  .catch(e => { process.stdout.write(JSON.stringify({ error: String(e && e.stack || e), calls, logs })); process.exitCode = 1 })
"""


def group(gid, state, **kw):
    g = dict(id=gid, state=state, story="terminal.key-frame.light", metric="key_to_frame_ms", host_class="m4pro-24g-120hz",
             direction="up", delta_pct=12.5, range_good="aaa111", range_bad="bbb222", alert_at="2026-10-25T10:00:00Z",
             owner="PL-switch", base_branch="feat-cmux-next", bisect_job="", culprit_sha="", culprit_verified="none",
             culprit_pr=0, traces=[])
    g.update(kw)
    return g


CULPRIT_GROUP = group("g3", "culprit", bisect_job="pp-9", culprit_sha="ccc333", culprit_verified="verified",
                      culprit_pr=25001, traces=["sha256:aa", "sha256:bb"])


@unittest.skipUnless(shutil.which("node"), "node is not installed")
class PerfSheriffWorkflowTests(unittest.TestCase):
    def run_workflow(self, args, answers=None):
        with tempfile.TemporaryDirectory() as tmp:
            harness = Path(tmp) / "harness.js"
            harness.write_text(HARNESS)
            spec = Path(tmp) / "spec.json"
            spec.write_text(json.dumps({"args": args, "answers": answers or {}}))
            out = subprocess.run(["node", str(harness), str(SCRIPT), str(spec)], capture_output=True, text=True, timeout=60)
        data = json.loads(out.stdout)
        self.assertNotIn("error", data, data.get("error"))
        return data

    def test_dry_run_prints_one_plan_per_group_and_spawns_no_agent(self):
        groups = [group("g1", "new"), group("g2", "triaged", bisect_job="pp-1"), CULPRIT_GROUP]
        data = self.run_workflow({"dryRun": True, "groups": groups})
        self.assertEqual(data["calls"], [])
        plans = [m for m in data["logs"] if m.startswith("Plan ")]
        self.assertEqual([p.split()[1] for p in plans], ["g1", "g2", "g3"])
        self.assertEqual(data["result"]["groups"], 3)
        self.assertIn("lab.py sheriff take g1", plans[0])
        self.assertNotIn("sheriff take", plans[1])
        self.assertNotIn("bisect: read job", plans[2])
        self.assertIn("fix or flag-off by 2026-10-25T22:00:00.000Z", plans[0])
        self.assertIn("--feature X=off", plans[2])
        self.assertIn("Takes back #25001", plans[2])
        self.assertIn("scripts/gh-merge-green --revert", plans[2])

    def test_dry_run_reads_the_queue_with_one_read_only_agent(self):
        q = {"groups": [group("g1", "new"), group("g2", "new")], "raw_count": 2}
        data = self.run_workflow("--dry-run", {"queue": q})
        self.assertEqual([c["label"] for c in data["calls"]], ["queue"])
        self.assertIn("lab.py alerts --state new,triaged,culprit --json", data["calls"][0]["prompt"])
        self.assertEqual(len([m for m in data["logs"] if m.startswith("Plan ")]), 2)

    def test_dry_run_on_main_plans_no_revert(self):
        data = self.run_workflow({"dryRun": True, "groups": [group("m1", "culprit", base_branch="main", culprit_sha="d", culprit_verified="verified")]})
        plan = data["logs"][0]
        self.assertNotIn("gh-merge-green --revert", plan)
        self.assertIn("fix forward", plan)

    def test_perf_path_culprit_gets_a_flag_off_pr(self):
        answers = {
            "culprit": {"route": "flag-off", "feature": "cefLayerHosting", "culprit_pr": 25001, "receipts": "Perf try ...", "note": ""},
            "flag-off": {"pr_url": "https://github.com/manaflow-ai/cmux/pull/25100", "branch": "b", "head_sha": "e", "state_set": True, "note": ""},
        }
        data = self.run_workflow({"groups": [CULPRIT_GROUP]}, answers)
        self.assertEqual([c["label"].split(":")[0] for c in data["calls"]], ["culprit", "flag-off"])
        flag = data["calls"][1]
        self.assertEqual(flag["isolation"], "worktree")
        for needle in ("schemas/features/features.d/cefLayerHosting.json", "gen-features.py --check", "risk:normal",
                       "Takes back #25001:", "sheriff set g3 flag-off"):
            self.assertIn(needle, flag["prompt"])
        self.assertEqual(data["result"]["summary"][0]["outcome"], "flag-off")

    def test_fix_path_reviews_twice_verifies_and_opens_a_pr(self):
        fix = {"branch": "perf-sheriff/g3-fix1", "base_sha": "b0", "head_sha": "h1", "files_changed": ["Packages/macOS/X.swift"],
               "cause": "O(session) walk per key", "summary": "", "tests": "red/green", "owner_told": "", "gave_up": ""}
        answers = {
            "culprit": {"route": "fix", "feature": "", "culprit_pr": 25001, "receipts": "r", "note": ""},
            "fix1": fix,
            "review-correctness1": {"findings": []},
            "review-principled1": {"findings": []},
            "verify1": {"verdict": "improved", "other_regressions": [], "receipts": "Perf try ... strict DIFFERENT"},
            "pr": {"pr_url": "https://github.com/manaflow-ai/cmux/pull/25101", "branch": fix["branch"], "head_sha": "h1", "state_set": True, "note": ""},
        }
        data = self.run_workflow({"groups": [CULPRIT_GROUP]}, answers)
        labels = [c["label"].split(":")[0] for c in data["calls"]]
        self.assertEqual(labels, ["culprit", "fix1", "review-correctness1", "review-principled1", "verify1", "pr"])
        fixer = data["calls"][1]["prompt"]
        self.assertIn("Never edit a budget, threshold, expectation", fixer)
        self.assertIn("trace.py summary", fixer)
        self.assertIn('"sha256:aa"', fixer)
        self.assertIn("sheriff set g3 assigned", data["calls"][-1]["prompt"])
        self.assertEqual(data["result"]["summary"][0]["outcome"], "assigned")

    def test_fix_that_edits_a_budget_is_never_verified(self):
        bad = {"branch": "perf-sheriff/g3-fix1", "base_sha": "b0", "head_sha": "h1", "files_changed": ["scripts/cmux-next/idle-budget.json"],
               "cause": "c", "summary": "", "tests": "", "owner_told": "", "gave_up": ""}
        answers = {
            "culprit": {"route": "fix", "feature": "", "culprit_pr": 25001, "receipts": "r", "note": ""},
            "fix1": bad, "fix2": dict(bad, branch="perf-sheriff/g3-fix2"),
            "review-correctness1": {"findings": []}, "review-principled1": {"findings": []},
            "review-correctness2": {"findings": []}, "review-principled2": {"findings": []},
            "apply1": bad,
            "revert": {"action": "not-yet", "pr_url": "", "state_set": False, "note": ""},
        }
        data = self.run_workflow({"groups": [CULPRIT_GROUP]}, answers)
        labels = [c["label"].split(":")[0] for c in data["calls"]]
        self.assertNotIn("verify1", labels)
        self.assertNotIn("verify2", labels)
        self.assertNotIn("pr", labels)
        apply_prompt = next(c["prompt"] for c in data["calls"] if c["label"].startswith("apply1"))
        self.assertIn("idle-budget.json", apply_prompt)
        self.assertEqual(labels[-1], "revert")
        self.assertIn("scripts/gh-merge-green --revert manaflow-ai/cmux#25001", data["calls"][-1]["prompt"])
        self.assertEqual(data["result"]["summary"][0]["outcome"], "no-fix:not-yet")

    def test_new_group_triages_then_waits_for_the_bisect(self):
        g = group("g1", "new")
        answers = {"triage": {"route": "bisect-wait", "group": g, "receipt": "Perf try ...", "note": ""}}
        data = self.run_workflow({"groups": [g]}, answers)
        self.assertEqual([c["label"] for c in data["calls"]], ["triage:g1"])
        prompt = data["calls"][0]["prompt"]
        self.assertIn("lab.py sheriff take g1", prompt)
        self.assertIn("lab.py try --base aaa111 --head bbb222 --stories terminal.key-frame.light --attempts 20", prompt)
        self.assertEqual(data["result"]["summary"][0]["outcome"], "bisect-wait")

    def test_only_limits_the_pass(self):
        data = self.run_workflow({"dryRun": True, "only": ["g2"], "groups": [group("g1", "new"), group("g2", "new")]})
        self.assertEqual([m.split()[1] for m in data["logs"] if m.startswith("Plan ")], ["g2"])

    def test_script_uses_only_the_allowed_tools(self):
        src = SCRIPT.read_text()
        self.assertTrue(re.search(r"^export const meta = \{", src, re.M))
        for banned in ("maclease", "perf-cron", "xcodebuild", "sqlite3 ", "curl "):
            for line in src.splitlines():
                if banned in line:
                    self.assertRegex(line, r"[Nn]o |[Nn]ever ", f"{banned!r} used outside a prohibition: {line.strip()}")
        for line in src.splitlines():
            if "--admin" in line:
                self.assertIn("Never pass --admin", line)
        commands = set(re.findall(r"python3 (scripts/[\w/.-]+\.py)", src))
        self.assertEqual(commands, {"scripts/perf-lab/lab.py", "scripts/cmux-next/trace.py", "scripts/cmux-next/gen-features.py"})


if __name__ == "__main__":
    unittest.main()
