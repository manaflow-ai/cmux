#!/usr/bin/env python3
"""Edit-to-runnable time of cmux's Rust dev build, per build-setting variant.

Run from scripts/measure/rust-dev-loop.sh (which sets up the checkout). For each variant it
keeps its own target directory, builds it once from nothing (the clean build), then loops n
times: for each of cmux-tui-core, cmux-tui and acpmux it makes a one-line edit (an anonymous
`const _: u32 = N;` appended to the crate root, a new N each time) and times the dev build of
the cmux-tui and acpmux binaries. Variants run interleaved inside each round, so drift on the
worker lands on every variant alike. Output: DEVLOOP lines (p50/p95 per variant and scenario)
and a JSON file with every sample.
"""
from __future__ import annotations

import argparse
import json
import os
import platform
import re
import shutil
import statistics
import subprocess
import sys
import threading
import time
from pathlib import Path

# A nightly from the 1.95 cycle (the pinned stable, cmux-tui/rust-toolchain.toml), so a nightly
# variant changes only the flags it names; nightly-2026-11-01 (1.101) no longer compiles acpmux.
NIGHTLY = "nightly-2026-02-20"
EDITS = {
    "core": "crates/cmux-tui-core/src/lib.rs",
    "tui": "crates/cmux-tui/src/main.rs",
    "acpmux": "crates/acpmux/src/lib.rs",
}
BUILD = ["build", "--locked", "-p", "cmux-tui", "-p", "acpmux", "--bins"]
MARK = "// cmux dev-loop measurement edit\n"


def pct(xs: list[float], p: float) -> float:
    xs = sorted(xs)
    if not xs:
        return float("nan")
    k = (len(xs) - 1) * p
    lo, hi = int(k), min(int(k) + 1, len(xs) - 1)
    return xs[lo] + (xs[hi] - xs[lo]) * (k - lo)


def find_lld(tools: Path) -> str | None:
    """A Mach-O lld: Homebrew's, or the toolchain's own rust-lld under the ld64.lld name."""
    if platform.system() != "Darwin":
        return shutil.which("ld.lld")
    for c in (shutil.which("ld64.lld"), "/opt/homebrew/opt/lld/bin/ld64.lld", "/opt/homebrew/opt/llvm/bin/ld64.lld"):
        if c and os.access(c, os.X_OK):
            return c
    sysroot = subprocess.run(["rustc", "--print", "sysroot"], capture_output=True, text=True).stdout.strip()
    host = re.search(r"host: (\S+)", subprocess.run(["rustc", "-vV"], capture_output=True, text=True).stdout)
    if sysroot and host:
        rl = Path(sysroot) / "lib/rustlib" / host.group(1) / "bin/rust-lld"
        if rl.exists():
            tools.mkdir(parents=True, exist_ok=True)
            link = tools / "ld64.lld"
            if not link.exists():
                link.symlink_to(rl)
            return str(link)
    return None


def find_fast_linker() -> tuple[str, str] | None:
    """Linux: mold, else wild (name, path)."""
    for name in ("mold", "wild"):
        p = shutil.which(name)
        if p:
            return name, p
    return None


