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


class Plan(unittest.TestCase):
    def test_simulator_dispatch_identity(self):
        from unittest import mock

        step = {"name": "pair", "mode": "pair-e2e", "worker": "cmux22", "args": ["pair-e2e"]}

        def dispatch(head=HEAD, strict=False, attempt="1", **changes):
            result = ios_verify.subprocess.CompletedProcess([], 0, stdout="", stderr="")
            with mock.patch.object(ios_verify.subprocess, "run", return_value=result) as run:
                ios_verify.run_step({**step, **changes}, head, 7, strict, attempt)
            cmd = run.call_args.args[0]
            return cmd[cmd.index("--key") + 1]

        with mock.patch.object(ios_verify.time, "time", return_value=1):
            key = dispatch()
        with mock.patch.object(ios_verify.time, "time", return_value=2):
            self.assertEqual(key, dispatch())
        self.assertNotEqual(key, dispatch(head=HEAD[:-1] + "b"))
        self.assertNotEqual(key, dispatch(args=["pair-e2e", "reconnect-drops=10,60"]))
        self.assertNotEqual(key, dispatch(worker="cmux23"))
        self.assertNotEqual(key, dispatch(strict=True))
        self.assertNotEqual(key, dispatch(attempt="2"))
        self.assertEqual(dispatch(attempt="2"), dispatch(attempt="2"))

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
