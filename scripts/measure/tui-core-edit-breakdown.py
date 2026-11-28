#!/usr/bin/env python3
"""Where a one-line cmux-tui-core edit's rebuild goes (RFD 0174 slice 5, splitting cmux-tui-core).

scripts/measure/rust-live-parity.py measured 29.8 s p50 for rust-live's build of its `identify` edit
(scripts/cmux-next/rust-live.py EDIT_FILE). This makes the same edit, builds with rust-live's own cargo
args plus `--timings`, and splits each build by unit from cargo's timing report: cmux-tui-core (and its
part after its rmeta, where cargo reports that), the cmux-tui lib it forces to rebuild, the cmux-tui
bin (its own compile plus the link) and any other crate rebuilt. Then, once each, `-Z time-passes` (RUSTC_BOOTSTRAP=1, in its own target dir)
for the cmux-tui-core lib, the cmux-tui lib and the cmux-tui bin names the passes: the bin's `link_binary` is the link.

  python3 scripts/measure/tui-core-edit-breakdown.py [--n 4] [--edit FILE:ANCHOR] [--no-passes] [--out DIR]

Output: BREAKDOWN-SAMPLE per build, BREAKDOWN lines (p50 per part), PASSES lines (top passes), and
DIR/breakdown.json ($FAST_CHECKS_OUT when set).
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
import importlib.util  # noqa: E402


def load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod


live = load("rust_live", ROOT / "scripts/cmux-next/rust-live.py")
CORE, BIN = "cmux-tui-core", "cmux-tui"


def log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


def env_for(target: Path, bootstrap: bool = False) -> dict:
    env = dict(os.environ)
    env["CARGO_TARGET_DIR"] = str(target)
    if not env.get("RUSTC_WRAPPER") and shutil.which("sccache"):
        env["RUSTC_WRAPPER"] = "sccache"  # as rust-live.py's build
    if bootstrap:
        env["RUSTC_BOOTSTRAP"] = "1"
        env["RUSTC_WRAPPER"] = ""  # -Z output is the rustc's own, not a cache hit's
    return env


def units(target: Path) -> list[dict]:
    """The newest cargo timing report's UNIT_DATA."""
    reports = sorted((target / "cargo-timings").glob("cargo-timing-*.html"), key=lambda p: p.stat().st_mtime)
    if not reports:
        return []
    text = reports[-1].read_text()
    m = re.search(r"const UNIT_DATA = (\[.*?\]);\s*\n", text, re.S)
    return json.loads(m.group(1)) if m else []


def split(data: list[dict]) -> dict:
    parts = {"core": 0.0, "core_after_rmeta": 0.0, "bin": 0.0, "tui_lib": 0.0, "other": 0.0, "other_crates": []}
    for u in data:
        name, dur = u.get("name"), float(u.get("duration") or 0)
        if dur < 0.05:
            continue
        if name == CORE and u.get("target", "").strip() in ("", "lib"):
            rmeta = float(u.get("rmeta_time") or dur)
            parts["core"] += rmeta
            parts["core_after_rmeta"] += dur - rmeta
        elif name == BIN and "bin" in u.get("target", ""):
            parts["bin"] += dur
        elif name == BIN:
            parts["tui_lib"] += dur
        else:
            parts["other"] += dur
            parts["other_crates"].append(f"{name}{u.get('target', '')}:{dur:.1f}")
    return parts


def build(target: Path, out: Path, label: str) -> dict:
    argv = live.cargo_args([BIN], None) + ["--timings"]
    t = time.monotonic()
    r = subprocess.run(argv, cwd=ROOT / "cmux-tui", env=env_for(target), capture_output=True, text=True)
    dt = time.monotonic() - t
    (out / f"build-{label}.log").write_text(r.stderr + r.stdout)
    s = {"label": label, "s": round(dt, 2), "rc": r.returncode, **split(units(target))}
    log(f"BREAKDOWN-SAMPLE {label} {dt:.2f}s rc={r.returncode} core={s['core']:.2f} "
        f"core_after_rmeta={s['core_after_rmeta']:.2f} tui_lib={s['tui_lib']:.2f} bin={s['bin']:.2f} other={s['other']:.2f} "
        f"[{' '.join(s['other_crates']) or '-'}]")
    if r.returncode != 0:
        log((r.stderr + r.stdout)[-3000:])
    return s


