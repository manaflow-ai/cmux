#!/usr/bin/env python3
"""What split-latency-bench.py and bench-typing.py share when they launch a tagged build (p05-ipc-005).

- ``resolve_app(tag, app)``: the `cmux DEV <tag>.app` to launch: `--app`, else `$NX_APP` (a fleet step), else the
  tag's DerivedData build.
- ``daemon_socket(tag)``: the app's cmux-tui daemon socket (`$DARWIN_USER_TEMP_DIR/cmux-tui-*/cmux-app-<tag>.sock`,
  as bench-startup.py finds it).
- ``distribution(values)``: n, p50, p95, p99 and max of raw samples (nearest rank; never a mean alone).
- ``host_block()``: host name, platform, chip, macOS and its build, and the main display's Hz (bench_launch.read_host);
  None for what the host does not give (a Linux remote host has no sw_vers), never an exception.
- ``record_series(app, story, metric_samples, ...)``: one cmux-perf-result/v1 file per series through
  ``BenchApp.record``; a result that cannot be described truthfully (no build sha, no features snapshot) is
  skipped with its reason, not written wrong.

The launch itself is bench_launch.BenchApp's (one launch path for every GUI bench).
"""
import glob, math, os, platform, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
if HERE not in sys.path:
    sys.path.insert(0, HERE)
import bench_launch  # noqa: E402

DERIVED = os.path.expanduser("~/Library/Developer/Xcode/DerivedData")


def resolve_app(tag, app=None, environ=None):
    """The bundle path for `tag`; SystemExit naming every place looked at when there is none."""
    environ = os.environ if environ is None else environ
    if app:
        return app
    nx_app = environ.get("NX_APP")
    if nx_app:
        return nx_app
    if not tag:
        raise SystemExit("bench: pass --tag TAG or --app APP")
    looked = [os.path.join(DERIVED, f"cmux-{tag}", "Build/Products/Debug", f"cmux DEV {tag}.app"),
              os.path.join(DERIVED, "*", "Build/Products/*", f"cmux DEV {tag}.app")]
    for pattern in looked:
        found = sorted(glob.glob(pattern))
        if found:
            return found[0]
    raise SystemExit(f"bench: no build of tag {tag} (looked at --app, $NX_APP, {', '.join(looked)})")


def user_temp_dir():
    try:
        out = subprocess.run(["getconf", "DARWIN_USER_TEMP_DIR"], capture_output=True, text=True, timeout=10).stdout
    except (OSError, subprocess.TimeoutExpired):
        out = ""
    return out.strip() or os.environ.get("TMPDIR", "/tmp")


def daemon_socket(tag, timeout=30, temp_dir=None):
    """The cmux-tui socket of the tagged app's daemon; SystemExit when it does not appear within `timeout` s."""
    pattern = os.path.join(temp_dir or user_temp_dir(), "cmux-tui-*", f"cmux-app-{tag}.sock")
    deadline = time.monotonic() + timeout
    while True:
        found = sorted(glob.glob(pattern))
        if found:
            return found[0]
        if time.monotonic() >= deadline:
            raise SystemExit(f"bench: no daemon socket for tag {tag} after {timeout} s ({pattern})")
        time.sleep(0.2)  # bounded wait for the daemon the app is starting


def distribution(values):
    """{n, p50, p95, p99, max} of the samples that are not None (nearest rank), or None for no sample."""
    v = sorted(x for x in values if x is not None)
    if not v:
        return None

    def rank(q):
        return v[max(0, min(len(v) - 1, math.ceil(q * len(v)) - 1))]
    return {"n": len(v), "p50": round(rank(0.50), 3), "p95": round(rank(0.95), 3), "p99": round(rank(0.99), 3),
            "max": round(v[-1], 3)}


def host_block():
    """This host as a bench report names it: host, platform, macOS, chip, memory class and display Hz. Never raises: a
    field the host does not give (no sw_vers or pmset on a Linux remote host, no CoreGraphics) is None, and
    `host_record_error` says why read_host refused."""
    block = {"host": platform.node(), "platform": platform.platform(), "macos": None, "low_power_mode": None}
    try:
        block.update(bench_launch.host_facts())
    except (OSError, subprocess.SubprocessError) as error:
        block["host_facts_error"] = str(error)
    block["macos"] = block.get("macos") or None
    try:
        host = bench_launch.read_host()
    except (bench_launch.RecordError, OSError, subprocess.SubprocessError) as error:
        return {**block, "display_hz": bench_launch.main_display_hz(), "host_record_error": str(error)}
    return {**block, **host}


def record_series(app, story, series, unit="ms", better="lower", engine="none", log=print, targets=None):
    """Writes each {metric: samples} of `series` as one result through ``app.record``, with the targets.json row of
    {metric: target id} `targets` as its target_ref (a dashboard target tile reads only results that name it).
    Returns {metric: path or the reason it was not written}."""
    targets = targets or {}
    written = {}
    for metric, samples in series.items():
        samples = [s for s in samples if s is not None]
        if not samples:
            written[metric] = "no samples"
            continue
        try:
            written[metric] = str(app.record(story, metric, unit, samples, better=better, engine=engine,
                                             target_ref=targets.get(metric)))
        except Exception as error:  # RecordError or perf_result.ResultError: nothing was written
            written[metric] = f"not recorded: {error}"
            log(f"bench: {story}/{metric} not recorded: {error}")
    return written


def summary_line(name, stats, width=34):
    if not stats:
        return f"{name:<{width}} (no samples)"
    return (f"{name:<{width}} p50 {stats['p50']:9.2f}  p95 {stats['p95']:9.2f}  p99 {stats['p99']:9.2f}  "
            f"max {stats['max']:9.2f}  n={stats['n']}")
