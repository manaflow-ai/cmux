#!/usr/bin/env python3
"""run-scenarios.py --stage profile (p08-startup-050): the fixed plan and key scripts, the stage's flow over a fake
app (each run's environment, quit fixture, steps, refusals, launch and step failures, flush and profile checks), the
`llvm-profdata show` parse, the launch function list (a majority of each launch kind, sorted), and the merge of the
text-format fixtures in fixtures/pgo with the real llvm-profdata (skipped when none is installed). Runs on any OS:
python3 -I scripts/cmux-next/tests/test_pgo_scenarios.py"""

import contextlib
import glob
import importlib.util
import io
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
FIXTURES = os.path.join(HERE, "fixtures", "pgo")
SCRIPT = os.path.join(os.path.dirname(HERE), "pgo", "run-scenarios.py")

spec = importlib.util.spec_from_file_location("run_scenarios", SCRIPT)
rs = importlib.util.module_from_spec(spec)
sys.modules["run_scenarios"] = rs
spec.loader.exec_module(rs)

LAUNCHED = "/src/App.swift:$s4main8launchedyyF"
SOMETIMES = "Later.swift:$s4main9sometimesyyF"
FLAKY = "Later.swift:$s4main9flakyLateyyF"
REST_ONLY = "Rest.swift:$s4main8restOnlyyyF"
NEVER = "Rest.swift:$s4main5neveryyF"
WARM_ONLY = "Restore.swift:$s4main17restoreFromDaemonyyF"
COLD_ONLY = "Daemon.swift:$s4main11spawnDaemonyyF"


def find_llvm_profdata():
    """An llvm-profdata on this host: CMUX_PGO_LLVM_PROFDATA, llvm-profdata on PATH, a versioned one, or Xcode's."""
    for candidate in (os.environ.get("CMUX_PGO_LLVM_PROFDATA"), shutil.which("llvm-profdata"),
                      *sorted(glob.glob("/usr/bin/llvm-profdata-*"), reverse=True),
                      *sorted(glob.glob("/usr/lib/llvm-*/bin/llvm-profdata"), reverse=True)):
        if candidate and os.access(candidate, os.X_OK):
            return [candidate]
    if shutil.which("xcrun"):
        found = subprocess.run(["xcrun", "--find", "llvm-profdata"], capture_output=True, text=True)
        if found.returncode == 0:
            return ["xcrun", "llvm-profdata"]
    return None


TOOL = find_llvm_profdata()


def fixture(run, phase):
    return os.path.join(FIXTURES, f"run{run}-{phase}.proftext")


def place_runs(out, plan=rs.PLAN):
    """The fixture runs as a stage leaves them: plan run i gets fixture run i % 3 + 1 (text profiles under the
    .profraw names: llvm-profdata reads a profile by its content)."""
    for index, run in enumerate(plan):
        run_dir = os.path.join(out, "runs", run.name)
        os.makedirs(run_dir, exist_ok=True)
        shutil.copy(fixture(index % 3 + 1, "launch"), os.path.join(run_dir, rs.LAUNCH_PROFILE))
        shutil.copy(fixture(index % 3 + 1, "rest"), os.path.join(run_dir, rs.REST_PROFILE))


def append_record(path, name, func_hash, entry):
    """Adds one function to a text-format profile (make_fixtures.py's record shape)."""
    with open(path, "a") as profile:
        profile.write(f"\n{name}\n# Func Hash:\n{func_hash}\n# Num Counters:\n2\n# Counter Values:\n{entry}\n"
                      f"{entry // 2}\n")


def scale_counts(path, factor):
    """Multiplies every counter of a text-format profile by `factor`: other counts, the same functions run."""
    with open(path) as profile:
        lines = profile.read().split("\n")
    remaining, counters = 0, 0
    for index, line in enumerate(lines):
        if remaining:
            lines[index] = str(int(line) * factor)
            remaining -= 1
        elif line == "# Counter Values:":
            remaining = counters
        elif index and lines[index - 1] == "# Num Counters:":
            counters = int(line)
    with open(path, "w") as profile:
        profile.write("\n".join(lines))


