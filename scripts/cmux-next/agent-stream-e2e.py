#!/usr/bin/env python3
"""Streaming reply frames in the agent pane, page against page (R104).

Launches the app once per page variant through bench_launch.BenchApp (the bench env, a fresh saved session, the
tag's teardown), each loading its agent page from the variant's directory on the page host
(CMUX_NEXT_PAGE_ROOT_cmux_agent, Debug builds), so every variant runs in the same app and the same load path. With
no --variant it runs the bundle's own page (variant `bundled`). Opens an agent tab (Cmd-Shift-I), turns on the full
render rate, and runs `debug.agent_pane action=stream`: a scripted Markdown reply streamed into a long synthetic
transcript, deltas on a timer as a socket sends them. Prints frames, dropped frames, frames detached from the
bottom, per-frame content growth and per-frame layout/React time, per run and as medians (perf_stats, through
agent_bench_report.py). Run on cmux-lawrence-2 or the fleet, never the laptop.

Usage: agent-stream-e2e.py --tag <tag> --variant before=/dir/with/index.html --variant after=/dir \\
    [--variant-shared after=/pages/_shared] [--rows 2000] [--seconds 6] [--chunk-chars 24] [--chunk-ms 12] [--runs 3]
       agent-stream-e2e.py --app BUNDLE --engine chromium --story agent-stream --out DIR   (the lab story)

A variant page that imports the shared library (cmux-page://cmux.shared/, build-pages.mjs) loads it from its own
build's pages/_shared, as the bundle's page loads the bundle's: CMUX_NEXT_PAGE_ROOT_cmux_shared names that folder,
--variant-shared NAME=DIR or else the page's sibling `pages/_shared` (build-agent-pane-web.sh --out D/agent-pane
--pages-out D/pages); a variant that names one and has neither is refused.

--engine picks the agent page's engine (chromium: `browser.defaultEngine` Chromium and the `agent.chromium` debug
tunable on; webkit: the tunable off); without it the app's own settings decide. With --story (it needs --engine and
the bundle's own page) the run also writes cmux-perf-result/v1 into --out through BenchApp.record: every frame's
interval, layout and React ms (the page's per-frame samples, read after each run), per run the dropped, detached
and growing frames, and whether the tab showed in another engine (or one it could not read: then no frame records
and every run counts as missed). A variant page is not the measured build's, so a variant run never records.
"""
import argparse, glob, json, os, sys, tempfile, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # the bench modules, also under `python3 -I`
import agent_bench_report as report  # noqa: E402
from bench_launch import BenchApp, LaunchError, rpc_at, tag_of  # noqa: E402
from bench_story import story_problem  # noqa: E402

BUNDLED = "bundled"  # the variant name of the bundle's own agent page
ENGINE_CONFIG = {"chromium": {"browser": {"defaultEngine": "chromium"}}, "webkit": {}}
ENGINE_TUNABLES = {"chromium": {"agent.chromium": True}, "webkit": {"agent.chromium": False}}


