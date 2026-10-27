#!/usr/bin/env python3
"""The Rust benches of cmux-tui as perf lab stories (p12-perf-process-218).

Each bench is built in release at this checkout, run --runs times, and every run's numbers are written as
cmux-perf-result/v1 (scripts/perf-lab/perf_result.py, through daemon_bench_lab.write): build = the checkout's HEAD,
config release; host = this host (daemon_bench_lab.this_host). A bench that prints a summary gives one sample per run
of each statistic it prints; a bench that prints raw numbers gives them all.

  --bench mux2-parse   cmux-mux2's mux2-parsebench over a fixed corpus (written here, seeded: plain, SGR and cursor
                       lines, --corpus-mb MB), --chunk bytes per write. Story mux2-parse:
                       mux2.parse.<wrapper|raw> (bytes_per_s, higher), mux2.parse.wrapper_overhead (ratio)
  --bench mux2-spawn   cmux-mux2's mux2-spawnbench (macOS only: kqueue, posix_spawn), --count creates per run.
                       Story mux2-spawn: mux2.spawn.<terminal_new|openpty|fork|posix_spawn> (us, the run's p50)
  --bench holder-link  cmux-holder's ignored link_bench tests (cargo test --release --test link_bench -- --ignored).
                       Story holder-link: holder.link.echo.<p50|p95|max> (ms: typed marker to its echo behind two
                       flooding terminals), holder.link.yes4.<holder|direct> (bytes_per_s of four `yes` terminals
                       through the holder and on direct PTYs) and holder.link.yes4.<holder|direct|daemon>_cpu (ms)
  --bench rd-host      cmux-rd (cmux-rd-host, its own workspace): Xvfb, the marker test app, the host and the
                       loopback bench viewer (scripts/loopback-bench.sh's sequence, one token), --samples key presses
                       per run. Linux with Xvfb only. Story rd-host-g2g: rd.g2g.<p50|p95|p99|max> (ms, key press to
                       the decoded frame that shows it), rd.decode.p95 (ms), rd.lost (count), rd.frames (fps)

The story runner appends `--app APP --tag TAG --out DIR`: --app and --tag are ignored (these benches build their own
binary from the checkout), DIR gets the result-v1 file and a report (rust-<bench>.json).

  python3 -I cmux-tui/scripts/bench-rust-lab.py --bench mux2-parse --runs 3 --out DIR
"""
import argparse
import importlib.util
import json
import os
import random
import re
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("daemon_bench_lab", os.path.join(HERE, "daemon_bench_lab.py"))
lab = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(lab)

STORIES = {"mux2-parse": "mux2-parse", "mux2-spawn": "mux2-spawn", "holder-link": "holder-link",
           "rd-host": "rd-host-g2g"}
RD_HOST = os.path.join(lab.CARGO_WORKSPACE, "crates", "cmux-rd-host")
RUN_TIMEOUT_SECONDS = 900
MB = 1_000_000  # mux2-parsebench reports decimal MB/s
MIB = 1 << 20


class BenchError(RuntimeError):
    """A bench that cannot run here or gave no numbers."""


def run(argv, timeout=RUN_TIMEOUT_SECONDS, **kwargs):
    try:
        done = subprocess.run(argv, capture_output=True, text=True, timeout=timeout, **kwargs)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise BenchError(f"{os.path.basename(argv[0])}: {error}") from None
    return done


def json_line(text, key):
    """The last stdout line that is a JSON object with `key`."""
    for line in reversed(text.splitlines()):
        line = line.strip()
        if line.startswith("{"):
            try:
                obj = json.loads(line)
            except ValueError:
                continue
            if isinstance(obj, dict) and key in obj:
                return obj
    raise BenchError(f"no JSON line with {key!r} in the output: {text[-600:]}")


def fields(text, tag):
    """`TAG k=v k=v` of the output as {k: float}; libtest may print `test NAME ... ` before it on the line."""
    for line in text.splitlines():
        at = line.find(tag + " ")
        if at >= 0:
            return {k: float(v) for k, v in re.findall(r"(\w+)=([0-9.]+)", line[at:])}
    raise BenchError(f"no {tag} line in the output: {text[-600:]}")


# ---------------------------------------------------------------- mux2