def variants(tools: Path) -> dict[str, dict]:
    darwin = platform.system() == "Darwin"
    v: dict[str, dict] = {"base": {}}
    if darwin:
        lld = find_lld(tools)
        v["lld"] = {"rustflags": [f"-Clink-arg=--ld-path={lld}"]} if lld else {"skip": "no ld64.lld or rust-lld"}
    else:
        fl = find_fast_linker()
        v["mold"] = ({"rustflags": ["-Clinker=clang", f"-Clink-arg=--ld-path={fl[1]}"], "linker": fl[0]}
                     if fl else {"skip": "no mold or wild on PATH"})
        v["split"] = {"config": ['profile.dev.split-debuginfo="unpacked"']}
    v["nodebug"] = {"config": ["profile.dev.debug=0"]}
    fast = "lld" if darwin else "mold"
    v[f"{fast}+nodebug"] = {"rustflags": v[fast].get("rustflags", []), "config": ["profile.dev.debug=0"],
                            **({"skip": v[fast]["skip"]} if "skip" in v[fast] else {})}
    v["nightly"] = {"toolchain": NIGHTLY}
    v["nightly+threads8"] = {"toolchain": NIGHTLY, "rustflags": ["-Zthreads=8"]}
    v["cranelift"] = {"toolchain": NIGHTLY, "zflags": ["-Zcodegen-backend"],
                      "config": ['profile.dev.codegen-backend="cranelift"',
                                 'profile.dev.package."*".codegen-backend="llvm"']}
    v["cranelift+all"] = {"toolchain": NIGHTLY, "zflags": ["-Zcodegen-backend"],
                          "rustflags": ["-Zthreads=8", *v[fast].get("rustflags", [])],
                          "config": ['profile.dev.codegen-backend="cranelift"',
                                     'profile.dev.package."*".codegen-backend="llvm"', "profile.dev.debug=0"],
                          **({"skip": v[fast]["skip"]} if "skip" in v[fast] else {})}
    for k in ("cranelift", "cranelift+all"):
        v[k]["cranelift"] = True
    # blaze (github.com/indexable-inc/blaze): a cargo stand-in whose daemon keeps the workspace
    # compiled in memory and recompiles changed functions. Its own pinned nightly; dev loop only.
    v["blaze"] = {"blaze": True} if shutil.which("blaze") else {"skip": "no blaze on PATH (rust-dev-loop.sh fetches it)"}
    return v


def blaze_rss_mb() -> float:
    """Resident memory of this run's blaze processes (the daemon and any client), in MB."""
    r = subprocess.run(["ps", "-axo", "rss=,comm="], capture_output=True, text=True)
    kb = sum(int(line.split(None, 1)[0]) for line in r.stdout.splitlines()
             if line.strip() and Path(line.split(None, 1)[-1].strip()).name.startswith("blaze"))
    return round(kb / 1024, 1)


def ensure_nightly(log, cranelift: bool) -> tuple[str | None, str | None]:
    """(error for every nightly variant, error for the cranelift ones)."""
    if not shutil.which("rustup"):
        return "no rustup on this host", None
    r = subprocess.run(["rustup", "toolchain", "install", NIGHTLY, "--profile", "minimal"],
                       capture_output=True, text=True)
    log(f"rustup install {NIGHTLY}: exit {r.returncode} {r.stderr.strip().splitlines()[-1:]}")
    if r.returncode != 0:
        return f"rustup install {NIGHTLY} failed", None
    if not cranelift:
        return None, None
    r = subprocess.run(["rustup", "component", "add", "--toolchain", NIGHTLY, "rustc-codegen-cranelift-preview"],
                       capture_output=True, text=True)
    log(f"rustup component add rustc-codegen-cranelift-preview: exit {r.returncode}")
    return None, (None if r.returncode == 0 else "no rustc-codegen-cranelift-preview for this host")


def toolchain_bin(toolchain: str) -> str:
    r = subprocess.run(["rustup", "which", "--toolchain", toolchain, "cargo"], capture_output=True, text=True,
                       check=True)
    return str(Path(r.stdout.strip()).parent)


ZIG_PACKAGES: Path | None = None


def clean_env(target: Path) -> dict:
    """The environment every variant builds in: no inherited profile, wrapper or flags (a worker's
    global config.toml may set a wrapper or rustflags; empty values here override it), and zig
    caches of this target's own, linked to the packages fetched before timing."""
    env = dict(os.environ)
    for name in list(env):
        if name.startswith(("CARGO_PROFILE_", "CARGO_BUILD_", "CARGO_TARGET_")) or name in (
                "RUSTFLAGS", "CARGO_INCREMENTAL", "RUSTC_WORKSPACE_WRAPPER", "RUSTUP_TOOLCHAIN", "RUSTC"):
            del env[name]
    env["CARGO_TARGET_DIR"] = str(target)
    env["RUSTC_WRAPPER"] = ""
    env["CARGO_BUILD_RUSTC_WORKSPACE_WRAPPER"] = ""
    env["CARGO_ENCODED_RUSTFLAGS"] = ""
    # ghostty-vt-sys runs `zig build`; its caches live in the variant's target, so a clean build
    # of every variant compiles libghostty-vt from nothing, not only the first.
    env["ZIG_LOCAL_CACHE_DIR"] = str(target / "zig-local-cache")
    env["ZIG_GLOBAL_CACHE_DIR"] = str(target / "zig-global-cache")
    if ZIG_PACKAGES and ZIG_PACKAGES.is_dir():
        (target / "zig-global-cache").mkdir(parents=True, exist_ok=True)
        link = target / "zig-global-cache" / "p"
        if not link.exists():
            link.symlink_to(ZIG_PACKAGES)
    return env


