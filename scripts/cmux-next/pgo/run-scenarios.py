#!/usr/bin/env python3
"""The cmux-next PGO scenario runner (plans/cmux-next/chrome-parity/p08-startup.md, section F).

Stage 1, `--stage profile` (task 050): drives the instrumented profile build (`scripts/reload.sh --config
profile`, built and checked by `scripts/cmux-next/pgo/build-profile.sh`, task 049) through a fixed list of
launches and actions, collects each launch's two profiles and merges them:

    python3 scripts/cmux-next/pgo/run-scenarios.py --stage profile --app "/path/cmux DEV <tag>.app" --out DIR
    python3 scripts/cmux-next/pgo/run-scenarios.py --stage profile --merge-only --out DIR   # merge kept runs again

Run it on a fleet Mac with a GUI session (bench_launch.py: the launches need one), never on a person's Mac.
Chrome's equivalent is tools/pgo/generate_profile.py: benchmark stories on a chrome_pgo_phase=1 build, then
`llvm-profdata merge` of every .profraw (docs/pgo.md).

The plan (PLAN, fixed: the same launches, keys and actions every run):

    cold-1, cold-2, cold-3     no daemon of the tag runs and the saved session is empty; cold-3 quits keeping
                               its sessions, so the daemon lives on for
    warm-1, warm-2, warm-3     the app restores from the running daemon; warm-3 ends the sessions
    chromium-first-tab         an empty launch opens its first Chromium tab and waits for Chromium to be ready
    stress-build               builds the STRESS session (perf-stress-session.py) and quits keeping it
    stress-restore             restores STRESS from the running daemon, then: 2000 typed keys, Cmd-T / Cmd-W x50,
                               Cmd-D / Cmd-W x50 (in a scratch workspace), Cmd-N / Cmd-Shift-W x50, a workspace
                               switch (Cmd-1 to Cmd-9) x100, the command palette x20, and quit

Cold here means no daemon and an empty saved session, not an empty file cache: the code a launch runs does not
depend on the page cache, so the profile needs no purge.

Each launch writes two profiles into `DIR/runs/<run>/`. The runner sets only LLVM_PROFILE_FILE, to
`DIR/runs/<run>/other-%p.profraw`; the flush hooks (task 103, ProfileFlush.Files(environment:)) put both files in
that variable's folder, and `profile_files` derives the same two paths here:

    launch.profraw   written at `startup_complete`; then the hooks reset the counters and switch the runtime's
                     file to rest.profraw
    rest.profraw     written at `debug.pgo_flush`, which the runner sends before it quits the app, and again by
                     the profile runtime at exit (the same counters plus the quit path)

Until `startup_complete` the runtime's file is other-%p.profraw, so an app that exits before it leaves its counters
there; an instrumented helper process writes its own other-<pid>.profraw. Those files are kept but not merged. A
run whose launch.profraw or rest.profraw is missing or empty fails the stage.

Outputs in DIR:

    cmux-next.profdata          `llvm-profdata merge` of every launch.profraw and rest.profraw, inputs sorted
    cmux-next.profdata.sha256   its sha256, `sha256sum` format (052 checks it, 109 binds the order file to it)
    launch-functions.txt        the functions that ran before `startup_complete` in a majority of the cold launches
                                or in a majority of the warm launches (--min-launches), one profile name per line,
                                sorted by name; `#` lines are comments. Stage 2 (`--stage order`, task 109) maps it
                                through the link map.
    stage-profile.json          the plan, each run's files and step counts, the tool version and the sha256

The launches are of two kinds that run different code: cold (no daemon, an empty session: cold-1..3,
chromium-first-tab, stress-build) and warm (restored from the kept daemon: warm-1..3, stress-restore). The list
keeps a function when it ran in a majority of the launches of either kind, so the warm restore path, the normal
launch, is in it although it runs in only 4 of the 9 launches; a function that one launch happened to reach before
completion (a timer that fired early) does not move in and out of the order file between refreshes. The counts
vary by run, so the list is ordered by name, not by count.

Exit codes: 0 ok, 1 a launch, a step, a profile or the merge failed (the error line names the run), 2 usage. A
step fails when the app refused its first key or more than MAX_REFUSED_SHARE of its keys: the profile would miss
that scenario. A few refused keys and a scratch workspace that did not come back are warnings, printed and kept
in stage-profile.json.

Stage 2, `--stage order` (task 109): the order file, made against the final `-profile-use` build of the stage 1
profdata (052) and that build's link map (LD_GENERATE_MAP_FILE=YES, 051):

    python3 scripts/cmux-next/pgo/run-scenarios.py --stage order --app "/path/cmux DEV <tag>.app" \
        --link-map "/path/cmux DEV-LinkMap-normal-arm64.txt" --out DIR
    python3 scripts/cmux-next/pgo/run-scenarios.py --stage order --merge-only --app ... --link-map ... --out DIR

The app is the bench config of that build (Release optimization with the bench hooks, so `debug.timings` answers).
`--runs` cold launches (default 3), each after `sudo -n purge` (bench-startup.py's purge, refused up front), each
under `xctrace record` of System Trace (trace.py's XcTrace) from before the launch until the stage saw
`startup_complete` (no lab host validation in the launch). The virtual-memory table gives the app's fault addresses,
cut at the trace time of its `startup_complete` launch mark (the os-signpost table), so the bench's own requests and
the work after startup are not in them; vmmap gives the address its `__TEXT` was mapped at; both are kept in
`DIR/order-runs/<run>/faults.json`. page-fault-order.py then maps them and stage 1's launch-functions.txt (from
`--profile-dir`, default DIR) through the link map. The stage refuses unless launch-functions.txt, stage 1's
cmux-next.profdata.sha256 and the build's `--profdata-sha256` (default Resources/build/cmux-next.profdata.sha256)
name the same profdata.

Outputs in DIR:

    cmux-next.order             the launch symbols, then the page-fault symbols of a majority of the cold launches
                                (--min-runs); its `# profdata sha256` header is what check.py compares
    cmux-next.swift-only.order  the launch symbols only: the other side of the cold pageins A/B
    stage-order.json            the runs, the counts, the launch functions the map has no symbol for

Seams (tests only): `--llvm-profdata` or CMUX_PGO_LLVM_PROFDATA replace `xcrun llvm-profdata` (as in
build-profile.sh); ProfileStage takes the launcher and the STRESS context, OrderStage the launcher, the purge, the
fault recorder and the load address reader, each with `errors`, the exceptions it raises for a failed run (the
stage reports them as that run's error).
"""
import argparse, contextlib, dataclasses, hashlib, importlib.util, json, os, re, shlex, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
CMUX_NEXT = os.path.dirname(HERE)
REPO = os.path.dirname(os.path.dirname(CMUX_NEXT))