class PlanTests(unittest.TestCase):
    def test_plan_is_the_fixed_list(self):
        self.assertEqual([run.name for run in rs.PLAN],
                         ["cold-1", "cold-2", "cold-3", "warm-1", "warm-2", "warm-3", "chromium-first-tab",
                          "stress-build", "stress-restore"])
        self.assertEqual(rs.PLAN[-1].steps, ("typing", "tab_cycle", "split_cycle", "workspace_cycle",
                                             "workspace_switch", "palette"))
        for step in (s for run in rs.PLAN for s in run.steps):
            self.assertIn(step, rs.STEPS)

    def test_a_kept_state_launch_follows_a_keep_quit_and_the_stage_ends_the_sessions(self):
        for previous, run in zip(rs.PLAN, rs.PLAN[1:]):
            self.assertEqual(run.keep_state, previous.quit == "keep", run.name)
        self.assertFalse(rs.PLAN[0].keep_state)
        self.assertEqual(rs.PLAN[-1].quit, "end-sessions")

    def test_typing_is_2000_keys_of_shell_comment_lines(self):
        keys = rs.typing_keys()
        self.assertEqual(keys, rs.typing_keys())
        self.assertEqual(len(keys), 2000)
        lines, line = [], []
        for press in keys:
            line.append(press["key"])
            if press["key"] == "return":
                lines.append(line)
                line = []
        self.assertEqual(line, [], "the last line ends with return")
        self.assertEqual(len(lines), 32)
        for each in lines:
            self.assertEqual(each[:2], ["#", "space"])
            self.assertLessEqual(len(each), rs.TYPED_LINE)
        self.assertTrue(all(press["modifiers"] == [] for press in keys))

    def test_action_scripts(self):
        self.assertEqual(len(rs.cycle_keys(rs.NEW_TAB, rs.CLOSE_TAB)), 100)
        self.assertEqual(rs.cycle_keys(rs.NEW_TAB, rs.CLOSE_TAB)[:2], [{"key": "t", "modifiers": ["cmd"]},
                                                                       {"key": "w", "modifiers": ["cmd"]}])
        switches = rs.switch_keys()
        self.assertEqual(len(switches), 100)
        self.assertEqual([k["key"] for k in switches[:10]], ["1", "2", "3", "4", "5", "6", "7", "8", "9", "1"])
        palette = rs.palette_keys()
        self.assertEqual(len(palette), 20 * (2 + len(rs.PALETTE_QUERY)))
        self.assertEqual(palette[0], {"key": "p", "modifiers": ["cmd", "shift"]})
        self.assertEqual(palette[-1], {"key": "escape", "modifiers": [], "target": "palette"})


class FakeProcess:
    def __init__(self):
        self.code = None

    def poll(self):
        return self.code


class FakeApp:
    """A profile build: answers the methods the stage sends, writes launch.profraw once startup completes (the
    second debug.timings) and rest.profraw at debug.pgo_flush, as the flush hooks (103) do. Like
    ProfileFlush.Files(environment:), it reads only LLVM_PROFILE_FILE and writes both files in its folder; this
    derivation is the fake's own, not the runner's profile_files, so the tests catch a runner that looks
    elsewhere. `refuse(params)` answers debug.key with an error when true."""

    def __init__(self, run, env, fixture_run, flush_reply=None, write_launch=True, refuse=None):
        self.run, self.env, self.fixture_run = run, env, fixture_run
        folder = os.path.dirname(env["LLVM_PROFILE_FILE"])
        self.launch_file, self.rest_file = os.path.join(folder, "launch.profraw"), os.path.join(folder, "rest.profraw")
        self.flush_reply = {"written": self.rest_file} if flush_reply is None else flush_reply
        self.write_launch, self.refuse = write_launch, refuse
        self.calls, self.timings, self.workspaces = [], 0, 3
        self.process = FakeProcess()

    def alive(self):
        return self.process.poll() is None

    def rpc(self, method, params=None, timeout=60):
        self.calls.append((method, params))
        if method == "debug.timings":
            self.timings += 1
            if self.timings < 2:
                return {"launch_ms_since_process_start": {"first_window_frame_committed": 80.0}}
            if self.write_launch:
                shutil.copy(fixture(self.fixture_run, "launch"), self.launch_file)
            return {"launch_ms_since_process_start": {"startup_complete.idle": 300.0, "startup_complete": 300.0}}
        if method == "debug.pgo_flush":
            shutil.copy(fixture(self.fixture_run, "rest"), self.rest_file)
            return self.flush_reply
        if method == "debug.cef":
            return {"state": "ready"}
        if method == "snapshot.get":
            return {"topology": {"workspaces": [{"id": f"w{i}"} for i in range(self.workspaces)]}}
        if method == "debug.key":
            if self.refuse and self.refuse(params):
                return {"error": {"code": "refused", "message": "the palette is not open"}}
            if params == rs.NEW_WORKSPACE:
                self.workspaces += 1
            elif params == rs.CLOSE_WORKSPACE:
                self.workspaces -= 1
            return {"handled_by": "router"}
        return {"error": f"unknown method {method}"}


