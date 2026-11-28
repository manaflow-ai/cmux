#!/usr/bin/env python3
"""scripts/ci/proof_record.py and scripts/ci/ios_verify.py: the proof record a pre-PR verify loop posts, the
`cmux/ios-fast` gate that requires one at the PR's current head, and the loop's plan. Run: python3 -I THIS.
"""
import copy
import json
import pathlib
import re
import sys
import tempfile
import unittest
from unittest import mock

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
    "runs": [{"name": "sim 1/1", "result": "pass", "step": "abc12345", "seconds": 140}],
    "captures": [{"name": "a.png", "sha256": "0" * 64, "verdict": "same"}],
    "verdict": "pass", "timing": {"push_to_proof_s": 212}, "tool": "scripts/ci/ios_verify.py@x",
}


def comment(body, assoc="COLLABORATOR", login="someone", kind="User", at="2026-11-27T02:00:00Z"):
    return {"body": body, "author_association": assoc, "user": {"login": login, "type": kind},
            "created_at": at, "html_url": "u"}


class ReadRetry(unittest.TestCase):
    def test_a_passing_refusal_is_asked_again(self):
        # One 502 used to turn a passed build into "proof record not read (HTTPError): rerun this job".
        import functools
        from unittest import mock
        http = pr.gh_http.deadline_http
        answers = [(502, b"", http.Headers({})), (200, json.dumps([comment("x")]).encode(), http.Headers({}))]
        seen = []

        def fake(req, seconds, **kwargs):
            seen.append(req.full_url)
            return answers.pop(0)

        retrying = functools.partial(pr.gh_http.request, sleep=lambda s: None, log=lambda line: None)
        with mock.patch.object(http, "request", side_effect=fake), mock.patch.object(pr.gh_http, "request", retrying):
            got = pr.pr_comments("o/r", 7, "t")
        self.assertEqual([c["body"] for c in got], ["x"])
        self.assertEqual(len(seen), 2)


class Record(unittest.TestCase):
    def test_round_trip(self):
        body = pr.render(RECORD, "summary")
        self.assertTrue(body.startswith(f"<!-- cmux-proof-record ios-flows {HEAD} -->"))
        self.assertEqual(pr.parse(body), RECORD)

    def test_a_big_record_still_fits_one_comment(self):
        # cmux#38466: 201 screens rendered 38365 characters, the broker refused it and the gate never saw the proof.
        big = copy.deepcopy(RECORD)
        big["captures"] = [{"name": f"{i:08X}-4C8B-4892-AAAB-66BEE93F5ACA.png", "sha256": f"{i:064x}",
                            "diff_ratio": 0.0008, "verdict": "same"} for i in range(201)]
        big["visual"] = {"screens": 201, "changed": [c["name"] for c in big["captures"][:100]]}
        self.assertGreater(len(json.dumps(big, indent=1)), pr.COMMENT_BUDGET)
        body = pr.render(big, "summary")
        self.assertLessEqual(len(body), pr.COMMENT_BUDGET)
        back = pr.parse(body)
        self.assertEqual(back["verdict"], "pass")
        self.assertEqual(len(back["captures"]), 201)
        self.assertEqual(pr.gate(back, "ios-flows")[0], "success")
        self.assertEqual(back["captures"][0]["sha256"], f"{0:012x}")
        self.assertIn('\n "kind"', pr.render(RECORD))  # a small record keeps the readable indented form

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

    def test_a_private_member_who_can_push_counts(self):
        # cmux#62808: a member whose org membership is private reads as CONTRIBUTOR to a workflow's github.token,
        # so their passing record never counted. Whether they can push is what the gate asks GitHub instead.
        body = pr.render(RECORD)
        asked = []

        def can_write(login):
            asked.append(login)
            return login == "member"

        self.assertIsNone(pr.find([comment(body, assoc="CONTRIBUTOR", login="member")], "ios-flows", HEAD))
        self.assertIsNotNone(pr.find([comment(body, assoc="CONTRIBUTOR", login="member")], "ios-flows", HEAD,
                                     (), can_write))
        self.assertIsNone(pr.find([comment(body, assoc="CONTRIBUTOR", login="outsider")], "ios-flows", HEAD,
                                  (), can_write))
        # A bot never passes on a permission read, and a comment with no record costs no read.
        self.assertIsNone(pr.find([comment(body, assoc="NONE", login="member", kind="Bot")], "ios-flows", HEAD,
                                  (), can_write))
        pr.find([comment("no record here", assoc="CONTRIBUTOR", login="chatty")], "ios-flows", HEAD, (), can_write)
        self.assertEqual(asked, ["member", "outsider"])

    def test_writer_check_reads_the_permission_once_and_fails_closed(self):
        from unittest import mock
        answers = {"admin-user": "admin", "writer": "write", "reader": "read"}
        seen = []

        def fake(req, seconds, **kwargs):
            login = req.full_url.split("/collaborators/")[1].split("/")[0]
            seen.append(login)
            if login == "broken":
                raise pr.urllib.error.HTTPError(req.full_url, 404, "Not Found", {}, None)
            return 200, json.dumps({"permission": answers[login]}).encode(), {}

        with mock.patch.object(pr.gh_http, "request", side_effect=fake):
            can_write = pr.writer_check("o/r", ["t"])
            got = {login: can_write(login) for login in ("admin-user", "writer", "reader", "broken", "writer")}
        self.assertEqual(got, {"admin-user": True, "writer": True, "reader": False, "broken": False})
        self.assertEqual(seen, ["admin-user", "writer", "reader", "broken"])

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
                rc = pr.main(["gate", "--suite", "ios-flows"])
            self.assertEqual(rc, pr.UNREAD)
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