# The file names of the flush hooks (task 103, CmuxNextLaunch/ProfileFlush.swift, ProfileFlush.Files), both in
# the folder of LLVM_PROFILE_FILE.
LAUNCH_PROFILE, REST_PROFILE, OTHER_PROFILES = "launch.profraw", "rest.profraw", "other-%p.profraw"
PROFDATA, LAUNCH_FUNCTIONS, MANIFEST = "cmux-next.profdata", "launch-functions.txt", "stage-profile.json"
STARTUP_COMPLETE = "startup_complete"


class StageError(RuntimeError):
    """A stage failure with its reason; main() prints it and exits 1."""


@dataclasses.dataclass(frozen=True)
class Run:
    """One launch of the plan. `keep_state` launches on the saved session and daemon the previous run kept;
    `quit` is the debug.quit fixture: `keep` leaves the daemon and its sessions for the next run, `end-sessions`
    ends them (a cold start for the next run)."""
    name: str
    keep_state: bool
    quit: str
    steps: tuple = ()

    @property
    def kind(self):
        """`warm` restores from the kept daemon, `cold` starts one: the launch list takes a majority of each."""
        return "warm" if self.keep_state else "cold"


STRESS_STEPS = ("typing", "tab_cycle", "split_cycle", "workspace_cycle", "workspace_switch", "palette")
PLAN = (
    Run("cold-1", False, "end-sessions"),
    Run("cold-2", False, "end-sessions"),
    Run("cold-3", False, "keep"),
    Run("warm-1", True, "keep"),
    Run("warm-2", True, "keep"),
    Run("warm-3", True, "end-sessions"),
    Run("chromium-first-tab", False, "end-sessions", ("chromium_first_tab",)),
    Run("stress-build", False, "keep", ("stress_build",)),
    Run("stress-restore", True, "end-sessions", STRESS_STEPS),
)

TYPED_KEYS, TYPED_LINE = 2000, 64
MAX_REFUSED_SHARE = 0.02
CYCLES, SWITCHES, PALETTE_OPENS = 50, 100, 20
PALETTE_QUERY = "sp"


def key(name, *modifiers, target=None):
    params = {"key": name, "modifiers": list(modifiers)}
    if target:
        params["target"] = target
    return params


def typing_keys(count=TYPED_KEYS, line=TYPED_LINE):
    """`count` debug.key presses for the focused terminal: shell comment lines (`# abc...` and return, `line` keys
    each, the last one shorter), so the shell runs nothing."""
    if line < 3 or count % line in (1, 2):
        raise ValueError(f"typing_keys: {count} keys in lines of {line} leave a line too short for '# ' and return")
    keys, letter = [], 0
    while len(keys) < count:
        width = min(line, count - len(keys))
        keys += [key("#"), key("space")]
        for _ in range(width - 3):
            keys.append(key(chr(ord("a") + letter % 26)))
            letter += 1
        keys.append(key("return"))
    return keys


def cycle_keys(open_key, close_key, cycles=CYCLES):
    return [press for _ in range(cycles) for press in (open_key, close_key)]


def switch_keys(count=SWITCHES):
    """Cmd-1 to Cmd-9 in turn (selectWorkspaceByNumber), `count` presses."""
    return [key(str(index % 9 + 1), "cmd") for index in range(count)]


def palette_keys(opens=PALETTE_OPENS, query=PALETTE_QUERY):
    """Cmd-Shift-P (commandPalette), the query typed into the palette, escape; `opens` times."""
    once = [key("p", "cmd", "shift")] + [key(ch, target="palette") for ch in query] + [key("escape", target="palette")]
    return once * opens


NEW_WORKSPACE, CLOSE_WORKSPACE = key("n", "cmd"), key("w", "cmd", "shift")
NEW_TAB, CLOSE_TAB, SPLIT_RIGHT = key("t", "cmd"), key("w", "cmd"), key("d", "cmd")


def workspace_count(rpc):
    reply = rpc("snapshot.get")
    topology = (reply.get("topology") or {}) if isinstance(reply, dict) else {}
    return len([w for w in topology.get("workspaces") or [] if w.get("id")])


