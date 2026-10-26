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

Each launch writes two profiles into `DIR/runs/<run>/` (the flush hooks, task 103; the runner names both files
in the app's environment):

    launch.profraw   LAUNCH_PROFILE_ENV: written at `startup_complete`, then the counters reset
    rest.profraw     REST_PROFILE_ENV: written at `debug.pgo_flush`, which the runner sends before it quits the
                     app, and again by the profile runtime at exit (the same counters plus the quit path)

LLVM_PROFILE_FILE is `other-%p.profraw` in the same folder, for any instrumented helper process; those files are
kept but not merged. A run whose launch.profraw or rest.profraw is missing or empty fails the stage.

Outputs in DIR:

    cmux-next.profdata          `llvm-profdata merge` of every launch.profraw and rest.profraw, inputs sorted
    cmux-next.profdata.sha256   its sha256, `sha256sum` format (052 checks it, 109 binds the order file to it)
    launch-functions.txt        the functions that ran before `startup_complete` in a majority of the launches
                                (--min-launches), one profile name per line, sorted by name; `#` lines are
                                comments. Stage 2 (`--stage order`, task 109) maps it through the link map.
    stage-profile.json          the plan, each run's files and step counts, the tool version and the sha256

The list keeps a function only when it ran in a majority of the launch profiles, so a function that one launch
happened to reach before completion (a timer that fired early) does not move in and out of the order file
between refreshes; the counts themselves vary by run, so the list is ordered by name, not by count.

Exit codes: 0 ok, 1 a launch, a profile or the merge failed, 2 usage. Warnings (a key the app refused, a scratch
workspace that did not come back) are printed and kept in stage-profile.json; they do not fail the stage.

Seams (tests only): `--llvm-profdata` or CMUX_PGO_LLVM_PROFDATA replace `xcrun llvm-profdata` (as in
build-profile.sh); ProfileStage takes the launcher and the STRESS builder.
"""
import argparse, contextlib, dataclasses, hashlib, importlib.util, json, os, re, shlex, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
CMUX_NEXT = os.path.dirname(HERE)

# The names the flush hooks (task 103, CmuxNextLaunch/ProfileFlush.swift) read: the file written at
# `startup_complete` and the file `debug.pgo_flush` and the exit write.
LAUNCH_PROFILE_ENV = "CMUX_PGO_LAUNCH_PROFILE"
REST_PROFILE_ENV = "CMUX_PGO_REST_PROFILE"
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
        if not app.alive():
            raise StageError(f"the app exited during {report['step']} after {report['keys']} keys")


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
        raise StageError(f"chromium-first-tab: workspace {workspace_id} shows no pane")
    stress.add_tab(workspace_id, panes[0]["id"], "chromium")  # raises when the tab never appears
    ready = ctx.wait(lambda: (app.rpc("debug.cef") or {}).get("state") == "ready", 60)
    problems = ctx.cef_problems(app.rpc("debug.cef"))
    if not ready or problems:
        raise StageError(f"chromium-first-tab: Chromium did not get ready: {problems}")
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
    so the pages stress-build opened still load when stress-restore brings them back."""

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


class BenchLauncher:
    """Launches the profile build through bench_launch.BenchApp (its GUI session check, Finder limits, scratch
    config and socket wait) and quits it with the run's debug.quit fixture."""

    def __init__(self, app, timeout=180, quit_timeout=60):
        self.bench_launch = load_by_path("bench_launch", os.path.join(CMUX_NEXT, "bench_launch.py"))
        self.app, self.timeout, self.quit_timeout = app, timeout, quit_timeout

    def end_tag(self):
        """Ends every process of the bundle's tag (daemons a kept run or an earlier stage left)."""
        sys.path.insert(0, CMUX_NEXT)
        from tag_teardown import TagTeardown
        TagTeardown(self.app).end()

    @contextlib.contextmanager
    def launch(self, run, run_dir, env):
        bench = self.bench_launch.BenchApp(self.app, out=run_dir, env=env, log_name="app.log",
                                           teardown=run.quit == "end-sessions", fresh_state=not run.keep_state)
        bench.launch(timeout=self.timeout)
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
    return {LAUNCH_PROFILE_ENV: os.path.join(run_dir, LAUNCH_PROFILE),
            REST_PROFILE_ENV: os.path.join(run_dir, REST_PROFILE),
            "LLVM_PROFILE_FILE": os.path.join(run_dir, OTHER_PROFILES)}


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
        report = {"run": run.name, "keep_state": run.keep_state, "quit": run.quit, "steps": []}
        started = time.monotonic()
        self.log(f"pgo-stage: {run.name}: launching")
        with self.launcher.launch(run, run_dir, env) as app:
            if not self.wait(lambda: startup_completed(app) or not app.alive(), self.timeout) or not app.alive():
                raise StageError(f"{run.name}: the app never reached {STARTUP_COMPLETE}")
            if not self.wait(lambda: nonempty(env[LAUNCH_PROFILE_ENV]), 30):
                raise StageError(f"{run.name}: {STARTUP_COMPLETE} came but {env[LAUNCH_PROFILE_ENV]} was not written: "
                                 "is this a profile build (reload.sh --config profile) with the flush hooks (103)?")
            for name in run.steps:
                step = {"step": name}
                STEPS[name](app, self.context, step)
                if step.get("warning") or step.get("refused"):
                    self.log(f"pgo-stage: WARNING {run.name} {name}: {step.get('warning') or step.get('first_refusal')}")
                report["steps"].append(step)
            flushed = app.rpc("debug.pgo_flush", timeout=60)
            if not isinstance(flushed, dict) or flushed.get("error"):
                raise StageError(f"{run.name}: debug.pgo_flush answered {str(flushed)[:200]}: the build has no flush "
                                 "hooks (103)")
        for path in (env[LAUNCH_PROFILE_ENV], env[REST_PROFILE_ENV]):
            if not nonempty(path):
                raise StageError(f"{run.name}: no profile at {path}")
        report["seconds"] = round(time.monotonic() - started, 1)
        with open(os.path.join(run_dir, "run.json"), "w") as out:
            json.dump(report, out, indent=1)
        return report


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


def launch_functions(per_launch, min_launches=None):
    """The names with an entry count above 0 in at least `min_launches` (default a majority) of the launch
    profiles `per_launch` ({name: count} each), sorted by name."""
    needed = majority(len(per_launch)) if min_launches is None else min_launches
    ran = {}
    for counts in per_launch:
        for name, count in counts.items():
            if count > 0:
                ran[name] = ran.get(name, 0) + 1
    return sorted(name for name, launches in ran.items() if launches >= needed)


def sha256_of(path):
    digest = hashlib.sha256()
    with open(path, "rb") as source:
        for block in iter(lambda: source.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def merge_stage(out, tool, plan=PLAN, min_launches=None):
    """Merges the profiles of every run of `plan` in `out/runs` into `out`/PROFDATA and writes the launch function
    list; returns the merge part of the manifest."""
    launches, rests = [], []
    for run in plan:
        run_dir = os.path.join(out, "runs", run.name)
        for name, kept in ((LAUNCH_PROFILE, launches), (REST_PROFILE, rests)):
            path = os.path.join(run_dir, name)
            if not nonempty(path):
                raise StageError(f"{run.name}: no profile at {path}")
            kept.append(path)
    needed = majority(len(launches)) if min_launches is None else min_launches
    if not 1 <= needed <= len(launches):
        raise StageError(f"--min-launches {needed}: there are {len(launches)} launch profiles")
    profdata = os.path.join(out, PROFDATA)
    run_tool(tool, "merge", "-o", profdata, *sorted(launches + rests))
    per_launch = []
    for path in launches:
        counts = function_counts(run_tool(tool, "show", "--all-functions", path))
        if not counts:
            raise StageError(f"llvm-profdata show listed no functions for {path}")
        per_launch.append(counts)
    names = launch_functions(per_launch, needed)
    sha = sha256_of(profdata)
    with open(profdata + ".sha256", "w") as stamp:
        stamp.write(f"{sha}  {PROFDATA}\n")
    with open(os.path.join(out, LAUNCH_FUNCTIONS), "w") as listing:
        listing.write(f"# cmux-next launch functions: ran before {STARTUP_COMPLETE} in at least {needed} of "
                      f"{len(launches)} launch profiles (run-scenarios.py --stage profile)\n")
        listing.write(f"# profdata sha256 {sha}\n")
        listing.writelines(name + "\n" for name in names)
    return {"profdata": {"path": PROFDATA, "sha256": sha, "bytes": os.path.getsize(profdata),
                         "inputs": [os.path.relpath(p, out) for p in sorted(launches + rests)]},
            "launch_functions": {"path": LAUNCH_FUNCTIONS, "count": len(names), "min_launches": needed,
                                 "launch_profiles": len(launches)},
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
                "profile_env": [LAUNCH_PROFILE_ENV, REST_PROFILE_ENV], "runs": reports, **merged}
    with open(os.path.join(out, MANIFEST), "w") as target:
        json.dump(manifest, target, indent=1)
    return manifest


def parse_args(argv):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--stage", required=True, choices=["profile"])
    parser.add_argument("--app", help="the profile build: cmux DEV <tag>.app of reload.sh --config profile")
    parser.add_argument("--out", required=True, help="the stage folder: runs/, the profdata and the function list")
    parser.add_argument("--merge-only", action="store_true", help="merge the runs already in --out; launch nothing")
    parser.add_argument("--timeout", type=float, default=180, help="seconds for a launch to answer and complete")
    parser.add_argument("--min-launches", type=int, help="launch profiles a listed function ran in (default a majority)")
    parser.add_argument("--llvm-profdata", help="llvm-profdata command (default: xcrun llvm-profdata)")
    args = parser.parse_args(argv)
    if not args.merge_only and not args.app:
        parser.error("--app is required unless --merge-only")
    if args.app and not os.path.isdir(args.app):
        parser.error(f"--app {args.app} is not an app bundle")
    return args


def main(argv=None, launcher=None, context=None):
    args = parse_args(argv)
    out = os.path.abspath(args.out)
    os.makedirs(out, exist_ok=True)
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
