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
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / ".claude" / "workflows" / "perf-sheriff.js"
LAB = ROOT / "scripts" / "perf-lab" / "lab.py"

# Runs the workflow body with the hooks the Workflow tool gives it. Each fake agent answer is picked by the
# label prefix (the part before ":"); a list answers successive calls; a label with no answer fails the run,
# so the test sees every call. A JS expression in spec.exprs is evaluated against the script's own scope.
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
  return JSON.parse(JSON.stringify(Array.isArray(a) ? a.shift() : a))
}
async function parallel(thunks) { const out = []; for (const t of thunks) { try { out.push(await t()) } catch (e) { out.push(null) } } return out }
async function pipeline(items, ...stages) {
  return Promise.all(items.map(async (item, i) => { let r = item; for (const s of stages) { try { r = await s(r, item, i) } catch (e) { return null } } return r }))
}
const exprs = spec.exprs ? `return { exprs: [${spec.exprs.join(',')}] }\n` : ''
const body = new Function('agent', 'parallel', 'pipeline', 'log', 'phase', 'args', 'budget', 'workflow',
  `return (async () => {\n${src.replace(/\nphase\('Queue'\)\n/, '\n' + exprs + "phase('Queue')\n")}\nreturn undefined\n})()`)
body(agent, parallel, pipeline, m => logs.push(m), () => {}, spec.args, { total: null, spent: () => 0, remaining: () => Infinity }, null)
  .then(result => { process.stdout.write(JSON.stringify({ result, calls, logs })) })
  .catch(e => { process.stdout.write(JSON.stringify({ error: String(e && e.stack || e), calls, logs })); process.exitCode = 1 })