def press_all(app, keys, report):
    """Sends `keys` in order; counts presses and the ones the app refused (an error reply)."""
    for press in keys:
        reply = app.rpc("debug.key", press, timeout=30)
        report["keys"] = report.get("keys", 0) + 1
        if isinstance(reply, dict) and reply.get("error"):
            report["refused"] = report.get("refused", 0) + 1
            report.setdefault("first_refusal", f"{json.dumps(press)}: {str(reply['error'])[:160]}")
            if report["keys"] == 1:
                report["first_key_refused"] = True
        if not app.alive():
            raise StageError(f"the app exited during {report['step']} after {report['keys']} keys")


def refusal_problem(step):
    """Why the app's refusals fail `step`, or None: it refused the step's first key (the one that opens what the
    rest act on) or more than MAX_REFUSED_SHARE of its keys."""
    refused, keys = step.get("refused", 0), step.get("keys", 0)
    if step.get("first_key_refused"):
        return f"the app refused its first key, {step['first_refusal']}"
    if refused > keys * MAX_REFUSED_SHARE:
        return f"the app refused {refused} of {keys} keys, first {step['first_refusal']}"
    return None


def press_balanced(app, keys, report):
    """Sends `keys`, which open as many workspaces as they close; a workspace count that does not come back is a
    warning."""
    before = workspace_count(app.rpc)
    press_all(app, keys, report)
    after = workspace_count(app.rpc)
    if after != before:
        report["warning"] = f"{before} workspaces before, {after} after"


def in_scratch_workspace(app, keys, report):
    """Runs `keys` in a new workspace (Cmd-N) and closes it (Cmd-Shift-W): the STRESS workspaces stay as they were."""
    press_balanced(app, [NEW_WORKSPACE] + keys + [CLOSE_WORKSPACE], report)


def step_typing(app, ctx, report):
    press_all(app, typing_keys(), report)


def step_tab_cycle(app, ctx, report):
    in_scratch_workspace(app, cycle_keys(NEW_TAB, CLOSE_TAB), report)


def step_split_cycle(app, ctx, report):
    in_scratch_workspace(app, cycle_keys(SPLIT_RIGHT, CLOSE_TAB), report)


def step_workspace_cycle(app, ctx, report):
    press_balanced(app, cycle_keys(NEW_WORKSPACE, CLOSE_WORKSPACE), report)


def step_workspace_switch(app, ctx, report):
    press_all(app, switch_keys(), report)


def step_palette(app, ctx, report):
    press_all(app, palette_keys(), report)


def step_chromium_first_tab(app, ctx, report):
    stress = ctx.stress(app.rpc)
    workspace_id = stress.focused_workspace()
    panes = stress.panes(stress.workspace(workspace_id))
    if not panes:
        raise StageError(f"workspace {workspace_id} shows no pane")
    stress.add_tab(workspace_id, panes[0]["id"], "chromium")  # raises when the tab never appears
    ready = ctx.wait(lambda: (app.rpc("debug.cef") or {}).get("state") == "ready", 60)
    problems = ctx.cef_problems(app.rpc("debug.cef"))
    if not ready or problems:
        raise StageError(f"Chromium did not get ready: {problems}")
    report["chromium"] = "ready"


def step_stress_build(app, ctx, report):
    summary = ctx.stress(app.rpc).build()  # raises StressShapeError on another shape
    report["stress"] = {k: summary.get(k) for k in ("workspaces", "panes", "build_s")}


STEPS = {"typing": step_typing, "tab_cycle": step_tab_cycle, "split_cycle": step_split_cycle,
         "workspace_cycle": step_workspace_cycle, "workspace_switch": step_workspace_switch,
         "palette": step_palette, "chromium_first_tab": step_chromium_first_tab, "stress_build": step_stress_build}


def load_by_path(name, path):
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


class StressContext:
    """What the Chromium and STRESS steps share across the stage: one local page server for every Chromium tab,
    so the pages stress-build opened still load when stress-restore brings them back. `errors`: what its builder
    raises for a failed step (StressShapeError, and the RuntimeError of a tab that never appeared)."""

    errors = (RuntimeError,)

    def __init__(self, module=None):
        self.module = module or load_by_path("perf_stress_session", os.path.join(CMUX_NEXT, "perf-stress-session.py"))
        self.pages = self.module.Pages()
        self.wait = self.module.wait
        self.cef_problems = self.module.cef_problems

    def stress(self, rpc):
        builder = self.module.Stress(rpc)
        builder.pages = self.pages
        return builder

    def close(self):
        self.pages.close()


class LiveApp:
    """A launched profile build, as the steps see it."""

    def __init__(self, bench):
        self.bench = bench

    def rpc(self, method, params=None, timeout=60):
        return self.bench.rpc(method, params, timeout)

    def alive(self):
        return self.bench.process is not None and self.bench.process.poll() is None

    @property
    def pid(self):
        return self.bench.process.pid

    @property
    def binary(self):
        return self.bench.binary


