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
from dataclasses import replace
from pathlib import Path
from types import SimpleNamespace

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
run_story = _load("run_story", LAB / "run_story.py")
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

    def test_the_build_is_asked_and_one_from_before_the_probe_answers_its_methods(self) -> None:
        needs = ("debug:debug.closed_ids", "signpost:key.frame", "env:CMUX_NEXT_TRACE_FLOWS", TURN_HISTOGRAM)
        asked = []

        def probe_build(method):
            asked.append(method)
            return probe()

        self.assertEqual(caps.probe_missing(needs, probe_build),
                         ("debug:debug.closed_ids", "signpost:key.frame", "env:CMUX_NEXT_TRACE_FLOWS"))
        self.assertEqual(asked, [caps.PROBE_METHOD])

        def old_build(method):
            if method == caps.PROBE_METHOD:
                return {"error": {"code": "method_not_found"}}
            return {"protocol_version": 1, "methods": ["system.ping", "debug.hangs"]}

        # Signposts and variables of an old build are unknown, never "lacking".
        self.assertEqual(caps.probe_missing(needs, old_build), ("debug:debug.closed_ids",))
        self.assertEqual(caps.probe_missing(["debug:debug.hangs"], old_build), ())
        with self.assertRaises(caps.CapabilityError):
            caps.probe_missing(needs, lambda method: {"error": "unreachable", "unreachable": True})

    def test_the_swift_lists_parse(self) -> None:
        lists = caps.declared_lists((REPO_ROOT / caps.DEBUG_CAPABILITIES).read_text(encoding="utf-8"))
        self.assertIn("actionCommit", lists["emittedSignposts"])
        self.assertIn("scrollToFrame", lists["emittedSignposts"])
        self.assertNotIn("actionPresented", lists["emittedSignposts"])  # reserved: no emitter yet
        self.assertIn("CMUX_NEXT_TYPING_PROBE", lists["probeEnvironment"])
        cases = caps.tip_signpost_cases(REPO_ROOT)
        self.assertEqual(cases["scrollToFrame"], "key.scroll_frame")


class CompileTests(unittest.TestCase):
    BENCH = caps.CONFIG_FLAGS["bench"]

    def test_conditions_under_the_bench_flags(self) -> None:
        cases = {"DEBUG": False, "DEBUG || CMUX_BENCH_HOOKS": True, "!DEBUG": True,
                 "(DEBUG || CMUX_BLOCKING_CHECKS)": False, "DEBUG && arch(arm64)": False,
                 "(DEBUG || CMUX_BENCH_HOOKS) && !GHOSTTY_RENDERER_FRAMES": None, "arch(arm64)": None,
                 "compiler(>=6.4)": None, "DEBUG ||": None, "true": True, "!(DEBUG)": True}
        for expr, value in cases.items():
            self.assertIs(caps.condition(expr, self.BENCH), value, expr)

    def test_a_block_a_config_does_not_compile_is_blanked(self) -> None:
        swift = "\n".join(['#if DEBUG', '"debug.a"', '#elseif CMUX_BENCH_HOOKS', '"debug.b"', '#else', '"debug.c"',
                           '#endif', '#if DEBUG || CMUX_BENCH_HOOKS', '"debug.d"', '#if DEBUG', '"debug.e"', '#endif',
                           '#endif', '#if GHOSTTY_RENDERER_FRAMES', '"debug.f"', '#else', '"debug.g"', '#endif',
                           '"debug.h"'])

        def found(config):
            return set(caps.METHOD_LITERAL.findall(caps.compiled(swift, caps.CONFIG_FLAGS[config])))

        self.assertEqual(found("bench"), {"debug.b", "debug.d", "debug.f", "debug.g", "debug.h"})
        self.assertEqual(found("debug"), {"debug.a", "debug.d", "debug.e", "debug.f", "debug.g", "debug.h"})
        self.assertEqual(found("release"), {"debug.c", "debug.f", "debug.g", "debug.h"})
        self.assertEqual(len(caps.compiled(swift, self.BENCH).splitlines()), len(swift.splitlines()))

    def test_a_story_need_only_debug_compiles_is_reported_for_a_bench_story(self) -> None:
        debug_build = caps.Capabilities(caps.SOURCE, frozenset({"debug.hangs", "debug.closed_ids"}), frozenset(),
                                        frozenset())
        bench = replace(debug_build, methods=frozenset({"debug.hangs"}))
        tip = {"debug": debug_build, "bench": bench, "bench-checks": bench,
               "release": replace(bench, methods=frozenset())}
        sweep = SimpleNamespace(path="stories.d/sweep.json", config="bench",
                                needs=("debug:debug.hangs", "debug:debug.closed_ids"))
        dev_sweep = SimpleNamespace(**{**vars(sweep), "path": "stories.d/dev.json", "config": "debug"})
        problems = caps.story_problems([sweep, dev_sweep], tip.__getitem__, lambda path: True)
        self.assertEqual(problems, ["stories.d/sweep.json: needs debug:debug.closed_ids, which a bench build of the "
                                    "tip does not have (only a debug build has it): no build can measure it"])


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
        self.write(f"{caps.SOURCES}/A/History.swift",
                   '#if DEBUG\n.mainActor("debug.closed_ids") { _ in }\n#endif\n'
                   '#if DEBUG || CMUX_BENCH_HOOKS\n.mainActor("debug.frames") { _ in }\n#endif\n'
                   '// .mainActor("debug.commented") is a comment, never a method\n')
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
        self.assertEqual(new.methods, {"debug.hangs", "debug.capabilities", "debug.frames"})
        self.assertEqual(new.signposts, {"action.commit", "key.frame"})

    def test_a_method_only_debug_registers_is_absent_for_a_bench_story(self) -> None:
        commits = caps.GitCapabilities.of(self.repo)
        self.assertNotIn("debug.closed_ids", commits.at(self.new, "bench").methods)
        self.assertNotIn("debug.closed_ids", commits.at(self.new, "bench-checks").methods)
        self.assertIn("debug.closed_ids", commits.at(self.new, "debug").methods)
        self.assertNotIn("debug.commented", commits.at(self.new, "debug").methods)
        needs = ("debug:debug.closed_ids", "debug:debug.frames")
        story = caps.StoryNeeds({"sweep": needs, "dev-sweep": needs}, commits,
                                {"sweep": "bench", "dev-sweep": "debug"})
        self.assertEqual(story("sweep", self.new), ("debug:debug.closed_ids",))
        self.assertEqual(story("dev-sweep", self.new), ())
        with self.assertRaises(caps.CapabilityError):
            commits.at(self.new, "profile")

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


