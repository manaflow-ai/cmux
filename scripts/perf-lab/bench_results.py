#!/usr/bin/env python3
"""cmux-perf-result/v1 for benches that launch no app: the webviews benches (bun, node) and their Python stages.

BenchApp.record (scripts/cmux-next/bench_launch.py) fills a result's build, host and features from the app it launched.
A webviews bench measures the checkout's own code in bun, jsdom or a headless browser, with no app to read, so this
module fills those blocks from the lab's environment and writes through perf_result.write_ndjson. The writer stays the
one validator, as every catapult benchmark writes through the one HistogramSet serializer
(third_party/catapult/tracing/tracing/value/histogram_set.py).

When PERF_RESULT_DIR is unset nothing is written: a bench run by hand prints its report as before.

The blocks come from the story runner's variables (run_story.py story_env), each with a default for a manual run:

  story    PERF_LAB_STORY, else the bench's own story id
  run      PERF_LAB_RUN_ID and PERF_LAB_RUN_STARTED_AT (one story run spans several bench processes, and the ingest
           stores one run per run id and story), else the bench process's run, else a new run
  build    sha PERF_LAB_SHA, else `git rev-parse HEAD` of this checkout; config PERF_LAB_CONFIG, else release (the
           config of a linux story, stories.d/README.md); measure_version PERF_LAB_MEASURE_VERSION, else 1
  host     the block in PERF_LAB_HOST_FILE, else this machine's (local_host)
  session  PERF_LAB_SESSION, else light

A webviews bench has no feature registry: features are empty, features_hash and safe_mode null.

Python benches import this file by path and call record(). Other benches pipe one JSON spec to the CLI
(webviews/scripts/perf-result.mjs does):

  echo '{"story": "webviews", "engine": "none", "results": [{"metric": "web.x", "unit": "ms",
         "better": "lower", "samples": [1.5, 2.0]}]}' | PERF_RESULT_DIR=OUT python3 -I scripts/perf-lab/bench_results.py

It prints the written file's path (nothing when PERF_RESULT_DIR is unset) and exits 2 on an invalid spec or result.
Stdlib only, loaded by file path under python3 -I.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import platform
import re
import subprocess
import sys
from pathlib import Path
from types import ModuleType
from typing import Any, Callable, Mapping, Optional

HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parent.parent

RESULT_DIR_ENV = "PERF_RESULT_DIR"
STORY_ENV, RUN_ID_ENV, RUN_STARTED_ENV = "PERF_LAB_STORY", "PERF_LAB_RUN_ID", "PERF_LAB_RUN_STARTED_AT"
SHA_ENV, CONFIG_ENV, MEASURE_VERSION_ENV = "PERF_LAB_SHA", "PERF_LAB_CONFIG", "PERF_LAB_MEASURE_VERSION"
HOST_FILE_ENV, SESSION_ENV = "PERF_LAB_HOST_FILE", "PERF_LAB_SESSION"
DEFAULT_CONFIG = "release"
DEFAULT_MEASURE_VERSION = 1
DEFAULT_SESSION = "light"
SPEC_KEYS = ("story", "engine", "results", "run")
SERIES_KEYS = ("metric", "unit", "better", "samples")


def _load(name: str, path: Path) -> ModuleType:
    if name not in sys.modules:
        spec = importlib.util.spec_from_file_location(name, path)
        module = importlib.util.module_from_spec(spec)
        sys.modules[name] = module  # dataclasses resolve their module through sys.modules
        spec.loader.exec_module(module)
    return sys.modules[name]


perf_result = _load("perf_result", HERE / "perf_result.py")  # the name bench_launch and ingest use


class BenchResultsError(ValueError):
    """A spec, environment or host this module cannot turn into results; nothing is written."""


def _slug(text: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", text.strip().lower()).strip("-") or "unknown"


def _cpu_model(read_text: Callable[[str], str]) -> str:
    """The first `model name` of /proc/cpuinfo (Linux), else the platform's processor or machine name."""
    try:
        for line in read_text("/proc/cpuinfo").splitlines():
            key, _, value = line.partition(":")
            if key.strip() == "model name" and value.strip():
                return value.strip()
    except OSError:
        pass
    return platform.processor() or platform.machine() or ""


