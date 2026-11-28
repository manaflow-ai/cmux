#!/usr/bin/env python3
"""Seconds to 15 Mbps on demand, and a sweep of the rate controller's constants, on one Linux machine.

  rate-sweep.py --commit SHA --out DIR [--var LABEL:NAME=VALUE[,NAME=VALUE...]]... [--trials 10]
                [--profile clean --profile loss-1] [--passive-s 10] [--work DIR]
  rate-sweep.py table DIR/sweep.jsonl

The goal screen-share-rate-control reads `rate_s_to_15mbps` from the wired Mac pair, and that number
arrives only when the pair's scheduled leg runs. This script measures the same number in minutes on any
Linux box with root and sch_netem (a lane VM, or a pool host through `cmux-ci test --setup netem`). It
needs no Mac and no lease.

It reuses rd-netem-linux.py as it stands. That script runs the real `cmux-rd host`, which captures an
Xvfb display running `cmux-rd testapp --workload motion` (the synthetic motion source on Linux, where the
host's own `--source synthetic` is refused). The viewer is `cmux-rd bench --input none` in a second network
namespace, behind `tc netem`. The host sends stats every 100 ms. Each passive session's 100 ms rows are read
with HQ NOW's time_to_rate rule (fine_rate's `s_to_15mbps_100ms`): the seconds until both the host's
target and the received rate are at 15 Mbps. A trial that never gets there scores its length + 1 s, as
NOW scores an unreached trial.

One source tree at SHA, one cargo target dir. Each `--var` rewrites constants in
cmux-tui/crates/cmux-rd-core/src/cc.rs before its build:
  - a `const NAME: TYPE = VALUE;` (PROBE_GROWTH_PER_S, BETA, OVERUSE_TIME_MS, ...), or
  - a `CcConfig::default()` field (start_bps, lan_start_bps, lan_rtt_us, ...).
The build fails unless each name matches exactly once. "base" (no rewrites) is always built and measured.
Trials are interleaved (round 1 runs every variant, then round 2, and so on), so drift on the machine
spreads evenly across the variants. Each trial starts a fresh host.

Writes DIR/sweep.jsonl (one line per variant, profile and trial) and DIR/sweep.md (the table).
In parallel across machines: give each machine a disjoint set of `--var` and join the jsonl files
with `table`.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import re
import shutil
import statistics
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCHEMA = "cmux.rate-sweep/1"
CC_RS = "cmux-tui/crates/cmux-rd-core/src/cc.rs"


def _netem():
    spec = importlib.util.spec_from_file_location("rd_netem_linux", HERE / "rd-netem-linux.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def parse_var(text: str) -> tuple[str, dict[str, str]]:
    """`LABEL:NAME=VALUE,NAME=VALUE` -> (LABEL, {NAME: VALUE})."""
    label, sep, body = text.partition(":")
    if not sep or not re.fullmatch(r"[A-Za-z0-9_.-]+", label) or label == "base":
        raise ValueError(f"--var {text!r}: LABEL:NAME=VALUE[,NAME=VALUE] with a label other than base")
    edits = {}
    for part in body.split(","):
        name, eq, value = part.partition("=")
        if not eq or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", name) or not re.fullmatch(r"[0-9_.]+", value):
            raise ValueError(f"--var {text!r}: {part!r} is not NAME=NUMBER")
        edits[name] = value
    return label, edits


def apply_edits(source: str, edits: dict[str, str]) -> str:
    """cc.rs with each NAME's value replaced: a `const NAME: T = V;` or a `name: V,` field line."""
    for name, value in edits.items():
        if name.isupper():
            pat = re.compile(rf"^(\s*(?:pub\s+)?const\s+{name}\s*:\s*[A-Za-z0-9_]+\s*=\s*)[^;]+;", re.M)
        else:
            pat = re.compile(rf"^(\s+{name}\s*:\s*)[0-9_.]+,", re.M)
        hits = pat.findall(source)
        if len(hits) != 1:
            raise ValueError(f"{name}: {len(hits)} matches in {CC_RS}, want exactly 1")
        source = pat.sub(lambda m: m.group(1) + value + (";" if name.isupper() else ","), source)
    return source


def score(passive: dict | None, passive_s: int) -> tuple[float, bool]:
    """(seconds, reached) as NOW scores a trial: unreached is the trial's length + 1 s."""
    got = (passive or {}).get("s_to_15mbps_100ms")
    if isinstance(got, (int, float)):
        return float(got), True
    return float(passive_s + 1), False


def _q(values: list[float], p: float) -> float | None:
    if not values:
        return None
    s = sorted(values)
    return s[min(len(s) - 1, max(0, int(round(p * len(s) + 0.5)) - 1))]  # nearest rank