class BuildAnswerWorld(tpe.World):
    """The build itself says it lacks NEED below commit ADDED, where git sees nothing missing (a guess the source scan
    gets wrong): as run_story.py's exit 6 with the needs in summary.json, or as the controller's not_measurable."""

    ADDED = 5
    NEED = "debug:debug.closed_ids"

    def __init__(self, root: Path, *, via: str, **options) -> None:
        super().__init__(root, **options)
        self.via = via
        self.exit_code = lambda request, number: run_story.EXIT_NOT_MEASURABLE if self.lacking(request.sha) else 0

    def lacking(self, sha: str) -> bool:
        return tpe.SHAS.index(sha) < self.ADDED

    def status(self, controller_id):
        status = super().status(controller_id)
        job = self.jobs[controller_id]
        if job["kind"] != "story" or not status.finished or not self.lacking(job["request"].sha):
            return status
        if self.via == "controller":
            return replace(status, exit_code=0, not_measurable=True, missing=(self.NEED,))
        folder = self.root / "artifacts" / controller_id
        folder.mkdir(parents=True, exist_ok=True)
        (folder / "summary.json").write_text(json.dumps({"refusal": {"kind": "not-measurable",
                                                                     "missing": [self.NEED]}}))
        return replace(status, artifact=folder)


class BuildAnswerTests(tpe.Fixture):
    """p12-perf-process-211: a Change whose build says it lacks a need is not-measurable, never failed attempts."""

    def check(self, via: str) -> None:
        world = BuildAnswerWorld(self.root, via=via)
        group_id = tpe.seed_lab(world)
        self.drive(world, self.executor(world))
        result = self.result(world)
        lacking = set(tpe.SHAS[:world.ADDED])
        events = self.journal()["events"]
        failed = [e for e in events if e["t"] == "attempt" and e["attempt"]["failed"]]
        self.assertEqual(failed, [], "a build that lacks a need never gives a failed attempt")
        self.assertIn([tpe.SHAS[0], pinpoint.NOT_MEASURABLE], result["skipped"])
        self.assertTrue(all(reason == pinpoint.NOT_MEASURABLE for _, reason in result["skipped"]))
        self.assertIn(tpe.SHAS[tpe.CULPRIT], [c["change"]["sha"] for c in result["culprits"]])
        self.assertFalse([c for c in result["culprits"] if lacking & set(c["commits"])], "blamed a lacking commit")
        unmeasurable = [e for e in events if e["t"] == "unmeasurable"]
        self.assertTrue(unmeasurable and all(e["missing"] == [world.NEED] for e in unmeasurable))
        last = max(tpe.SHAS.index(e["change"]["sha"]) for e in unmeasurable)
        limit = f"range limited by capability {world.NEED} since {tpe.SHAS[last + 1][:12]}"
        self.assertEqual(result["range_limits"], [limit])
        reason = world.lab._db.execute("SELECT reason FROM sheriff_history WHERE group_id = ? ORDER BY id DESC",
                                       (group_id,)).fetchone()[0]
        self.assertIn(limit, reason)

    def test_the_runner_exit_and_its_summary_make_the_change_not_measurable(self) -> None:
        self.check("exit")

    def test_a_controller_reported_not_measurable_puts_the_limit_in_the_result(self) -> None:
        self.check("controller")

    def test_the_exit_codes_agree(self) -> None:
        self.assertEqual(exe.NOT_MEASURABLE_EXITS, (run_story.EXIT_NOT_MEASURABLE,))
        self.assertNotIn(run_story.EXIT_NOT_MEASURABLE, exe.MEASURED_EXITS)


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