class PeakRss:
    """Peak resident memory of the host's blaze processes (the daemon and what it runs under a
    blaze name), sampled every 200 ms while a build runs. On an exclusive worker these are this
    run's own."""

    def __init__(self) -> None:
        self.peak_mb = 0.0
        self._stop = threading.Event()
        self._t = threading.Thread(target=self._run, daemon=True)

    def _run(self) -> None:
        while not self._stop.is_set():
            self.peak_mb = max(self.peak_mb, blaze_rss_mb())
            self._stop.wait(0.2)

    def __enter__(self) -> "PeakRss":
        self._t.start()
        return self

    def __exit__(self, *exc) -> None:
        self._stop.set()
        self._t.join()
        self.peak_mb = max(self.peak_mb, blaze_rss_mb())


def blaze_reset(log) -> None:
    """Stop the daemon and remove blaze's build state, keeping its downloaded toolchain, so the
    next blaze build is cold."""
    subprocess.run(["blaze", "stop"], capture_output=True, text=True)
    home = Path(os.environ.get("BLAZE_HOME", "")).resolve() if os.environ.get("BLAZE_HOME") else None
    if home is None or not home.name.startswith("cmux-rust-dev-loop-blaze-home-"):
        raise SystemExit("blaze variant: BLAZE_HOME must be this run's cmux-rust-dev-loop-blaze-home-* "
                         "(rust-dev-loop.sh sets it); refusing to reset any other blaze home")
    for child in home.iterdir() if home.is_dir() else []:
        if child.name in ("toolchains", "native"):
            continue
        size = subprocess.run(["du", "-sk", str(child)], capture_output=True, text=True).stdout.split()[:1]
        log(f"DEVLOOP-BLAZE-RESET rm {child.name} {size[0] if size else '?'}KB")
        shutil.rmtree(child, ignore_errors=True) if child.is_dir() else child.unlink(missing_ok=True)
    blaze_start(log)


def blaze_start(log) -> None:
    """Start the daemon before a timed build. A client that starts it itself can find its socket
    not ready ("v2.sock changed and can't be read: No such device or address", Linux, 0.20261105.1)."""
    for attempt in range(10):
        r = subprocess.run(["blaze", "status"], capture_output=True, text=True)
        if r.returncode == 0:
            log(f"DEVLOOP-BLAZE-START ready after {attempt + 1} status call(s)")
            return
        time.sleep(1)
    log(f"DEVLOOP-BLAZE-START not ready: {r.stderr.strip().splitlines()[-1:]}")


LAST_PEAK: dict[str, float] = {}