def table(rows: list[dict]) -> str:
    groups: dict[tuple[str, str], list[dict]] = {}
    for r in rows:
        groups.setdefault((r["variant"], r["profile"]), []).append(r)
    out = ["| variant | edits | profile | trials | s to 15 Mbps p50 | p90 | max (NOW's number) | unreached "
           "| target s p50 | received s p50 | errors |", "|" + "---|" * 11]
    for (variant, profile), rs in groups.items():
        ok = [r for r in rs if not r.get("error")]
        secs = [r["s_to_15mbps"] for r in ok]
        tgt = [r["target_s"] for r in ok if r.get("target_s") is not None]
        rcv = [r["received_s"] for r in ok if r.get("received_s") is not None]
        edits = ", ".join(f"{k}={v}" for k, v in (rs[0].get("edits") or {}).items()) or "(main)"

        def f(v):
            return "–" if v is None else f"{v:.2f}"
        out.append(f"| {variant} | {edits} | {profile} | {len(ok)} | {f(_q(secs, .5))} | {f(_q(secs, .9))} "
                   f"| {f(max(secs) if secs else None)} | {sum(not r['reached'] for r in ok)} "
                   f"| {f(statistics.median(tgt) if tgt else None)} | {f(statistics.median(rcv) if rcv else None)} "
                   f"| {len(rs) - len(ok)} |")
    return "\n".join(out) + "\n"


SETUP_RETRIES = 2


def local_repo(commit: str) -> str | None:
    """This checkout's object store as a file:// remote when it already has the commit: no network fetch."""
    here = Path(__file__).resolve().parent
    have = subprocess.run(["git", "-C", str(here), "cat-file", "-e", f"{commit}^{{commit}}"], capture_output=True)
    if have.returncode:
        return None
    common = subprocess.run(["git", "-C", str(here), "rev-parse", "--path-format=absolute", "--git-common-dir"],
                            capture_output=True, text=True, check=True).stdout.strip()
    return f"file://{common}"


def build_all(netem, commit: str, work: Path, variants: list[tuple[str, dict]], repo_url: str) -> dict[str, Path]:
    src = work / "src"
    git = ["git", "-C", str(src)]
    if not (src / ".git").exists():
        src.mkdir(parents=True, exist_ok=True)
        netem.run(git + ["init", "-q"])
        netem.run(git + ["remote", "add", "origin", repo_url])
        netem.run(git + ["sparse-checkout", "set", *netem.SPARSE_PATHS])
    netem.run(git + ["remote", "set-url", "origin", repo_url])
    netem.run(git + ["fetch", "-q", "--depth=1", "--filter=blob:none", "origin", commit])
    netem.run(git + ["checkout", "-q", "--force", "--detach", commit])
    toolchain = re.search(r'channel\s*=\s*"([^"]+)"', (src / "cmux-tui/rust-toolchain.toml").read_text()).group(1)
    env = dict(os.environ, RUSTUP_TOOLCHAIN=toolchain, CARGO_TARGET_DIR=str(work / "target"))
    cargo_bin = Path(os.environ.get("CARGO_HOME", Path.home() / ".cargo")) / "bin"
    env["PATH"] = f"{cargo_bin}:{env['PATH']}"
    subprocess.run(["rustup", "toolchain", "install", toolchain, "--profile", "minimal"], check=True, env=env)
    cc = src / CC_RS
    pristine = cc.read_text()
    bins = {}
    (work / "bin").mkdir(exist_ok=True)
    try:
        for label, edits in variants:
            cc.write_text(apply_edits(pristine, edits))
            t0 = time.time()
            subprocess.run(["cargo", "build", "--release", "--locked", "--bin", "cmux-rd", "--no-default-features",
                            "--features", netem.BUILD_FEATURES, "--manifest-path",
                            str(src / "cmux-tui/crates/cmux-rd-host/Cargo.toml")], check=True, env=env)
            print(f"rate-sweep: built {label} in {time.time() - t0:.0f} s", file=sys.stderr, flush=True)
            bins[label] = work / "bin" / f"cmux-rd-{label}"
            shutil.copy2(work / "target/release/cmux-rd", bins[label])
    finally:
        cc.write_text(pristine)
    return bins