class NoFlows(unittest.TestCase):
    """A head whose changed paths select no flow posts a no-flows pass the gate reads (cmux#58097: the gate asked
    for a proof for .github/workflows/test-ios.yml, and the loop returned with nothing posted)."""

    def run_main(self, argv):
        view = {"number": 7, "headRefName": "h", "headRefOid": HEAD, "baseRefName": "feat-cmux-next",
                "url": "https://github.com/manaflow-ai/cmux/pull/7", "isCrossRepository": False, "body": ""}
        sh = mock.MagicMock(return_value="")
        with mock.patch.object(ios_verify, "pr_view", return_value=view), \
                mock.patch.object(ios_verify, "git", return_value=OTHER), \
                mock.patch.object(ios_verify.select_flows, "changed_from_git", return_value=[".github/workflows/test-ios.yml"]), \
                mock.patch.object(ios_verify.select_flows, "select", return_value={
                    "ios": False, "compile": False, "flows": [], "kit": [], "ui": [], "swift": [], "scripts": [],
                    "pair_e2e": [], "pair": False, "reason": {}}), \
                mock.patch.object(ios_verify, "run_step", side_effect=AssertionError("no simulator run")), \
                mock.patch.object(ios_verify, "baseline", side_effect=AssertionError("no baseline read")), \
                mock.patch.object(ios_verify, "pushed_at", return_value="2026-11-28T00:00:00Z"), \
                mock.patch.object(ios_verify, "rerun_gate", return_value="gate rerun") as rerun, \
                mock.patch.object(ios_verify, "sh", sh), \
                tempfile.TemporaryDirectory() as d:
            out = pathlib.Path(d) / "record.json"
            rc = ios_verify.main([*argv, "--out", str(out)])
            record = json.loads(out.read_text()) if out.exists() else None
        return rc, record, sh, rerun

    def test_posts_a_pass_the_gate_accepts(self):
        rc, record, sh, rerun = self.run_main(["--pr", "7", "--no-merge-base"])
        self.assertEqual(rc, 0)
        self.assertEqual(pr.problems(record), [])
        self.assertEqual(record["verdict"], "pass")
        self.assertEqual([r["name"] for r in record["runs"]], [ios_verify.NO_FLOWS_RUN])
        self.assertEqual(record["selection"]["flows"], [])
        body = sh.call_args.args
        self.assertEqual(body[:3], ("gh", "pr", "comment"))
        rerun.assert_called_once_with("manaflow-ai/cmux", HEAD)
        posted = pr.find([comment(pr.render(record))], "ios-flows", HEAD)
        self.assertEqual(pr.gate(posted, "ios-flows")[0], "success")

    def test_plan_still_posts_nothing(self):
        rc, record, sh, rerun = self.run_main(["--pr", "7", "--plan"])
        self.assertEqual(rc, 0)
        self.assertIsNone(record)
        sh.assert_not_called()
        rerun.assert_not_called()


class FromStep(unittest.TestCase):
    """--from-step posts a finished step's result instead of running it again, and only for the same work."""
    HEAD = "434cecd2bc9a5be7c5031e9c7b5ddeda15dd03cf"
    STEP = {"name": "sim 1/1: test ui=AppReviewGateUITests", "mode": "test", "worker": "cmux23",
            "args": ["test", "ui=AppReviewGateUITests", "video"]}

    def job(self, **over):
        j = {"ref": self.HEAD, "script": ios_verify.SIM_SCRIPT, "args": self.STEP["args"], "state": "done",
             "exit_code": 0, "worker": "aws-m4pro-4"}
        j.update(over)
        return mock.Mock(returncode=0, stdout=json.dumps(j))

    def read(self, proc):
        with mock.patch.object(ios_verify.subprocess, "run", return_value=proc):
            return ios_verify.finished_step(self.STEP, self.HEAD, ["694304f17866e34a2c99d717"])

    def test_a_finished_green_step_is_a_pass_from_the_host_that_ran_it(self):
        got = self.read(self.job())
        self.assertEqual((got["result"], got["worker"], got["step"]), ("pass", "aws-m4pro-4", "694304f17866e34a2c99d717"))

    def test_a_failed_or_unfinished_step_is_a_fail(self):
        self.assertEqual(self.read(self.job(exit_code=1))["result"], "fail")
        self.assertEqual(self.read(self.job(state="running", exit_code=None))["result"], "fail")

    def test_another_head_shard_or_script_is_not_borrowed(self):
        self.assertIsNone(self.read(self.job(ref="0" * 40)))
        self.assertIsNone(self.read(self.job(args=["test", "ui=OtherUITests", "video"])))
        self.assertIsNone(self.read(self.job(script="scripts/ci/other.sh")))
        self.assertIsNone(self.read(mock.Mock(returncode=1, stdout="")))