def write_corpus(path, size, seed=7):
    """A fixed corpus: lines of digits, of words with 16-color SGR runs, and of cursor moves with erases (the three
    kinds of cmux-mux2/bench/gen-corpus.pl), interleaved, from one seed."""
    rng = random.Random(seed)
    words = ["".join(chr(97 + rng.randrange(26)) for _ in range(2 + rng.randrange(9))) for _ in range(2000)]
    written = 0
    with open(path, "w", encoding="ascii", newline="") as f:
        while written < size:
            kind = rng.randrange(3)
            if kind == 0:
                line = " ".join(str(rng.randrange(10 ** 9)) for _ in range(10))
            elif kind == 1:
                line = " ".join((f"\x1b[3{rng.randrange(8)}m" if rng.random() < 0.2 else "") + rng.choice(words)
                                + ("\x1b[0m" if rng.random() < 0.2 else "") for _ in range(12))
            else:
                line = f"\x1b[{1 + rng.randrange(50)};{1 + rng.randrange(150)}H{rng.choice(words)}\x1b[K"
            f.write(line + "\n")
            written += len(line) + 1


def mux2_parse(args, work):
    lab.cargo(["build", "--release", "--locked", "-p", "cmux-mux2", "--bin", "mux2-parsebench"])
    binary = os.path.join(lab.target_dir(), "release", "mux2-parsebench")
    corpus = os.path.join(work, "corpus.txt")
    write_corpus(corpus, args.corpus_mb * MB)
    wrapper, raw, overhead, runs = [], [], [], []
    for _ in range(args.runs):
        done = run([binary, corpus, str(args.chunk)])
        if done.returncode != 0:
            raise BenchError(f"mux2-parsebench exited {done.returncode}: {done.stderr[-600:]}")
        row = json_line(done.stdout, "parsebench")
        runs.append(row)
        wrapper.append(row["wrapper_mb_s"] * MB)
        raw.append(row["raw_mb_s"] * MB)
        overhead.append(row["wrapper_overhead"])
    series = [lab.Series("mux2.parse.wrapper", "bytes_per_s", "higher", wrapper),
              lab.Series("mux2.parse.raw", "bytes_per_s", "higher", raw),
              lab.Series("mux2.parse.wrapper_overhead", "ratio", "lower", overhead)]
    return series, {"chunk": args.chunk, "corpus_mb": args.corpus_mb, "runs": runs}


def mux2_spawn(args, work):
    if sys.platform != "darwin":
        raise BenchError("mux2-spawnbench is macOS only (kqueue, posix_spawn)")
    lab.cargo(["build", "--release", "--locked", "-p", "cmux-mux2", "--bin", "mux2-spawnbench"])
    binary = os.path.join(lab.target_dir(), "release", "mux2-spawnbench")
    keys = ("terminal_new", "openpty", "fork", "posix_spawn")
    samples, runs = {key: [] for key in keys}, []
    for _ in range(args.runs):
        done = run([binary, str(args.count)])
        if done.returncode != 0:
            raise BenchError(f"mux2-spawnbench exited {done.returncode}: {done.stderr[-600:]}")
        row = json_line(done.stdout, "spawnbench")
        runs.append(row)
        for key in keys:
            samples[key].append(row[f"{key}_us"])
    return ([lab.Series(f"mux2.spawn.{key}", "us", "lower", samples[key]) for key in keys],
            {"count": args.count, "runs": runs})


# ---------------------------------------------------------------- holder

