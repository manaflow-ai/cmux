#!/usr/bin/env python3
"""Split the cmux-tui workspace's test targets into shards, and run one shard.

One `cargo test --workspace` ran every test binary in one job and passed test
(linux)'s 90-minute limit on every feat full run (jobs 130997361973,
131090089893, 131108159345). Each shard leg builds the workspace's test binaries
once (`cargo test --no-run --message-format=json`: the same build, so the same
targets, in every leg) and runs its own part of them:

  plan              prints each shard's predicted seconds and target count, and
                    exits 2 when a shard is predicted past the budget (45 min), so
                    a slower suite shows before a leg reaches its job limit.
  run               runs one shard: each test binary directly (after cargo's
                    `Running SRC (BINARY)` line, so log readers keep working), in its package's
                    directory with the CARGO_* variables `cargo test` sets (one
                    `cargo test -p` per package would resolve other features than
                    the workspace build and compile again), and the workspace's doc
                    tests in the shard that holds them. Every target runs after a
                    red; the first red status is the exit status.
  weights-from-log  prints the weight list from a test job's log.

The split: longest first, each target into the shard with the least predicted
time (ties to the lower shard), by the weights in
.github/cmux-tui-test-weights.json; a target missing from it counts the default.
Every leg computes the same plan from the same target list, so the legs together
run every target exactly once.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
from typing import NamedTuple

# Library-like target kinds; `cargo test` runs their unit tests as `--lib`.
LIB_KINDS = frozenset({"lib", "rlib", "dylib", "cdylib", "staticlib", "proc-macro"})
# The workspace's doc tests, run together as one target.
DOC = "doc"


class Target(NamedTuple):
    """One test target: `package/lib`, `package/KIND/NAME`, or the workspace doc tests."""

    unit: str
    weight_key: str
    executable: str | None
    source: str
    package: str
    version: str
    manifest_dir: str
    crate_name: str


def package_of(package_id: str) -> tuple[str, str]:
    """The package name and version in a cargo package id, old or new form."""
    if " " in package_id:  # "name 1.0.0 (path+file:///...)"
        name, version = package_id.split(" ")[:2]
        return name, version
    location, _, fragment = package_id.partition("#")
    if "@" in fragment:  # "...#name@1.0.0"
        name, _, version = fragment.partition("@")
        return name, version
    # "path+file:///.../name#1.0.0": the name is the directory's.
    return location.rstrip("/").rsplit("/", 1)[-1], fragment


def targets_in(messages: Path) -> list[Target]:
    """Every test target cargo built (and so `cargo test` would run), and the doc tests."""
    found: dict[str, Target] = {}
    with messages.open(encoding="utf-8") as lines:
        for line in lines:
            try:
                message = json.loads(line)
            except json.JSONDecodeError:
                continue
            if message.get("reason") != "compiler-artifact":
                continue
            if not message.get("profile", {}).get("test") or not message.get("executable"):
                continue
            target = message.get("target", {})
            kinds = set(target.get("kind", []))
            name = str(target.get("name", ""))
            package, version = package_of(str(message.get("package_id", "")))
            crate = name.replace("-", "_")
            if kinds & LIB_KINDS:
                unit, key = f"{package}/lib", f"lib/{crate}"
            elif len(kinds) == 1:
                kind = next(iter(kinds))
                unit, key = f"{package}/{kind}/{name}", f"{kind}/{crate}"
            else:
                raise SystemExit(f"{package}: test target {name} has kinds {sorted(kinds)}")
            found[unit] = Target(
                unit=unit,
                weight_key=key,
                executable=str(message["executable"]),
                source=str(target.get("src_path", "")),
                package=package,
                version=version,
                manifest_dir=str(Path(str(message.get("manifest_path", ""))).parent),
                crate_name=crate,
            )
    if not found:
        raise SystemExit(f"{messages}: cargo reported no test targets")
    found[DOC] = Target(DOC, DOC, None, "", "", "", "", "")
    return sorted(found.values(), key=lambda t: t.unit)


class Weights(NamedTuple):
    seconds: dict[str, float]
    default: float
    budget: float

    def of(self, target: Target) -> float:
        return float(self.seconds.get(target.weight_key, self.default))


def load_weights(path: Path) -> Weights:
    data = json.loads(path.read_text(encoding="utf-8"))
    return Weights(
        seconds={str(k): float(v) for k, v in data.get("seconds", {}).items()},
        default=float(data.get("default_seconds", 30)),
        budget=float(data.get("budget_seconds", 45 * 60)),
    )


def plan(targets: list[Target], weights: Weights, shards: int) -> list[list[Target]]:
    """Longest first, each target into the shard with the least predicted time."""
    if shards < 1:
        raise SystemExit("--of must be at least 1")
    parts: list[list[Target]] = [[] for _ in range(shards)]
    totals = [0.0] * shards
    for target in sorted(targets, key=lambda t: (-weights.of(t), t.unit)):
        at = min(range(shards), key=lambda i: (totals[i], i))
        parts[at].append(target)
        totals[at] += weights.of(target)
    placed = sorted(t.unit for part in parts for t in part)
    if placed != sorted(t.unit for t in targets):
        raise SystemExit("the shard plan lost or repeated a target")
    return [sorted(part, key=lambda t: t.unit) for part in parts]


def report(parts: list[list[Target]], weights: Weights) -> bool:
    """Prints each shard's predicted time; False when one is past the budget."""
    within = True
    for number, part in enumerate(parts, start=1):
        total = sum(weights.of(t) for t in part)
        print(f"shard {number}/{len(parts)}: {total:.0f} s predicted, {len(part)} targets")
        if total > weights.budget:
            within = False
            print(
                f"::error::shard {number}/{len(parts)} is predicted at {total / 60:.1f} min, past the "
                f"{weights.budget / 60:.0f} min budget: add a shard, or update the weights "
                "(.github/cmux-tui-test-weights.json, weights-from-log)",
                file=sys.stderr,
            )
    return within


