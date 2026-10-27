#!/usr/bin/env python3
"""Cost of fsync, F_FULLFSYNC and F_BARRIERFSYNC on this disk (--writes x 4 KiB writes each, macOS).

  fsync-bench.py [--writes 40] [--app APP --out DIR [--tag TAG] [--build-config CONFIG]]

Prints one line per mode: p50, p95 and p99 (perf_stats.pct) in ms. With --out, every call's ms is written as
cmux-perf-result/v1 (`fsync.<mode>.call`, story fsync): the results name the --app bundle's build, the build the lab
run measures, and this host. The daemon's journal and the store write through these calls.
"""
import argparse
import os
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)  # its siblings, also under `python3 -I`
from bench_launch import RecordError  # noqa: E402
import idle_burst_bench_report as results  # noqa: E402


def parse(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--writes", type=int, default=40, help="4 KiB writes per mode, each followed by its sync")
    parser.add_argument("--app", help="the measured app bundle: it names the result's build")
    parser.add_argument("--out", help="write cmux-perf-result/v1 here")
    parser.add_argument("--tag")  # the story runner passes it; the bundle carries the tag
    parser.add_argument("--story", default=results.FSYNC_STORY, help="result-v1 story")
    parser.add_argument("--build-config", choices=["bench", "bench-checks", "release", "debug"],
                        help="result-v1 build config of a bench-hooks bundle that does not stamp it")
    opts = parser.parse_args(argv)
    if opts.writes < 1:
        parser.error("--writes must be at least 1")
    if opts.out and not opts.app:
        parser.error("--out needs --app: a result names the build it measured")
    return opts


def measure(writes):
    """{mode: [ms of each sync call]}, `writes` 4 KiB writes per mode over 16 blocks of one file in a new folder."""
    import fcntl
    folder = tempfile.mkdtemp(dir="/tmp")
    fd = os.open(os.path.join(folder, "x"), os.O_RDWR | os.O_CREAT)
    times = {}
    try:
        for mode, command in results.FSYNC_MODES:
            calls = times.setdefault(mode, [])
            for i in range(writes):
                os.pwrite(fd, os.urandom(4096), (i % 16) * 4096)
                start = time.perf_counter()
                if command is None:
                    os.fsync(fd)
                else:
                    fcntl.fcntl(fd, command)
                calls.append((time.perf_counter() - start) * 1000)
    finally:
        os.close(fd)
        os.unlink(os.path.join(folder, "x"))
        os.rmdir(folder)
    return times


def main(argv=None):
    opts = parse(argv)
    measured = results.measured_build(opts.app, opts.build_config) if opts.out else None  # refuse before any run
    times = measure(opts.writes)
    for mode, calls in times.items():
        print(results.fsync_line(mode, calls), flush=True)
    if measured:
        build, host = measured
        try:
            path = results.write_all(opts.out, results.fsync_series(times, story=opts.story), build, host)
        except (RecordError, results.perf_result.ResultError) as error:
            print(f"result-v1: not recorded: {error}", flush=True)
            return 1
        print(f"result-v1: {path}", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