def holder_link(args, work):
    lab.cargo(["test", "--release", "--locked", "-p", "cmux-holder", "--test", "link_bench", "--no-run"])
    echo = {"p50": [], "p95": [], "max": []}
    yes4 = {"holder": [], "direct": []}
    cpu = {"holder": [], "direct": [], "daemon": []}
    runs = []
    for _ in range(args.runs):
        # The echo test asserts its p95 after it prints it: a failed assertion still gives this run's numbers, and
        # the regression shows in the series. --strict also fails the run.
        done = run(["cargo", "test", "--release", "--locked", "-p", "cmux-holder", "--test", "link_bench", "--",
                    "--ignored", "--nocapture", "--test-threads", "1"], cwd=lab.CARGO_WORKSPACE,
                   timeout=lab.BUILD_TIMEOUT_SECONDS)
        out = done.stdout + done.stderr
        if args.strict and done.returncode != 0:
            raise BenchError(f"link_bench exited {done.returncode}: {out[-600:]}")
        e, y = fields(out, "ECHO-BEHIND-FLOODERS"), fields(out, "YES-X4")
        runs.append({"echo": e, "yes4": y, "exit": done.returncode})
        for key in echo:
            echo[key].append(e[f"{key}_ms"])
        yes4["holder"].append(y["holder_mib_s"] * MIB)
        yes4["direct"].append(y["direct_mib_s"] * MIB)
        cpu["holder"].append(y["holder_cpu_ms"])
        cpu["direct"].append(y["direct_cpu_ms"])
        cpu["daemon"].append(y["daemon_cpu_ms"])
    series = [lab.Series(f"holder.link.echo.{key}", "ms", "lower", values) for key, values in echo.items()]
    series += [lab.Series(f"holder.link.yes4.{key}", "bytes_per_s", "higher", values) for key, values in yes4.items()]
    series += [lab.Series(f"holder.link.yes4.{key}_cpu", "ms", "lower", values) for key, values in cpu.items()]
    return series, {"runs": runs}


# ---------------------------------------------------------------- rd-host

def free_display():
    for n in range(97, 160):
        if not os.path.exists(f"/tmp/.X11-unix/X{n}") and not os.path.exists(f"/tmp/.X{n}-lock"):
            return f":{n}"
    raise BenchError("no free X display between :97 and :159")


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class Group:
    """Child processes in their own process groups, ended on exit (SIGTERM, then SIGKILL)."""

    def __init__(self):
        self.procs = []

    def start(self, argv, log, **kwargs):
        proc = subprocess.Popen(argv, stdout=log, stderr=subprocess.STDOUT, start_new_session=True, **kwargs)
        self.procs.append(proc)
        return proc

    def stop(self):
        for proc in reversed(self.procs):
            if proc.poll() is None:
                os.killpg(proc.pid, signal.SIGTERM)
        for proc in reversed(self.procs):
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(proc.pid, signal.SIGKILL)
                proc.wait(timeout=10)


def wait_for(predicate, timeout, what):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.1)
    raise BenchError(f"{what} did not come up in {timeout} s")


def rd_host(args, work):
    if not sys.platform.startswith("linux"):
        raise BenchError("the rd host is Linux (X11) only")
    xvfb = shutil.which("Xvfb")
    if not xvfb:
        raise BenchError("Xvfb is not installed on this host (the lab host setup installs it)")
    lab.cargo(["build", "--release", "--locked"], cwd=RD_HOST)
    binary = os.path.join(lab.target_dir(cwd=RD_HOST), "release", "cmux-rd")
    stats = {"g2g": {"p50": [], "p95": [], "p99": [], "max": []}, "decode_p95": [], "lost": [], "fps": []}
    runs = []
    for _ in range(args.runs):
        report = rd_run(binary, xvfb, args.samples, work)
        runs.append(report)
        g2g = report.get("g2g_ms")
        if not g2g:
            raise BenchError(f"the rd bench measured no key press: {json.dumps(report)[:600]}")
        for key in stats["g2g"]:
            stats["g2g"][key].append(g2g[key])
        if report.get("decode_ms"):
            stats["decode_p95"].append(report["decode_ms"]["p95"])
        stats["lost"].append(report["lost"])
        stats["fps"].append(report["frames_per_s"])
    series = [lab.Series(f"rd.g2g.{key}", "ms", "lower", values) for key, values in stats["g2g"].items()]
    series += [lab.Series("rd.decode.p95", "ms", "lower", stats["decode_p95"]),
               lab.Series("rd.lost", "count", "lower", stats["lost"]),
               lab.Series("rd.frames", "fps", "higher", stats["fps"])]
    return series, {"samples": args.samples, "runs": runs}