class Plan(unittest.TestCase):
    def test_simulator_dispatch_identity(self):
        from unittest import mock

        step = {"name": "pair", "mode": "pair-e2e", "worker": "cmux22", "args": ["pair-e2e"]}

        def dispatch(head=HEAD, strict=False, attempt="1", **changes):
            with mock.patch.object(ios_verify, "stream", return_value=(0, "")) as run:
                ios_verify.run_step({**step, **changes}, head, 7, strict, attempt)
            cmd = run.call_args.args[0]
            return cmd[cmd.index("--key") + 1]

        with mock.patch.object(ios_verify.time, "time", return_value=1):
            key = dispatch()
        with mock.patch.object(ios_verify.time, "time", return_value=2):
            self.assertEqual(key, dispatch())
        self.assertNotEqual(key, dispatch(head=HEAD[:-1] + "b"))
        self.assertNotEqual(key, dispatch(args=["pair-e2e", "reconnect-drops=10,60"]))
        # The same work on another worker is one step (dedupes in the queue) unless the run is pinned strict.
        self.assertEqual(key, dispatch(worker="aws-m4pro-4"))
        self.assertNotEqual(dispatch(strict=True), dispatch(strict=True, worker="cmux23"))
        self.assertNotEqual(key, dispatch(strict=True))
        self.assertNotEqual(key, dispatch(attempt="2"))
        self.assertEqual(dispatch(attempt="2"), dispatch(attempt="2"))

    def test_a_leased_worker_falls_to_the_next_placement(self):
        refusal = ("refused: fleet registry reservation lease-abc holds this worker for another account: nothing is "
                   "moved to or tested on it; omit target_worker so the job places on the rest of the fleet")
        step = {"name": "sim 1/2: test only=K1", "mode": "test", "worker": "w1", "args": ["test"]}

        def run(outputs, strict=False, leased=None, workers=("w1", "w2")):
            with mock.patch.object(ios_verify, "stream", side_effect=outputs) as s, \
                    mock.patch.object(ios_verify, "xcode_label", return_value=None):
                out = ios_verify.run_step(dict(step), HEAD, 7, strict, "1", list(workers), leased or set())
            cmds = [c.args[0] for c in s.call_args_list]
            pins = [c[c.index("--target-worker") + 1] if "--target-worker" in c else None for c in cmds]
            return out, pins, [c[c.index("--key") + 1] for c in cmds]

        # Refused for a lease: the next named worker, then unpinned placement; each retry gets its own key.
        out, pins, keys = run([(1, refusal), (1, refusal), (0, "ok")])
        self.assertEqual(pins, ["w1", "w2", None])
        self.assertEqual(len(set(keys)), 3)
        self.assertEqual((out["result"], out["worker"], out["refused_workers"]), ("pass", None, ["w1", "w2"]))
        self.assertNotIn("refused_workers", ios_verify.public_runs([out])[0])
        # A lease read up front skips the worker without a refused submission.
        _, pins, _ = run([(0, "ok")], leased={"w1"})
        self.assertEqual(pins, ["w2"])
        # Any other failure is the PR's result, not a reason to move.
        out, pins, _ = run([(1, "test failed: K1")])
        self.assertEqual((pins, out["result"]), (["w1"], "fail"))
        # --pin-strict never falls back off its worker.
        out, pins, _ = run([(1, refusal)], strict=True, leased={"w1"})
        self.assertEqual((pins, out["result"]), (["w1"], "fail"))

    def test_leased_hosts_reads_the_active_leases(self):
        done = mock.Mock(returncode=0, stdout=json.dumps(
            {"leases": [{"hosts": ["w1.tail", "w2"]}, {"hosts": None}], "view": "active"}))
        with mock.patch.object(ios_verify.subprocess, "run", return_value=done):
            self.assertEqual(ios_verify.leased_hosts(), {"w1", "w2"})
        with mock.patch.object(ios_verify.subprocess, "run", side_effect=OSError("no cmux-ci")):
            self.assertEqual(ios_verify.leased_hosts(), set())
        with mock.patch.object(ios_verify.subprocess, "run", return_value=mock.Mock(returncode=1, stdout="")):
            self.assertEqual(ios_verify.leased_hosts(), set())

    def selection(self, **kw):
        base = {"ios": True, "compile": False, "flows": ["smoke-launch-sign-in"], "kit": ["K1", "K2"],
                "ui": ["U1", "U2", "U3"], "swift": [], "scripts": []}
        base.update(kw)
        return base

    def test_step_keys_name_the_head_and_the_shard(self):
        steps = ios_verify.plan(self.selection(), [], ["cmux22"], "always")
        keys = [ios_verify.step_key(s, HEAD, 7) for s in steps]
        self.assertEqual(len(keys), len(set(keys)))
        moved = [ios_verify.step_key(s, OTHER, 7) for s in steps]
        self.assertFalse(set(keys) & set(moved))
        self.assertTrue(all(HEAD[:12] in k for k in keys))
        # A newer head's key differs only in its head field, so cmux-ci's supersede (commits aside) replaces
        # the older queued step instead of queueing both.
        self.assertEqual([k.replace(HEAD, "") for k in keys], [k.replace(OTHER, "") for k in moved])

    def test_shards_across_workers_with_video(self):
        steps = ios_verify.plan(self.selection(), [], ["cmux22", "cmux23"], "auto")
        self.assertEqual([s["worker"] for s in steps], ["cmux22", "cmux23"])
        self.assertTrue(all(s["args"][0] == "test" and s["args"][-1] == "video" for s in steps))
        joined = " ".join(" ".join(s["args"]) for s in steps)
        for t in ("K1", "K2", "U1", "U2", "U3"):
            self.assertIn(t, joined)

    def test_default_shards_and_pair_let_the_fleet_choose_workers(self):
        # A default host hint hit a reservation and refused the proof before entering the queue.
        steps = ios_verify.plan(self.selection(), [], ios_verify.workers_from(""), "always")
        explicit = ios_verify.plan(self.selection(), [], ["cmux22", "cmux23"], "always")
        self.assertEqual([s["args"] for s in steps], [s["args"] for s in explicit])
        self.assertEqual(len(steps), 3)
        keys = []
        for step in steps:
            with mock.patch.object(ios_verify, "stream", return_value=(0, "step abc12345")) as run:
                receipt = ios_verify.run_step(step, HEAD, 7, False)
            cmd = run.call_args.args[0]
            self.assertNotIn("--target-worker", cmd)
            self.assertNotIn("--pin-strict", cmd)
            self.assertEqual(receipt["step"], "abc12345")
            key = cmd[cmd.index("--key") + 1]
            self.assertEqual(key, ios_verify.step_key(step, HEAD, 7))
            self.assertNotEqual(key, ios_verify.step_key(step, OTHER, 7))
            keys.append(key)
        self.assertEqual(len(set(keys)), len(keys))

    def test_explicit_worker_hint_and_strict_pin_reach_dispatch(self):
        step = {"name": "sim 1/1", "mode": "test", "args": ["test"], "worker": "cmux23"}
        for strict in (False, True):
            with self.subTest(strict=strict):
                with mock.patch.object(ios_verify, "stream", return_value=(0, "")) as run:
                    ios_verify.run_step(step, HEAD, 7, strict)
                cmd = run.call_args.args[0]
                self.assertEqual(cmd[cmd.index("--target-worker") + 1], "cmux23")
                self.assertEqual("--pin-strict" in cmd, strict)

    def test_cli_worker_defaults_environment_and_override(self):
        for env, args, expected in (({}, [], ""),
                                    ({"CMUX_IOS_VERIFY_WORKERS": "cmux23"}, [], "cmux23"),
                                    ({"CMUX_IOS_VERIFY_WORKERS": "cmux23"},
                                     ["--workers", "cmux22"], "cmux22")):
            with self.subTest(env=env, args=args), \
                    mock.patch.dict(ios_verify.os.environ, env, clear=True), \
                    mock.patch.object(ios_verify, "workers_from", wraps=ios_verify.workers_from) as workers, \
                    mock.patch.object(ios_verify, "pr_view", side_effect=RuntimeError("stop before GitHub")):
                with self.assertRaisesRegex(RuntimeError, "stop before GitHub"):
                    ios_verify.main(args)
                workers.assert_called_once_with(expected)

    def test_strict_pin_without_workers_stops_before_github(self):
        with mock.patch.dict(ios_verify.os.environ, {}, clear=True), \
                mock.patch.object(ios_verify, "pr_view") as view, \
                mock.patch("sys.stderr"):
            with self.assertRaises(SystemExit) as raised:
                ios_verify.main(["--pin-strict"])
        self.assertEqual(raised.exception.code, 2)
        view.assert_not_called()

    def test_pair_e2e_follows_the_flows(self):
        flows = [{"id": "pairing", "pair_e2e": True}]
        sel = self.selection(flows=["pairing"])
        self.assertEqual(ios_verify.plan(sel, flows, ["cmux23"], "auto")[-1]["mode"], "pair-e2e")
        self.assertNotIn("pair-e2e", [s["mode"] for s in ios_verify.plan(sel, flows, ["cmux23"], "never")])
        self.assertNotIn("pair-e2e", [s["mode"] for s in ios_verify.plan(self.selection(), flows, ["cmux23"], "auto")])

    def test_selected_pair_is_dispatched_once_and_respects_never(self):
        flows = [{"id": "pairing", "pair_e2e": True}]
        for workers in ([], ["cmux23"]):
            for words in ([], ["reconnect-drops=10,60"]):
                sel = self.selection(flows=["pairing"], pair=True, pair_e2e=words)
                for policy in ("auto", "always", "never"):
                    with self.subTest(workers=workers, words=words, policy=policy):
                        steps = ios_verify.plan(sel, flows, workers, policy)
                        pairs = [s for s in steps if s["mode"] == "pair-e2e"]
                        self.assertEqual(len(pairs), 0 if policy == "never" else 1)
                        if pairs:
                            self.assertEqual(pairs[0]["args"], ["pair-e2e", *words])
                            self.assertEqual(pairs[0]["worker"], workers[0] if workers else None)

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
        self.assertEqual(ios_verify.visual(caps, {"source": "nightly"}, None)["baseline_source"], "nightly")
        self.assertEqual(ios_verify.visual(caps, None, None)["baseline_source"], "none")

    def test_posted_proof_names_no_worker(self):
        # cmux#61688: public-body-guard refused the proof comment for naming the fleet hosts its shards ran on.
        runs = [{"name": "sim 1/2", "mode": "test", "worker": "cmux22", "step": "abc12345", "result": "pass",
                 "seconds": 140, "tail": "ran on cmux22"},
                {"name": "script: x", "mode": "script", "worker": "gcp-agent-lane-2", "result": "pass"}]
        rec = dict(RECORD, runs=ios_verify.public_runs(runs), timing={"push_to_proof_s": 212})
        body = pr.render(rec, ios_verify.summary_md(rec))
        for host in ("cmux22", "gcp-agent-lane-2"):
            self.assertNotIn(host, body)
        self.assertEqual(rec["runs"][0]["step"], "abc12345")
        self.assertEqual(pr.problems(rec), [])

    def test_posted_body_scrubs_every_host_it_knows(self):
        # #57488, #57672: a host in any field (a tail, a note, a script name) still got the proof refused.
        rec = dict(RECORD, runs=[{"name": "script: x on huge-blue", "result": "pass", "step": "abc12345",
                                  "note": "moved off cmux22 to aws-m4pro-7.local"}], timing={"push_to_proof_s": 212})
        body = ios_verify.scrub_hosts(pr.render(rec, ios_verify.summary_md(rec)),
                                      ["cmux22", "huge-blue", "aws-m4pro-7.local", "cmux2"])
        for host in ("cmux22", "huge-blue", "aws-m4pro-7"):
            self.assertNotIn(host, body)
        got = pr.parse(body)
        self.assertEqual(got["runs"][0]["note"], "moved off a fleet worker to a fleet worker")
        self.assertEqual((got["head_sha"], got["repo"], got["verdict"]), (HEAD, "manaflow-ai/cmux", "pass"))
        self.assertEqual(pr.problems(got), [])

    def test_a_base_merge_that_changes_the_loop_runs_the_merged_loop(self):
        # cmux#57582: its head predated #62103, so the loop it ran still posted the worker, and public-body-guard
        # refused the comment ("this text names fleet host 'cmux22'"). Merging the base brought the fix onto disk
        # only; the loop now re-executes the merged copy, pinned to the merged head, before it verifies or posts.
        from unittest import mock

        class Exec(Exception):
            pass

        view = {"number": 7, "url": "https://github.com/o/r/pull/7", "baseRefName": "feat-cmux-next",
                "headRefOid": OTHER}
        merged_loop = {f: b"merged" for f in ios_verify.TOOL}
        with mock.patch.object(ios_verify, "pr_view", return_value=view), \
                mock.patch.object(ios_verify, "merge_base_first", return_value=(HEAD, True)), \
                mock.patch.object(ios_verify, "TOOL_LOADED", merged_loop), \
                mock.patch.dict(ios_verify.os.environ, {}, clear=False), \
                mock.patch.object(ios_verify.os, "execve", side_effect=Exec) as execve:
            ios_verify.os.environ.pop(ios_verify.REEXEC_HEAD, None)
            with self.assertRaises(Exec):
                ios_verify.main(["--pr", "7", "--workers", "cmux22"])
        exe, args, env = execve.call_args.args
        self.assertEqual(args[1:], ["-I", str(ios_verify.HERE / "ios_verify.py"), "--pr", "7", "--workers", "cmux22"])
        self.assertEqual(env[ios_verify.REEXEC_HEAD], HEAD)

        # The merged loop takes the merged head as given: it neither merges again nor re-executes again.
        with mock.patch.object(ios_verify, "pr_view", return_value=view), \
                mock.patch.object(ios_verify, "merge_base_first") as merge, \
                mock.patch.dict(ios_verify.os.environ, {ios_verify.REEXEC_HEAD: HEAD}), \
                mock.patch.object(ios_verify, "git", side_effect=Exec) as git:
            with self.assertRaises(Exec):
                ios_verify.main(["--pr", "7", "--workers", "cmux22"])
        merge.assert_not_called()
        self.assertEqual(git.call_args.args, ("merge-base", "origin/feat-cmux-next", HEAD))

        # An unchanged loop goes on in this process.
        self.assertFalse(ios_verify.tool_changed())

    def test_baseline_prefers_a_proof_in_the_nightly(self):
        rec = dict(RECORD, runs=[dict(RECORD["runs"][0], mode="test")])
        body = pr.render(rec)
        merges = {1: "m1", 2: "m2"}
        saved = (ios_verify.nightly_sha, ios_verify.search_prs, ios_verify.gh_json, ios_verify.in_nightly,
                 ios_verify.fetch)
        try:
            ios_verify.nightly_sha = lambda: "n" * 40
            ios_verify.search_prs = lambda repo, q: [{"number": 1}, {"number": 2}]
            ios_verify.gh_json = lambda *a: ({"merge_commit_sha": merges[int(a[1].rsplit("/", 1)[1])]}
                                             if "/pulls/" in a[1] else [comment(body, login="x")])
            ios_verify.in_nightly = lambda sha, n: sha == "m2"
            ios_verify.fetch = lambda step, into: [pathlib.Path("a.png")]
            meta, shots = ios_verify.baseline("o/r", "feat-cmux-next", pathlib.Path("/nonexistent"))
            self.assertEqual((meta["pr"], meta["source"]), (2, "nightly"))
            ios_verify.in_nightly = lambda sha, n: False
            meta, _ = ios_verify.baseline("o/r", "feat-cmux-next", pathlib.Path("/nonexistent"))
            self.assertEqual((meta["pr"], meta["source"]), (1, "merged"))
        finally:
            (ios_verify.nightly_sha, ios_verify.search_prs, ios_verify.gh_json, ios_verify.in_nightly,
             ios_verify.fetch) = saved


