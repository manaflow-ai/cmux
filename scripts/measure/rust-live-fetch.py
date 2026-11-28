#!/usr/bin/env python3
"""What `cmux live --rust` pays to bring a daemon back from --build-host (RFD 0174 slice 5, the copy).

docs/cmux-next/hot-reload.md: after a one-line cmux-tui-core edit, Builder.fetch strips the debug
cmux-tui on the build host (614 MB -> 263 MB) and pulls it with `rsync -z` against the last build;
that took 19 s from a fleet box to a Mac over the tailnet. This builds that edit on one box (a warm
build, then N edits, each against the one before, as the loop does) and, for every edit, moves the
new binary into a staged copy of the previous one under each transfer variant:

  rsync_zlib        rsync -z, zlib (what a Mac's rsync 2.6.9 or openrsync negotiates: the loop today)
  rsync_zstd        rsync -z, zstd (two rsync 3.2+ ends negotiate it)
  rsync_whole_zlib  rsync -z --whole-file, zlib: no delta
  rsync_plain       rsync, no -z: the delta, uncompressed (any rsync, openrsync too)
  zstd1             zstd -T0 -1 on the host, piped, zstd -d here: no rsync, no delta
  zstd3             the same at zstd's default level 3
  gzip1             pigz -1 (gzip -1 without it) on the host, gzip -d here: a stock Mac has gzip, not zstd

Both ends run here (rsync's ssh replaced by a local exec), so the CPU of strip, delta and compression
is real and the network is not: each variant reports its local seconds and the bytes it put on the
wire, and FETCH lines add the wire at --mbps (default the tailnet's 200 and 1000 Mbit/s) as
max(local, bytes/rate) plus the strip, since the transfer streams.

  python3 scripts/measure/rust-live-fetch.py [--n 3] [--variants ...] [--mbps 200,1000] [--out DIR]

Output: FETCH-SAMPLE per transfer, FETCH lines (variant n p50 local, wire MB, modeled seconds per
rate), DIR/samples.json ($FAST_CHECKS_OUT when set).
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

ROOT = Path(__file__).resolve().parents[2]


def load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod


live = load("rust_live", ROOT / "scripts/cmux-next/rust-live.py")
EDIT = ROOT / live.EDIT_FILE
ANCHOR = live.EDIT_ANCHOR
VARIANTS = ["rsync_zlib", "rsync_zstd", "rsync_whole_zlib", "rsync_plain", "zstd1", "zstd3", "gzip1"]


def log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


def build(target: Path, label: str) -> Path:
    env = dict(os.environ, CARGO_TARGET_DIR=str(target))
    if not env.get("RUSTC_WRAPPER") and shutil.which("sccache"):
        env["RUSTC_WRAPPER"] = "sccache"
    t = time.monotonic()
    r = subprocess.run(live.cargo_args(["cmux-tui"], None), cwd=ROOT / "cmux-tui", env=env,
                       capture_output=True, text=True)
    log(f"FETCH-BUILD {label} {time.monotonic() - t:.1f}s rc={r.returncode}")
    if r.returncode != 0:
        raise RuntimeError((r.stderr + r.stdout)[-3000:])
    return target / "debug" / "cmux-tui"


def strip(src: Path, dest: Path) -> float:
    """rust-live.py's own strip command, timed."""
    t = time.monotonic()
    subprocess.run(f"objcopy --strip-debug {src} {dest} 2>/dev/null || strip -S -o {dest} {src}",
                   shell=True, check=True)
    return time.monotonic() - t