def _memory_bytes() -> int:
    try:
        return int(os.sysconf("SC_PAGE_SIZE")) * int(os.sysconf("SC_PHYS_PAGES"))
    except (OSError, ValueError):
        return 0


def local_host(
    read_text: Callable[[str], str] = lambda path: Path(path).read_text(encoding="utf-8", errors="replace"),
    system: Optional[str] = None,
    release: Optional[str] = None,
    cpu_count: Optional[int] = None,
    memory_bytes: Optional[int] = None,
):
    """This machine's host block for a bench with no display: chip, CPU count and memory, no macOS and no Hz.

    The class is `<system>:<chip>:<n>cpu:<m>gb`, never the Mac's chip/<n>gb/<n>hz form, so the ingest keeps it as the
    series host class as is (ingest._store_host). The fingerprint adds the kernel release, as a Mac's adds its macOS
    build: a kernel update is a new fingerprint inside one series. Raises BenchResultsError when the chip, CPU count
    or memory cannot be read, since zeros would make a series of their own.
    """
    system = _slug(system if system is not None else platform.system())
    release = release if release is not None else platform.release()
    chip = _cpu_model(read_text)
    cpus = cpu_count if cpu_count is not None else os.cpu_count() or 0
    memory = memory_bytes if memory_bytes is not None else _memory_bytes()
    missing = [name for name, value in (("chip", chip), ("CPU count", cpus), ("memory", memory)) if not value]
    if missing:
        raise BenchResultsError(f"this host's {', '.join(missing)} could not be read; "
                                f"set {HOST_FILE_ENV} to a host block")
    fingerprint = hashlib.sha256("\0".join(str(v) for v in (system, chip, release, cpus, memory)).encode())
    return perf_result.Host(fingerprint=fingerprint.hexdigest(),
                            host_class=f"{system}:{_slug(chip)}:{cpus}cpu:{round(memory / 2 ** 30)}gb",
                            chip=chip, macos=None, macos_build=None, display_hz=None)


def lab_host(environ: Mapping[str, str], host: Callable[[], Any] = local_host):
    """The runner's host block (PERF_LAB_HOST_FILE) when it names one, else ``host()``."""
    path = environ.get(HOST_FILE_ENV, "").strip()
    if not path:
        return host()
    try:
        return perf_result.Host.from_dict(json.loads(Path(path).read_text(encoding="utf-8")))
    except (OSError, ValueError, KeyError, TypeError) as error:
        raise BenchResultsError(f"{HOST_FILE_ENV}={path} is not a host block ({error})") from None


