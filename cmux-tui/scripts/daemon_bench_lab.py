"""The perf lab side of the daemon and Rust benches in this folder (p12-perf-process-218).

Every percentile comes from scripts/perf-lab/perf_stats.py (`pct`, linear interpolation) and every lab result is
cmux-perf-result/v1 written through scripts/perf-lab/perf_result.py (perf_import.write_series). A daemon bench
measures one cmux-tui binary and needs no window, so the lab runs it in its Linux part (stories.d, tier `linux`). The
run names the build it measured, and a result never guesses it:

  --build       build cmux-tui at this checkout (`cargo build --release --locked -p cmux-tui`, $CARGO_TARGET_DIR) and
                measure it: the checkout's HEAD, config release. The linux stories use it. $PERF_LAB_SHA, when set,
                must be HEAD; any --app the runner appends is ignored, since a Linux host has no app bundle
  --app APP     an app bundle (a lab Mac): its Contents/Resources/bin/cmux-tui is the daemon, and its Info.plist names
                the commit and config (bench_launch.build_sha, build_config)
  --bin BIN     any cmux-tui, named by --sha (default $PERF_LAB_SHA) and --build-config (default $PERF_LAB_CONFIG)

The host block is the runner's $PERF_LAB_HOST_FILE when set, else this host's: `linux_host` (/proc) on Linux,
bench_launch.read_host on a Mac. Under the Mac runner ($PERF_LAB_VDISPLAY_OUT), `validate_host` runs host_env.py's
full validation over the daemon's pids and leaves its host-env-full-<pid>.json in the result folder, as BenchApp
does after a launch.

`--out PATH` of each bench: a path ending in .json is the report file alone (the scripts/measure fleet entries);
any other path is a folder that gets the result-v1 file and the report (the lab runner's `--out DIR`).

Stdlib only; load it by path (the benches run under python3 -I, so this folder is not on sys.path).
"""
import collections
import hashlib
import importlib.util
import json
import os
import platform
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
CARGO_WORKSPACE = os.path.join(ROOT, "cmux-tui")
PERF_IMPORT = os.path.join(ROOT, "scripts", "perf-lab", "perf_import.py")

SHA_ENV, CONFIG_ENV, HOST_FILE_ENV, VDISPLAY_ENV = (
    "PERF_LAB_SHA", "PERF_LAB_CONFIG", "PERF_LAB_HOST_FILE", "PERF_LAB_VDISPLAY_OUT")
SESSION = "light"  # a headless daemon has no app session; every daemon story is light
ENGINE = "none"
BUILT_CONFIG = "release"  # what `--build` and a cargo --release build are
BUNDLED_DAEMON = "Contents/Resources/bin/cmux-tui"
REPORT_SUFFIX = ".json"
# result-v1 build.measure_version of the daemon stories: bump it when what these benches measure, or how, changes.
MEASURE_VERSION = 1
BUILD_TIMEOUT_SECONDS = 3600


def _load_perf_import():
    name = "perf_import"
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, PERF_IMPORT)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    try:
        spec.loader.exec_module(module)
    except BaseException:
        del sys.modules[name]
        raise
    return module


perf_import = _load_perf_import()
perf_stats = perf_import.load("perf_stats")
perf_result = perf_import.load("perf_result")
Series = perf_import.Series
pct = perf_stats.pct

Outputs = collections.namedtuple("Outputs", "results report")
Measured = collections.namedtuple("Measured", "build host")


class LabError(RuntimeError):
    """The run cannot be recorded truthfully (no build sha or config, a host that cannot be read, a failed build)."""


def outputs(out, report_name):
    """(result folder or None, report path or None) of a bench's `--out`."""
    if not out:
        return Outputs(None, None)
    if out.endswith(REPORT_SUFFIX):
        return Outputs(None, out)
    return Outputs(out, os.path.join(out, report_name))


def spans_copy(out):
    """Where a bench keeps its debug spans beside the report. In a result folder no other file may end .ndjson: the
    story runner takes every *.ndjson there for result-v1 (run_story.py collect)."""
    return out.report + (".spans.jsonl" if out.results else ".spans.ndjson")


def full_sha(sha, root=ROOT):
    """The 40-hex commit `sha` names (a short one is resolved in this checkout); LabError when it names none."""
    sha = (sha or "").strip().lower()
    if re.fullmatch(r"[0-9a-f]{40}", sha):
        return sha
    if re.fullmatch(r"[0-9a-f]{7,39}", sha):
        done = subprocess.run(["git", "-C", root, "rev-parse", "--verify", "--quiet", f"{sha}^{{commit}}"],
                              capture_output=True, text=True, timeout=30)
        if re.fullmatch(r"[0-9a-f]{40}", done.stdout.strip()):
            return done.stdout.strip()
    raise LabError(f"no build sha: --sha / ${SHA_ENV} is {sha!r}, not a commit of {root}")


