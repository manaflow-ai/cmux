#!/usr/bin/env python3
"""Shared Rust compile cache for GitHub jobs (.github/actions/rust-compile-cache).

    rust_compile_cache.py start --job NAME    # sccache on the repository's Actions cache, for the rest of the job
    rust_compile_cache.py report --job NAME   # hits, misses, store errors: one summary line; ::error when down

Every cargo step after `start` runs rustc through sccache 0.19.0. The store is this repository's GitHub Actions
cache (SCCACHE_GHA_ENABLED), which every runner the jobs use can reach with the job's own token. A compile's key
hashes its inputs (sources, arguments, CARGO_* environment, rustc), never the commit, so a later head, another
PR or the base push that compiled the same crate from the same inputs serves it. Pull requests write too: an
Actions cache entry a PR writes is visible only to that PR's later runs, never to the base or another PR.

A store that cannot be reached is loud, not a miss (hq docs/handbook/cache-store-down-reads-as-misses.md):
`start` prints an ::error and the job compiles without sccache; `report` prints an ::error when lookups failed
against the store. Neither fails the job: the cache changes how long a compile takes, never its verdict.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
from pathlib import Path

VERSION = "0.19.0"
# The release digest, as build-fleet/swift-linux-builder/gha-runners/pool-startup.sh pins it for the pool's VMs.
DIGESTS = {
    "x86_64": ("x86_64-unknown-linux-musl", "aa73c7270c997894038c0d8f0d297865f57569e1687883322bc431713d4bb9dd"),
}
# Bump to start an empty namespace (a poisoned or incompatible store).
GHA_VERSION = "cmux-rcc-v1"


def env_file(name: str, pairs: dict[str, str]) -> None:
    path = os.environ.get(name)
    if not path:
        return
    with open(path, "a", encoding="utf-8") as f:
        for k, v in pairs.items():
            f.write(f"{k}={v}\n")


def find_sccache() -> str | None:
    """The pinned sccache: the runner's own when it is that version (the GCP pool bakes it), else downloaded."""
    have = shutil.which("sccache")
    if have:
        out = subprocess.run([have, "--version"], capture_output=True, text=True).stdout.strip()
        if out == f"sccache {VERSION}":
            return have
    import platform
    arch = platform.machine()
    if sys.platform != "linux" or arch not in DIGESTS:
        print(f"rust compile cache: no pinned sccache for {sys.platform}/{arch}; compiling without it")
        return None
    triple, digest = DIGESTS[arch]
    dest = Path(os.environ.get("RUNNER_TEMP", tempfile.gettempdir())) / f"sccache-{VERSION}"
    binary = dest / "sccache"
    if binary.is_file():
        return str(binary)
    url = f"https://github.com/mozilla/sccache/releases/download/v{VERSION}/sccache-v{VERSION}-{triple}.tar.gz"
    with tempfile.TemporaryDirectory() as t:
        tgz = Path(t) / "s.tgz"
        for attempt in range(3):
            try:
                with urllib.request.urlopen(url, timeout=60) as r:
                    tgz.write_bytes(r.read())
                break
            except OSError as e:
                if attempt == 2:
                    print(f"::error title=rust compile cache::sccache download failed ({e}); compiling cold")
                    return None
        if hashlib.sha256(tgz.read_bytes()).hexdigest() != digest:
            print("::error title=rust compile cache::sccache download has the wrong sha256; compiling cold")
            return None
        with tarfile.open(tgz) as tar:
            member = tar.getmember(f"sccache-v{VERSION}-{triple}/sccache")
            member.name = "sccache"
            dest.mkdir(parents=True, exist_ok=True)
            tar.extract(member, dest, filter="data")
    binary.chmod(0o755)
    return str(binary)


def server_env() -> dict[str, str]:
    rw = os.environ.get("RCC_RW_MODE", "READ_WRITE")
    return {
        "SCCACHE_GHA_ENABLED": "true",
        "SCCACHE_GHA_VERSION": GHA_VERSION,
        "SCCACHE_GHA_RW_MODE": rw,
        "SCCACHE_IDLE_TIMEOUT": "0",
        # A store that does not answer is an error to report, not a hang per compile.
        "SCCACHE_STARTUP_TIMEOUT_MS": "15000",
    }


