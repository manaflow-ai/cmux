"""The perf lab for a bench outside scripts/cmux-next: its modules by file path, and result-v1 for a run.

A bench runs under ``python3 -I``, which puts no script folder on sys.path, so it loads this file by path
and takes everything else from it::

    _spec = importlib.util.spec_from_file_location("perf_import", <repo>/scripts/perf-lab/perf_import.py)
    perf_import = importlib.util.module_from_spec(_spec)
    _spec.loader.exec_module(perf_import)
    perf_stats = perf_import.load("perf_stats")

``load_by_path`` is the same code as scripts/cmux-next/bench_launch.py's load_by_path (registered in
sys.modules before exec, removed when exec fails; tests/test_stats_helpers_migration.py checks both), so a
module loaded here and one loaded there are the same object. ``measured_build`` names the build and host of
a run that measured an app bundle (``--app``), as bench_daemon_spawn.measured_build does, and
``write_series`` writes every series of one run as cmux-perf-result/v1 through perf_result. Stdlib only.
"""
import collections
import importlib.util
import os
import sys

PERF_LAB = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(PERF_LAB))
BENCH_LAUNCH = os.path.join(ROOT, "scripts", "cmux-next", "bench_launch.py")

# One series of one run: result-v1's metric, unit, better and raw samples.
Series = collections.namedtuple("Series", "metric unit better samples")


def load_by_path(name, path):
    """The module at `path`, imported as `name` once per process (bench_launch.load_by_path)."""
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None:
        raise ImportError(f"perf-import: no module at {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module  # before exec: a dataclass resolves its module through sys.modules
    try:
        spec.loader.exec_module(module)
    except BaseException:
        del sys.modules[name]
        raise
    return module


def load(name):
    """scripts/perf-lab/<name>.py, imported as `name`."""
    return load_by_path(name, os.path.join(PERF_LAB, f"{name}.py"))


def bench_launch():
    """scripts/cmux-next/bench_launch.py (its RecordError, build_sha, build_config and read_host)."""
    return load_by_path("bench_launch", BENCH_LAUNCH)


def measured_build(app, stated_config=None):
    """(result-v1 Build, Host) of the bundle `app` on this Mac. Raises bench_launch.RecordError when the build or
    the host cannot be named; call it before the run, so a run that cannot be recorded never starts."""
    launch = bench_launch()
    perf_result = load("perf_result")
    build = perf_result.Build(sha=launch.build_sha(app),
                              config=launch.build_config(app, launch.main_binary(app), stated_config),
                              measure_version=launch.PERF_LAB_MEASURE_VERSION)
    return build, perf_result.Host.from_dict(launch.read_host())


def write_series(out, story, session, engine, series, build, host, run=None, features=None):
    """Every non-empty series of one run into one result-v1 file in `out` (validated first: nothing is written
    when one is invalid). `features` is the measured app's (features, features_hash, safe_mode)
    (bench_launch.features_snapshot); None for a run with no app (a headless daemon). The file's path."""
    perf_result = load("perf_result")
    run = run or perf_result.Run.start()
    names, features_hash, safe_mode = features or ({}, None, None)
    resolved = {name: perf_result.Feature(**value) for name, value in names.items()}
    results = [perf_result.Result(story=story, metric=s.metric, unit=s.unit, better=s.better,
                                  samples=list(s.samples), build=build, host=host, engine=engine,
                                  session=session, run=run, features=resolved, features_hash=features_hash,
                                  safe_mode=safe_mode)
               for s in series if s.samples]
    return perf_result.write_ndjson(out, results, repo_root=ROOT)
