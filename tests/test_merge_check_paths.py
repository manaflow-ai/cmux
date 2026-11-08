"""scripts/ci/merge_check_paths.py against a fake GitHub: no network, no sleeping.

The check-path gate gh-merge-green applies into feat-cmux-next: a pull request whose fast gates ran before a check
path changed on the base is rerun against the current tip before it merges (2026-10-21: #22967, #22975 and #23094
merged after #23365 added check:fixed-waits and turned it red on the base).
"""
import contextlib
import importlib.util
import io
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("merge_check_paths", ROOT / "scripts/ci/merge_check_paths.py")
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)
HEAD, OLD, TIP, NEWER = "a" * 40, "b" * 40, "c" * 40, "e" * 40
CHECK_PATHS = ("# a sample of the base's scripts/ci/check-paths.txt\n\nscripts/check-*\nwebviews/scripts/check-*\n"
               "webviews/scripts/*baseline*\nwebviews/package.json\n.github/workflows/ci-web.yml\n")
# #23365's files, which the base changed after #22975's fast gates ran, and #22975's own.
FILES_23365 = [".github/workflows/ci-web.yml", "webviews/package.json", "webviews/scripts/check-fixed-waits.ts",
               "webviews/scripts/fixed-waits-baseline.tsv", "webviews/test/check-fixed-waits.test.ts",
               "webviews/test/support/pageSwitch.ts"]
FILES_22975 = ["Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/AcpmuxPaneMethods+Params.swift",
               "cmux-tui/crates/cmux-agent-pane-policy/policy.json", "webviews/src/agent-session/acpmux/App.tsx",
               "webviews/src/agent-session/acpmux/ComposerQueue.tsx", "webviews/src/agent-session/acpmux/QueuedImages.tsx"]


def status(base, state="success", at="2026-10-21T13:00:00Z"):
    return {"context": gate.CONTEXT, "state": state, "description": f"base {base}", "updated_at": at,
            "target_url": "https://github.com/manaflow-ai/cmux/actions/runs/1"}


class FakeApi:
    def __init__(self, statuses, tips=(TIP,), compares=None, check_paths=CHECK_PATHS):
        self.statuses, self.tips, self.compares, self.text = list(statuses), list(tips), compares or {}, check_paths
        self.dispatched, self.reads = [], 0

    def check_paths(self, branch):
        if isinstance(self.text, Exception):
            raise self.text
        return self.text

    def status(self, sha):
        self.reads += 1
        return self.statuses.pop(0) if len(self.statuses) > 1 else self.statuses[0]

    def tip(self, branch):
        return self.tips.pop(0) if len(self.tips) > 1 else self.tips[0]

    def compare(self, base, tip):
        return self.compares.get((base, tip)) or {"status": "diverged", "ahead_by": 0, "files": []}

    def dispatch(self, number, branch):
        self.dispatched.append((number, branch))


class Clock:
    def __init__(self):
        self.now = 0.0

    def __call__(self):
        return self.now

    def sleep(self, seconds):
        self.now += seconds


def run(api, timeout=900, check_only=False):
    clock = Clock()
    stderr = io.StringIO()
    with contextlib.redirect_stderr(stderr):
        result = gate.gate(api, "42", HEAD, gate.BRANCH, timeout, 20, clock, clock.sleep, check_only=check_only)
    return result, stderr.getvalue()