class BenchLauncher:
    """Launches the profile build through bench_launch.BenchApp (its GUI session check, Finder limits, scratch
    config and socket wait) and quits it with the run's debug.quit fixture. `errors`: what a failed launch raises
    (bench_launch.LaunchError and its other SystemExit reports, RecordError)."""

    def __init__(self, app, timeout=180, quit_timeout=60, validate_host=True):
        self.bench_launch = load_by_path("bench_launch", os.path.join(CMUX_NEXT, "bench_launch.py"))
        self.app, self.timeout, self.quit_timeout = app, timeout, quit_timeout
        self.validate_host = validate_host
        self.errors = (SystemExit, self.bench_launch.RecordError)

    def end_tag(self):
        """Ends every process of the bundle's tag (daemons a kept run or an earlier stage left)."""
        sys.path.insert(0, CMUX_NEXT)
        from tag_teardown import TagTeardown
        TagTeardown(self.app).end()

    @contextlib.contextmanager
    def launch(self, run, run_dir, env):
        bench = self.bench_launch.BenchApp(self.app, out=run_dir, env=env, log_name="app.log",
                                           teardown=run.quit == "end-sessions", fresh_state=not run.keep_state)
        bench.launch(timeout=self.timeout, validate_host=self.validate_host)
        completed = False
        try:
            yield LiveApp(bench)
            completed = True
        finally:
            if completed and run.quit == "keep":
                bench.rpc("debug.quit", {"fixture_quit": "keep"}, timeout=10)
                try:
                    bench.process.wait(self.quit_timeout)
                except subprocess.TimeoutExpired:
                    bench.stop()
                    raise StageError(f"{run.name}: the app did not quit in {self.quit_timeout} s (debug.quit keep)")
            bench.stop()  # end-sessions, or nothing when the app already quit


def profile_env(run_dir):
    """The app's profile environment: the runtime's file, whose folder also places the two profiles."""
    return {"LLVM_PROFILE_FILE": os.path.join(run_dir, OTHER_PROFILES)}


def profile_files(env):
    """{"launch": path, "rest": path}: where the flush hooks write for `env`, as ProfileFlush.Files(environment:)
    derives them, beside LLVM_PROFILE_FILE."""
    folder = os.path.dirname(env["LLVM_PROFILE_FILE"])
    return {"launch": os.path.join(folder, LAUNCH_PROFILE), "rest": os.path.join(folder, REST_PROFILE)}


def nonempty(path):
    return os.path.isfile(path) and os.path.getsize(path) > 0


def wait_until(predicate, seconds, clock=time.monotonic, sleep=time.sleep, step=0.25):
    deadline = clock() + seconds
    while True:  # test script: a bounded poll of the app's socket and of the profile file
        if predicate():
            return True
        if clock() >= deadline:
            return False
        sleep(step)


def startup_completed(app):
    reply = app.rpc("debug.timings", timeout=10)
    marks = reply.get("launch_ms_since_process_start") if isinstance(reply, dict) else None
    return isinstance(marks, dict) and STARTUP_COMPLETE in marks


class ProfileStage:
    """Stage 1: runs `plan` and checks every run's two profiles. `launcher.launch(run, run_dir, env)` is a context
    manager that yields a LiveApp and quits it; `context` gives the steps their STRESS builder."""

    def __init__(self, out, launcher, context, plan=PLAN, timeout=180, wait=wait_until, log=print):
        self.out, self.launcher, self.context, self.plan = out, launcher, context, plan
        self.timeout, self.wait, self.log = timeout, wait, log

    def run_dir(self, run):
        return os.path.join(self.out, "runs", run.name)

    def run(self):
        self.launcher.end_tag()  # cold-1 starts with no daemon of the tag
        reports = []
        try:
            for run in self.plan:
                reports.append(self.run_one(run))
        finally:
            self.launcher.end_tag()
        return reports

    def run_one(self, run):
        run_dir = self.run_dir(run)
        os.makedirs(run_dir, exist_ok=True)
        for name in os.listdir(run_dir):  # an earlier stage's profiles never pass for this run's
            if name.endswith(".profraw"):
                os.remove(os.path.join(run_dir, name))
        env = profile_env(run_dir)
        files = profile_files(env)
        report = {"run": run.name, "keep_state": run.keep_state, "quit": run.quit, "steps": []}
        started = time.monotonic()
        self.log(f"pgo-stage: {run.name}: launching")
        try:
            with self.launcher.launch(run, run_dir, env) as app:
                self.drive(run, app, files, report)
        except self.launcher.errors as error:
            raise StageError(f"{run.name}: launch: {type(error).__name__}: {error}") from error
        for path in files.values():
            if not nonempty(path):
                raise StageError(f"{run.name}: no profile at {path}")
        report["seconds"] = round(time.monotonic() - started, 1)
        with open(os.path.join(run_dir, "run.json"), "w") as out:
            json.dump(report, out, indent=1)
        return report

    def drive(self, run, app, files, report):
        """The launched app's part of `run`: startup complete and its launch profile, the steps, the flush."""
        if not self.wait(lambda: startup_completed(app) or not app.alive(), self.timeout) or not app.alive():
            raise StageError(f"{run.name}: the app never reached {STARTUP_COMPLETE}")
        if not self.wait(lambda: nonempty(files["launch"]), 30):
            raise StageError(f"{run.name}: {STARTUP_COMPLETE} came but {files['launch']} was not written: is this a "
                             "profile build (reload.sh --config profile) with the flush hooks (103)?")
        for name in run.steps:
            step = {"step": name}
            try:
                STEPS[name](app, self.context, step)
            except StageError as error:
                raise StageError(f"{run.name} {name}: {error}") from error
            except self.context.errors as error:
                raise StageError(f"{run.name} {name}: {type(error).__name__}: {error}") from error
            report["steps"].append(step)
            problem = refusal_problem(step)
            if problem:
                raise StageError(f"{run.name} {name}: {problem}")
            if step.get("warning") or step.get("refused"):
                self.log(f"pgo-stage: WARNING {run.name} {name}: {step.get('warning') or step.get('first_refusal')}")
        flushed = app.rpc("debug.pgo_flush", timeout=60)
        if not isinstance(flushed, dict) or flushed.get("error"):
            raise StageError(f"{run.name}: debug.pgo_flush answered {str(flushed)[:200]}: the build has no flush "
                             "hooks (103)")


