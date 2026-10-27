#!/usr/bin/env python3
"""capabilities.py (task 211): what a build can measure, and how Pinpoint and the scheduler treat a build that
cannot: not-measurable, never a regression.

  python3 -m unittest scripts/perf-lab/tests/test_capabilities.py
"""
from __future__ import annotations

import argparse
import importlib.util
import io
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

LAB = Path(__file__).resolve().parent.parent
REPO_ROOT = LAB.parents[1]


def _load(name: str, path: Path):
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


caps = _load("perf_lab_capabilities", LAB / "capabilities.py")
tpe = _load("perf_lab_test_pinpoint_exec", LAB / "tests" / "test_pinpoint_exec.py")
tsched = _load("perf_lab_test_scheduler", LAB / "tests" / "test_scheduler.py")
exe, pinpoint, scheduler = tpe.exe, tpe.pinpoint, tsched.scheduler

TURN_HISTOGRAM = "file:Packages/macOS/CmuxNext/Sources/CmuxNextControl/Diagnostics/MainTurnHistogram.swift"


def probe(**fields) -> dict:
    return {"schema": caps.SCHEMA, "methods": ["debug.capabilities", "debug.hangs"], "signposts": ["action.commit"],
            "environment": ["CMUX_NEXT_TYPING_PROBE"], **fields}


class ProbeTests(unittest.TestCase):
    def test_a_build_with_every_need_is_measurable(self) -> None:
        build = caps.Capabilities.from_probe(probe(), {"actionCommit": "action.commit"})
        needs = ("debug:debug.hangs", "signpost:action.commit", "signpost:actionCommit", "env:CMUX_NEXT_TYPING_PROBE",
                 "privilege:purge", TURN_HISTOGRAM)
        self.assertEqual(caps.missing(needs, build), ())

    def test_each_need_the_build_lacks_is_named_in_the_story_order(self) -> None:
        build = caps.Capabilities.from_probe(probe(), {})
        needs = ("env:CMUX_NEXT_TRACE_FLOWS", "debug:debug.hangs", "debug:debug.frames", "signpost:key.frame")
        self.assertEqual(caps.missing(needs, build),
                         ("env:CMUX_NEXT_TRACE_FLOWS", "debug:debug.frames", "signpost:key.frame"))

    def test_a_file_need_is_the_commits_not_the_probes(self) -> None:
        build = caps.Capabilities.from_probe(probe(), {})
        self.assertEqual(caps.missing([TURN_HISTOGRAM], build, has_file=lambda path: False), (TURN_HISTOGRAM,))

    def test_a_document_that_is_not_the_probe_is_refused(self) -> None:
        for document in ({"methods": []}, probe(schema="cmux-debug-capabilities/v0"), probe(methods="debug.hangs"),
                         probe(signposts=[1])):
            with self.assertRaises(caps.CapabilityError):
                caps.Capabilities.from_probe(document, {})

    def test_a_malformed_need_is_refused(self) -> None:
        build = caps.Capabilities.from_probe(probe(), {})
        for need in ("debug.hangs", "method:debug.hangs", "debug:"):
            with self.assertRaises(caps.CapabilityError):
                caps.missing([need], build)

    def test_the_swift_lists_parse(self) -> None:
        lists = caps.declared_lists((REPO_ROOT / caps.DEBUG_CAPABILITIES).read_text(encoding="utf-8"))
        self.assertIn("actionCommit", lists["emittedSignposts"])
        self.assertIn("scrollToFrame", lists["emittedSignposts"])
        self.assertNotIn("actionPresented", lists["emittedSignposts"])  # reserved: no emitter yet
        self.assertIn("CMUX_NEXT_TYPING_PROBE", lists["probeEnvironment"])
        cases = caps.tip_signpost_cases(REPO_ROOT)
        self.assertEqual(cases["scrollToFrame"], "key.scroll_frame")


class TreeTests(unittest.TestCase):
    def test_the_tree_claims_only_what_it_has_and_every_story_need_exists(self) -> None:
        self.assertEqual(caps.check_tree(REPO_ROOT), [])

    def test_an_emit_on_any_receiver_counts(self) -> None:
        swift = "stall.begin(.stallCreateSurface)\nTraceRuntime.shared.event(.webuiPreload, arg0: 1)\n" \
                "Signposter.action.interval(.actionCommit)\n// Signposter.action.begin(.actionGate)\n" \
                "case .motionFrame: \"motion.frame\"\n"
        self.assertEqual(caps.emitted_cases(swift), {"stallCreateSurface", "webuiPreload", "actionCommit"})