class CheckPathGate(unittest.TestCase):
    def test_replay_of_22975_a_check_that_landed_since_reruns_the_fast_gates_before_the_merge(self):
        # Its fast gates ran at OLD; the base then changed #23365's files, none of them #22975's own. The gate
        # dispatches the fast gates against the tip and merges only on their fresh success.
        landed = {(OLD, TIP): {"status": "ahead", "ahead_by": 1, "files": FILES_23365}}
        api = FakeApi([status(OLD), status(OLD), status(TIP, at="2026-10-21T14:12:00Z")], compares=landed)
        (checked, waited), err = run(api)
        self.assertEqual(api.dispatched, [("42", "feat-cmux-next")])
        self.assertIn("has changed the check path .github/workflows/ci-web.yml since", err)
        self.assertEqual(checked, "check paths (fast gates rerun on the current tip)")
        self.assertEqual(waited, 40)

    def test_replay_of_22975_the_rerun_red_refuses(self):
        # On the tip, the webviews checks fail #22975 for its own new fixed wait.
        landed = {(OLD, TIP): {"status": "ahead", "ahead_by": 1, "files": FILES_23365}}
        api = FakeApi([status(OLD), status(TIP, state="failure", at="2026-10-21T14:12:00Z")], compares=landed)
        with self.assertRaisesRegex(gate.Refused, "cmux-next/fast-gates is failure on the pull request merged with "
                                                  "the current tip.*actions/runs/1"):
            run(api)

    def test_fresh_needs_no_dispatch(self):
        api = FakeApi([status(TIP)])
        self.assertEqual(run(api)[0], ("check paths fresh", 0.0))
        moved = {(OLD, TIP): {"status": "ahead", "ahead_by": 4, "files": FILES_22975[:2] + ["docs/ci.md"]}}
        api = FakeApi([status(OLD)], compares=moved)
        self.assertEqual(run(api)[0], ("check paths fresh", 0.0))
        self.assertEqual(api.dispatched, [])

    def test_stale_reasons_dispatch(self):
        cases = {
            "has not run on this head": (None, {}),
            "names no base": ({**status(OLD), "description": "something else"}, {}),
            "not an ancestor": (status(OLD), {(OLD, TIP): {"status": "diverged", "ahead_by": 2, "files": []}}),
            "commits behind": (status(OLD), {(OLD, TIP): {"status": "ahead", "ahead_by": 251, "files": []}}),
            "too many files": (status(OLD), {(OLD, TIP): {"status": "ahead", "ahead_by": 9,
                                                          "files": [f"f{i}" for i in range(300)]}}),
        }
        for why, (first, compares) in cases.items():
            with self.subTest(why):
                api = FakeApi([first, status(TIP, at="2026-10-21T14:12:00Z")], compares=compares)
                _, err = run(api)
                self.assertIn(why, err)
                self.assertEqual(len(api.dispatched), 1)

    def test_no_result_within_the_timeout_refuses(self):
        landed = {(OLD, TIP): {"status": "ahead", "ahead_by": 1, "files": FILES_23365}}
        api = FakeApi([status(OLD)], compares=landed)
        with self.assertRaisesRegex(gate.Refused, "posted no result within 120s"):
            run(api, timeout=120)

    def test_a_pending_or_unchanged_status_is_not_the_dispatched_result(self):
        landed = {(OLD, TIP): {"status": "ahead", "ahead_by": 1, "files": FILES_23365}}
        api = FakeApi([status(OLD), status(OLD), status(TIP, state="pending", at="2026-10-21T14:11:00Z"),
                       status(TIP, at="2026-10-21T14:12:00Z")], compares=landed)
        (_, waited), _ = run(api)
        self.assertEqual(waited, 60)

    def test_a_check_path_that_changed_again_during_the_wait_refuses(self):
        landed = {(OLD, TIP): {"status": "ahead", "ahead_by": 1, "files": FILES_23365},
                  (TIP, NEWER): {"status": "ahead", "ahead_by": 1, "files": ["scripts/check-pbxproj.sh"]}}
        api = FakeApi([status(OLD), status(TIP, at="2026-10-21T14:12:00Z")], tips=(TIP, NEWER), compares=landed)
        with self.assertRaisesRegex(gate.Refused, "after the dispatched run.*scripts/check-pbxproj.sh"):
            run(api)

    def test_check_only_dispatches_nothing(self):
        landed = {(OLD, TIP): {"status": "ahead", "ahead_by": 1, "files": FILES_23365}}
        api = FakeApi([status(OLD)], compares=landed)
        (checked, _), err = run(api, check_only=True)
        self.assertEqual(api.dispatched, [])
        self.assertIn("a merge would dispatch", err)
        self.assertIn("check only", checked)

    def test_no_list_on_the_base_yet_passes(self):
        api = FakeApi([status(OLD)], check_paths=None)
        (checked, _), err = run(api)
        self.assertIn("is not on feat-cmux-next", err)
        self.assertEqual(api.dispatched, [])

    def test_an_unreadable_list_refuses(self):
        api = FakeApi([status(OLD)], check_paths=gate.Refused("gh api repos/x failed: HTTP 502"))
        with self.assertRaises(gate.Refused):
            run(api)

    def test_patterns_and_hits(self):
        pats = gate.patterns(CHECK_PATHS)
        self.assertEqual(pats[0], "scripts/check-*")
        self.assertEqual(gate.hits(FILES_23365, pats), [".github/workflows/ci-web.yml", "webviews/package.json",
                                                         "webviews/scripts/check-fixed-waits.ts",
                                                         "webviews/scripts/fixed-waits-baseline.tsv"])
        self.assertEqual(gate.hits(FILES_22975, pats), [])

    def test_main_skips_other_bases_and_checks_its_arguments(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(gate.main(["manaflow-ai/cmux", "42", HEAD, "--base", "main"]), 0)
        self.assertIn("not feat-cmux-next", out.getvalue())
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(gate.main(["manaflow-ai/cmux", "42", "abc"]), 1)


if __name__ == "__main__":
    unittest.main()