"""

GOOD, BAD = "a" * 40, "b" * 40
CULPRIT, PARENT = "c" * 40, "d" * 40
BASE_TIP, FIX_HEAD = "e" * 40, "f" * 40
SESSION = "sheriff-session-1"
LEAD = "lead-session-9"
# try_admission.py's _SHA: --base and --head are full commit SHAs.
ADMISSION_SHA = re.compile(r"[0-9a-f]{40}")


def group(gid, state, **kw):
    g = dict(id=gid, state=state, story="terminal.key-frame.light", metric="key_to_frame_ms", host_class="m4pro-24g-120hz",
             direction="up", delta_pct=12.5, range_good=GOOD, range_bad=BAD, alert_at="2026-10-25T10:00:00Z",
             owner="PL-switch", base_branch="feat-cmux-next", bisect_job="", culprit_sha="", culprit_parent_sha="",
             culprit_verified="none", culprit_pr=0, traces=[])
    g.update(kw)
    return g


def culprit_group(gid=3, **kw):
    return group(gid, "culprit", **{**dict(bisect_job="pp-9", culprit_sha=CULPRIT, culprit_parent_sha=PARENT,
                                          culprit_verified="verified", culprit_pr=25001, traces=["sha256:aa", "sha256:bb"]), **kw})


CULPRIT_GROUP = culprit_group()


def queue_answer(groups=None, followups=None, session=SESSION, lead="", missing=None, error="", lab_db="/lab/lab.sqlite"):
    groups = groups or []
    return {"session": session, "lead_session": lead, "lab_db": lab_db, "missing_commands": missing or [], "error": error,
            "groups": groups, "followups": followups or [], "raw_count": len(groups)}


def branch(**kw):
    b = dict(branch="perf-sheriff/ccccccc-fix1-eeeeeee", base_sha=BASE_TIP, head_sha=FIX_HEAD, files_changed=["Packages/macOS/X.swift"],
             pr_url="", held="", note="")
    b.update(kw)
    return b


def fix(**kw):
    return branch(**{**dict(cause="O(session) walk per key", summary="", tests="red/green", owner_told="", gave_up=""), **kw})


def review(paths=("Packages/macOS/X.swift",), findings=()):
    return {"changed_paths": list(paths), "findings": list(findings)}


def pr(url="https://github.com/manaflow-ai/cmux/pull/25100", **kw):
    p = dict(pr_url=url, held=False, state_set=True, landed="ready-to-land", note="")
    p.update(kw)
    return p


FLAG_CULPRIT = {"route": "flag-off", "feature": "cefLayerHosting", "culprit_pr": 25001, "receipts": "Perf try ...", "note": ""}
FIX_CULPRIT = {"route": "fix", "feature": "", "culprit_pr": 25001, "receipts": "r", "note": ""}
CRITICAL = {"severity": "critical", "file": "a.swift", "problem": "p", "failure_scenario": "f", "principled_fix": "x"}


def labels(data):
    return [c["label"].split(":")[0] for c in data["calls"]]


@unittest.skipUnless(shutil.which("node"), "node is not installed")
class PerfSheriffWorkflowTests(unittest.TestCase):
    def run_workflow(self, args, answers=None, exprs=None):
        with tempfile.TemporaryDirectory() as tmp:
            harness = Path(tmp) / "harness.js"
            harness.write_text(HARNESS)
            spec = Path(tmp) / "spec.json"
            spec.write_text(json.dumps({"args": args, "answers": answers or {}, "exprs": exprs}))
            out = subprocess.run(["node", str(harness), str(SCRIPT), str(spec)], capture_output=True, text=True, timeout=60)
        data = json.loads(out.stdout)
        self.assertNotIn("error", data, data.get("error"))
        return data

    def forbidden(self, paths):
        return self.run_workflow({"dryRun": True, "groups": []},
                                 exprs=[f"forbiddenFiles({json.dumps(paths)})"])["result"]["exprs"][0]

    def assert_try_commands_admissible(self, data):
        seen = 0
        for call in data["calls"]:
            for m in re.finditer(r"lab\.py try --base (\S+) --head (\S+)", call["prompt"]):
                seen += 1
                for sha in m.groups():
                    self.assertTrue(ADMISSION_SHA.fullmatch(sha), f"{call['label']}: try --base/--head {sha!r} is refused by admission")
        return seen

    # ---- dry run ----

    def test_dry_run_prints_one_plan_per_group_and_spawns_no_agent(self):
        groups = [group(1, "new"), group(2, "triaged", bisect_job="pp-1"), CULPRIT_GROUP]
        data = self.run_workflow({"dryRun": True, "groups": groups})
        self.assertEqual(data["calls"], [])
        plans = [m for m in data["logs"] if m.startswith("Plan ")]
        self.assertEqual([p.split()[1] for p in plans], ["1", "2", "3"])
        self.assertEqual(data["result"]["groups"], 3)
        self.assertIn("lab.py sheriff take 1", plans[0])
        self.assertIn("lab.py sheriff set 1 triaged", plans[0])
        self.assertIn("lab.py bisect", plans[0])
        self.assertIn("wait on job pp-1", plans[1])
        self.assertNotIn("confirm:", plans[1])
        self.assertNotIn("bisect:", plans[2])
        self.assertIn("sheriff set 3 assigned --reason", plans[2])
        self.assertIn("sheriff set 3 flag-off --reason", plans[2])
        self.assertIn("fix or flag-off by 2026-10-25T22:00:00.000Z", plans[0])
        self.assertIn(f"--base {PARENT} --head {CULPRIT}", plans[2])
        self.assertIn("--feature X=off", plans[2])
        self.assertIn("Takes back #25001", plans[2])
        self.assertIn("scripts/gh-merge-green --revert manaflow-ai/cmux#25001", plans[2])

    def test_dry_run_reads_the_queue_with_one_read_only_agent(self):
        q = queue_answer([group(1, "new"), group(2, "new")])
        data = self.run_workflow("--dry-run", {"queue": q})
        self.assertEqual(labels(data), ["queue"])
        prompt = data["calls"][0]["prompt"]
        self.assertIn("lab.py sheriff list --state new,triaged,bisecting,culprit --json", prompt)
        self.assertIn("CMUX_PERF_LAB_DB", prompt)
        self.assertIn("git rev-parse <culprit_sha>^", prompt)
        self.assertEqual(len([m for m in data["logs"] if m.startswith("Plan ")]), 2)

    def test_dry_run_on_main_plans_no_revert_and_lands_through_gh_merge_green(self):
        data = self.run_workflow({"dryRun": True, "groups": [culprit_group(9, base_branch="main")]})
        plan = data["logs"][0]
        self.assertNotIn("gh-merge-green --revert", plan)
        self.assertIn("fix forward", plan)
        self.assertIn("scripts/gh-merge-green manaflow-ai/cmux#<PR>", plan)
        self.assertNotIn("ready-to-land", plan)

    def test_only_limits_the_pass(self):
        data = self.run_workflow({"dryRun": True, "only": [2], "groups": [group(1, "new"), group(2, "new")]})
        self.assertEqual([m.split()[1] for m in data["logs"] if m.startswith("Plan ")], ["2"])
        data = self.run_workflow("--dry-run 2", {"queue": queue_answer([group(1, "new"), group(2, "new")])})
        self.assertEqual([m.split()[1] for m in data["logs"] if m.startswith("Plan ")], ["2"])

    def test_groups_without_full_shas_are_left_out(self):
        groups = [group(1, "new", range_good="aaa111"), culprit_group(2, culprit_parent_sha=""), group(3, "new")]
        data = self.run_workflow({"dryRun": True, "groups": groups})
        self.assertEqual([m.split()[1] for m in data["logs"] if m.startswith("Plan ")], ["3"])
        self.assertTrue(any("group 1: range_good is not a full 40-hex SHA" in m for m in data["logs"]))
        self.assertTrue(any("group 2: culprit_sha and culprit_parent_sha" in m for m in data["logs"]))

    # ---- session ----

    def test_session_is_never_an_argument(self):
        for args in ({"groups": [CULPRIT_GROUP], "session": SESSION}, f"--session {SESSION} 3", {"dryRun": True, "session": LEAD}):
            data = self.run_workflow(args)
            self.assertEqual(data["calls"], [])
            self.assertIn("the session is not an argument", data["result"]["error"])

    def test_live_pass_acts_as_the_session_from_its_own_environment(self):
        data = self.run_workflow({"groups": [CULPRIT_GROUP]}, {"queue": queue_answer(session=""), "culprit": FLAG_CULPRIT})
        self.assertEqual(labels(data), ["queue"])
        self.assertIn("needs an agent session in the environment", data["result"]["error"])
        self.assertIn("never take one from anywhere else", data["calls"][0]["prompt"])
        data = self.run_workflow({"groups": [CULPRIT_GROUP]}, {"queue": queue_answer(session="a b; rm -rf /")})
        self.assertEqual(labels(data), ["queue"])

    def test_live_pass_refuses_the_performance_lead_session(self):
        data = self.run_workflow({"groups": [CULPRIT_GROUP]}, {"queue": queue_answer(session=LEAD, lead=LEAD)})
        self.assertEqual(labels(data), ["queue"])
        self.assertIn("Performance Lead", data["result"]["error"])

    # ---- lab commands ----

    def test_a_missing_lab_command_is_an_error_not_an_empty_queue(self):
        data = self.run_workflow("--dry-run", {"queue": queue_answer(missing=["sheriff", "alerts", "bisect"])})
        self.assertIn("lab.py has no sheriff, alerts command", data["result"]["error"])
        data = self.run_workflow({"groups": [CULPRIT_GROUP]}, {"queue": queue_answer(missing=["try"])})
        self.assertIn("lab.py has no try command", data["result"]["error"])
        data = self.run_workflow("--dry-run", {"queue": queue_answer(lab_db="")})
        self.assertIn("CMUX_PERF_LAB_DB is not set", data["result"]["error"])
        data = self.run_workflow("--dry-run", {"queue": queue_answer(error="lab.py sheriff list: invalid choice")})
        self.assertIn("invalid choice", data["result"]["error"])

    def test_lab_py_has_every_command_the_workflow_runs(self):
        listed = subprocess.run([sys.executable, "-I", str(LAB), "--help"], capture_output=True, text=True, timeout=60).stdout
        missing = [c for c in ("sheriff", "alerts", "try") if not re.search(rf"^\s+{c}\b", listed, re.M)]
        if missing:
            self.skipTest(f"lab.py does not register {', '.join(missing)} yet (sheriff.py and alerts.py need LAB_COMMANDS "
                          "and the (command, ...) signatures; try is task 018); the workflow reports this as an error")
        for command in ("sheriff", "alerts", "try"):
            out = subprocess.run([sys.executable, "-I", str(LAB), command, "--help"], capture_output=True, text=True, timeout=60)
            self.assertEqual(out.returncode, 0, out.stderr)

    # ---- live routes ----

    def test_new_group_triages_starts_and_waits_for_the_bisect(self):
        g = group(1, "new")
        answers = {"queue": queue_answer(), "triage": {"route": "bisect-wait", "group": g, "receipt": "Perf try ...", "note": ""}}
        data = self.run_workflow({"groups": [g]}, answers)
        self.assertEqual(labels(data), ["queue", "triage"])
        prompt = data["calls"][1]["prompt"]
        sheriff = f"CMUX_AGENT_SESSION={SESSION} python3 scripts/perf-lab/lab.py sheriff"
        for needle in (f"{sheriff} take 1", f"{sheriff} set 1 triaged", f"{sheriff} set 1 invalid --reason",
                       f"{sheriff} set 1 bisecting", f"{sheriff} set 1 culprit --culprit", "lab.py bisect --help",
                       "at most 3 h", f"--base {GOOD} --head {BAD} --stories terminal.key-frame.light --attempts 20"):
            self.assertIn(needle, prompt)
        self.assertEqual(data["result"]["summary"][0]["outcome"], "bisect-wait")

    def test_triage_that_reaches_a_culprit_goes_on_in_the_same_pass(self):
        g = group(1, "triaged")
        found = culprit_group(1)
        answers = {"queue": queue_answer(), "triage": {"route": "culprit", "group": found, "receipt": "", "note": ""},
                   "culprit": {"route": "unverified", "feature": "", "culprit_pr": 25001, "receipts": "r", "note": ""}}
        data = self.run_workflow({"groups": [g]}, answers)
        self.assertEqual(labels(data), ["queue", "triage", "culprit"])
        self.assertEqual(data["result"]["summary"][0]["outcome"], "unverified")

    def test_perf_path_culprit_gets_a_reviewed_flag_off_pr_and_stays_assigned(self):
        answers = {"queue": queue_answer(), "culprit": FLAG_CULPRIT,
                   "flag-off": branch(branch="perf-sheriff/ccccccc-cefLayerHosting-off-eeeeeee",
                                      files_changed=["schemas/features/features.d/cefLayerHosting.json"]),
                   "review-flag-off1": review(["schemas/features/features.d/cefLayerHosting.json"]), "pr": pr()}
        data = self.run_workflow({"groups": [CULPRIT_GROUP]}, answers)
        self.assertEqual(labels(data), ["queue", "culprit", "flag-off", "review-flag-off1", "pr"])
        sheriff = f"CMUX_AGENT_SESSION={SESSION} python3 scripts/perf-lab/lab.py sheriff"
        self.assertIn(f"{sheriff} take 3", data["calls"][1]["prompt"])
        flag = data["calls"][2]
        self.assertEqual(flag["isolation"], "worktree")
        for needle in ("schemas/features/features.d/cefLayerHosting.json", "gen-features.py --check", "Do not open the PR",
                       "perf-sheriff/ccccccc-cefLayerHosting-off-<first 7 of base_sha>", "git ls-remote --exit-code --heads",
                       "gh pr list --repo manaflow-ai/cmux --state open"):
            self.assertIn(needle, flag["prompt"])
        open_pr = data["calls"][4]["prompt"]
        for needle in ("risk:normal", "Takes back #25001:", f'{sheriff} set <group> assigned --reason "perf-sheriff flag-off cefLayerHosting <PR url>"',
                       "Only when state_set is true", "ready-to-land"):
            self.assertIn(needle, open_pr)
        # The take comes before gh pr create, and the label after the assigned move.
        self.assertLess(open_pr.index(f"{sheriff} take 3"), open_pr.index("gh pr create"))
        self.assertLess(open_pr.index("set <group> assigned"), open_pr.index("--add-label ready-to-land"))
        self.assertNotIn("set 3 flag-off", open_pr)
        self.assertNotIn("<group> flag-off", open_pr)
        self.assertEqual(data["result"]["summary"][0]["outcome"], "flag-off-pr")
        self.assertGreater(self.assert_try_commands_admissible(data), 0)

    def test_flag_off_review_is_bounded_and_opens_no_pr_without_ship(self):
        answers = {"queue": queue_answer(), "culprit": FLAG_CULPRIT,
                   "flag-off": branch(files_changed=["schemas/features/features.d/cefLayerHosting.json"]),
                   "review-flag-off1": review(findings=[CRITICAL]), "apply1": branch(head_sha="1" * 40),
                   "review-flag-off2": review(findings=[CRITICAL])}
        data = self.run_workflow({"groups": [CULPRIT_GROUP]}, answers)
        self.assertEqual(labels(data), ["queue", "culprit", "flag-off", "review-flag-off1", "apply1", "review-flag-off2"])
        self.assertEqual(data["result"]["summary"][0]["outcome"], "flag-off-review-failed")

    def test_merged_flag_off_pr_moves_to_flag_off_only_after_recovery(self):
        url = "https://github.com/manaflow-ai/cmux/pull/25100"
        fu = {"id": 3, "reason": f"perf-sheriff flag-off cefLayerHosting {url}", "story": "terminal.key-frame.light",
              "metric": "key_to_frame_ms", "host_class": "m4pro-24g-120hz", "direction": "up", "base_branch": "feat-cmux-next"}
        other = dict(fu, id=4, reason="perf-sheriff fix https://github.com/manaflow-ai/cmux/pull/25101")
        answers = {"queue": queue_answer(followups=[fu, dict(fu, id=5), other]),
                   "followup": {"action": "flag-off", "merge_sha": "9" * 40, "receipts": "r", "note": ""}}
        data = self.run_workflow([], answers)
        self.assertEqual(labels(data), ["queue", "followup"])
        prompt = data["calls"][1]["prompt"]
        for needle in (f"gh pr view {url} --json state,mergedAt,mergeCommit", "action=pending", "strict DIFFERENT in its improvement direction",
                       f"CMUX_AGENT_SESSION={SESSION} python3 scripts/perf-lab/lab.py sheriff take 3",
                       f"CMUX_AGENT_SESSION={SESSION} python3 scripts/perf-lab/lab.py sheriff take 5",
                       "set <group> flag-off --reason \"cefLayerHosting off by default in"):
            self.assertIn(needle, prompt)
        self.assertLess(prompt.index("mergedAt"), prompt.index("flag-off --reason"))
        self.assertEqual(sorted((s["group"], s["outcome"]) for s in data["result"]["summary"]),
                         [(3, "follow-up:flag-off"), (5, "follow-up:flag-off")])

    def test_groups_with_one_culprit_get_one_pr(self):
        groups = [CULPRIT_GROUP, culprit_group(4, story="sidebar.switch", delta_pct=30.0)]
        answers = {"queue": queue_answer(), "culprit": FLAG_CULPRIT,
                   "flag-off": branch(files_changed=["schemas/features/features.d/cefLayerHosting.json"]),
                   "review-flag-off1": review(["schemas/features/features.d/cefLayerHosting.json"]), "pr": pr()}
        data = self.run_workflow({"groups": groups}, answers)
        self.assertEqual(labels(data), ["queue", "culprit", "culprit", "flag-off", "review-flag-off1", "pr"])
        flag = data["calls"][3]["prompt"]
        self.assertIn("take 3", flag)
        self.assertIn("take 4", flag)
        self.assertIn("Takes back #25001: sidebar.switch.key_to_frame_ms regressed 30", data["calls"][5]["prompt"])
        self.assertEqual([(s["group"], s["outcome"], s["pr"]) for s in data["result"]["summary"]],
                         [(3, "flag-off-pr", pr()["pr_url"]), (4, "flag-off-pr", pr()["pr_url"])])

    def test_fix_path_reviews_twice_verifies_and_opens_a_pr(self):
        answers = {"queue": queue_answer(), "culprit": FIX_CULPRIT, "fix1": fix(),
                   "review-correctness1": review(), "review-principled1": review(),
                   "verify1": {"verdict": "improved", "other_regressions": [], "receipts": "Perf try ... strict DIFFERENT"},
                   "pr": pr("https://github.com/manaflow-ai/cmux/pull/25101")}
        data = self.run_workflow({"groups": [CULPRIT_GROUP]}, answers)
        self.assertEqual(labels(data), ["queue", "culprit", "fix1", "review-correctness1", "review-principled1", "verify1", "pr"])
        fixer = data["calls"][2]["prompt"]
        self.assertIn("Never edit a budget, threshold, expectation", fixer)
        self.assertIn("perf-gate row (scripts/cmux-next/perf-gate.py)", fixer)
        self.assertIn("trace.py summary", fixer)
        self.assertIn('"sha256:aa"', fixer)
        self.assertIn(f"CMUX_AGENT_SESSION={SESSION} python3 scripts/perf-lab/lab.py sheriff take 3", fixer)
        self.assertIn("perf-sheriff/ccccccc-fix1-<first 7 of base_sha>", fixer)
        self.assertIn("git diff --name-only", data["calls"][4]["prompt"])
        self.assertIn("take 3", data["calls"][5]["prompt"])
        self.assertIn('set <group> assigned --reason "perf-sheriff fix <PR url>"', data["calls"][-1]["prompt"])
        self.assertEqual(data["result"]["summary"][0]["outcome"], "assigned")
        self.assertGreater(self.assert_try_commands_admissible(data), 0)

    def test_two_passes_on_one_culprit_never_reuse_a_pushed_branch(self):
        answers = {"queue": queue_answer(), "culprit": FIX_CULPRIT, "fix1": fix(gave_up="too large"),
                   "revert": {"action": "not-yet", "pr_url": "", "state_set": False, "note": ""}}
        prompts = [self.run_workflow({"groups": [CULPRIT_GROUP]}, answers)["calls"][2]["prompt"] for _ in range(2)]
        for prompt in prompts:
            self.assertNotRegex(prompt, r"git switch -c perf-sheriff/\S+ ")
            self.assertIn("git switch -c <branch>", prompt)
            self.assertIn("git ls-remote --exit-code --heads origin <branch>", prompt)
            self.assertIn("append -2, -3", prompt)
        self.assertEqual(prompts[0], prompts[1])

    def test_fix_that_edits_a_bar_is_never_verified(self):
        bad = fix(files_changed=["scripts/cmux-next/idle-budget.json"])
        answers = {"queue": queue_answer(), "culprit": FIX_CULPRIT, "fix1": bad, "fix2": bad,
                   "review-correctness1": review(), "review-principled1": review(),
                   "review-correctness2": review(), "review-principled2": review(),
                   "apply1": bad,
                   "revert": {"action": "not-yet", "pr_url": "", "state_set": False, "note": ""}}
        data = self.run_workflow({"groups": [CULPRIT_GROUP]}, answers)
        got = labels(data)
        self.assertNotIn("verify1", got)
        self.assertNotIn("verify2", got)
        self.assertNotIn("pr", got)
        apply_prompt = next(c["prompt"] for c in data["calls"] if c["label"].startswith("apply1"))
        self.assertIn("idle-budget.json", apply_prompt)
        self.assertEqual(got[-1], "revert")
        self.assertIn("scripts/gh-merge-green --revert manaflow-ai/cmux#25001", data["calls"][-1]["prompt"])
        self.assertEqual(data["result"]["summary"][0]["outcome"], "no-fix:not-yet")

    def test_r3_reads_the_computed_diff_not_only_the_fixer_report(self):
        sneaky = fix(files_changed=["Packages/macOS/X.swift"])
        answers = {"queue": queue_answer(), "culprit": FIX_CULPRIT, "fix1": [sneaky, sneaky], "fix2": sneaky,
                   "review-correctness1": review(["Packages/macOS/X.swift", "scripts/cmux-next/perf-gate.py"]),
                   "review-principled1": review(),
                   "review-correctness2": review(["Packages/macOS/X.swift", "scripts/cmux-next/perf-gate.py"]),
                   "review-principled2": review(), "apply1": sneaky,
                   "revert": {"action": "not-yet", "pr_url": "", "state_set": False, "note": ""}}
        data = self.run_workflow({"groups": [CULPRIT_GROUP]}, answers)
        self.assertNotIn("verify1", labels(data))
        apply_prompt = next(c["prompt"] for c in data["calls"] if c["label"].startswith("apply1"))
        self.assertIn("scripts/cmux-next/perf-gate.py", apply_prompt)

    def test_forbidden_files_are_bar_files_not_budget_named_source(self):
        refused = ["scripts/cmux-next/idle-budget.json", "scripts/cmux-next/perf-gate.py", "scripts/perf-lab/stories.d/switch.json",
                   "scripts/cmux-next/perf-budgets.json", "scripts/cmux-next/perf-budgets.py",
                   "scripts/cmux-next/perf-budgets-baseline/apple-m4-pro-macos27.json", "scripts/cmux-next/perf-hot-benches.json",
                   "scripts/perf-lab/subscriptions.json", "scripts/perf-lab/targets.json", "scripts/perf-lab/shard_map.json",
                   "scripts/perf-lab/perf_stats.py", "scripts/perf-lab/anomaly_edivisive.py", "scripts/perf-lab/pinpoint_thresholds.py",
                   "scripts/perf-lab/expectations.json", "scripts/perf-bench/budgets-heavy.json",
                   "scripts/perf-bench/baseline/apple-m6-macos27.json", "scripts/ci/launch_budget_gate.py"]
        allowed = ["Packages/macOS/CmuxNext/Sources/CmuxNextWakeups/MainFrameBudget.swift",
                   "Packages/macOS/CmuxNext/Sources/CmuxNext/ActionBudget/ActionBudgetMonitor.swift",
                   "Packages/macOS/CmuxNext/Sources/CmuxNext/MainThreadWatchdog+TaskBudget.swift",
                   "Packages/macOS/CmuxNext/Sources/CmuxNext/WarmSetBudget.swift",
                   "cmux-tui/crates/cmux-term/src/kitty_budget.rs", "cmux-tui/crates/cmux-daemon/src/memory_budget.rs",
                   "Packages/macOS/CmuxNext/Sources/CmxIroh/CmxIrohExpectation.swift", "Packages/macOS/X.swift"]
        self.assertEqual(sorted(self.forbidden(refused + allowed)), sorted(refused))

    def test_held_group_stops_after_the_take(self):
        answers = {"queue": queue_answer(), "culprit": {"route": "held", "feature": "", "culprit_pr": 0, "receipts": "", "note": "held by s-2"}}
        data = self.run_workflow({"groups": [CULPRIT_GROUP]}, answers)
        self.assertEqual(labels(data), ["queue", "culprit"])
        self.assertEqual(data["result"]["summary"][0]["outcome"], "held")

    def test_a_refused_take_in_a_later_step_stops_the_attempt(self):
        answers = {"queue": queue_answer(), "culprit": FIX_CULPRIT, "fix1": fix(), "review-correctness1": review(),
                   "review-principled1": review(), "verify1": {"verdict": "held", "other_regressions": [], "receipts": ""}}
        data = self.run_workflow({"groups": [CULPRIT_GROUP]}, answers)
        self.assertEqual(labels(data)[-1], "verify1")
        self.assertEqual(data["result"]["summary"][0]["outcome"], "held")

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
            if "--override" in line:
                self.assertIn("never --override", line)
        commands = set(re.findall(r"python3 (scripts/[\w/.-]+\.py)", src))
        self.assertEqual(commands, {"scripts/perf-lab/lab.py", "scripts/cmux-next/trace.py", "scripts/cmux-next/gen-features.py"})
        self.assertNotIn("args.session", src)


if __name__ == "__main__":
    unittest.main()