def exit_status(returncode: int) -> int:
    """A positive status: a signal-ended process (negative returncode) maps to 128 + signal."""
    return 128 - returncode if returncode < 0 else returncode


def environment(target: Target) -> dict[str, str]:
    """The variables `cargo test` sets for a test binary of TARGET's package."""
    env = dict(os.environ)
    major, minor, patch = (target.version.split("-")[0].split(".") + ["0", "0", "0"])[:3]
    env.update({
        "PWD": target.manifest_dir,
        "CARGO_MANIFEST_DIR": target.manifest_dir,
        "CARGO_MANIFEST_PATH": str(Path(target.manifest_dir) / "Cargo.toml"),
        "CARGO_PKG_NAME": target.package,
        "CARGO_PKG_VERSION": target.version,
        "CARGO_PKG_VERSION_MAJOR": major,
        "CARGO_PKG_VERSION_MINOR": minor,
        "CARGO_PKG_VERSION_PATCH": patch,
        "CARGO_PKG_VERSION_PRE": target.version.partition("-")[2],
        "CARGO_CRATE_NAME": target.crate_name,
        "CARGO_PRIMARY_PACKAGE": "1",
    })
    cargo = shutil.which("cargo")
    if cargo:
        env["CARGO"] = cargo
    deps = str(Path(str(target.executable)).parent)
    env["LD_LIBRARY_PATH"] = os.pathsep.join(
        p for p in (deps, str(Path(deps).parent), os.environ.get("LD_LIBRARY_PATH", "")) if p
    )
    return env


def running_line(target: Target) -> str:
    """Cargo's `Running SRC (BINARY)` words, which weights-from-log and affected_tests_replay.py read."""
    source = os.path.relpath(target.source, target.manifest_dir) if target.source else "?"
    binary = os.path.relpath(str(target.executable))
    return f"{'unittests ' if target.weight_key.split('/')[0] in ('lib', 'bin') else ''}{source} ({binary})"