class VisualDiff(unittest.TestCase):
    URL = "https://github.com/manaflow-ai/cmux/pull/7#issuecomment-123"

    def record(self):
        rec = copy.deepcopy(RECORD)
        rec["baseline"] = {"source": "nightly", "nightly_sha": OTHER}
        rec["captures"] = [{"name": "a.png", "verdict": "same", "diff_ratio": 0.0},
                           {"name": "b.png", "verdict": "changed", "diff_ratio": 0.5}]
        return rec

    def test_measured_changed_and_unchanged(self):
        line = ios_verify.visual_diff_line(self.record(), self.URL)
        self.assertIn("1 changed, 1 unchanged", line)
        self.assertIn(self.URL, line)
        self.assertIn(HEAD, line)

    def test_unproved_runs_never_claim_a_visual_diff(self):
        cases = []
        for source in ("merged", "none"):
            rec = self.record()
            rec["baseline"]["source"] = source
            cases.append(rec)
        for captures in ([], [{"name": "x", "verdict": "same"}],
                         [{"name": "x", "verdict": "changed", "diff_ratio": None}],
                         [{"name": "x", "verdict": "unbaselined"}],
                         [{"name": "x", "verdict": "new"}],
                         [{"name": "x", "verdict": "missing"}]):
            rec = self.record()
            rec["captures"] = captures
            cases.append(rec)
        rec = self.record()
        rec["verdict"] = "fail"
        cases.append(rec)
        rec = self.record()
        rec["runs"][0]["result"] = "fail"
        cases.append(rec)
        for rec in cases:
            with self.subTest(record=rec):
                self.assertIsNone(ios_verify.visual_diff_line(rec, self.URL))
        self.assertIsNone(ios_verify.visual_diff_line(self.record(), None))

    def test_preserves_user_text_and_footer_and_is_idempotent(self):
        body = "\nUser text\nVisual-diff: hand-written evidence\n\nAgent-Session: footer\n"
        line = ios_verify.visual_diff_line(self.record(), self.URL)
        updated = ios_verify.visual_diff_body(body, line)
        self.assertTrue(updated.endswith(body))
        self.assertEqual(ios_verify.visual_diff_body(updated, line), updated)
        self.assertEqual(ios_verify.visual_diff_body(updated, None), body)

    def test_head_move_before_comment_has_no_effects(self):
        from unittest import mock
        with mock.patch.object(ios_verify, "pr_view", return_value={"headRefOid": OTHER}), \
                mock.patch.object(ios_verify, "sh") as run:
            self.assertFalse(ios_verify.post_proof("manaflow-ai/cmux", 7, HEAD, self.record(), "proof", pathlib.Path("/unused")))
            run.assert_not_called()

    def test_post_reads_fresh_body_and_removes_stale_claim_on_failure(self):
        from unittest import mock
        import tempfile
        user_body = "Body edited during verification\n\nAgent-Session: footer\n"
        old = ios_verify.visual_diff_body(user_body, "Visual-diff: stale")
        for failed in (False, True):
            rec = self.record()
            if failed:
                rec["verdict"] = "fail"
            views = [{"headRefOid": HEAD, "body": "outdated"},
                     {"headRefOid": HEAD, "body": old}]
            calls = []
            def run(*args):
                calls.append(args)
                if args[2] == "comment":
                    return self.URL + "\n"
                self.assertEqual(args[2], "edit")
                got = pathlib.Path(args[-1]).read_text()
                self.assertTrue(got.endswith(user_body))
                self.assertEqual(ios_verify.VISUAL_DIFF_START in got, not failed)
                return ""
            with tempfile.TemporaryDirectory() as temp, \
                    mock.patch.object(ios_verify, "pr_view", side_effect=views), \
                    mock.patch.object(ios_verify, "sh", side_effect=run):
                self.assertTrue(ios_verify.post_proof("manaflow-ai/cmux", 7, HEAD, rec, "proof", pathlib.Path(temp)))
                self.assertEqual(len(calls), 2)

    def test_head_move_after_comment_does_not_edit_body(self):
        from unittest import mock
        import tempfile
        with tempfile.TemporaryDirectory() as temp, \
                mock.patch.object(ios_verify, "pr_view", side_effect=[{"headRefOid": HEAD}, {"headRefOid": OTHER}]), \
                mock.patch.object(ios_verify, "sh", return_value=self.URL) as run:
            self.assertFalse(ios_verify.post_proof("manaflow-ai/cmux", 7, HEAD, self.record(), "proof", pathlib.Path(temp)))
            self.assertEqual(run.call_count, 1)


