#!/usr/bin/env python3
"""Check that every committed Cargo.lock still resolves with `--locked`.

The Release build compiles its Rust parts with `cargo build --locked` (for example
scripts/build-diff-sidecar.sh for Native/DiffSidecar). When a change adds a
dependency to a crate that another workspace uses by path, that other
workspace's Cargo.lock goes stale, and the Release build fails with
"cannot update (or create) the lock file ... because --locked was passed". The Linux compile
check does not build those workspaces, so it stays green (#34782 added
serde_json to cmux-tui/crates/cmux-git; Native/DiffSidecar/Cargo.lock was not
updated; every Release dogfood build failed until #34935).

For each workspace this script runs a full dependency resolution,
`cargo metadata --locked --format-version 1`, which fails exactly when the
lock file would have to change. (`--no-deps` does not resolve, and
`cargo update --dry-run` ignores `--locked`, so neither one sees a stale lock.)
It compiles nothing: no build script, no rustc. It can download crate sources
into the cargo cache, as `cargo fetch` does, and rustup can install a pinned
toolchain that is missing (each workspace has at most LIMIT seconds).

The workspaces: the directory of every tracked Cargo.lock, plus the crate
directories that the Release build compiles with `--locked` (RELEASE_DIRS), so
a bundled crate whose lock is missing is also seen. Each one runs with the
toolchain the build uses: its own rust-toolchain(.toml) (rustup reads it from
the working directory), else the cmux-tui pin, as the release scripts do for a
crate with no pin of its own.

Output: one line per workspace, "OK <dir>", "STALE <dir>: <cargo's error line>"
or "ERROR <dir>: <cargo's error line>" (not a stale lock: a network fault, a
missing path dependency, a missing toolchain), then one summary line.
Exit 0 when all are OK, 1 when a lock is stale (and only then), 2 when there is
no stale lock but a workspace could not be checked, or the script itself failed
(no git checkout, no cargo).

  python3 scripts/cmux-next/check-cargo-locks.py [--repo DIR] [--jobs N]
"""
import argparse
import concurrent.futures
import os
import re
import shutil
import subprocess
import sys

# Crate directories the Release app build compiles with `cargo build --locked`
# (scripts/build-diff-sidecar.sh, scripts/cmux-next/build-*.sh,
# scripts/cmux-next/build-cmux-tui-client.sh). Each one has its own Cargo.lock
# today; the list keeps a bundled crate checked if its lock is ever removed.
RELEASE_DIRS = (
    "Native/DiffSidecar",
    "Native/OptChat/optchat-chief",
    "cmux-tui",
    "cmux-tui/crates/cmux-app-ffi",
    "cmux-tui/crates/cmux-rd-ffi",
    "cmux-tui/crates/cmux-remote-browser-host",
    "cmux-tui/bindings/examples/rust-agent-screen-detection",
    "cmux-next-ios/rust",
    "first-party-apps/cloud/server",
)
DEFAULT_PIN = "cmux-tui/rust-toolchain.toml"
TOOLCHAIN_FILES = ("rust-toolchain.toml", "rust-toolchain")
STALE = re.compile(r"cannot (?:update|create) the lock file .* because --locked was passed"
                   r"|the lock file .* needs to be updated but --locked was passed")
LIMIT = 600


class Unchecked(Exception):
    """The script could not check the checkout (exit 2, never the stale-lock exit 1)."""


def git_root(path):
    out = subprocess.run(["git", "-C", path, "rev-parse", "--show-toplevel"], capture_output=True, text=True)
    if out.returncode:
        raise Unchecked(f"{path} is not a git checkout: {out.stderr.strip()}")
    return out.stdout.strip()


def workspaces(repo):
    out = subprocess.run(["git", "-C", repo, "ls-files", "-z", "--", "*Cargo.lock"], capture_output=True)
    if out.returncode:
        raise Unchecked(f"git ls-files in {repo} failed: {out.stderr.decode(errors='replace').strip()}")
    dirs = {os.path.dirname(p.decode()) or "." for p in out.stdout.split(b"\0") if p}
    dirs.update(d for d in RELEASE_DIRS if os.path.isfile(os.path.join(repo, d, "Cargo.toml")))
    return sorted(d for d in dirs if os.path.isfile(os.path.join(repo, d, "Cargo.toml")))