def run(targets: list[Target], doc_command: list[str], args: list[str]) -> int:
    failed: list[tuple[str, int]] = []
    for at, target in enumerate(targets, start=1):
        print(f"started {target.unit} [{at}/{len(targets)}]", flush=True)
        if target.unit != DOC:
            print(f"     Running {running_line(target)}", flush=True)
        if target.unit == DOC:
            command, cwd, env = doc_command + (["--", *args] if args else []), None, None
        else:
            command, cwd, env = [str(target.executable), *args], target.manifest_dir, environment(target)
        status = exit_status(subprocess.run(command, cwd=cwd, env=env, check=False).returncode)
        print(f"finished {target.unit}: exit {status}", flush=True)
        if status != 0:
            print(f"::error::{target.unit} exited {status}", file=sys.stderr)
            failed.append((target.unit, status))
    if failed:
        print(f"Failed {len(failed)} of {len(targets)} targets:", file=sys.stderr)
        for unit, status in failed:
            print(f"  {unit} exited {status}", file=sys.stderr)
        return failed[0][1]
    print(f"Passed all {len(targets)} targets of this shard")
    return 0


# Only the workspace's own binaries: another workspace's print as `other/target/debug/deps/...`.
_RUNNING = re.compile(r"Running (unittests )?(\S+) \((\S*/)?target/debug/deps/([A-Za-z0-9_]+)-[0-9a-f]+\)")
_KIND_OF_DIRECTORY = {"tests": "test", "benches": "bench", "examples": "example"}
_DOC = re.compile(r"Doc-tests (\S+)")
_RESULT = re.compile(r"test result: \w+\..*finished in ([0-9.]+)s")


def weights_from_log(log: Path, exclude: set[str]) -> dict[str, float]:
    """`kind/name` to seconds from a test job's log.

    The doc tests' line says `finished in 0.00s` (rustdoc compiles each one before
    that clock starts), so their weight is the span of their lines, set by hand.
    """
    seconds: dict[str, float] = {}
    key: str | None = None
    for line in log.read_text(encoding="utf-8", errors="replace").splitlines():
        line = re.sub(r"\x1b\[[0-9;]*m", "", line)
        running, doc, result = _RUNNING.search(line), _DOC.search(line), _RESULT.search(line)
        if running:
            unit_tests, source, other, stem = running.groups()
            if other or stem in exclude:
                key = None
            elif not unit_tests:
                kind = _KIND_OF_DIRECTORY.get(source.split("/")[0], "test")
                key = f"{kind}/{stem}"
            elif source.startswith("src/lib.rs"):
                key = f"lib/{stem}"
            else:
                key = f"bin/{stem}"
        elif doc:
            key = None  # libtest's doc time leaves out rustdoc's compile; measure the span instead
        elif result and key:
            took = float(result.group(1))
            seconds[key] = max(seconds.get(key, 0.0), took)
            key = None
    return {k: round(v, 1) for k, v in sorted(seconds.items())}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("plan", "run"):
        sub = commands.add_parser(name)
        sub.add_argument("--messages", type=Path, required=True)
        sub.add_argument("--weights", type=Path, required=True)
        sub.add_argument("--of", type=int, required=True)
        if name == "run":
            sub.add_argument("--shard", type=int, required=True)
            sub.add_argument(
                "--doc-command",
                default="cargo test --workspace --exclude cmux-tui-core --locked --doc",
                help="how the doc tests run",
            )
            sub.add_argument("args", nargs=argparse.REMAINDER, help="-- then libtest arguments")
    from_log = commands.add_parser("weights-from-log")
    from_log.add_argument("log", type=Path)
    from_log.add_argument("--exclude", action="append", default=["cmux_tui_core"])
    options = parser.parse_args()

    if options.command == "weights-from-log":
        print(json.dumps(weights_from_log(options.log, set(options.exclude)), indent=2, sort_keys=True))
        return 0
    weights = load_weights(options.weights)
    parts = plan(targets_in(options.messages), weights, options.of)
    within = report(parts, weights)
    if options.command == "plan":
        return 0 if within else 2
    if not 1 <= options.shard <= options.of:
        raise SystemExit(f"--shard must be between 1 and {options.of}")
    args = options.args[1:] if options.args[:1] == ["--"] else options.args
    status = run(parts[options.shard - 1], options.doc_command.split(), args)
    # A shard past its budget still runs its tests first, so the drift and the tests both show.
    return status if status or within else 2


if __name__ == "__main__":
    sys.exit(main())