class Launcher(unittest.TestCase):
    def test_cmux_ios_verify_runs_this_script(self):
        dev = (ROOT / "cmux-tui/crates/cmux-tui/src/cli/dev.rs").read_text()
        self.assertRegex(dev, r'words: \["ios", "verify"\]')
        sh = (ROOT / "scripts/ci/ios-verify.sh").read_text()
        self.assertTrue(re.search(r"scripts/ci/ios_verify\.py", sh))


class TokenFallbackTest(unittest.TestCase):
    """Before -> after on PR 45147 (2026-11-27): the run's github.token 403'd on every call, the gate read with it
    alone and posted `UI proof not read (HTTPError)` on every rerun. After: the pool token reads it."""

    @staticmethod
    def refused(code: int):
        import urllib.error
        return urllib.error.HTTPError("https://api.github.com/x", code, "refused", {}, None)

    def test_a_refused_token_falls_back_to_the_next(self) -> None:
        seen = []

        def read(token: str) -> str:
            seen.append(token)
            if token == "run":
                raise self.refused(403)
            return f"read with {token}"

        self.assertEqual(pr.with_tokens(read, ["run", "pool1", "pool2"]), "read with pool1")
        self.assertEqual(seen, ["run", "pool1"])

    def test_a_rate_limited_token_moves_on_without_waiting_it_out(self) -> None:
        # Before -> after on cmux job 140783003633 (2026-11-27 23:21Z): the run token's comments read got a
        # rate-limit 403, gh_http slept 900 s in a 5-min job, and the job was cancelled unposted. After: the
        # pool token reads it at once; only the last token may wait, and no longer than RATE_WAIT_LAST_S.
        import functools
        http = pr.gh_http.deadline_http
        limited = (403, b'{"message":"API rate limit exceeded for installation"}',
                   http.Headers({"x-ratelimit-remaining": "0", "x-ratelimit-reset": "1900"}))
        ok = (200, json.dumps([comment("x")]).encode(), http.Headers({}))
        seen, slept = [], []

        def fake(req, seconds, **kwargs):
            token = req.get_header("Authorization").split()[-1]
            seen.append(token)
            return limited if token == "run" else ok

        retrying = functools.partial(pr.gh_http.request, sleep=slept.append, now=lambda: 1000.0,
                                     log=lambda line: None)
        with mock.patch.object(http, "request", side_effect=fake), mock.patch.object(pr.gh_http, "request", retrying):
            got = pr.with_tokens(lambda token: pr.pr_comments("o/r", 7, token), ["run", "pool1"])
        self.assertEqual([c["body"] for c in got], ["x"])
        self.assertEqual(seen, ["run", "pool1"])
        self.assertEqual(slept, [])
        # The last token: a limit ending past the bound is not slept on either.
        seen.clear()
        with mock.patch.object(http, "request", side_effect=fake), mock.patch.object(pr.gh_http, "request", retrying):
            with self.assertRaises(pr.urllib.error.HTTPError):
                pr.with_tokens(lambda token: pr.pr_comments("o/r", 7, token), ["run"])
        self.assertEqual(slept, [])
        self.assertEqual(pr._rate_wait_s.get(), pr.RATE_WAIT_LAST_S)

    def test_the_last_refusal_and_other_errors_raise(self) -> None:
        import urllib.error

        def always(token: str):
            raise self.refused(403)

        with self.assertRaises(urllib.error.HTTPError) as got:
            pr.with_tokens(always, ["a", "b"])
        self.assertEqual(pr.read_error(got.exception), "HTTPError 403")
        tried = []

        def missing(token: str):
            tried.append(token)
            raise self.refused(404)

        # A 404 is the read's answer, not the token's: no other token changes it.
        with self.assertRaises(urllib.error.HTTPError):
            pr.with_tokens(missing, ["a", "b"])
        self.assertEqual(tried, ["a"])
        with self.assertRaises(ValueError):
            pr.with_tokens(missing, [])

    def test_read_tokens_puts_gh_token_first_then_the_pool_once_each(self) -> None:
        import os
        from unittest import mock
        with mock.patch.dict(os.environ, {"GH_TOKEN": "run", "TOKENS": "run pool1  pool2"}, clear=False):
            self.assertEqual(pr.read_tokens(), ["run", "pool1", "pool2"])
        with mock.patch.dict(os.environ, {"GH_TOKEN": "", "GITHUB_TOKEN": "", "TOKENS": ""}, clear=False):
            self.assertEqual(pr.read_tokens(), [])