def rd_run(binary, xvfb, samples, work):
    """One loopback run: Xvfb, the marker test app, the host and the bench viewer over UDP with one token."""
    display, port = free_display(), free_port()
    token = os.urandom(32).hex()
    group = Group()
    log = open(os.path.join(work, "rd.log"), "ab")
    try:
        group.start([xvfb, display, "-screen", "0", "1920x1080x24", "-nolisten", "tcp"], log)
        wait_for(lambda: os.path.exists(f"/tmp/.X11-unix/X{display[1:]}"), 10, f"Xvfb {display}")
        group.start([binary, "testapp", "--display", display, "--workload", "marker"], log)
        host_read, host_write = os.pipe()
        os.write(host_write, token.encode())
        os.close(host_write)
        group.start([binary, "host", "--owner", "owner", "--display", display, "--port", str(port), "--profile",
                     "baseline", "--token-fd", str(host_read)], log, pass_fds=(host_read,))
        os.close(host_read)
        wait_for(lambda: _listening(port), 15, f"cmux-rd host on {port}")
        bench_read, bench_write = os.pipe()
        os.write(bench_write, token.encode())
        os.close(bench_write)
        try:
            done = subprocess.run([binary, "bench", "--addr", f"127.0.0.1:{port}", "--carrier", "udp", "--samples",
                                   str(samples), "--user", "owner", "--token-fd", str(bench_read)],
                                  capture_output=True, text=True, timeout=RUN_TIMEOUT_SECONDS, pass_fds=(bench_read,))
        finally:
            os.close(bench_read)
        if done.returncode != 0:
            raise BenchError(f"cmux-rd bench exited {done.returncode}: {done.stderr[-600:]}")
        return json_line(done.stdout, "g2g_ms")
    finally:
        group.stop()
        log.close()


def _listening(port):
    with socket.socket() as s:
        s.settimeout(0.2)
        return s.connect_ex(("127.0.0.1", port)) == 0


BENCHES = {"mux2-parse": mux2_parse, "mux2-spawn": mux2_spawn, "holder-link": holder_link, "rd-host": rd_host}


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--bench", required=True, choices=sorted(BENCHES))
    ap.add_argument("--runs", type=int, default=3)
    ap.add_argument("--corpus-mb", type=int, default=64, help="mux2-parse: corpus size in MB")
    ap.add_argument("--chunk", type=int, default=16384, help="mux2-parse: bytes per write")
    ap.add_argument("--count", type=int, default=200, help="mux2-spawn: creates per run")
    ap.add_argument("--samples", type=int, default=100, help="rd-host: key presses per run")
    ap.add_argument("--strict", action="store_true", help="holder-link: a failed bench assertion fails the run")
    ap.add_argument("--app", help="the lab story runner passes it; ignored (the bench builds its own binary)")
    ap.add_argument("--tag", help="the lab story runner passes it; ignored")
    ap.add_argument("--story", help="result-v1 story (default: the bench's)")
    ap.add_argument("--out", help="a folder for result-v1 and the report rust-<bench>.json")
    args = ap.parse_args(argv)
    if args.runs < 1:
        ap.error("--runs is at least 1")
    story = args.story or STORIES[args.bench]
    try:
        measured = lab.built(lab.checkout_sha()) if args.out else None
    except lab.LabError as error:
        ap.error(f"no result-v1 can name this run: {error}")
    work = tempfile.mkdtemp(prefix=f"rust-lab-{args.bench}-")
    report = {"bench": args.bench, "story": story}
    status = 0
    try:
        series, detail = BENCHES[args.bench](args, work)
        report.update(detail)
        for s in series:
            print(f"RUST-LAB {args.bench} {s.metric} n={len(s.samples)} p50={lab.pct(s.samples, 0.5)} "
                  f"max={max(s.samples) if s.samples else None} unit={s.unit}", flush=True)
        if measured:
            path = lab.write(args.out, story, series, measured)
            report["results"] = str(path) if path else None
            print(f"RUST-LAB {args.bench} result-v1 {path}", flush=True)
    except (BenchError, lab.LabError) as error:
        report["error"] = str(error)
        print(f"RUST-LAB {args.bench} error {error}", file=sys.stderr, flush=True)
        status = 1
    finally:
        shutil.rmtree(work, ignore_errors=True)
        if args.out:
            os.makedirs(args.out, exist_ok=True)
            with open(os.path.join(args.out, f"rust-{args.bench}.json"), "w") as f:
                json.dump(report, f, indent=1)
    return status


if __name__ == "__main__":
    sys.exit(main())