class FakeLaunchError(SystemExit):
    """bench_launch.LaunchError's shape: a SystemExit with the report."""


class FakeLauncher:
    errors = (SystemExit,)

    def __init__(self, fail_launch=None, **app_options):
        self.apps, self.ended, self.app_options, self.fail_launch = [], 0, app_options, fail_launch

    def end_tag(self):
        self.ended += 1

    @contextlib.contextmanager
    def launch(self, run, run_dir, env):
        if run.name == self.fail_launch:
            raise FakeLaunchError("bench-launch: socket-timeout: the app did not answer debug.windows in 180 s")
        app = FakeApp(run, env, len(self.apps) % 3 + 1, **self.app_options)
        self.apps.append(app)
        yield app
        app.quit = run.quit


class FakeShapeError(RuntimeError):
    """perf-stress-session's StressShapeError's shape."""


class FakeContext:
    errors = (RuntimeError,)

    def __init__(self, wrong_shape=False):
        self.stress_steps, self.wrong_shape = [], wrong_shape

    def stress(self, rpc):
        context = self

        class Builder:
            def build(self):
                if context.wrong_shape:
                    raise FakeShapeError("STRESS session has the wrong shape: 59 workspaces")
                context.stress_steps.append("build")
                return {"workspaces": 60, "panes": 14, "build_s": 1.0}

            def focused_workspace(self):
                return "w0"

            def workspace(self, workspace_id):
                return {"id": workspace_id, "screens": [{"panes": [{"id": "p0"}]}]}

            @staticmethod
            def panes(workspace):
                return [p for s in workspace["screens"] for p in s["panes"]]

            def add_tab(self, workspace_id, pane_id, kind):
                context.stress_steps.append(f"add_tab {workspace_id} {pane_id} {kind}")

        return Builder()

    @staticmethod
    def wait(predicate, seconds):
        return predicate()

    @staticmethod
    def cef_problems(cef):
        return []

    def close(self):
        pass


def instant_wait(predicate, seconds):
    for _ in range(5):
        if predicate():
            return True
    return False