class SimStepRoutingTest(unittest.TestCase):
    """cmux#38805, 11-27: a step pinned to cmux22 moved to a simulator host with no Xcode 27.2 (exit 3), and the
    strict rerun at the same head was refused, its key already naming that step (HTTP 409)."""

    def test_label_is_newest_macos_pin(self):
        tmp = pathlib.Path(tempfile.mkdtemp()) / "xcode-pins.txt"
        tmp.write_text("# macOS  Xcode\n15       26.3\n26       27.2\n27       27.3  # newest\n")
        self.assertEqual(ios_verify.xcode_label(tmp), "xcode-27.3")
        self.assertIsNone(ios_verify.xcode_label(tmp.with_name("missing.txt")))
        self.assertRegex(ios_verify.xcode_label() or "", r"^xcode-\d+\.\d+$")

    def test_run_step_asks_for_the_xcode_label(self):
        seen = {}

        def fake_stream(cmd, tag):
            seen["cmd"] = cmd
            return 0, "step: abcdef123456"

        real = ios_verify.stream
        ios_verify.stream = fake_stream
        try:
            ios_verify.run_step({"name": "sim 1/1", "mode": "test", "worker": "cmux22", "args": ["test"]}, HEAD, 7, True)
        finally:
            ios_verify.stream = real
        cmd = seen["cmd"]
        self.assertEqual(cmd[cmd.index("--label") + 1], ios_verify.xcode_label())
        self.assertIn("--pin-strict", cmd)

    def test_stream_echoes_lines_and_returns_output(self):
        import io
        err, real = io.StringIO(), ios_verify.sys.stderr
        ios_verify.sys.stderr = err
        try:
            code, text = ios_verify.stream([sys.executable, "-c", "print('queued'); print('step: abc'); raise SystemExit(3)"], "sim 1/1")
        finally:
            ios_verify.sys.stderr = real
        self.assertEqual(code, 3)
        self.assertEqual(text, "queued\nstep: abc\n")
        self.assertIn("[sim 1/1] queued\n", err.getvalue())

    def test_key_names_head_and_pin_mode(self):
        step = {"mode": "test", "worker": "cmux22", "name": "sim 1/1: test", "args": ["test"]}
        loose, strict = ios_verify.step_key(step, HEAD, 7, False), ios_verify.step_key(step, HEAD, 7, True)
        self.assertNotEqual(loose, strict)
        self.assertNotEqual(loose, ios_verify.step_key(step, OTHER, 7, False))
        self.assertIn(HEAD[:12], loose)


