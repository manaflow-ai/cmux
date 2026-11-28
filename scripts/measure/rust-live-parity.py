#!/usr/bin/env python3
"""Why `cmux live --rust` builds slower than the dev loop (RFD 0174 slice 5, daemon build parity).

docs/cmux-next/hot-reload.md measured 41.4 s p50 for rust-live's incremental build of a one-line
`identify` edit in cmux-tui-core; scripts/measure/rust-dev-loop.sh measured about 11.75 s for an edit
in the same crate. This builds that same edit on one box under each variant, each in its own target
directory (a warm-up build first), interleaved, and prints per build the seconds and the crates cargo
compiled, so the gap is split by cause:

  live         rust-live.py's own build: its cargo_args() and environment (the inherited one, sccache
               as RUSTC_WRAPPER when on PATH and none is set)
  live_nowrap  the same, RUSTC_WRAPPER empty
  live_inc     the same as live, CARGO_INCREMENTAL=1
  loop         rust-dev-loop.py's build: its clean_env() and BUILD (-p cmux-tui -p acpmux --bins)

  python3 scripts/measure/rust-live-parity.py [--variants live,live_nowrap,loop] [--n 4] [--out DIR]

Output: PARITY-ENV lines (the build environment), PARITY-SAMPLE per build, PARITY lines (variant n p50
min max compiled-crates), and DIR/samples.json ($FAST_CHECKS_OUT when set).
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import statistics
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts/cmux-next"))
sys.path.insert(0, str(ROOT / "scripts/measure"))
import importlib.util  # noqa: E402


def load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod  # a dataclass looks its module up here
    spec.loader.exec_module(mod)
    return mod


live = load("rust_live", ROOT / "scripts/cmux-next/rust-live.py")
devloop = load("rust_dev_loop", ROOT / "scripts/measure/rust-dev-loop.py")

EDIT = ROOT / live.EDIT_FILE
ANCHOR = live.EDIT_ANCHOR


def log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


def variant(name: str, target: Path) -> tuple[list[str], dict]:
    if name == "loop":
        env = devloop.clean_env(target)
        return ["cargo", *devloop.BUILD], env
    env = dict(os.environ)
    env["CARGO_TARGET_DIR"] = str(target)
    if name in ("live", "live_inc") and not env.get("RUSTC_WRAPPER") and shutil.which("sccache"):
        env["RUSTC_WRAPPER"] = "sccache"
    if name == "live_nowrap":
        env["RUSTC_WRAPPER"] = ""
        env["CARGO_BUILD_RUSTC_WRAPPER"] = ""
    if name == "live_inc":
        env["CARGO_INCREMENTAL"] = "1"
    return live.cargo_args(["cmux-tui"], None), env


def build(name: str, target: Path, out: Path, label: str) -> dict:
    argv, env = variant(name, target)
    t = time.monotonic()
    r = subprocess.run(argv, cwd=ROOT / "cmux-tui", env=env, capture_output=True, text=True)
    dt = time.monotonic() - t
    text = r.stderr + r.stdout
    (out / f"{name}-{label}.log").write_text(text)
    crates = re.findall(r"^\s+Compiling (\S+)", text, re.M)
    sample = {"variant": name, "label": label, "s": round(dt, 2), "rc": r.returncode, "compiled": crates}
    log(f"PARITY-SAMPLE {name} {label} {dt:.2f}s rc={r.returncode} compiled={','.join(crates) or '-'}")
    if r.returncode != 0:
        log(text[-3000:])
    return sample


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--variants", default="live,live_nowrap,loop")
    ap.add_argument("--n", type=int, default=4)
    ap.add_argument("--out", default=os.environ.get("FAST_CHECKS_OUT") or str(ROOT / ".build/rust-live-parity"))
    a = ap.parse_args()
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    names = a.variants.split(",")
    scratch = Path(os.environ.get("CMUX_PARITY_SCRATCH") or Path.home() / ".cache/cmux-rust-live-parity") / f"run-{os.getpid()}"
    scratch.mkdir(parents=True, exist_ok=True)
    for key in sorted(os.environ):
        if key.startswith(("CARGO", "RUST", "SCCACHE")) or key in ("CC", "CXX", "LD"):
            log(f"PARITY-ENV {key}={os.environ[key]}")
    log(f"PARITY-ENV sccache={shutil.which('sccache')} nproc={os.cpu_count()}")
    for cfg in (Path.home() / ".cargo/config.toml", Path.home() / ".cargo/config", ROOT / ".cargo/config.toml",
                ROOT / "cmux-tui/.cargo/config.toml"):
        if cfg.is_file():
            log(f"PARITY-ENV {cfg}:\n{cfg.read_text()}")
    original = EDIT.read_text()
    if ANCHOR not in original:
        log(f"error: {EDIT} has no edit anchor")
        return 2
    samples = []
    try:
        for name in names:
            samples.append(build(name, scratch / name, out, "warm"))
            samples.append(build(name, scratch / name, out, "noop"))
        for i in range(a.n):
            EDIT.write_text(original.replace(ANCHOR, ANCHOR + f'        "parity_probe": {i},\n', 1))
            for name in names:
                samples.append(build(name, scratch / name, out, f"edit{i}"))
    finally:
        EDIT.write_text(original)
        (out / "samples.json").write_text(json.dumps(samples, indent=1))
        shutil.rmtree(scratch, ignore_errors=True)
    failed = False
    for name in names:
        edits = [s for s in samples if s["variant"] == name and s["label"].startswith("edit")]
        ok = [s["s"] for s in edits if s["rc"] == 0]
        failed |= len(ok) != len(edits)
        if ok:
            crates = sorted({c for s in edits for c in s["compiled"]})
            print(f"PARITY {name} n={len(ok)} p50={statistics.median(ok):.2f} min={min(ok):.2f} "
                  f"max={max(ok):.2f} compiled={','.join(crates)}", flush=True)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