def transfer(variant: str, source: Path, staged: Path, rsh: Path) -> tuple[float, int]:
    """Move source into staged (which holds the last build), as the loop's pull would; (seconds, wire bytes)."""
    t = time.monotonic()
    if variant.startswith("rsync"):
        argv = ["rsync", "--stats", "-e", str(rsh)]
        if "plain" not in variant:
            argv += ["-z", "--compress-choice=" + ("zstd" if "zstd" in variant else "zlib")]
        if "whole" in variant:
            argv.append("--whole-file")
        else:
            argv.append("--no-whole-file")  # a local copy defaults to whole-file; the loop's remote one does not
        r = subprocess.run([*argv, f"host:{source}", str(staged)], capture_output=True, text=True, check=True)
        wire = int(re.search(r"Total bytes received: ([\d,]+)", r.stdout).group(1).replace(",", ""))
    else:
        tmp = staged.with_name(staged.name + ".in")
        if variant == "gzip1":
            pack, unpack = ("pigz -1 -c" if shutil.which("pigz") else "gzip -1 -c"), "gzip -dc"
        else:
            pack, unpack = f"zstd -q -T0 -{variant.removeprefix('zstd')} -c", "zstd -q -dc"
        # The wire is the pipe between the two ends; wc counts it on the way.
        script = (f"set -o pipefail; {pack} {source} | tee >(wc -c > {tmp}.n) | {unpack} > {tmp}"
                  f" && mv -f {tmp} {staged}")
        subprocess.run(["bash", "-c", script], check=True)
        time.sleep(0.05)
        wire = int(Path(f"{tmp}.n").read_text().split()[0])
        Path(f"{tmp}.n").unlink()
    dt = time.monotonic() - t
    return dt, wire


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=3)
    ap.add_argument("--variants", default=",".join(VARIANTS))
    ap.add_argument("--mbps", default="200,1000")
    ap.add_argument("--out", default=os.environ.get("FAST_CHECKS_OUT") or str(ROOT / ".build/rust-live-fetch"))
    a = ap.parse_args()
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    names = a.variants.split(",")
    rates = [float(x) for x in a.mbps.split(",")]
    for tool in ("rsync", "zstd", "pigz", "gzip", "objcopy"):
        log(f"FETCH-ENV {tool}={shutil.which(tool)}")
    log("FETCH-ENV " + subprocess.run(["rsync", "--version"], capture_output=True, text=True).stdout.splitlines()[0])
    scratch = Path(tempfile.mkdtemp(prefix="rust-live-fetch-", dir=os.environ.get("CMUX_FETCH_SCRATCH")))
    rsh = scratch / "rsh"
    rsh.write_text('#!/bin/sh\nshift\nexec "$@"\n')  # `rsh host cmd...`: run cmd here
    rsh.chmod(0o755)
    original = EDIT.read_text()
    if ANCHOR not in original:
        log(f"error: {EDIT} has no edit anchor")
        return 2
    samples = []
    try:
        built = build(scratch / "target", "warm")
        prev = scratch / "prev.live"
        strip(built, prev)
        log(f"FETCH-SIZE debug={built.stat().st_size} stripped={prev.stat().st_size}")
        for i in range(a.n):
            EDIT.write_text(original.replace(ANCHOR, ANCHOR + f'        "fetch_probe": {i},\n', 1))
            built = build(scratch / "target", f"edit{i}")
            cur = scratch / "cur.live"
            strip_s = strip(built, cur)
            log(f"FETCH-STRIP edit{i} {strip_s:.2f}s")
            for name in names:
                staged = scratch / f"staged-{name}"
                shutil.copy2(prev, staged)
                try:
                    dt, wire = transfer(name, cur, staged, rsh)
                except (subprocess.CalledProcessError, AttributeError) as error:
                    log(f"FETCH-SAMPLE {name} edit{i} failed: {error}")
                    samples.append({"variant": name, "edit": i, "failed": str(error)})
                    continue
                same = subprocess.run(["cmp", "-s", str(cur), str(staged)]).returncode == 0
                samples.append({"variant": name, "edit": i, "s": round(dt, 2), "wire": wire,
                                "strip_s": round(strip_s, 2), "intact": same})
                log(f"FETCH-SAMPLE {name} edit{i} {dt:.2f}s wire={wire / 1e6:.1f}MB intact={same}")
                staged.unlink()
            cur.replace(prev)
    finally:
        EDIT.write_text(original)
        (out / "samples.json").write_text(json.dumps(samples, indent=1))
        shutil.rmtree(scratch, ignore_errors=True)
    failed = False
    for name in names:
        ok = [s for s in samples if s["variant"] == name and "s" in s]
        failed |= len(ok) != a.n or not all(s["intact"] for s in ok)
        if not ok:
            continue
        local = statistics.median(s["s"] for s in ok)
        wire = statistics.median(s["wire"] for s in ok)
        strip_s = statistics.median(s["strip_s"] for s in ok)
        modeled = " ".join(f"at{int(r)}={strip_s + max(local, wire * 8 / (r * 1e6)):.1f}s" for r in rates)
        print(f"FETCH {name} n={len(ok)} local_p50={local:.2f}s strip_p50={strip_s:.2f}s "
              f"wire_p50={wire / 1e6:.1f}MB {modeled}", flush=True)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