def cargo(spec: dict, target: Path, args: list[str], log_path: Path) -> tuple[float, int, int]:
    env = clean_env(target)
    if spec.get("blaze"):
        # blaze takes cargo's flags but refuses --locked; its build directory is under BLAZE_HOME.
        cmd = ["blaze", *[x for x in args if x != "--locked"]]
        t0 = time.monotonic()
        with open(log_path, "a") as f:
            f.write(f"\n$ {' '.join(cmd)}\n")
            f.flush()
            with PeakRss() as peak:
                r = subprocess.run(cmd, env=env, stdout=f, stderr=subprocess.PIPE, text=True)
            f.write(r.stderr)
        dt = time.monotonic() - t0
        LAST_PEAK["blaze"] = peak.peak_mb
        if r.returncode != 0:
            for line in r.stderr.strip().splitlines()[-15:]:
                print(f"DEVLOOP-LOG {line}", flush=True)
        return dt, r.returncode, len(re.findall(r"^\s+Compiling ", r.stderr, re.M))
    env["CARGO_ENCODED_RUSTFLAGS"] = "\x1f".join(spec.get("rustflags", []))
    cmd = ["cargo"]
    env.pop("RUSTUP_TOOLCHAIN", None)
    if spec.get("toolchain"):
        # The cargo on PATH is not always rustup's proxy (fast checks put the pinned toolchain's own
        # bin first), so RUSTUP_TOOLCHAIN alone can leave a "nightly" variant on stable.
        bin_dir = toolchain_bin(spec["toolchain"])
        env["PATH"] = f"{bin_dir}{os.pathsep}{env.get('PATH', '')}"
        env["RUSTC"] = str(Path(bin_dir) / "rustc")
        cmd = [str(Path(bin_dir) / "cargo")]
    else:
        env.pop("RUSTC", None)
    cmd += [args[0], *spec.get("zflags", [])]
    for c in spec.get("config", []):
        cmd += ["--config", c]
    cmd += args[1:]
    t0 = time.monotonic()
    with open(log_path, "a") as f:
        f.write(f"\n$ {' '.join(cmd)}\n")
        f.flush()
        r = subprocess.run(cmd, env=env, stdout=f, stderr=subprocess.PIPE, text=True)
        f.write(r.stderr)
    dt = time.monotonic() - t0
    if r.returncode != 0:
        lines = r.stderr.strip().splitlines()
        picked = [i for i, ln in enumerate(lines) if ln.startswith("error")][:6]
        keep = sorted({j for i in picked for j in range(i, min(i + 6, len(lines)))}) or range(max(0, len(lines) - 12), len(lines))
        for j in keep:
            print(f"DEVLOOP-LOG {lines[j]}", flush=True)
    compiled = len(re.findall(r"^\s+Compiling ", r.stderr, re.M))
    return dt, r.returncode, compiled


def edit(path: Path, n: int) -> None:
    text = path.read_text()
    i = text.find(MARK)
    if i >= 0:
        text = text[:i]
    path.write_text(text + MARK + f"const _: u32 = {n};\n")