class SeededRegression(unittest.TestCase):
    """A seeded visual regression (a bar painted over 5% of a screen) fails the proof unless the PR body justifies it;
    no baseline, a size change and a change under 1% never fail."""

    @staticmethod
    def png(path, w, h, bar=False):
        """An RGB PNG, stdlib only: a dark screen, with a blue bar over rows 40-49 when BAR (5% of 100x200)."""
        import struct
        import zlib
        dark, blue = bytes((20, 20, 24)), bytes((40, 120, 255))
        raw = b"".join(b"\0" + (blue if bar and 40 <= y < 50 else dark) * w for y in range(h))
        chunk = lambda t, d: struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d))
        path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
                         + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))

    def setUp(self):
        import tempfile
        self.dir = pathlib.Path(tempfile.mkdtemp())
        (self.dir / "base" / "terminal").mkdir(parents=True)
        (self.dir / "head" / "terminal").mkdir(parents=True)
        self.base = self.dir / "base" / "terminal" / "attach.png"
        self.head = self.dir / "head" / "terminal" / "attach.png"
        self.png(self.base, 100, 200)
        self.png(self.head, 100, 200, bar=True)  # the seeded regression

    def run_compare(self, body="", base=True):
        caps = ios_verify.compare([self.head], {"attach.png": self.base} if base else {}, body)
        return caps, ios_verify.verdict([{"name": "sim", "result": "pass"}], caps)

    def test_unjustified_change_fails(self):
        caps, v = self.run_compare()
        self.assertEqual(v, "fail")
        self.assertEqual(ios_verify.unjustified(caps), ["attach.png"])
        self.assertEqual(caps[0]["verdict"], "changed")
        self.assertEqual(pr.problems({**RECORD, "captures": caps}), [])

    def test_justified_change_passes(self):
        for line in ("Visual-change: attach.png: new bar", "Visual-change: terminal/*: bar", "Visual-change: *: all"):
            caps, v = self.run_compare(f"Summary\n\n{line}\n")
            self.assertEqual(v, "pass", line)
            self.assertTrue(caps[0]["why"])

    def test_fenced_example_justifies_nothing(self):
        self.assertEqual(self.run_compare("```\nVisual-change: *: example\n```")[1], "fail")

    def test_no_baseline_passes(self):
        caps, v = self.run_compare(base=False)
        self.assertEqual((v, caps[0]["verdict"]), ("pass", "unbaselined"))

    def test_same_and_size_change_pass(self):
        self.png(self.head, 100, 200)
        caps, v = self.run_compare()
        self.assertEqual((v, caps[0]["verdict"]), ("pass", "same"))
        self.png(self.head, 120, 200, bar=True)  # another device: not comparable, not judged
        self.assertEqual(self.run_compare()[1], "pass")

    def test_stdlib_decoder_agrees(self):
        import builtins
        real = builtins.__import__
        no_pil = lambda name, *a, **k: (_ for _ in ()).throw(ImportError(name)) if name == "PIL" else real(name, *a, **k)
        with mock.patch.object(builtins, "__import__", no_pil):
            self.assertEqual(ios_verify.diff_ratio(self.head, self.base), 0.05)
            self.assertEqual(self.run_compare()[1], "fail")

    def test_a_failed_run_still_fails(self):
        self.assertEqual(ios_verify.verdict([{"name": "sim", "result": "error"}], []), "fail")


if __name__ == "__main__":
    unittest.main()
