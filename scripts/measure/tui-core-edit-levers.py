#!/usr/bin/env python3
"""Which build settings cut a cmux-tui-core edit's rebuild without moving code (RFD 0174 slice 5).

Runs scripts/measure/tui-core-edit-breakdown.py (the same edit, rust-live's cargo args, `--timings`)
once per arm, each arm only an environment change, in arms order:

  base        rust-live's build as it is
  threads8    rustc's parallel frontend, -Z threads=8 (RUSTC_BOOTSTRAP=1: measured, never shipped)
  mold        link with mold (clang or cc -fuse-ld=mold), where mold is installed
  debug0      CARGO_PROFILE_DEV_DEBUG=0 (no line tables in our crates)
  cgu16       CARGO_PROFILE_DEV_CODEGEN_UNITS=16
  cgu1024     CARGO_PROFILE_DEV_CODEGEN_UNITS=1024
  opt0        our crates at opt-level 0 (dependencies stay at 3)
  cgu1024+debug0  both
An arm named NAME@K reruns NAME later in the run (interleave arms to see drift on the machine).

  python3 scripts/measure/tui-core-edit-levers.py [--n 4] [--arms base,mold,...]

Output: LEVER lines (p50 per part per arm) and a Markdown table at the end.
"""
from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HARNESS = ROOT / "scripts/measure/tui-core-edit-breakdown.py"


def mold_flags() -> str | None:
    mold = shutil.which("mold")
    if not mold:
        return None
    # Rust 1.90+ links x86_64 Linux with its own rust-lld; -lld turns that off so cc takes mold.
    return f"-C linker-features=-lld -C link-arg=-fuse-ld=mold"


def arms() -> dict[str, dict | None]:
    flags = os.environ.get("RUSTFLAGS", "")
    mold = mold_flags()
    return {
        "base": {},
        "threads8": {"RUSTC_BOOTSTRAP": "1", "RUSTFLAGS": f"{flags} -Z threads=8".strip()},
        "mold": {"RUSTFLAGS": f"{flags} {mold}".strip()} if mold else None,
        "debug0": {"CARGO_PROFILE_DEV_DEBUG": "0"},
        "cgu16": {"CARGO_PROFILE_DEV_CODEGEN_UNITS": "16"},
        "cgu1024": {"CARGO_PROFILE_DEV_CODEGEN_UNITS": "1024"},
        "opt0": {"CARGO_PROFILE_DEV_OPT_LEVEL": "0"},
        "cgu1024+debug0": {"CARGO_PROFILE_DEV_CODEGEN_UNITS": "1024", "CARGO_PROFILE_DEV_DEBUG": "0"},
    }


LINE = re.compile(r"^BREAKDOWN (\S+) n=(\d+) p50=([\d.]+)")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=4)
    ap.add_argument("--arms", default="base,threads8,mold,debug0,cgu16,cgu1024,opt0")
    a = ap.parse_args()
    table = arms()
    out = Path(os.environ.get("FAST_CHECKS_OUT") or ROOT / ".build/tui-core-levers")
    print(f"LEVER-ENV nproc={os.cpu_count()} mold={shutil.which('mold')} clang={shutil.which('clang')} "
          f"lld={shutil.which('ld.lld')} rustc={subprocess.run(['rustc', '-V'], capture_output=True, text=True).stdout.strip()}",
          flush=True)
    rows = []
    for name in a.arms.split(","):
        env_add = table.get(name.split("@")[0])  # base@2: the same arm again, later in the run
        if env_add is None:
            print(f"LEVER {name} skipped (not available here)", flush=True)
            continue
        env = dict(os.environ, **env_add)
        argv = [sys.executable, str(HARNESS), "--n", str(a.n), "--no-passes", "--out", str(out / name)]
        r = subprocess.run(argv, cwd=ROOT, env=env, capture_output=True, text=True)
        for line in r.stderr.splitlines():
            if line.startswith(("BREAKDOWN-SAMPLE", "BREAKDOWN-ENV", "error")):
                print(f"{name}: {line}", flush=True)
        p50 = {m.group(1): float(m.group(3)) for m in map(LINE.match, r.stdout.splitlines()) if m}
        print(f"LEVER {name} rc={r.returncode} " + " ".join(f"{k}={v:.2f}" for k, v in p50.items()), flush=True)
        if r.returncode != 0:
            print(r.stderr[-2000:], flush=True)
        rows.append((name, r.returncode, p50))
    print("\n| arm | total p50 | cmux-tui-core | cmux-tui lib | cmux-tui bin (link) |\n|---|---|---|---|---|")
    for name, rc, p in rows:
        cell = lambda k: f"{p[k]:.2f} s" if k in p else "-"  # noqa: E731
        print(f"| {name}{'' if rc == 0 else f' (rc {rc})'} | {cell('s')} | {cell('core')} | {cell('tui_lib')} | {cell('bin')} |")
    return 0 if rows and all(rc == 0 for _, rc, _ in rows) else 1


if __name__ == "__main__":
    sys.exit(main())