def restore(path: Path) -> None:
    text = path.read_text()
    i = text.find(MARK)
    if i >= 0:
        path.write_text(text[:i])


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--workspace", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--variants", default="base")
    ap.add_argument("--n", type=int, default=8)
    ap.add_argument("--clean-n", type=int, default=1, help="clean builds per variant (the first warms it)")
    ap.add_argument("--scenarios", default="core,tui,acpmux,switch")
    ap.add_argument("--tests", default="", help="packages to time cargo test vs cargo nextest on (base variant)")
    ap.add_argument("--timings", action="store_true", help="after the rounds, per-unit --timings of one edit per crate (base)")
    ap.add_argument("--zig-packages", default="", help="a zig global cache p/ already holding Ghostty's packages")
    ap.add_argument("--target-root", default="", help="where the per-variant target directories go (default OUT/target)")
    a = ap.parse_args()
    global ZIG_PACKAGES
    ZIG_PACKAGES = Path(a.zig_packages).resolve() if a.zig_packages else None

    ws = Path(a.workspace).resolve()
    out = Path(a.out).resolve()
    out.mkdir(parents=True, exist_ok=True)
    os.chdir(ws)

    def log(msg: str) -> None:
        print(msg, flush=True)

    allv = variants(out / "tools")
    names = [x for x in a.variants.split(",") if x]
    chosen: dict[str, dict] = {}
    for name in names:
        if name not in allv:
            log(f"DEVLOOP-SKIP {name}: unknown (have {','.join(allv)})")
            continue
        chosen[name] = allv[name]
    if any(s.get("toolchain") == NIGHTLY for s in chosen.values()):
        err, cl_err = ensure_nightly(log, any(s.get("cranelift") for s in chosen.values()))
        for k, s in chosen.items():
            if s.get("toolchain") == NIGHTLY and err:
                s["skip"] = err
            elif s.get("cranelift") and cl_err:
                s["skip"] = cl_err
    for k in list(chosen):
        tc = chosen[k].get("toolchain")
        if tc and not chosen[k].get("skip"):
            v = subprocess.run([str(Path(toolchain_bin(tc)) / "rustc"), "-V"], capture_output=True, text=True)
            log(f"DEVLOOP-TOOLCHAIN {k}: {v.stdout.strip()}")
        if chosen[k].get("skip"):
            log(f"DEVLOOP-SKIP {k}: {chosen[k]['skip']}")
            del chosen[k]

    host = {"os": platform.system(), "machine": platform.machine(), "cpus": os.cpu_count(),
            "node": platform.node(),
            "rustc": subprocess.run(["rustc", "-V"], capture_output=True, text=True).stdout.strip()}
    if host["os"] == "Darwin":
        host["ld"] = subprocess.run(["ld", "-v"], capture_output=True, text=True).stderr.strip().splitlines()[:1]
    log(f"DEVLOOP-HOST {json.dumps(host)}")
    samples: list[dict] = []
    scen = [s for s in a.scenarios.split(",") if s]

    def rec(variant: str, scenario: str, dt: float, rc: int, compiled: int, i: int) -> None:
        smp = {"variant": variant, "scenario": scenario, "seconds": round(dt, 3), "exit": rc,
               "compiled": compiled, "round": i}
        extra = ""
        if chosen.get(variant, {}).get("blaze"):
            smp["rss_peak_mb"] = LAST_PEAK.get("blaze", 0.0)
            smp["rss_after_mb"] = blaze_rss_mb()
            extra = f" rss_peak_mb={smp['rss_peak_mb']} rss_after_mb={smp['rss_after_mb']}"
        samples.append(smp)
        log(f"DEVLOOP-SAMPLE {variant} {scenario} round={i} {dt:.2f}s exit={rc} compiled={compiled}{extra}")
        (out / "samples.json").write_text(json.dumps({"host": host, "samples": samples}, indent=1))

    if "blaze" in chosen:
        # blaze fetches its own toolchain on its first build (v2 has no `blaze toolchain`): a tiny
        # untimed build takes that download out of the timed clean build.
        blaze_start(log)
        r = subprocess.run(["blaze", "build", "-p", "acpmux-build-id"], capture_output=True, text=True)
        log(f"DEVLOOP-BLAZE-WARMUP exit {r.returncode} {r.stderr.strip().splitlines()[-1:]}")
        v = subprocess.run(["blaze", "--version"], capture_output=True, text=True)
        log(f"DEVLOOP-TOOLCHAIN blaze: {v.stdout.strip() or v.stderr.strip()} (its own pinned nightly)")
    troot = Path(a.target_root).resolve() if a.target_root else out / "target"
    # Crates come from the network once, before any clock starts.
    subprocess.run(["cargo", "fetch", "--locked"], check=False)
    targets = {k: troot / re.sub(r"[^A-Za-z0-9_.-]", "_", k) for k in chosen}
    for c in range(a.clean_n):
        for k, spec in chosen.items():
            if spec.get("blaze"):
                blaze_reset(log)
            shutil.rmtree(targets[k], ignore_errors=True)
            for p in EDITS.values():
                restore(ws / p)
            dt, rc, comp = cargo(spec, targets[k], BUILD, out / f"{targets[k].name}.log")
            rec(k, "clean", dt, rc, comp, c)
            if rc != 0:
                log(f"DEVLOOP-FAIL {k} clean build exit {rc}; dropped (log {targets[k].name}.log)")
                spec["skip"] = "clean build failed"
        chosen = {k: s for k, s in chosen.items() if not s.get("skip")}

    try:
        # Round -> scenario -> variant: one edit, then every variant builds it, so each target
        # sees exactly one changed crate since its last build (cargo dirties by mtime, and the
        # variants share this source tree).
        for i in range(a.n):
            for s in scen:
                if s in EDITS:
                    edit(ws / EDITS[s], i + 1)
                for k, spec in chosen.items():
                    lp = out / f"{targets[k].name}.log"
                    if s in EDITS:
                        dt, rc, comp = cargo(spec, targets[k], BUILD, lp)
                        rec(k, s, dt, rc, comp, i)
                    elif s == "switch" and i == 0 and not spec.get("blaze"):
                        # Feature unification: build one package alone after the pair. Any
                        # dependency recompiled here is what a workspace-hack crate would save.
                        for pk, extra in (("acpmux", ["--bin", "acpmux"]), ("cmux-tui", ["--bins"])):
                            dt, rc, comp = cargo(spec, targets[k], ["build", "--locked", "-p", pk, *extra], lp)
                            rec(k, f"switch-{pk}", dt, rc, comp, i)
                        dt, rc, comp = cargo(spec, targets[k], BUILD, lp)
                        rec(k, "switch-back", dt, rc, comp, i)
    finally:
        for p in EDITS.values():
            restore(ws / p)
        if "blaze" in names and shutil.which("blaze"):
            st = subprocess.run(["blaze", "status", "--json"], capture_output=True, text=True)
            log(f"DEVLOOP-BLAZE-STATUS {st.stdout.strip()[:2000]}")
            subprocess.run(["blaze", "stop"], capture_output=True, text=True)
            home = os.environ.get("BLAZE_HOME", "")
            if Path(home).name.startswith("cmux-rust-dev-loop-blaze-home-"):
                shutil.rmtree(home, ignore_errors=True)

    if a.timings and "base" in chosen:
        # Where one edit's time goes: cargo's --timings report for one more edit of each crate,
        # per unit (crate or build script): total seconds and seconds to its metadata (rmeta).
        for s_name, rel in EDITS.items():
            edit(ws / rel, 9999)
            env_t = targets["base"]
            cargo({}, env_t, [*BUILD, "--timings"], out / "timings.log")
            html = sorted((env_t / "cargo-timings").glob("cargo-timing-*.html"))
            restore(ws / rel)
            if not html:
                log(f"DEVLOOP-UNIT {s_name} no timing report")
                continue
            m = re.search(r"const UNIT_DATA = (\[.*?\]);", html[-1].read_text(), re.S)
            units = json.loads(m.group(1)) if m else []
            for u in sorted(units, key=lambda u: -u.get("duration", 0))[:8]:
                log(f"DEVLOOP-UNIT {s_name} {u.get('name')} {u.get('target', '').strip() or 'lib'} "
                    f"total={u.get('duration', 0):.2f}s rmeta={u.get('rmeta_time') or 0:.2f}s "
                    f"mode={u.get('mode')}")
        cargo({}, targets["base"], BUILD, out / "timings.log")

    if a.tests and "base" in chosen:
        lp = out / "tests.log"
        pk = []
        for p in a.tests.split(","):
            pk += ["-p", p]
        cargo({}, targets["base"], ["test", "--locked", "--no-run", *pk], lp)
        have_nextest = shutil.which("cargo-nextest") is not None
        for i in range(a.n):
            dt, rc, _ = cargo({}, targets["base"], ["test", "--locked", *pk], lp)
            rec("base", "test-cargo", dt, rc, 0, i)
            if have_nextest:
                dt, rc, _ = cargo({}, targets["base"], ["nextest", "run", "--locked", "--no-fail-fast", *pk], lp)
                rec("base", "test-nextest", dt, rc, 0, i)
        if not have_nextest:
            log("DEVLOOP-SKIP test-nextest: cargo-nextest not on PATH")

    rows = {}
    for smp in samples:
        rows.setdefault((smp["variant"], smp["scenario"]), []).append(smp)
    log("DEVLOOP variant scenario n p50_s p95_s min_s max_s compiled_p50 failures")
    for (v, s), xs in rows.items():
        ok = [x["seconds"] for x in xs if x["exit"] == 0]
        fails = sum(1 for x in xs if x["exit"] != 0)
        comp = statistics.median([x["compiled"] for x in xs])
        rss = [x["rss_peak_mb"] for x in xs if "rss_peak_mb" in x]
        log(f"DEVLOOP {v} {s} {len(ok)} {pct(ok, .5):.2f} {pct(ok, .95):.2f} "
            f"{min(ok, default=float('nan')):.2f} {max(ok, default=float('nan')):.2f} {comp:g} {fails}"
            + (f" rss_max_mb={max(rss)}" if rss else ""))
    return 1 if any(x["exit"] != 0 for x in samples if not x["scenario"].startswith("test")) else 0


if __name__ == "__main__":
    sys.exit(main())