class StageFlowTests(unittest.TestCase):
    def setUp(self):
        self.out = tempfile.mkdtemp(prefix="pgo-stage-")
        self.addCleanup(shutil.rmtree, self.out, True)

    def stage(self, launcher, context=None):
        return rs.ProfileStage(self.out, launcher, context or FakeContext(), wait=instant_wait, log=lambda line: None)

    def test_every_run_gets_its_own_profiles_and_quit(self):
        launcher, context = FakeLauncher(), FakeContext()
        reports = self.stage(launcher, context).run()
        self.assertEqual([r["run"] for r in reports], [run.name for run in rs.PLAN])
        self.assertEqual(launcher.ended, 2, "the tag's daemons end before the first and after the last run")
        for run, app in zip(rs.PLAN, launcher.apps):
            run_dir = os.path.join(self.out, "runs", run.name)
            # Only the runtime's file: 103's ProfileFlush.Files reads its folder and no CMUX_* variable.
            self.assertEqual(app.env, {"LLVM_PROFILE_FILE": os.path.join(run_dir, "other-%p.profraw")})
            self.assertEqual(rs.profile_files(app.env), {"launch": app.launch_file, "rest": app.rest_file})
            self.assertEqual(app.quit, run.quit)
            methods = [method for method, _ in app.calls]
            self.assertEqual(methods[-1], "debug.pgo_flush", "the flush is the last request before the quit")
            self.assertLess(methods.index("debug.timings"), methods.index("debug.pgo_flush"))
            self.assertTrue(os.path.getsize(os.path.join(run_dir, "launch.profraw")) > 0)
            self.assertTrue(os.path.exists(os.path.join(run_dir, "run.json")))
        self.assertEqual(context.stress_steps, ["add_tab w0 p0 chromium", "build"])
        restore = launcher.apps[-1]
        keys = [params for method, params in restore.calls if method == "debug.key"]
        expected = (rs.typing_keys() + [rs.NEW_WORKSPACE] + rs.cycle_keys(rs.NEW_TAB, rs.CLOSE_TAB) + [rs.CLOSE_WORKSPACE]
                    + [rs.NEW_WORKSPACE] + rs.cycle_keys(rs.SPLIT_RIGHT, rs.CLOSE_TAB) + [rs.CLOSE_WORKSPACE]
                    + rs.cycle_keys(rs.NEW_WORKSPACE, rs.CLOSE_WORKSPACE) + rs.switch_keys() + rs.palette_keys())
        self.assertEqual(keys, expected)
        steps = reports[-1]["steps"]
        self.assertEqual([s["step"] for s in steps], list(rs.STRESS_STEPS))
        self.assertFalse([s for s in steps if s.get("warning") or s.get("refused")])
        for other in launcher.apps[:-1]:
            self.assertNotIn("debug.key", [method for method, _ in other.calls])

    def test_a_stale_profile_from_an_earlier_stage_is_removed(self):
        run_dir = os.path.join(self.out, "runs", "cold-1")
        os.makedirs(run_dir)
        with open(os.path.join(run_dir, "rest.profraw"), "w") as stale:
            stale.write("stale")
        launcher = FakeLauncher(write_launch=False)
        with self.assertRaisesRegex(rs.StageError, "cold-1: startup_complete came but .*launch.profraw was not written"):
            self.stage(launcher).run()
        self.assertFalse(os.path.exists(os.path.join(run_dir, "rest.profraw")))
        self.assertEqual(launcher.ended, 2, "a failed stage still ends the tag's daemons")

    def test_a_build_without_the_flush_hooks_fails_naming_them(self):
        launcher = FakeLauncher(flush_reply={"error": "unknown method debug.pgo_flush"})
        with self.assertRaisesRegex(rs.StageError, r"cold-1: debug.pgo_flush answered .*flush hooks \(103\)"):
            self.stage(launcher).run()

    def test_the_profiles_follow_llvm_profile_file(self):
        env = {"LLVM_PROFILE_FILE": "/out/runs/warm-1/helpers/other-%p.profraw"}
        self.assertEqual(rs.profile_files(env), {"launch": "/out/runs/warm-1/helpers/launch.profraw",
                                                 "rest": "/out/runs/warm-1/helpers/rest.profraw"})

    def test_a_palette_that_never_opens_fails_the_stage_naming_the_step(self):
        launcher = FakeLauncher(refuse=lambda params: params.get("target") == "palette")
        with self.assertRaisesRegex(rs.StageError, r"stress-restore palette: the app refused 60 of 80 keys, first "
                                                   r".*the palette is not open"):
            self.stage(launcher).run()
        self.assertEqual(launcher.ended, 2)

    def test_a_refused_opening_key_fails_the_stage(self):
        launcher = FakeLauncher(refuse=lambda params: params == rs.NEW_WORKSPACE)
        with self.assertRaisesRegex(rs.StageError, r"stress-restore tab_cycle: the app refused its first key, "
                                                   r'\{"key": "n"'):
            self.stage(launcher).run()

    def test_every_key_refused_fails_the_stage(self):
        launcher = FakeLauncher(refuse=lambda params: True)
        with self.assertRaisesRegex(rs.StageError, r"stress-restore typing: the app refused its first key"):
            self.stage(launcher).run()

    def test_a_few_refused_keys_stay_a_warning(self):
        refused = []

        def refuse_one_close(params):
            if params == rs.CLOSE_TAB and not refused:
                refused.append(params)
                return True
            return False

        lines = []
        launcher = FakeLauncher(refuse=refuse_one_close)
        stage = rs.ProfileStage(self.out, launcher, FakeContext(), wait=instant_wait, log=lines.append)
        reports = stage.run()
        tab_cycle = reports[-1]["steps"][1]
        self.assertEqual((tab_cycle["step"], tab_cycle["keys"], tab_cycle["refused"]), ("tab_cycle", 102, 1))
        self.assertIn("pgo-stage: WARNING stress-restore tab_cycle: " + tab_cycle["first_refusal"], lines)

    def test_a_failed_launch_fails_the_stage_naming_the_run(self):
        launcher = FakeLauncher(fail_launch="warm-2")
        with self.assertRaisesRegex(rs.StageError, "warm-2: launch: FakeLaunchError: bench-launch: socket-timeout"):
            self.stage(launcher).run()
        self.assertEqual(launcher.ended, 2)

    def test_the_cli_exits_1_with_an_error_line_naming_the_failed_launch(self):
        app = tempfile.mkdtemp(prefix="cmux DEV pgo-", suffix=".app")
        self.addCleanup(shutil.rmtree, app, True)
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr), contextlib.redirect_stdout(io.StringIO()):
            code = rs.main(["--stage", "profile", "--app", app, "--out", self.out, "--llvm-profdata", "false"],
                           launcher=FakeLauncher(fail_launch="cold-2"), context=FakeContext())
        self.assertEqual(code, 1)
        self.assertRegex(stderr.getvalue(), r"^pgo-stage: error: cold-2: launch: FakeLaunchError: ")

    def test_a_wrong_stress_shape_fails_the_stage_naming_the_run(self):
        with self.assertRaisesRegex(rs.StageError, "stress-build stress_build: FakeShapeError: STRESS session has "
                                                   "the wrong shape"):
            self.stage(FakeLauncher(), FakeContext(wrong_shape=True)).run()

    def test_a_scratch_workspace_that_does_not_close_is_a_warning(self):
        app = FakeApp(rs.PLAN[-1], rs.profile_env("/nowhere"), 1)
        original = app.rpc

        def rpc(method, params=None, timeout=60):
            if method == "debug.key" and params == rs.CLOSE_WORKSPACE:
                return {"error": {"code": "refused"}}
            return original(method, params, timeout)

        app.rpc = rpc
        report = {"step": "tab_cycle"}
        rs.step_tab_cycle(app, FakeContext(), report)
        self.assertEqual(report["keys"], 102)
        self.assertEqual(report["refused"], 1)
        self.assertEqual(report["warning"], "3 workspaces before, 4 after")
        self.assertIsNone(rs.refusal_problem(report))

    def test_an_app_that_exits_during_a_step_fails_the_stage(self):
        app = FakeApp(rs.PLAN[-1], rs.profile_env("/nowhere"), 1)
        app.process.code = 6
        with self.assertRaisesRegex(rs.StageError, "the app exited during typing after 1 keys"):
            rs.step_typing(app, FakeContext(), {"step": "typing"})