# The merge.

def profdata_tool(explicit=None, environ=os.environ):
    """The llvm-profdata command: `--llvm-profdata`, else CMUX_PGO_LLVM_PROFDATA, else `xcrun llvm-profdata` (the
    toolchain's own, matching the profile build's compiler)."""
    chosen = explicit or environ.get("CMUX_PGO_LLVM_PROFDATA")
    return shlex.split(chosen) if chosen else ["xcrun", "llvm-profdata"]


def run_tool(tool, *args):
    try:
        done = subprocess.run([*tool, *args], capture_output=True, text=True)
    except OSError as error:
        raise StageError(f"{' '.join(tool)}: {error}")
    if done.returncode != 0:
        raise StageError(f"{' '.join(tool + list(args[:1]))} failed ({done.returncode}): {done.stderr.strip()[-600:]}")
    return done.stdout


FUNCTION_LINE = re.compile(r"^  (\S.*):$")
FUNCTION_COUNT = re.compile(r"^    Function count: (\d+)$")


def function_counts(show_output):
    """{profile name: entry count} from `llvm-profdata show --all-functions` (a name that appears twice, two
    functions with one name and different hashes, adds up)."""
    counts, name = {}, None
    for line in show_output.splitlines():
        match = FUNCTION_LINE.match(line)
        if match:
            name = match.group(1)
            continue
        match = FUNCTION_COUNT.match(line)
        if match and name is not None:
            counts[name] = counts.get(name, 0) + int(match.group(1))
            name = None
    return counts


def majority(count):
    return count // 2 + 1


def needed_launches(sizes, min_launches=None):
    """{kind: launch profiles a listed function ran in} for `sizes` ({kind: launch profiles of that kind}):
    `min_launches` for every kind, default a majority of each."""
    needed = {kind: majority(size) if min_launches is None else min_launches for kind, size in sizes.items()}
    for kind, count in needed.items():
        if not 1 <= count <= sizes[kind]:
            raise StageError(f"--min-launches {count}: there are {sizes[kind]} {kind} launch profiles")
    return needed


def launch_functions(per_kind, min_launches=None):
    """The names with an entry count above 0 in at least the needed number (needed_launches) of the launch
    profiles of any one kind of `per_kind` ({kind: [{name: count}, ...]}), sorted by name."""
    needed = needed_launches({kind: len(pool) for kind, pool in per_kind.items()}, min_launches)
    kept = set()
    for kind, pool in per_kind.items():
        ran = {}
        for counts in pool:
            for name, count in counts.items():
                if count > 0:
                    ran[name] = ran.get(name, 0) + 1
        kept.update(name for name, launches in ran.items() if launches >= needed[kind])
    return sorted(kept)