def start(job: str) -> int:
    if not os.environ.get("ACTIONS_RESULTS_URL") and not os.environ.get("ACTIONS_CACHE_URL"):
        print(f"::error title=rust compile cache down::{job}: the runner gave no Actions cache service URL; "
              "this job compiles cold")
        return 0
    binary = find_sccache()
    if not binary:
        return 0
    env = {**os.environ, **server_env()}
    subprocess.run([binary, "--stop-server"], env=env, capture_output=True)
    started = subprocess.run([binary, "--start-server"], env=env, capture_output=True, text=True)
    if started.returncode != 0:
        print(f"::error title=rust compile cache down::{job}: sccache did not start on the Actions cache "
              f"({(started.stderr or started.stdout).strip()[:300]}); this job compiles cold")
        return 0
    shown = subprocess.run([binary, "--show-stats", "--stats-format", "json"], env=env, capture_output=True, text=True)
    try:
        location = str(json.loads(shown.stdout).get("cache_location", ""))
    except ValueError:
        location = ""
    if "GHA" not in location.upper():
        print(f"::error title=rust compile cache down::{job}: sccache's store is {location or 'unknown'}, "
              "not the Actions cache; this job compiles cold")
        subprocess.run([binary, "--stop-server"], env=env, capture_output=True)
        return 0
    env_file("GITHUB_ENV", {**server_env(), "RUSTC_WRAPPER": binary, "CARGO_INCREMENTAL": "0",
                            "RCC_SCCACHE": binary})
    print(f"rust compile cache: sccache {VERSION} on the Actions cache ({GHA_VERSION}, "
          f"{server_env()['SCCACHE_GHA_RW_MODE']})")
    return 0


def total(value) -> int:
    """sccache's per-language counters ({"counts": {"Rust": 3}, "adv_counts": ...}) or a plain number, summed."""
    if isinstance(value, bool):
        return 0
    if isinstance(value, (int, float)):
        return int(value)
    if isinstance(value, dict):
        if "counts" in value:
            return total(value["counts"])
        return sum(total(v) for k, v in value.items() if k != "adv_counts")
    return 0


def summarize(stats: dict) -> dict:
    s = stats.get("stats", stats)
    hits, misses = total(s.get("cache_hits")), total(s.get("cache_misses"))
    errors = (total(s.get("cache_errors")) + total(s.get("cache_read_errors")) + total(s.get("cache_write_errors"))
              + total(s.get("cache_timeouts")))
    noncache = total(s.get("requests_not_cacheable"))
    looked = hits + misses
    return {"hits": hits, "misses": misses, "store_errors": errors, "not_cacheable": noncache,
            "hit_rate": round(hits / looked, 3) if looked else None,
            # Down: lookups failed and none hit. A few failed writes beside hits is a busy store, not down.
            "store_down": errors > 0 and hits == 0}


def report(job: str) -> int:
    binary = os.environ.get("RCC_SCCACHE")
    if not binary:
        print(f"rust compile cache: {job}: not started")
        return 0
    out = subprocess.run([binary, "--show-stats", "--stats-format", "json"], capture_output=True, text=True)
    try:
        row = summarize(json.loads(out.stdout))
    except (ValueError, AttributeError):
        print(f"::error title=rust compile cache down::{job}: sccache gave no stats ({out.stderr.strip()[:200]})")
        return 0
    row = {"schema": "cmux-rust-compile-cache/v1", "job": job, **row}
    line = json.dumps(row, sort_keys=True)
    print(line)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as f:
            f.write(f"rust compile cache: `{line}`\n")
    if row["store_down"]:
        print(f"::error title=rust compile cache down::{job}: {row['store_errors']} store errors and no hit: "
              "the Actions cache did not answer, so this job compiled cold")
    subprocess.run([binary, "--stop-server"], capture_output=True)
    return 0


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("mode", choices=["start", "report"])
    p.add_argument("--job", required=True)
    a = p.parse_args(argv)
    return start(a.job) if a.mode == "start" else report(a.job)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