def parse(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--tag", help="the tag of a DerivedData Debug app (default: read from --app)")
    parser.add_argument("--app", help="the app bundle (default: the DerivedData Debug app of --tag)")
    parser.add_argument("--variant", action="append", default=[], help="name=directory holding index.html")
    parser.add_argument("--variant-shared", action="append", default=[],
                        help="name=the pages/_shared folder of the variant's build (default: its sibling pages/_shared)")
    parser.add_argument("--engine", choices=sorted(ENGINE_CONFIG), help="the agent page's engine (default: the app's)")
    parser.add_argument("--story", help="write result-v1 under this stories.d story (needs --engine, no --variant)")
    parser.add_argument("--build-config", choices=["bench", "bench-checks"],
                        help="result-v1 build config of a bench-hooks bundle that does not stamp it")
    parser.add_argument("--session", choices=["light"], default="light", help="result-v1 session (the story runner's)")
    parser.add_argument("--rows", type=int, default=2000)
    parser.add_argument("--seconds", type=float, default=6)
    parser.add_argument("--chunk-chars", type=int, default=24)
    parser.add_argument("--chunk-ms", type=float, default=12)
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS", "/tmp"))
    opts = parser.parse_args(argv)
    if not opts.app and not opts.tag:
        parser.error("name the app with --app, or the tag of a DerivedData Debug app with --tag")
    if opts.story:
        if opts.variant:
            parser.error("--story records the bundle's own page: a --variant page is not the measured build's")
        if not opts.engine:
            parser.error("--story records one engine: pass --engine")
        problem = story_problem(opts.story, opts.engine)
        if problem:
            parser.error(problem)
    for flag, specs in (("--variant", opts.variant), ("--variant-shared", opts.variant_shared)):
        for spec in specs:
            if "=" not in spec:
                parser.error(f"{flag} {spec!r} is not name=directory")
    names = {spec.split("=", 1)[0] for spec in opts.variant}
    for spec in opts.variant_shared:
        if spec.split("=", 1)[0] not in names:
            parser.error(f"--variant-shared {spec!r} names no --variant")
    shared = dict(spec.split("=", 1) for spec in opts.variant_shared)
    opts.shared = {}
    for name, directory in (spec.split("=", 1) for spec in opts.variant):
        folder = variant_shared(directory, shared.get(name))
        if folder is False:
            parser.error(f"--variant {name}: its page imports {SHARED_ORIGIN} but no pages/_shared was found; "
                         f"pass --variant-shared {name}=<its build's pages/_shared>")
        opts.shared[name] = folder
    return opts


SHARED_ORIGIN = "cmux-page://cmux.shared/"  # build-pages.mjs SHARED_ORIGIN


def variant_shared(directory, given):
    """The shared folder of a variant's build: `given`, else its sibling pages/_shared; None when its page imports
    no shared file, False when it does and there is none."""
    if given:
        return os.path.abspath(given)
    try:
        with open(os.path.join(directory, "index.html"), encoding="utf-8") as handle:
            names_shared = SHARED_ORIGIN in handle.read()
    except OSError:
        return None  # no page there: the app reports it
    if not names_shared:
        return None
    sibling = os.path.join(os.path.dirname(os.path.abspath(directory.rstrip("/"))), "pages", "_shared")
    return sibling if os.path.isdir(sibling) else False


def find_app(opts):
    """--app, else the tag's DerivedData Debug app; None when there is none."""
    if opts.app:
        return os.path.realpath(opts.app.rstrip("/"))
    return next(iter(sorted(glob.glob(os.path.expanduser(
        f"~/Library/Developer/Xcode/DerivedData/*/Build/Products/Debug/cmux DEV {opts.tag}.app")))), None)


def wait(predicate, seconds, step=0.25):
    end = time.time() + seconds
    while time.time() < end:
        value = predicate()
        if value:
            return value
        time.sleep(step)  # test harness wait, not app code
    return None


def run_variant(opts, app, name, directory, scratch):
    """The variant's stream runs: per run its reply and the frames read after it, the engine the tab showed in, and
    the result-v1 paths when this run records."""
    env = {}
    if directory:
        env["CMUX_NEXT_PAGE_ROOT_cmux_agent"] = os.path.abspath(directory)
    if opts.shared.get(name):
        env["CMUX_NEXT_PAGE_ROOT_cmux_shared"] = opts.shared[name]
    if opts.engine:
        tunables = os.path.join(scratch, f"debug-tunables-{name}.json")
        with open(tunables, "w") as handle:
            json.dump({"version": 1, "values": ENGINE_TUNABLES[opts.engine]}, handle)
        env["CMUX_NEXT_DEBUG_TUNABLES_FILE"] = tunables
    bench = BenchApp(app, out=opts.out, env=env, config=ENGINE_CONFIG.get(opts.engine, {}),
                     window=(40, 40, 1400, 900), screen="last", log_name=f"app-{name}.log",
                     build_config=opts.build_config)
    runs, shown = [], None

    def rpc(method, params=None, timeout=60):
        return rpc_at(bench.socket, method, params, timeout) or {}

    try:
        try:
            bench.launch(timeout=120)  # returns once a window is up; prints the reason when it does not come up
        except LaunchError:
            sys.exit(f"{name}: the tagged app did not come up")
        time.sleep(2)  # test harness: the window settles before the key
        rpc("debug.key", {"key": "i", "modifiers": ["cmd", "shift"]})
        if not wait(lambda: "error" not in rpc("debug.agent_pane", {"action": "pid"}), 60, 0.5):
            sys.exit(f"{name}: no agent tab")
        time.sleep(3)  # test harness: the agent page loads
        shown = rpc("debug.agent_pane", {"action": "engine"}).get("engine")
        print(f"{name}: engine {shown}, full rate {rpc('debug.agent_pane', {'action': 'full_rate', 'enabled': True})}",
              flush=True)
        for run in range(opts.runs):
            result = rpc("debug.agent_pane", {"action": "stream", "rows": opts.rows, "seconds": opts.seconds,
                                              "chunk_chars": opts.chunk_chars, "chunk_ms": opts.chunk_ms},
                         timeout=opts.seconds + 120)
            print(f"{name} run {run + 1}: {json.dumps(result)}", flush=True)
            # The stream reset the page's frame samples at its start, so a run that worked reads its own frames; a
            # failed or timed-out one gets none (report.run_frames), never the last run's ring.
            frames = {}
            if "error" not in result:
                frames = rpc("debug.agent_pane", {"action": "perf_stats", "raw": True}, timeout=30)
            frames = report.run_frames(result, frames)
            runs.append({"reply": result, **{key: report.frame_samples(frames, key)
                                             for key in ("interval_ms", "layout_ms", "react_ms")}})
    finally:
        bench.stop()
    written = None
    if opts.story and name == BUNDLED:
        written = report.record_all(bench, report.stream_series(opts.engine, runs, shown, story=opts.story),
                                    engine=opts.engine, session=opts.session)
    return runs, shown, written


def main(argv=None):
    opts = parse(argv)
    app = find_app(opts)
    if not app:
        sys.exit(f"no tagged app for {opts.tag}")
    tag = opts.tag or tag_of(app)
    scratch = tempfile.mkdtemp(prefix=f"stream-{tag}-")
    variants = [spec.split("=", 1) for spec in opts.variant] or [(BUNDLED, None)]
    all_results, recorded = {}, {}
    for name, directory in variants:
        runs, shown, written = run_variant(opts, app, name, directory, scratch)
        all_results[name] = [r["reply"] for r in runs]
        if written is not None:
            recorded[name] = {"engine": shown, "result_v1": written}
    os.makedirs(opts.out, exist_ok=True)
    with open(os.path.join(opts.out, f"agent-stream-{tag}.json"), "w") as handle:
        json.dump(all_results, handle, indent=1)
    print("\nmedians (per run):")
    print("variant  " + "  ".join(".".join(column) for column in report.STREAM_COLUMNS))
    for name, results in all_results.items():
        print(f"{name:8} " + "  ".join(str(report.stream_median(results, *column)) for column in report.STREAM_COLUMNS))
    if opts.story:
        written = (recorded.get(BUNDLED) or {}).get("result_v1") or {}
        if not report.any_written(written):
            sys.exit("RESULT-V1 FAIL: no series written")
        print(f"result-v1: {len(written)} series under {opts.story}", flush=True)


if __name__ == "__main__":
    main()