def checkout_sha(root=ROOT, environ=None):
    """HEAD of the checkout a story builds; $PERF_LAB_SHA, when set, must name the same commit."""
    environ = os.environ if environ is None else environ
    done = subprocess.run(["git", "-C", root, "rev-parse", "HEAD"], capture_output=True, text=True, timeout=30)
    head = done.stdout.strip()
    if not re.fullmatch(r"[0-9a-f]{40}", head):
        raise LabError(f"{root} has no HEAD commit")
    stated = environ.get(SHA_ENV)
    if stated and full_sha(stated, root) != head:
        raise LabError(f"${SHA_ENV} is {stated}, but the checkout that builds is {head}")
    return head


def cargo(argv, cwd=CARGO_WORKSPACE, environ=None, timeout=BUILD_TIMEOUT_SECONDS):
    """Runs `cargo ARGV` in `cwd`; its stdout. Raises LabError with the output's tail when it fails."""
    environ = dict(os.environ if environ is None else environ)
    try:
        done = subprocess.run(["cargo", *argv], cwd=cwd, env=environ, capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise LabError(f"cargo {' '.join(argv)}: {error}") from None
    if done.returncode != 0:
        raise LabError(f"cargo {' '.join(argv)} exited {done.returncode}: {(done.stderr or done.stdout)[-2000:]}")
    return done.stdout


def target_dir(cwd=CARGO_WORKSPACE, environ=None):
    environ = os.environ if environ is None else environ
    return environ.get("CARGO_TARGET_DIR") or os.path.join(cwd, "target")


def build_daemon(environ=None):
    """cmux-tui built in release at this checkout; its path."""
    cargo(["build", "--release", "--locked", "-p", "cmux-tui", "--bin", "cmux-tui"], environ=environ)
    return os.path.join(target_dir(environ=environ), "release", "cmux-tui")


def linux_host(read=None, cpus=None, release=None):
    """This Linux host's result-v1 host block. The class is the series' host part: the CPU model, cores and memory
    decide a daemon's numbers, a display does not (display_hz null). `read(path)` is the /proc seam."""
    read = read or _read_text
    cpuinfo = read("/proc/cpuinfo")
    chip = next((line.split(":", 1)[1].strip() for line in cpuinfo.splitlines()
                 if ":" in line and line.split(":", 1)[0].strip() in ("model name", "Hardware", "cpu model")), "")
    chip = chip or platform.machine()
    memory = next((int(line.split()[1]) * 1024 for line in read("/proc/meminfo").splitlines()
                   if line.startswith("MemTotal:")), 0)
    cores = cpus if cpus is not None else os.cpu_count()
    if not chip or not memory or not cores:
        raise LabError("this host's CPU model, memory or core count could not be read: a zero would start a series "
                       "of its own")
    release = release if release is not None else platform.release()
    memory_gb = round(memory / 2 ** 30)
    slug = re.sub(r"[^a-z0-9.]+", "-", chip.lower()).strip("-")
    identity = "\0".join(str(v) for v in (chip, cores, memory, release))
    return perf_result.Host(fingerprint=hashlib.sha256(identity.encode()).hexdigest(),
                            host_class=f"linux/{slug}/{cores}c/{memory_gb}gb", chip=chip, macos=None,
                            macos_build=None, display_hz=None)


def _read_text(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        return f.read()


def this_host(environ=None):
    """The runner's host block ($PERF_LAB_HOST_FILE), else this host's."""
    environ = os.environ if environ is None else environ
    host_file = environ.get(HOST_FILE_ENV)
    launch = perf_import.bench_launch()
    try:
        if host_file:
            with open(host_file, encoding="utf-8") as f:
                return perf_result.Host.from_dict(json.load(f))
        if sys.platform.startswith("linux"):
            return linux_host()
        return perf_result.Host.from_dict(launch.read_host())
    except (OSError, ValueError, KeyError, launch.RecordError) as error:
        raise LabError(f"no host block: {error}") from None


def built(sha, environ=None):
    """(build, host) of a binary built at `sha` in release (a `--build` run, a Rust bench story)."""
    return Measured(perf_result.Build(sha=sha, config=BUILT_CONFIG, measure_version=MEASURE_VERSION),
                    this_host(environ))


def bundled(app, config=None, environ=None):
    """(build, host) of an app bundle's daemon: the bundle names its commit and config."""
    launch = perf_import.bench_launch()
    try:
        build = perf_result.Build(sha=launch.build_sha(app),
                                  config=launch.build_config(app, launch.main_binary(app), config),
                                  measure_version=MEASURE_VERSION)
    except launch.RecordError as error:
        raise LabError(str(error)) from None
    return Measured(build, this_host(environ))


def stated(sha, config, environ=None):
    """(build, host) of a `--bin` the caller names: --sha / $PERF_LAB_SHA and --build-config / $PERF_LAB_CONFIG."""
    environ = os.environ if environ is None else environ
    config = config or environ.get(CONFIG_ENV) or None
    if config not in perf_result.CONFIGS:
        raise LabError(f"no build config: --build-config / ${CONFIG_ENV} is {config!r}, not one of "
                       f"{', '.join(perf_result.CONFIGS)} (a cargo --release daemon is {BUILT_CONFIG})")
    return Measured(perf_result.Build(sha=full_sha(sha or environ.get(SHA_ENV)), config=config,
                                      measure_version=MEASURE_VERSION), this_host(environ))


APP_HELP = "an app bundle: its cmux-tui is the daemon, and it names the build"
TAG_HELP = "the lab story runner passes it; the bundle carries the tag"


def add_arguments(parser, story):
    """How a daemon bench names its measured build. Each bench declares the runner's `--app --tag --out` itself
    (APP_HELP, TAG_HELP): run_story.contract_problems reads them from the bench's own source."""
    parser.add_argument("--build", action="store_true",
                        help="build cmux-tui in release at this checkout and measure it (the linux stories)")
    parser.add_argument("--sha", help=f"the commit --bin was built from (default ${SHA_ENV})")
    parser.add_argument("--build-config", choices=perf_result.CONFIGS,
                        help=f"result-v1 build config of --bin (default ${CONFIG_ENV}; cargo --release is release)")
    parser.add_argument("--story", default=story, help=f"result-v1 story (default {story})")


def prepare(parser, args, report_name, environ=None):
    """(daemon binary, Outputs, Measured or None) of a bench's parsed flags, before anything runs: a result folder
    whose run cannot name its build or host stops the bench here (parser.error)."""
    out = outputs(args.out, report_name)
    try:
        if args.build:
            sha = checkout_sha(environ=environ)
            binary = build_daemon(environ)
            run_measured = built(sha, environ) if out.results else None
        elif args.bin:
            binary = args.bin
            run_measured = stated(args.sha, args.build_config, environ) if out.results else None
        elif args.app:
            binary = os.path.join(os.path.realpath(args.app), BUNDLED_DAEMON)
            run_measured = bundled(args.app, args.build_config, environ) if out.results else None
        else:
            parser.error("name the daemon: --build, --bin <cmux-tui> or --app <bundle>")
    except LabError as error:
        parser.error(f"no result-v1 can name this run: {error}")
    if out.results:
        os.makedirs(out.results, exist_ok=True)
    return binary, out, run_measured


def validate_host(results_dir, pids, environ=None, check=None):
    """Under the Mac runner: host_env.py's full validation of the measured daemon's pids into
    `results_dir`/host-env-full-<pid>.json (bench_launch.lab_host_check); the report, or None outside it."""
    environ = os.environ if environ is None else environ
    vdisplay_out = environ.get(VDISPLAY_ENV)
    if not results_dir or not vdisplay_out:
        return None
    launch = perf_import.bench_launch()
    check = check or launch.lab_host_check
    report = check(vdisplay_out, list(pids))
    os.makedirs(results_dir, exist_ok=True)
    with open(os.path.join(results_dir, f"{launch.LAB_CHECK_PREFIX}{pids[0] if pids else 'none'}.json"), "w") as f:
        json.dump(report, f, sort_keys=True)
    return report


def write(results_dir, story, series, run_measured, run=None):
    """Every series with samples into one result-v1 file of `story` in `results_dir`; its path, or None when no
    series has a sample (nothing measured, nothing to store)."""
    kept = [s for s in series if s.samples]
    if not kept:
        return None
    return perf_import.write_series(results_dir, story, SESSION, ENGINE, kept, run_measured.build,
                                    run_measured.host, run=run)


def metric_part(text):
    """A report key as one result-v1 metric name part: lower case, runs of other characters as one `_`."""
    return re.sub(r"[^a-z0-9]+", "_", str(text).lower()).strip("_")