class GitTests(unittest.TestCase):
    """GitCapabilities on a real repository: a commit before DebugCapabilities.swift, and one with it."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = Path(self.tmp.name)
        self.git("init", "-q", "-b", "main")
        self.write(caps.SIGNPOST_NAME, 'switch self {\ncase .actionCommit: "action.commit"\n'
                                       'case .keyToFrame: "key.frame"\ncase .motionFrame: "motion.frame"\n}\n')
        self.write(f"{caps.SOURCES}/A/Hangs.swift",
                   '.snapshot("debug.hangs") { _ in }\nSignposter.action.begin(.actionCommit)\n'
                   'let probe = env["CMUX_NEXT_TYPING_PROBE"]\n')
        self.old = self.commit("before the probe")
        self.write(caps.DEBUG_CAPABILITIES,
                   'static let method = "debug.capabilities"\n'
                   'static let emittedSignposts: [SignpostName] = [\n    .actionCommit, .keyToFrame,\n]\n'
                   'static let probeEnvironment: [String] = [\n    "CMUX_NEXT_TYPING_PROBE",\n]\n')
        self.write(f"{caps.SOURCES}/A/Turn.swift", "struct MainTurnHistogram {}\n")
        self.new = self.commit("the probe")

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def git(self, *args: str) -> str:
        return subprocess.run(["git", "-C", str(self.repo), "-c", "user.name=t", "-c", "user.email=t@t", *args],
                              check=True, capture_output=True, text=True).stdout

    def write(self, rel: str, text: str) -> None:
        path = self.repo / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")

    def commit(self, message: str) -> str:
        self.git("add", "-A")
        self.git("commit", "-q", "-m", message)
        return self.git("rev-parse", "HEAD").strip()

    def test_a_commit_before_the_probe_is_read_from_its_sources(self) -> None:
        old = caps.GitCapabilities.of(self.repo).at(self.old)
        self.assertEqual(old.methods, {"debug.hangs"})
        self.assertEqual(old.signposts, {"action.commit"})  # the scan: keyToFrame has no emitter there
        self.assertEqual(old.environment, {"CMUX_NEXT_TYPING_PROBE"})

    def test_a_commit_with_the_probe_uses_its_own_lists(self) -> None:
        new = caps.GitCapabilities.of(self.repo).at(self.new)
        self.assertEqual(new.methods, {"debug.hangs", "debug.capabilities"})
        self.assertEqual(new.signposts, {"action.commit", "key.frame"})

    def test_missing_needs_per_commit_and_the_range_limit(self) -> None:
        commits = caps.GitCapabilities.of(self.repo)
        story = caps.StoryNeeds({"main-turn": ("debug:debug.hangs", f"file:{caps.SOURCES}/A/Turn.swift"),
                                 "free": ()}, commits)
        self.assertEqual(story("main-turn", self.old), (f"file:{caps.SOURCES}/A/Turn.swift",))
        self.assertEqual(story("main-turn", self.new), ())
        self.assertEqual(story("free", self.old), ())
        self.assertEqual(story("unknown", self.old), ())
        limits = caps.range_limits([self.old, self.new], story.needs("main-turn"), lambda s: story("main-turn", s))
        self.assertEqual(limits, [f"range limited by capability file:{caps.SOURCES}/A/Turn.swift since {self.new[:12]}"])

    def test_an_unknown_commit_is_an_error(self) -> None:
        with self.assertRaises(caps.CapabilityError):
            caps.GitCapabilities.of(self.repo).at("0" * 40)

    def test_the_command_prints_each_story(self) -> None:
        out, err = io.StringIO(), io.StringIO()
        args = argparse.Namespace(root=REPO_ROOT, repo=self.repo, check=False, sha=self.old, probe=None, range=None,
                                  stories="main-turn")
        code = caps.run("capabilities", args, out, err)
        self.assertEqual(code, 1, err.getvalue())
        self.assertIn("main-turn\tnot-measurable: lacks", out.getvalue())


class RangeTests(unittest.TestCase):
    SHAS = [f"{i:02x}" * 20 for i in range(9)]

    def lacks_before(self, index: int, need: str = "debug:debug.x"):
        calls = []

        def lacks(sha: str):
            calls.append(sha)
            return (need,) if self.SHAS.index(sha) < index else ()

        return lacks, calls

    def test_first_with_bisects_the_range(self) -> None:
        lacks, calls = self.lacks_before(5)
        self.assertEqual(caps.first_with(self.SHAS, "debug:debug.x", lacks), 5)
        self.assertLessEqual(len(calls), 5)

    def test_no_line_when_the_whole_range_has_it_and_a_line_when_none_does(self) -> None:
        lacks, _ = self.lacks_before(0)
        self.assertEqual(caps.range_limits(self.SHAS, ["debug:debug.x"], lacks), [])
        lacks, _ = self.lacks_before(99)
        self.assertEqual(caps.range_limits(self.SHAS, ["debug:debug.x"], lacks),
                         ["no commit in the range has capability debug:debug.x"])


class PinpointTests(tpe.Fixture):
    """A bisect across the commit that adds a story's need (task 031's MainTurnHistogram.swift at SHAS[5])."""

    ADDED = 5

    def lacks(self, story: str, sha: str):
        return (TURN_HISTOGRAM,) if tpe.SHAS.index(sha) < self.ADDED else ()

    def test_a_bisect_across_the_capability_reports_the_limit_and_finds_the_culprit(self) -> None:
        world = self.world()
        group_id = tpe.seed_lab(world)
        self.drive(world, self.executor(world, lacks=self.lacks))
        result = self.result(world)
        lacking = set(tpe.SHAS[:self.ADDED])
        self.assertIn(tpe.SHAS[tpe.CULPRIT], [c["change"]["sha"] for c in result["culprits"]])
        self.assertFalse([c for c in result["culprits"] if lacking & set(c["commits"])], "blamed a lacking commit")
        self.assertIn([tpe.SHAS[0], pinpoint.NOT_MEASURABLE], result["skipped"])
        limit = f"range limited by capability {TURN_HISTOGRAM} since {tpe.SHAS[self.ADDED][:12]}"
        self.assertEqual(result["range_limits"], [limit])
        reason = world.lab._db.execute("SELECT reason FROM sheriff_history WHERE group_id = ? ORDER BY id DESC",
                                       (group_id,)).fetchone()[0]
        self.assertIn(limit, reason)
        self.assertFalse([r for _, r in world.story_requests if r.sha in lacking], "a lacking Change was run")
        self.assertFalse([b for b in world.build_requests if b.sha in lacking], "a lacking Change was built")

    def test_a_step_inside_the_lacking_commits_is_never_a_regression(self) -> None:
        world = self.world(culprit=3)  # the values move at SHAS[3], before the story can measure
        group_id = tpe.seed_lab(world)
        self.drive(world, self.executor(world, lacks=self.lacks))
        result = self.result(world)
        self.assertEqual(result["culprits"], [])
        self.assertEqual(result["outcome"], pinpoint.NO_CULPRIT)
        self.assertEqual(self.group(world, group_id)["state"], "triaged")
        self.assertTrue(all(reason == pinpoint.NOT_MEASURABLE for sha, reason in result["skipped"]))

    def test_the_journal_replays_the_unmeasurable_answers(self) -> None:
        world = self.world()
        tpe.seed_lab(world)
        executor = self.executor(world, lacks=self.lacks)
        world.tick(executor)
        events = self.journal()["events"]
        self.assertTrue([e for e in events if e["t"] == "unmeasurable"])
        job = exe.job_of(json.loads(self.bisect_row(world)["params_json"])["job"])
        state = exe.replay(job, events)  # a restarted labd reproduces the same steps
        self.assertIn(tpe.SHAS[0], {sha for sha, _ in state._finish().skipped})

    def test_a_capability_that_cannot_be_read_holds_only_its_job(self) -> None:
        world = self.world()
        tpe.seed_lab(world)

        def broken(story, sha):
            raise caps.CapabilityError("git grep exited 128")

        report = world.tick(self.executor(world, lacks=broken))
        self.assertTrue(any("capabilities of" in p and "git grep exited 128" in p for p in report.problems))
        self.assertEqual(self.bisect_row(world)["state"], "running")


class CoreTests(unittest.TestCase):
    def test_an_unmeasurable_change_costs_no_build(self) -> None:
        commits = tuple(pinpoint.Commit(f"{i:02x}" * 20, stored_build=i in (0, 4)) for i in range(5))
        job = pinpoint.Job(kind=pinpoint.BISECT, mode=pinpoint.PERFORMANCE, story="s", metric="m", host_class="h",
                           good=commits[0].change, bad=commits[-1].change, magnitude=1.0, commits=commits)
        state = pinpoint.JobState(job)
        pinpoint.step(state)
        state.record_unmeasurable(commits[0].change)
        state.record_unmeasurable(commits[0].change)  # a second answer is a no-op
        self.assertEqual(dict(state._finish().skipped), {commits[0].sha: pinpoint.NOT_MEASURABLE})
        with self.assertRaises(pinpoint.PinpointError):
            state.record_unmeasurable(commits[2].change)  # never added to the range


class SchedulerTests(unittest.TestCase):
    def test_a_story_the_round_commit_cannot_measure_is_a_gap_not_a_job(self) -> None:
        sim = tsched.Sim(lacks=lambda story, sha: ("debug:debug.key",) if story == "t0-key" else ())
        sim.merge()
        sim.step(tsched.BUILD_MINUTES + 1)
        planned = {s for j, _ in sim.jobs for s in j.stories}
        self.assertNotIn("t0-key", planned)
        self.assertIn("t0-switch", planned)
        gaps = [g for p in sim.plans for g in p.gaps if g.story == "t0-key"]
        self.assertTrue(gaps)
        self.assertTrue(all(g.reason.startswith("not-measurable: ") and "lacks debug:debug.key" in g.reason
                            for g in gaps))

    def test_a_hook_that_fails_is_a_problem_and_the_story_runs(self) -> None:
        def broken(story, sha):
            raise caps.CapabilityError("no such commit")

        sim = tsched.Sim(lacks=broken)
        sim.merge()
        sim.step(tsched.BUILD_MINUTES + 1)
        self.assertIn("t0-key", {s for j, _ in sim.jobs for s in j.stories})
        self.assertTrue(any("no such commit" in problem for p in sim.plans for problem in p.problems))


if __name__ == "__main__":
    unittest.main()