PASS = re.compile(r"^time:\s+([\d.]+);.*?\s(\S+)\s*$")


def passes(target: Path, out: Path, edit, i: int) -> dict:
    """-Z time-passes on the core lib and the bin after one edit (its own target dir, warmed first)."""
    res = {}
    base = ["cargo", "rustc", "--message-format=short", "--profile", live.PROFILE]
    jobs = {"core": base + ["-p", CORE, "--lib", "--", "-Ztime-passes"],
            "lib": base + ["-p", BIN, "--lib", "--", "-Ztime-passes"],
            "bin": base + ["-p", BIN, "--bin", live.DAEMONS[BIN][0], "--", "-Ztime-passes"]}
    for key, argv in jobs.items():  # warm: the -Z flag is part of the unit's fingerprint
        subprocess.run(argv, cwd=ROOT / "cmux-tui", env=env_for(target, True), capture_output=True, text=True)
    edit(i)
    for key, argv in jobs.items():
        t = time.monotonic()
        r = subprocess.run(argv, cwd=ROOT / "cmux-tui", env=env_for(target, True), capture_output=True, text=True)
        dt = time.monotonic() - t
        (out / f"passes-{key}.log").write_text(r.stderr + r.stdout)
        top = {}
        for line in (r.stderr + r.stdout).splitlines():
            m = PASS.match(line)
            if m:
                top[m.group(2)] = max(top.get(m.group(2), 0.0), float(m.group(1)))
        ranked = sorted(top.items(), key=lambda kv: -kv[1])[:20]
        res[key] = {"s": round(dt, 2), "rc": r.returncode, "top": ranked}
        print(f"PASSES {key} {dt:.2f}s rc={r.returncode} " + " ".join(f"{n}={v:.2f}" for n, v in ranked), flush=True)
    return res


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=4)
    ap.add_argument("--edit", default=f"{live.EDIT_FILE}:{live.EDIT_ANCHOR}",
                    help="FILE:ANCHOR (a line the probe is inserted after; \\n escapes allowed)")
    ap.add_argument("--no-passes", action="store_true")
    ap.add_argument("--out", default=os.environ.get("FAST_CHECKS_OUT") or str(ROOT / ".build/tui-core-breakdown"))
    a = ap.parse_args()
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    file, anchor = a.edit.split(":", 1)
    anchor = anchor.encode().decode("unicode_escape")
    path = ROOT / file
    original = path.read_text()
    if anchor not in original:
        log(f"error: {file} has no anchor {anchor!r}")
        return 2
    indent = re.match(r"\s*", anchor).group(0)

    def edit(i: int) -> None:
        path.write_text(original.replace(anchor, anchor + f'{indent}"breakdown_probe": {i},\n', 1))

    scratch = Path(os.environ.get("CMUX_PARITY_SCRATCH") or Path.home() / ".cache/cmux-tui-core-breakdown") / f"run-{os.getpid()}"
    scratch.mkdir(parents=True, exist_ok=True)
    log(f"BREAKDOWN-ENV nproc={os.cpu_count()} sccache={shutil.which('sccache')} edit={file} "
        f"linker={os.environ.get('CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER', '-')} "
        f"rustflags={os.environ.get('RUSTFLAGS', '-')}")
    result = {"samples": [], "passes": None}
    try:
        result["samples"].append(build(scratch / "t", out, "warm"))
        result["samples"].append(build(scratch / "t", out, "noop"))
        for i in range(a.n):
            edit(i)
            result["samples"].append(build(scratch / "t", out, f"edit{i}"))
        if not a.no_passes:
            result["passes"] = passes(scratch / "p", out, edit, a.n)
    finally:
        path.write_text(original)
        (out / "breakdown.json").write_text(json.dumps(result, indent=1))
        shutil.rmtree(scratch, ignore_errors=True)
    edits = [s for s in result["samples"] if s["label"].startswith("edit") and s["rc"] == 0]
    if not edits:
        return 1
    for key in ("s", "core", "core_after_rmeta", "tui_lib", "bin", "other"):
        print(f"BREAKDOWN {key} n={len(edits)} p50={statistics.median(s[key] for s in edits):.2f}", flush=True)
    return 0 if len(edits) == a.n else 1


if __name__ == "__main__":
    sys.exit(main())