def _git_head(repo: Path) -> str:
    try:
        done = subprocess.run(["git", "-C", str(repo), "rev-parse", "HEAD"], capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise BenchResultsError(f"no build sha: git rev-parse failed ({error}); set {SHA_ENV}") from None
    if done.returncode != 0:
        raise BenchResultsError(f"no build sha: {done.stderr.strip()[:200]}; set {SHA_ENV}")
    return done.stdout.strip()


def lab_build(environ: Mapping[str, str], head: Callable[[], str] = lambda: _git_head(REPO_ROOT)):
    """The measured build: the runner's sha, config and measure version, or this checkout's HEAD as a release build."""
    version_text = environ.get(MEASURE_VERSION_ENV, "").strip()
    try:
        version = int(version_text) if version_text else DEFAULT_MEASURE_VERSION
    except ValueError:
        raise BenchResultsError(f"{MEASURE_VERSION_ENV}={version_text!r} is not an integer") from None
    return perf_result.Build(sha=environ.get(SHA_ENV, "").strip() or head(),
                             config=environ.get(CONFIG_ENV, "").strip() or DEFAULT_CONFIG,
                             measure_version=version)


def lab_run(environ: Mapping[str, str], spec_run: Optional[Mapping[str, str]] = None):
    """The story run (both PERF_LAB_RUN_* set), else the bench process's run from its spec, else a new run."""
    run_id, started = environ.get(RUN_ID_ENV, "").strip(), environ.get(RUN_STARTED_ENV, "").strip()
    if run_id or started:
        if not (run_id and started):
            raise BenchResultsError(f"set both {RUN_ID_ENV} and {RUN_STARTED_ENV}, or neither")
        return perf_result.Run(id=run_id, started_at=started)
    if spec_run is not None:
        if not isinstance(spec_run, Mapping) or set(spec_run) != {"id", "started_at"}:
            raise BenchResultsError("spec run needs exactly id and started_at")
        return perf_result.Run(id=spec_run["id"], started_at=spec_run["started_at"])
    return perf_result.Run.start()


def build_results(spec: Mapping[str, Any], environ: Mapping[str, str], *, build=None, host=None) -> list:
    """The Results of one spec: {story, engine, results: [{metric, unit, better, samples}], run?}."""
    if not isinstance(spec, Mapping):
        raise BenchResultsError("the spec is not an object")
    unknown = sorted(set(spec) - set(SPEC_KEYS))
    missing = [key for key in SPEC_KEYS[:3] if key not in spec]
    if unknown or missing:
        raise BenchResultsError(f"spec keys: missing {missing}, unknown {unknown}")
    series = spec["results"]
    if not isinstance(series, list) or not series:
        raise BenchResultsError("spec results is an empty list or not a list")
    for index, entry in enumerate(series):
        if not isinstance(entry, Mapping) or set(entry) != set(SERIES_KEYS):
            raise BenchResultsError(f"results[{index}] needs exactly {', '.join(SERIES_KEYS)}")
    story = environ.get(STORY_ENV, "").strip() or spec["story"]
    run = lab_run(environ, spec.get("run"))
    build = build if build is not None else lab_build(environ)
    host = host if host is not None else lab_host(environ)
    session = environ.get(SESSION_ENV, "").strip() or DEFAULT_SESSION
    return [perf_result.Result(story=story, metric=entry["metric"], unit=entry["unit"], better=entry["better"],
                               samples=entry["samples"], build=build, host=host, engine=spec["engine"],
                               session=session, run=run)
            for entry in series]


def record(spec: Mapping[str, Any], environ: Optional[Mapping[str, str]] = None, *, build=None, host=None,
           repo_root: Path = REPO_ROOT) -> Optional[Path]:
    """Writes the spec's results as one result-v1 file into PERF_RESULT_DIR and returns its path; None (nothing
    read, nothing written) when PERF_RESULT_DIR is unset. Raises BenchResultsError or perf_result.ResultError."""
    environ = os.environ if environ is None else environ
    directory = environ.get(RESULT_DIR_ENV, "").strip()
    if not directory:
        return None
    return perf_result.write_ndjson(directory, build_results(spec, environ, build=build, host=host),
                                    repo_root=repo_root)


def main(argv: Optional[list[str]] = None, stdin=None, stdout=None, environ: Optional[Mapping[str, str]] = None) -> int:
    parser = argparse.ArgumentParser(description="Write result-v1 from a JSON spec on stdin into $PERF_RESULT_DIR.")
    parser.parse_args(argv)
    stdin = sys.stdin if stdin is None else stdin
    stdout = sys.stdout if stdout is None else stdout
    try:
        spec = json.loads(stdin.read())
        path = record(spec, environ)
    except (BenchResultsError, perf_result.ResultError, json.JSONDecodeError) as error:
        print(f"bench-results: {error}", file=sys.stderr)
        return 2
    if path is not None:
        print(path, file=stdout)
    return 0


if __name__ == "__main__":
    sys.exit(main())