SHOW = """Counters:
  main:
    Hash: 0x00000000000003e9
    Counters: 2
    Function count: 2
  /src/App.swift:$s4main8launchedyyF:
    Hash: 0x00000000000003ea
    Counters: 2
    Function count: 16
  main:
    Hash: 0x00000000000004e9
    Counters: 1
    Function count: 1
Instrumentation level: Front-end
Functions shown: 3
Total functions: 3
Maximum function count: 16
Maximum internal block count: 7
"""


class ListTests(unittest.TestCase):
    def test_show_output_parse(self):
        self.assertEqual(rs.function_counts(SHOW), {"main": 3, LAUNCHED: 16})
        self.assertEqual(rs.function_counts("Instrumentation level: Front-end\nTotal functions: 0\n"), {})

    def test_launch_list_keeps_a_majority_sorted_by_name(self):
        per_launch = [{"b": 1, "a": 2, "c": 0, "d": 5}, {"b": 3, "a": 0, "c": 0}, {"b": 1, "a": 9, "d": 0}]
        self.assertEqual(rs.launch_functions({"cold": per_launch}), ["a", "b"])
        self.assertEqual(rs.launch_functions({"cold": list(reversed(per_launch))}), ["a", "b"])
        self.assertEqual(rs.launch_functions({"cold": per_launch}, min_launches=1), ["a", "b", "d"])
        self.assertEqual(rs.majority(9), 5)
        self.assertEqual(rs.majority(4), 3)

    def test_launch_list_takes_a_majority_of_each_launch_kind(self):
        # The plan's kinds: 5 cold launches (cold-1..3, chromium-first-tab, stress-build), 4 warm ones that restore
        # from the kept daemon (warm-1..3, stress-restore). A majority of all 9 is 5, which the warm path never has.
        self.assertEqual([run.kind for run in rs.PLAN], ["cold"] * 3 + ["warm"] * 3 + ["cold", "cold", "warm"])
        per_kind = {}
        for run in rs.PLAN:
            counts = {"main": 1, "restoreFromDaemon": 4 if run.kind == "warm" else 0,
                      "spawnDaemon": 2 if run.kind == "cold" else 0, "oneWarmTimer": 1 if run.name == "warm-2" else 0}
            per_kind.setdefault(run.kind, []).append(counts)
        self.assertEqual(rs.launch_functions(per_kind), ["main", "restoreFromDaemon", "spawnDaemon"])
        self.assertEqual(rs.needed_launches({"cold": 5, "warm": 4}), {"cold": 3, "warm": 3})
        with self.assertRaisesRegex(rs.StageError, "--min-launches 5: there are 4 warm launch profiles"):
            rs.needed_launches({"cold": 5, "warm": 4}, 5)

    def test_tool_choice(self):
        self.assertEqual(rs.profdata_tool(environ={}), ["xcrun", "llvm-profdata"])
        self.assertEqual(rs.profdata_tool(environ={"CMUX_PGO_LLVM_PROFDATA": "/opt/llvm/bin/llvm-profdata"}),
                         ["/opt/llvm/bin/llvm-profdata"])
        self.assertEqual(rs.profdata_tool("xcrun -sdk macosx llvm-profdata", environ={"CMUX_PGO_LLVM_PROFDATA": "x"}),
                         ["xcrun", "-sdk", "macosx", "llvm-profdata"])