def sha256_of(path):
    digest = hashlib.sha256()
    with open(path, "rb") as source:
        for block in iter(lambda: source.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def merge_stage(out, tool, plan=PLAN, min_launches=None):
    """Merges the profiles of every run of `plan` in `out/runs` into `out`/PROFDATA and writes the launch function
    list; returns the merge part of the manifest."""
    launches, rests = {}, []
    for run in plan:
        files = profile_files(profile_env(os.path.join(out, "runs", run.name)))
        for path in files.values():
            if not nonempty(path):
                raise StageError(f"{run.name}: no profile at {path}")
        launches.setdefault(run.kind, []).append(files["launch"])
        rests.append(files["rest"])
    sizes = {kind: len(launches[kind]) for kind in sorted(launches)}
    needed = needed_launches(sizes, min_launches)
    inputs = sorted([path for paths in launches.values() for path in paths] + rests)
    profdata = os.path.join(out, PROFDATA)
    run_tool(tool, "merge", "-o", profdata, *inputs)
    per_kind = {}
    for kind in sizes:
        for path in launches[kind]:
            counts = function_counts(run_tool(tool, "show", "--all-functions", path))
            if not counts:
                raise StageError(f"llvm-profdata show listed no functions for {path}")
            per_kind.setdefault(kind, []).append(counts)
    names = launch_functions(per_kind, min_launches)
    sha = sha256_of(profdata)
    with open(profdata + ".sha256", "w") as stamp:
        stamp.write(f"{sha}  {PROFDATA}\n")
    rule = " or ".join(f"{needed[kind]} of {size} {kind}" for kind, size in sizes.items())
    with open(os.path.join(out, LAUNCH_FUNCTIONS), "w") as listing:
        listing.write(f"# cmux-next launch functions: ran before {STARTUP_COMPLETE} in at least {rule} launch "
                      "profiles (run-scenarios.py --stage profile)\n")
        listing.write(f"# profdata sha256 {sha}\n")
        listing.writelines(name + "\n" for name in names)
    return {"profdata": {"path": PROFDATA, "sha256": sha, "bytes": os.path.getsize(profdata),
                         "inputs": [os.path.relpath(p, out) for p in inputs]},
            "launch_functions": {"path": LAUNCH_FUNCTIONS, "count": len(names), "min_launches": needed,
                                 "launch_profiles": sizes},
            "tool": [*tool], "tool_version": run_tool(tool, "--version").strip().splitlines()[:2]}


def read_reports(out, plan=PLAN):
    reports = []
    for run in plan:
        path = os.path.join(out, "runs", run.name, "run.json")
        if os.path.exists(path):
            with open(path) as source:
                reports.append(json.load(source))
    return reports


def write_manifest(out, app, reports, merged, plan=PLAN):
    manifest = {"stage": "profile", "app": app, "plan": [dataclasses.asdict(run) for run in plan],
                "profile_env": sorted(profile_env("")), "runs": reports, **merged}
    with open(os.path.join(out, MANIFEST), "w") as target:
        json.dump(manifest, target, indent=1)
    return manifest


# Stage 2: the order file.

ORDER, SWIFT_ONLY_ORDER, ORDER_MANIFEST, FAULTS = ("cmux-next.order", "cmux-next.swift-only.order", "stage-order.json",
                                                  "faults.json")
ORDER_RUNS = 3
DEFAULT_PROFDATA_SHA256 = os.path.join(REPO, "Resources", "build", "cmux-next.profdata.sha256")
XCTRACE = ("xcrun", "xctrace")
ORDER_TRACE_CAP_S = 600


def order_lib():
    return load_by_path("page_fault_order", os.path.join(HERE, "page-fault-order.py"))


def order_plan(runs=ORDER_RUNS):
    """The cold launches of stage 2: no daemon, an empty session, an empty file cache; each ends its sessions."""
    return tuple(Run(f"order-cold-{index}", False, "end-sessions") for index in range(1, runs + 1))


class PurgedCache:
    """Empties the file cache before each cold launch with bench-startup.py's purge (`sudo -n purge`); `check` refuses
    before any launch when the account may not. `errors`: bench-startup's Refused (a SystemExit that printed why)."""

    errors = (SystemExit,)

    def __init__(self):
        self.bench_startup = load_by_path("bench_startup", os.path.join(CMUX_NEXT, "bench-startup.py"))

    def check(self):
        self.bench_startup.check_purge_right()

    def __call__(self):
        self.bench_startup.purge()


class VmFaultRecorder:
    """`xctrace record` of System Trace for one cold launch (trace.py's XcTrace, every process) and the app's fault
    addresses from its virtual-memory table. `errors`: what a recording that failed raises."""

    errors = (RuntimeError, OSError)

    def __init__(self, run_dir, trace=None):
        self.trace = trace or load_by_path("cmux_trace", os.path.join(CMUX_NEXT, "trace.py"))
        self.run_dir = run_dir
        self.recording = self.trace.XcTrace(run_dir, system_trace=True, cap_s=ORDER_TRACE_CAP_S)

    def start(self):
        self.recording.start()

    def stop(self):
        """Ends the recording; xctrace saves it."""
        if not self.recording.stop():
            raise StageError(f"xctrace saved no recording ({self.recording.log_path})")

    def kill(self):
        """Ends xctrace without saving."""
        self.recording.kill()

    def export(self, schema):
        """The path of the recording's `schema` table, exported; None when xctrace wrote nothing."""
        path = os.path.join(self.run_dir, f"xctrace-{schema}.xml")
        self.trace.export_file([*XCTRACE, "export", "--input", self.recording.path, "--xpath",
                                f'/trace-toc/run[@number="1"]/data/table[@schema="{schema}"]'], path,
                               self.trace.EXPORT_TIMEOUT_S, schema)
        return path if os.path.exists(path) else None

    def faults(self, pid):
        """(the fault addresses of process `pid` up to its startup_complete launch mark, in time order; that mark's
        trace time in ns). The recording runs on past the mark (the launcher's socket wait, the startup poll), so
        the faults after it, the bench's own requests among them, are cut."""
        lib, trace = order_lib(), self.trace
        toc = os.path.join(self.run_dir, "xctrace-toc.xml")
        trace.export_file([*XCTRACE, "export", "--input", self.recording.path, "--toc"], toc, trace.EXPORT_TOC_S,
                          "toc", to_stdout=True)
        schemas = trace.parse_toc(toc)["schemas"]
        tables = [schema for schema in schemas if lib.is_vm_schema(schema)]
        if not tables or lib.SIGNPOST_SCHEMA not in schemas:
            raise StageError(f"the System Trace needs a virtual-memory and an {lib.SIGNPOST_SCHEMA} table (tables: "
                             f"{', '.join(schemas) or 'none'})")
        signposts = self.export(lib.SIGNPOST_SCHEMA)
        if signposts is None:
            raise StageError(f"xctrace exported no {lib.SIGNPOST_SCHEMA} table")
        cutoff = lib.startup_cutoff(trace.xctrace_rows(signposts), pid)
        for schema in tables:
            path = self.export(schema)
            if path is not None:
                addresses = lib.fault_addresses(trace.xctrace_rows(path), pid, cutoff)
                if addresses:
                    return addresses, cutoff
        raise StageError(f"the virtual-memory tables {', '.join(tables)} have no fault of pid {pid} up to "
                         f"{STARTUP_COMPLETE}")


def vmmap_load_address(pid, binary):
    """The address process `pid` mapped `binary`'s __TEXT at (`vmmap -w`)."""
    try:
        done = subprocess.run(["vmmap", "-w", str(pid)], capture_output=True, text=True, timeout=120)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise StageError(f"vmmap {pid}: {error}") from error
    if done.returncode != 0:
        raise StageError(f"vmmap {pid} failed ({done.returncode}): {done.stderr.strip()[-300:]}")
    return order_lib().text_load_address(done.stdout, binary)


class OrderStage:
    """Stage 2's recording: `plan`'s cold launches, each after `cold()` (the purge) under a fresh `recorder(run_dir)`
    until `startup_complete`, then `load_address(pid, binary)`; each run's faults up to its startup_complete mark
    (`recorder.faults(pid)`: the addresses and the mark's trace time) go to its faults.json."""

    def __init__(self, out, launcher, cold, recorder, load_address=vmmap_load_address, plan=None, timeout=180,
                 wait=wait_until, log=print):
        self.out, self.launcher, self.cold, self.recorder = out, launcher, cold, recorder
        self.load_address, self.plan = load_address, plan or order_plan()
        self.timeout, self.wait, self.log = timeout, wait, log

    def run(self):
        try:
            self.cold.check()
        except self.cold.errors as error:
            raise StageError(f"purge refused: {error}") from error
        self.launcher.end_tag()
        try:
            return [self.run_one(run) for run in self.plan]
        finally:
            self.launcher.end_tag()

    def run_one(self, run):
        run_dir = os.path.join(self.out, "order-runs", run.name)
        os.makedirs(run_dir, exist_ok=True)
        faults_path = os.path.join(run_dir, FAULTS)
        if os.path.exists(faults_path):  # an earlier stage's faults never pass for this run's
            os.remove(faults_path)
        self.log(f"pgo-stage: {run.name}: purge, record, launch")
        try:
            self.cold()
        except self.cold.errors as error:
            raise StageError(f"{run.name}: purge failed: {error}") from error
        recorder = self.recorder(run_dir)
        try:
            recorder.start()
            try:
                with self.launcher.launch(run, run_dir, {}) as app:
                    if not self.wait(lambda: startup_completed(app) or not app.alive(), self.timeout) \
                            or not app.alive():
                        raise StageError(f"the app never reached {STARTUP_COMPLETE}")
                    recorder.stop()
                    pid, load_address = app.pid, self.load_address(app.pid, app.binary)
            except BaseException:
                recorder.kill()  # a failed run keeps no recording
                raise
            addresses, cutoff = recorder.faults(pid)
        except (StageError, order_lib().OrderError) as error:
            raise StageError(f"{run.name}: {error}") from error
        except self.launcher.errors as error:
            raise StageError(f"{run.name}: launch: {type(error).__name__}: {error}") from error
        except recorder.errors as error:
            raise StageError(f"{run.name}: recording: {type(error).__name__}: {error}") from error
        record = {"run": run.name, "pid": pid, "load_address": hex(load_address), "startup_complete_ns": cutoff,
                  "faults": len(addresses), "addresses": [hex(address) for address in addresses]}
        with open(faults_path, "w") as target:
            json.dump(record, target)
        return {key: record[key] for key in ("run", "pid", "load_address", "faults")}


def order_launcher(app, timeout):
    """The launcher of the cold launches: no lab host validation (its minute of nettop would run in the recording)."""
    return BenchLauncher(app, timeout=timeout, validate_host=False)


def same_profdata(profile_dir, build_sha256, lib):
    """(launch function names, profdata sha256) of stage 1 when its stamp, its launch list's header and the build's
    sha256 file name the same profdata; raises naming the two that differ."""
    names, listed = lib.read_launch_functions(os.path.join(profile_dir, LAUNCH_FUNCTIONS))
    stamped = lib.read_sha256_file(os.path.join(profile_dir, PROFDATA + ".sha256"))
    built = lib.read_sha256_file(build_sha256)
    if listed != stamped:
        raise StageError(f"{LAUNCH_FUNCTIONS} names profdata {listed}, {PROFDATA}.sha256 {stamped}: run stage 1 again")
    if built != stamped:
        raise StageError(f"stage 1 made profdata {stamped}, the -profile-use build used {built} ({build_sha256}): "
                         "the order must come from the build of this profile")
    return names, stamped


def order_stage(out, profile_dir, binary, link_map_path, build_sha256, plan, min_runs=None):
    """Maps stage 1's launch functions and every run's faults in `out/order-runs` through the link map and writes
    ORDER and SWIFT_ONLY_ORDER; returns the order part of the manifest."""
    lib = order_lib()
    try:
        names, sha = same_profdata(profile_dir, build_sha256, lib)
        with open(link_map_path) as source:
            link_map = lib.parse_link_map(source.read())
        text = lib.macho_text(binary, link_map.arch or "arm64")
        lib.check_link_map_matches(link_map, text)
        index = lib.TextIndex(link_map)
        runs = []
        for run in plan:
            path = os.path.join(out, "order-runs", run.name, FAULTS)
            if not os.path.exists(path):
                raise StageError(f"{run.name}: no recorded faults at {path}")
            with open(path) as source:
                record = json.load(source)
            runs.append(lib.unslid([int(a, 16) for a in record["addresses"]], int(record["load_address"], 16),
                                   text["vmaddr"]))
        launch, missing = lib.launch_symbols(names, index)
        faults, needed = lib.fault_symbols(runs, index, min_runs)
        lines = lib.order_lines(launch, faults, index)
        swift_only = lib.order_lines(launch, [], index)
    except (OSError, ValueError, KeyError, lib.OrderError) as error:
        raise StageError(str(error)) from error
    added = len(lines) - len(swift_only)
    binary_line = f"binary {os.path.basename(binary)} {link_map.arch} __text {text['text_size']:#x}"
    counts = (f"launch functions {len(names) - len(missing)} of {len(names)} in the map; page-fault symbols "
              f"{added} more (faulted in {needed} of {len(runs)} cold launches)")
    for name, body in ((ORDER, lines), (SWIFT_ONLY_ORDER, swift_only)):
        rendered = lib.render_order(sha, [binary_line, counts], body)
        problems = lib.check_order(rendered, sha)
        if problems:
            raise StageError(f"{name}: {'; '.join(problems)}")
        with open(os.path.join(out, name), "w") as target:
            target.write(rendered)
    return {"profdata_sha256": sha, "order": {"path": ORDER, "symbols": len(lines), "page_fault_symbols": added},
            "swift_only_order": {"path": SWIFT_ONLY_ORDER, "symbols": len(swift_only)},
            "launch_functions": {"count": len(names), "missing": len(missing), "first_missing": missing[:20]},
            "min_runs": needed, "link_map": os.path.abspath(link_map_path)}


def read_order_reports(out, plan):
    reports = []
    for run in plan:
        path = os.path.join(out, "order-runs", run.name, FAULTS)
        if os.path.exists(path):
            with open(path) as source:
                record = json.load(source)
            reports.append({key: record.get(key) for key in ("run", "pid", "load_address", "faults")})
    return reports


def parse_args(argv):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--stage", required=True, choices=["profile", "order"])
    parser.add_argument("--app", help="profile: the profile build (reload.sh --config profile); order: the bench "
                        "config of the -profile-use build")
    parser.add_argument("--out", required=True, help="the stage folder: runs/, the profdata and the function list; "
                        "order-runs/ and the order files")
    parser.add_argument("--merge-only", action="store_true", help="merge the runs already in --out; launch nothing")
    parser.add_argument("--timeout", type=float, default=180, help="seconds for a launch to answer and complete")
    parser.add_argument("--min-launches", type=int, help="launch profiles of one kind (cold or warm) a listed "
                        "function ran in (default a majority of each kind)")
    parser.add_argument("--llvm-profdata", help="llvm-profdata command (default: xcrun llvm-profdata)")
    parser.add_argument("--link-map", help="order: the link map of the --app binary (LD_GENERATE_MAP_FILE=YES)")
    parser.add_argument("--profile-dir", help="order: stage 1's folder (default --out)")
    parser.add_argument("--profdata-sha256", default=DEFAULT_PROFDATA_SHA256,
                        help="order: the sha256 file of the profdata the -profile-use build used (default %(default)s)")
    parser.add_argument("--runs", type=int, default=ORDER_RUNS, help="order: cold launches (default %(default)s)")
    parser.add_argument("--min-runs", type=int, help="order: cold launches a listed page-fault symbol faulted in "
                        "(default a majority)")
    args = parser.parse_args(argv)
    if args.stage == "order":
        if not args.app or not args.link_map:
            parser.error("--stage order needs --app and --link-map (also with --merge-only: the map must be the app's)")
        if args.runs < 1:
            parser.error("--runs must be at least 1")
    elif not args.merge_only and not args.app:
        parser.error("--app is required unless --merge-only")
    if args.app and not os.path.isdir(args.app):
        parser.error(f"--app {args.app} is not an app bundle")
    return args


def main_order(args, out, launcher=None, cold=None, recorder=None, load_address=None):
    """Stage 2: records the cold launches (unless --merge-only), then writes the order files and stage-order.json."""
    plan = order_plan(args.runs)
    binary = load_by_path("bench_launch", os.path.join(CMUX_NEXT, "bench_launch.py")).main_binary(args.app)
    try:
        if args.merge_only:
            reports = read_order_reports(out, plan)
        else:
            stage = OrderStage(out, launcher or order_launcher(args.app, args.timeout), cold or PurgedCache(),
                               recorder or VmFaultRecorder, load_address or vmmap_load_address, plan,
                               timeout=args.timeout)
            reports = stage.run()
        ordered = order_stage(out, os.path.abspath(args.profile_dir or out), binary, args.link_map,
                              args.profdata_sha256, plan, args.min_runs)
    except StageError as error:
        print(f"pgo-stage: error: {error}", file=sys.stderr, flush=True)
        return 1
    manifest = {"stage": "order", "app": os.path.abspath(args.app), "binary": binary,
                "plan": [dataclasses.asdict(run) for run in plan], "runs": reports, **ordered}
    with open(os.path.join(out, ORDER_MANIFEST), "w") as target:
        json.dump(manifest, target, indent=1)
    print("PGO-STAGE " + json.dumps({"stage": "order", "out": out, "profdata_sha256": ordered["profdata_sha256"],
                                     "order_symbols": ordered["order"]["symbols"],
                                     "page_fault_symbols": ordered["order"]["page_fault_symbols"],
                                     "launch_functions_missing": ordered["launch_functions"]["missing"]}), flush=True)
    return 0


def main(argv=None, launcher=None, context=None, cold=None, recorder=None, load_address=None):
    args = parse_args(argv)
    out = os.path.abspath(args.out)
    os.makedirs(out, exist_ok=True)
    if args.stage == "order":
        return main_order(args, out, launcher, cold, recorder, load_address)
    tool = profdata_tool(args.llvm_profdata)
    try:
        if args.merge_only:
            reports = read_reports(out)
        else:
            context = context or StressContext()
            try:
                stage = ProfileStage(out, launcher or BenchLauncher(args.app, timeout=args.timeout), context,
                                     timeout=args.timeout)
                reports = stage.run()
            finally:
                context.close()
        merged = merge_stage(out, tool, min_launches=args.min_launches)
    except StageError as error:
        print(f"pgo-stage: error: {error}", file=sys.stderr, flush=True)
        return 1
    manifest = write_manifest(out, args.app and os.path.abspath(args.app), reports, merged)
    warnings = [f"{r['run']} {s['step']}" for r in reports for s in r.get("steps", []) if s.get("warning") or s.get("refused")]
    print("PGO-STAGE " + json.dumps({"stage": "profile", "out": out, "profdata_sha256": manifest["profdata"]["sha256"],
                                     "launch_functions": manifest["launch_functions"]["count"], "warnings": warnings}),
          flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