def channel(path):
    try:
        with open(path) as f:
            text = f.read()
    except OSError:
        return None
    m = re.search(r'^\s*channel\s*=\s*"([^"]+)"', text, re.M)
    if m:
        return m.group(1)
    lines = [ln.strip() for ln in text.splitlines() if ln.strip() and not ln.lstrip().startswith("#")]
    return lines[0] if len(lines) == 1 and "=" not in lines[0] else None  # the legacy one-line rust-toolchain file


def toolchain_env(repo, rel):
    """The environment for the workspace REL: rustup's own pick when a pin file is at or above it (inside REPO), else
    RUSTUP_TOOLCHAIN set to the cmux-tui pin."""
    env = dict(os.environ)
    env.pop("RUSTUP_TOOLCHAIN", None)  # it would override the pin files
    d = os.path.join(repo, rel)
    while True:
        if any(os.path.isfile(os.path.join(d, f)) for f in TOOLCHAIN_FILES):
            return env, None
        if os.path.samefile(d, repo):
            break
        d = os.path.dirname(d)
    pin = channel(os.path.join(repo, DEFAULT_PIN))
    if pin:
        env["RUSTUP_TOOLCHAIN"] = pin
    return env, pin


def cargo_bin():
    """rustup's cargo first (the build scripts put $CARGO_HOME/bin first too): another cargo ignores the pins."""
    home = os.environ.get("CARGO_HOME") or os.path.expanduser("~/.cargo")
    return shutil.which("cargo", path=os.pathsep.join([os.path.join(home, "bin"), os.environ.get("PATH", "")]))


def check(repo, rel, cargo):
    env, _ = toolchain_env(repo, rel)
    cwd = os.path.join(repo, rel)
    argv = [cargo, "metadata", "--locked", "--format-version", "1", "--manifest-path", os.path.join(cwd, "Cargo.toml")]
    try:
        p = subprocess.run(argv, cwd=cwd, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True,
                           timeout=LIMIT)
    except subprocess.TimeoutExpired:
        return "ERROR", f"cargo metadata did not end in {LIMIT} s"
    if p.returncode == 0:
        return "OK", ""
    lines = [ln.strip() for ln in p.stderr.splitlines() if ln.strip()]
    stale = next((ln for ln in lines if STALE.search(ln)), None)
    if stale:
        return "STALE", stale
    first = next((ln for ln in lines if ln.startswith("error")), lines[-1] if lines else f"exit {p.returncode}")
    return "ERROR", first


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--repo", default=os.getcwd(), help="the checkout to check (default: the current directory's)")
    ap.add_argument("--jobs", type=int, default=4, help="workspaces checked at the same time (default 4)")
    args = ap.parse_args(argv)
    try:
        return run(args)
    except Exception as e:  # never the stale-lock exit 1 for a fault of the script or its host
        print(f"check-cargo-locks: not checked: {type(e).__name__}: {e}", file=sys.stderr)
        return 2


def fix_command(repo, rel):
    _, pin = toolchain_env(repo, rel)
    return f"(cd {rel} && cargo {'+' + pin + ' ' if pin else ''}update --workspace)"


def run(args):
    repo = git_root(args.repo)
    cargo = cargo_bin()
    if not cargo:
        raise Unchecked("no cargo in $CARGO_HOME/bin or on PATH")
    dirs = workspaces(repo)
    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, args.jobs)) as pool:
        results = list(pool.map(lambda d: (d, *check(repo, d, cargo)), dirs))
    for d, verdict, line in results:
        print(f"{verdict} {d}" + (f": {line}" if line else ""))
    stale = [d for d, v, _ in results if v == "STALE"]
    errors = [d for d, v, _ in results if v == "ERROR"]
    if stale:
        print(f"check-cargo-locks: {len(stale)} stale of {len(dirs)} Cargo.lock: {', '.join(stale)}. "
              f"Fix: {'; '.join(fix_command(repo, d) for d in stale)}, then commit only the lock.")
        return 1
    if errors:
        print(f"check-cargo-locks: no stale lock, but {len(errors)} of {len(dirs)} not checked: {', '.join(errors)}")
        return 2
    print(f"check-cargo-locks: all {len(dirs)} Cargo.lock resolve with --locked")
    return 0


if __name__ == "__main__":
    sys.exit(main())