@unittest.skipUnless(TOOL, "no llvm-profdata on this host")
class MergeTests(unittest.TestCase):
    def setUp(self):
        self.out = tempfile.mkdtemp(prefix="pgo-merge-")
        self.addCleanup(shutil.rmtree, self.out, True)

    def counts(self, path):
        return rs.function_counts(subprocess.run([*TOOL, "show", "--all-functions", path], capture_output=True,
                                                 text=True, check=True).stdout)

    def test_fixture_merge(self):
        place_runs(self.out)
        merged = rs.merge_stage(self.out, TOOL)
        profdata = os.path.join(self.out, rs.PROFDATA)
        # Plan runs 1..9 take fixture runs 1, 2, 3, 1, 2, 3, 1, 2, 3: every count three times.
        self.assertEqual(self.counts(profdata), {"main": 9, LAUNCHED: 3 * (7 + 9 + 8 + 2 + 0 + 1),
                                                 SOMETIMES: 3 * (3 + 0 + 2 + 0 + 5 + 0), FLAKY: 3 * (4 + 18),
                                                 REST_ONLY: 3 * 36, NEVER: 0})
        with open(os.path.join(self.out, rs.LAUNCH_FUNCTIONS)) as listing:
            lines = listing.read().splitlines()
        sha = rs.sha256_of(profdata)
        self.assertEqual(lines[1], f"# profdata sha256 {sha}")
        self.assertEqual([line for line in lines if not line.startswith("#")], sorted([LAUNCHED, SOMETIMES, "main"]))
        with open(profdata + ".sha256") as stamp:
            self.assertEqual(stamp.read(), f"{sha}  cmux-next.profdata\n")
        self.assertEqual(merged["profdata"]["sha256"], sha)
        self.assertEqual(merged["launch_functions"], {"path": rs.LAUNCH_FUNCTIONS, "count": 3,
                                                      "min_launches": {"cold": 3, "warm": 3},
                                                      "launch_profiles": {"cold": 5, "warm": 4}})
        self.assertEqual(lines[0], "# cmux-next launch functions: ran before startup_complete in at least 3 of 5 "
                                   "cold or 3 of 4 warm launch profiles (run-scenarios.py --stage profile)")
        self.assertEqual(len(merged["profdata"]["inputs"]), 18)

    def listed(self, out):
        with open(os.path.join(out, rs.LAUNCH_FUNCTIONS)) as listing:
            return [line for line in listing.read().splitlines() if not line.startswith("# profdata sha256 ")]

    def test_the_warm_restore_path_is_in_the_launch_list(self):
        # Only the 4 warm launches restore from the daemon, only the 5 cold ones spawn it: both paths are listed.
        place_runs(self.out)
        for run in rs.PLAN:
            extra = (WARM_ONLY, 1007) if run.kind == "warm" else (COLD_ONLY, 1008)
            append_record(os.path.join(self.out, "runs", run.name, rs.LAUNCH_PROFILE), *extra, entry=4)
        rs.merge_stage(self.out, TOOL)
        listed = [line for line in self.listed(self.out) if not line.startswith("#")]
        self.assertEqual(listed, sorted([LAUNCHED, SOMETIMES, "main", WARM_ONLY, COLD_ONLY]))

    def test_merge_output_does_not_depend_on_the_input_order(self):
        inputs = [fixture(run, phase) for run in (1, 2, 3) for phase in ("launch", "rest")]
        outputs = []
        for order in (inputs, list(reversed(inputs)), inputs[3:] + inputs[:3]):
            target = os.path.join(self.out, f"merged-{len(outputs)}.profdata")
            subprocess.run([*TOOL, "merge", "-o", target, *order], check=True, capture_output=True)
            with open(target, "rb") as merged:
                outputs.append(merged.read())
        self.assertEqual(outputs[1], outputs[0])
        self.assertEqual(outputs[2], outputs[0])

    def test_the_list_does_not_depend_on_the_counts(self):
        # A refresh where every launch ran the same functions with other counts lists the same functions.
        place_runs(self.out)
        first = rs.merge_stage(self.out, TOOL)
        again = tempfile.mkdtemp(prefix="pgo-merge-again-")
        self.addCleanup(shutil.rmtree, again, True)
        place_runs(again)
        for index, run in enumerate(rs.PLAN):
            scale_counts(os.path.join(again, "runs", run.name, rs.LAUNCH_PROFILE), index + 2)
        second = rs.merge_stage(again, TOOL)
        self.assertNotEqual(second["profdata"]["sha256"], first["profdata"]["sha256"])
        self.assertEqual(self.listed(again), self.listed(self.out))

    def test_a_missing_rest_profile_fails_the_merge_naming_its_run(self):
        place_runs(self.out)
        os.remove(os.path.join(self.out, "runs", "warm-2", rs.REST_PROFILE))
        with self.assertRaisesRegex(rs.StageError, "warm-2: no profile at .*rest.profraw"):
            rs.merge_stage(self.out, TOOL)

    def test_merge_only_cli_writes_the_manifest(self):
        place_runs(self.out)
        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout):
            code = rs.main(["--stage", "profile", "--merge-only", "--out", self.out, "--llvm-profdata", " ".join(TOOL)])
        self.assertEqual(code, 0)
        self.assertIn('"launch_functions": 3', stdout.getvalue())
        self.assertTrue(os.path.exists(os.path.join(self.out, rs.MANIFEST)))

    def test_stage_cli_over_a_fake_app(self):
        stdout = io.StringIO()
        app = tempfile.mkdtemp(prefix="cmux DEV pgo-", suffix=".app")
        self.addCleanup(shutil.rmtree, app, True)
        with contextlib.redirect_stdout(stdout):
            code = rs.main(["--stage", "profile", "--app", app, "--out", self.out, "--llvm-profdata", " ".join(TOOL)],
                           launcher=FakeLauncher(), context=FakeContext())
        self.assertEqual(code, 0, stdout.getvalue())
        manifest = rs.read_reports(self.out)
        self.assertEqual([r["run"] for r in manifest], [run.name for run in rs.PLAN])


if __name__ == "__main__":
    unittest.main()