def main(argv: list[str]) -> int:
    if argv[:1] == ["table"]:
        rows = [json.loads(line) for p in argv[1:] for line in Path(p).read_text().splitlines() if line.strip()]
        sys.stdout.write(table(rows))
        return 0
    netem = _netem()
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--commit", required=True, help="full cmux commit to build")
    ap.add_argument("--var", action="append", default=[], metavar="LABEL:NAME=VALUE[,NAME=VALUE]")
    ap.add_argument("--no-base", action="store_true", help="skip the unmodified build (another machine runs it)")
    ap.add_argument("--profile", action="append", choices=sorted(set(netem.PROFILES) - set(netem.LO_PROFILES)),
                    help="default: clean (the wired pair's LAN) and loss-1 (20 ms RTT, 1%% loss)")
    ap.add_argument("--trials", type=int, default=10)
    ap.add_argument("--passive-s", type=int, default=10)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--work", type=Path, help="source tree and cargo target to keep between runs")
    ap.add_argument("--repo-url", help="default: this checkout when it has --commit, else the GitHub repo")
    ap.add_argument("--openh264", default="cisco")
    ap.add_argument("--deps", action="store_true")
    args = ap.parse_args(argv)
    if not re.fullmatch(r"[0-9a-f]{40}", args.commit):
        ap.error("--commit: a full 40-hex sha")
    try:
        variants = ([] if args.no_base else [("base", {})]) + [parse_var(v) for v in args.var]
        if not variants:
            ap.error("nothing to measure")
        local_cc = HERE.parents[2] / CC_RS  # this checkout's cc.rs: a misspelt name fails before any build
        if local_cc.exists():
            for _, edits in variants:
                apply_edits(local_cc.read_text(), edits)
    except ValueError as error:
        ap.error(str(error))
    profiles = args.profile or ["clean", "loss-1"]
    args.out.mkdir(parents=True, exist_ok=True)
    if args.deps:
        netem.ensure_deps()
    if netem.run(netem.priv(["modprobe", "sch_netem"]), check=False).returncode:
        print("rate-sweep: modprobe sch_netem failed (cmuxterm-hq docs/handbook/netem-route-without-host-module.md)",
              file=sys.stderr)
        return 3
    netem.OPENH264[:] = [args.openh264]
    work = args.work or Path(tempfile.mkdtemp(prefix="rate-sweep-"))
    work.mkdir(parents=True, exist_ok=True)
    bins = build_all(netem, args.commit, work, variants, args.repo_url or local_repo(args.commit) or netem.REPO_URL)
    # measure_binary reads passive_s, samples and keep_logs; the key session is not this number, so keep it short.
    margs = argparse.Namespace(passive_s=args.passive_s, samples=5, keep_logs=False)
    scratch_out = Path(tempfile.mkdtemp(prefix="rate-sweep-rows-"))
    rows = []
    try:
        for trial in range(1, args.trials + 1):
            for label, edits in variants:
                # A trial whose rig never started (Xvfb or the testapp exiting at setup) measured nothing:
                # its rows stay as errors and it runs again, up to SETUP_RETRIES times, so each variant
                # still gets --trials readings.
                results = []
                for attempt in range(1 + SETUP_RETRIES):
                    got = netem.measure_binary(bins[label], label, profiles, scratch_out, margs)
                    results += [dict(r, attempt=attempt) for r in got]
                    if not all(r.get("error") and not r.get("passive") for r in got):
                        break
                for r in results:
                    p = r.get("passive") or {}
                    secs, reached = score(p, args.passive_s)
                    row = {"schema": SCHEMA, "commit": args.commit, "variant": label, "edits": edits,
                           "profile": r.get("profile"), "trial": trial, "s_to_15mbps": secs, "reached": reached,
                           "target_s": p.get("target_s_to_15mbps_100ms"),
                           "received_s": p.get("received_s_to_15mbps_100ms"),
                           "min_target_kbps_after": p.get("min_target_kbps_after_15mbps"),
                           "mbps_mean": p.get("mbps_mean"), "fine_rows": p.get("fine_rows"),
                           "error": r.get("error") or (None if p.get("ok") else "passive session failed"),
                           "attempt": r["attempt"], "host": os.uname().nodename, "kernel": os.uname().release}
                    rows.append(row)
                    with open(args.out / "sweep.jsonl", "a") as f:
                        f.write(json.dumps(row) + "\n")
                    print(f"rate-sweep: {label} {row['profile']} trial {trial}: {secs:.2f} s"
                          f"{'' if reached else ' (unreached)'}{' ' + row['error'] if row['error'] else ''}",
                          file=sys.stderr, flush=True)
    finally:
        shutil.rmtree(scratch_out, ignore_errors=True)
        if not args.work:
            shutil.rmtree(work, ignore_errors=True)
    md = table(rows)
    (args.out / "sweep.md").write_text(md)
    print(md)
    return 0 if rows and not all(r.get("error") for r in rows) else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
