#!/usr/bin/env python3
"""The tests a change can affect, as fleet steps `cmux-ci test --affected` runs at once.

    affected_tests.py --base BASE [--head HEAD] [--shards N]   # what BASE...HEAD can affect
    affected_tests.py --files a.rs b.swift --base BASE         # explicit paths (BASE still names the Rust diff)
    affected_tests.py --all --head HEAD [--shards N]           # the opt-out: every suite

Prints one JSON plan on stdout:

    {"base": SHA, "head": SHA, "all": false, "reasons": [...], "files": [...],
     "units": [{"name": "rust", "kind": "rust", "argv": ["run", ...], "why": "..."}, ...],
     "not_run": [{"what": "...", "why": "..."}]}

Each unit's argv is a `cmux-ci` command line without the leading `cmux-ci`. HQ's
`cmux-ci test --affected` runs every unit at once, each on its own free fleet machine, and
fails when any does. The selection is scripts/ci/focused_tests.py's map (Swift test targets by
import and path dependency, the webviews import graph, the Python tests that name a changed
path, Native cargo workspaces) with its caps off, and scripts/ci/cargo_affected.py for
cmux-tui, which the Rust step runs where cargo is (`cmux-tui-rust-check.sh test
@affected=BASE`):

  rust    cmux-tui-rust-check.sh test @affected=BASE, `--shards` nextest partitions. The
          step computes the crates (owners plus reverse dependencies) itself.
  swift   package-test-lane.sh suite PACKAGE TARGET,...: the selected test targets of each
          package, split round-robin over the shards. A whole-package selection (a manifest,
          CmuxNext's route marking everything) lists every test target of the package.
  web     run-webviews-tests.sh with CMUX_WEB_TEST_FILES, split over the shards; files that
          launch a browser engine run apart with CMUX_BROWSER_TESTS=1.
  python  run_python_test_lane.py --lane linux-guard --path ... --shard K/N through
          `cmux-ci test` (fast checks on Linux).
  native  the Native/ cargo workspace's own tests (optchat-chief's step mode on macOS, else
          `cargo test --manifest-path` through `cmux-ci test --setup rust`).

It never trades a test for speed: a changed path that no rule maps (`unmapped`), a change
to this planner or the scripts the units run, or more than MAX_FILES paths, selects
everything (--all), and the plan says why. Python tests whose lane runs only on macOS, and
manual or legacy entries, are listed in not_run, never dropped silently.

Replay: scripts/ci/affected_tests_replay.py checks this selection against the failures CI
recorded on merged PRs. Test: tests/test_ci_affected_tests.py.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

# focused_tests caps its selection for a car's guard; a lane's own run takes all of it.
os.environ.setdefault("FOCUSED_WEB_CAP", "100000")
os.environ.setdefault("FOCUSED_SWIFT_CAP", "100000")
sys.path.insert(0, str(Path(__file__).resolve().parent))
import focused_tests  # noqa: E402

RUST_SCRIPT = "scripts/ci/cmux-tui-rust-check.sh"
SWIFT_SCRIPT = "scripts/ci/package-test-lane.sh"
WEB_SCRIPT = "scripts/ci/run-webviews-tests.sh"
PYTHON_RUNNER = "scripts/ci/run_python_test_lane.py"
LINUX_PYTHON_LANE = "linux-guard"
CMUX_NEXT = "Packages/macOS/CmuxNext"
NATIVE_MODES = {"Native/OptChat/optchat-chief/Cargo.toml": "optchat-chief"}
# A change to what decides or runs the selection selects everything.
SELF_INPUTS = (
    "scripts/ci/affected_tests.py", "scripts/ci/focused_tests.py", "scripts/ci/cargo_affected.py",
    "scripts/ci/cmux_next_route.py", "scripts/ci/select_package_tests.py", "scripts/ci/focused-tests-extra.json",
    RUST_SCRIPT, SWIFT_SCRIPT, WEB_SCRIPT, PYTHON_RUNNER, "tests/test-execution.toml",
)
MAX_FILES = 400
# Tests that drive a phone or simulator rig; they run on their own hardware, never in a fast check.
DEVICE_ONLY = ("cmux-next-ios/verify/",)
DEFAULT_SHARDS = 4
MAX_SHARDS = 16


def git(root: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(root), *args], check=True, capture_output=True, text=True).stdout.strip()


def split(items: list[str], shards: int) -> list[list[str]]:
    """Round-robin over at most `shards` parts, none empty, each in input order."""
    n = max(1, min(shards, len(items)))
    return [items[i::n] for i in range(n)]


def swift_test_targets(root: Path, package: str) -> list[str]:
    tests = root / package / "Tests"
    return sorted(p.name for p in tests.iterdir() if p.is_dir()) if tests.is_dir() else []


def swift_packages(root: Path) -> list[str]:
    found = []
    for manifest in sorted((root / "Packages").glob("**/Package.swift")):
        rel = manifest.parent.relative_to(root).as_posix()
        if "/.build" in rel or "/Tests/" in rel or "/Sources/" in rel:
            continue
        if swift_test_targets(root, rel):
            found.append(rel)
    return found


def web_tests(root: Path) -> list[str]:
    return sorted(p[len(focused_tests.WEB):] for p in focused_tests.tracked(root, focused_tests.WEB)
                  if focused_tests.WEB_TEST.search(p) and "/node_modules/" not in p)


def unregistered_python_tests(root: Path) -> list[str]:
    """test_*.py files outside the lane registry's directories (scripts/cmux-next/tests, cmux-tui/scripts,
    cmux-tui/bindings, ...): their own workflows run them, so the lane runner cannot."""
    registered = set(focused_tests.lanes(root))
    return sorted(p for p in focused_tests.tracked(root, ".") if Path(p).name.startswith("test_") and p.endswith(".py")
                  and p not in registered and not p.startswith(tuple(d + "/" for d in focused_tests.PYTHON_TEST_DIRS))
                  and "/node_modules/" not in p and not p.startswith(DEVICE_ONLY) and (root / p).is_file())


def area(path: str) -> str:
    return "/".join(path.split("/")[:2])


def python_lane_tests(root: Path) -> dict[str, str]:
    return {path: lane for path, (lane, _serial) in focused_tests.lanes(root).items()}


class Planner:
    def __init__(self, root: Path, base: str, head: str, shards: int):
        self.root, self.base, self.head, self.shards = root, base, head, shards
        self.units: list[dict] = []
        self.not_run: list[dict] = []

    def key(self, name: str) -> str:
        return f"affected-{self.head[:12]}-{name}"

    def run_step(self, name: str, kind: str, why: str, script: str, cls: str, args: list[str],
                 env: dict[str, str] | None = None, extra: list[str] | None = None) -> None:
        argv = ["run", "--class", cls, "--script", script, "--ref", self.head, "--key", self.key(name)]
        for arg in args:
            argv.append(f"--arg={arg}")
        for k, v in (env or {}).items():
            argv += ["--env", f"{k}={v}"]
        self.units.append({"name": name, "kind": kind, "argv": argv + (extra or []), "why": why})

    def rust(self, everything: bool) -> None:
        args = ["test"] if everything else ["test", f"@affected={self.base}"]
        extra = ["--os", "linux"] + (["--shards", str(self.shards)] if self.shards > 1 else [])
        why = "every cmux-tui crate" if everything else "the cmux-tui crates the change reaches (cargo_affected.py on the step)"
        self.run_step("rust", "rust", why, RUST_SCRIPT, "light", args, extra=extra)

    def swift(self, targets: dict[str, list[str]], why: str) -> None:
        for package, names in sorted(targets.items()):
            label = package.rsplit("/", 1)[-1]
            parts = split(names, self.shards)
            for i, part in enumerate(parts, 1):
                name = f"swift-{label}" + (f"-{i}of{len(parts)}" if len(parts) > 1 else "")
                self.run_step(name, "swift", why, SWIFT_SCRIPT, "light", ["suite", package, ",".join(part)])

    def web(self, files: list[dict] | None) -> None:
        if files is None:
            plain, browser = web_tests(self.root), []
        else:
            plain = [f["path"] for f in files if not f.get("browser")]
            browser = [f["path"] for f in files if f.get("browser")]
        for label, chosen, env in (("web", plain, {}), ("web-browser", browser, {"CMUX_BROWSER_TESTS": "1"})):
            parts = split(chosen, self.shards)
            for i, part in enumerate(parts, 1):
                name = label + (f"-{i}of{len(parts)}" if len(parts) > 1 else "")
                self.run_step(name, "web", f"{len(chosen)} webviews test files", WEB_SCRIPT, "light", [],
                              env={**env, "CMUX_WEB_TEST_FILES": "\n".join(part)})

    def python(self, paths: list[str] | None) -> None:
        lanes = python_lane_tests(self.root)
        if paths is None:
            chosen = [p for p, lane in lanes.items() if lane == LINUX_PYTHON_LANE]
        else:
            chosen = []
            for path in paths:
                lane = lanes.get(path, "")
                if lane == LINUX_PYTHON_LANE:
                    chosen.append(path)
                else:
                    self.not_run.append({"what": path, "why": f"Python lane {lane or 'unregistered'!r} does not run on Linux fast checks"})
        if not chosen:
            return
        n = max(1, min(self.shards, (len(chosen) + 19) // 20))
        for i in range(1, n + 1):
            cmd = ["python3", PYTHON_RUNNER, "--lane", LINUX_PYTHON_LANE, "--jobs", "8"]
            if paths is not None:
                for path in chosen:
                    cmd += ["--path", path]
            if n > 1:
                cmd += ["--shard", f"{i}/{n}"]
            name = "python" + (f"-{i}of{n}" if n > 1 else "")
            self.units.append({"name": name, "kind": "python", "why": f"{len(chosen)} Python tests ({LINUX_PYTHON_LANE})",
                               "argv": ["test", "--setup", "none", "--", *cmd]})

    def python_extra(self, paths: list[str], why: str) -> None:
        """Tests outside the lane registry run one process each, from the repository root."""
        for i, part in enumerate(split(paths, max(1, min(self.shards, (len(paths) + 29) // 30))), 1):
            script = 'rc=0; for t in "$@"; do echo "== python3 $t"; python3 "$t" || { echo "FAILED: $t"; rc=1; }; done; exit $rc'
            name = "python-extra" + (f"-{i}" if len(paths) > 30 else "")
            self.units.append({"name": name, "kind": "python", "why": why,
                               "argv": ["test", "--setup", "none", "--", "bash", "-c", script, "affected", *part]})

    def native(self, manifests: list[str]) -> None:
        for manifest in manifests:
            label = manifest.rsplit("/", 2)[-2]
            mode = NATIVE_MODES.get(manifest)
            if mode:
                self.run_step(f"native-{label}", "native", manifest, RUST_SCRIPT, "light", [mode], extra=["--os", "macos"])
            else:
                self.units.append({"name": f"native-{label}", "kind": "native", "why": manifest,
                                   "argv": ["test", "--setup", "rust", "--", "cargo", "test", "--locked", "--manifest-path", manifest]})


def extra_python(root: Path, files: list[str]) -> list[str]:
    """Unregistered Python tests a change can affect: a changed test itself, a test in the same
    two-level area (cmux-tui/scripts, scripts/cmux-next) as a changed file, or one that names a
    changed path or its distinctive basename."""
    tests = unregistered_python_tests(root)
    areas = {area(f) for f in files if "/" in f}
    names = {f: focused_tests.distinctive(f) for f in files}
    out = []
    for test in tests:
        if test in files or area(test) in areas:
            out.append(test)
            continue
        text = (root / test).read_text(encoding="utf-8", errors="replace")
        if any(f in text or (n and n in text) for f, n in names.items()):
            out.append(test)
    return out


def everything_reasons(files: list[str], focused: dict) -> list[str]:
    reasons = []
    if len(files) > MAX_FILES:
        reasons.append(f"{len(files)} changed paths (over {MAX_FILES})")
    reasons += [f"{p}: decides or runs the selection" for p in files if p in SELF_INPUTS]
    reasons += [f"{p}: no rule maps it to tests" for p in focused.get("unmapped", [])]
    return reasons


def plan(root: Path, base: str, head: str, files: list[str] | None, shards: int, everything: bool) -> dict:
    if files is None:
        files = sorted({line for line in git(root, "diff", "--name-only", "--no-renames", f"{base}...{head}").splitlines() if line})
    focused = focused_tests.plan(root, files)
    reasons = ["--all"] if everything else everything_reasons(files, focused)
    p = Planner(root, base, head, shards)
    if reasons:
        p.rust(everything=True)
        p.swift({pkg: swift_test_targets(root, pkg) for pkg in swift_packages(root)}, "every Swift package test target")
        p.web(None)
        p.python(None)
        p.python_extra(unregistered_python_tests(root), "every Python test outside the lane registry")
        p.native(sorted({focused_tests.native_manifest(root, m.as_posix()) or "" for m in root.glob("Native/**/Cargo.lock")} - {""}))
    else:
        if focused["cargo"]["changed"]:
            p.rust(everything=False)
        targets: dict[str, list[str]] = {}
        for item in focused["swift"]:
            targets.setdefault(item["package"], []).append(item["filter"])
        if focused["swift_deferred"]:
            # A whole-package selection: every test target of each package a changed path is in.
            for path in files:
                pkg = CMUX_NEXT if path.startswith(CMUX_NEXT + "/") else (
                    (focused_tests.swift_package(root, path) or (None,))[0] or focused_tests.swift_package_root(root, path))
                if pkg:
                    targets[pkg] = swift_test_targets(root, pkg)
        p.swift({k: sorted(set(v)) for k, v in targets.items() if v}, focused["swift_deferred"] or "test targets that import a changed target")
        if focused["web"]:
            p.web(focused["web"])
        p.python([item["path"] for item in focused["python"]])
        extra = extra_python(root, files)
        if extra:
            p.python_extra(extra, f"{len(extra)} Python tests outside the lane registry")
        p.native([item["manifest"] for item in focused["native"]])
    return {"base": base, "head": head, "all": bool(reasons), "reasons": reasons, "files": files,
            "units": p.units, "not_run": p.not_run, "docs": focused.get("docs", [])}


def resolve(root: Path, ref: str) -> str:
    return git(root, "rev-parse", "--verify", f"{ref}^{{commit}}")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0], epilog=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--root", default=str(Path(__file__).resolve().parents[2]))
    parser.add_argument("--base", help="the merge base the change starts from (default: merge-base of HEAD and origin/feat-cmux-next)")
    parser.add_argument("--head", default="HEAD")
    parser.add_argument("--files", nargs="*", help="changed paths instead of BASE...HEAD")
    parser.add_argument("--shards", type=int, default=DEFAULT_SHARDS, help=f"machines per suite (1..{MAX_SHARDS})")
    parser.add_argument("--all", action="store_true", help="the opt-out: every suite, whatever changed")
    args = parser.parse_args(argv)
    if not 1 <= args.shards <= MAX_SHARDS:
        parser.error(f"--shards must be 1..{MAX_SHARDS}")
    root = Path(args.root).resolve()
    head = resolve(root, args.head)
    base = args.base or git(root, "merge-base", head, "origin/feat-cmux-next")
    base = resolve(root, base)
    files = sorted(set(args.files)) if args.files is not None else None
    print(json.dumps(plan(root, base, head, files, args.shards, args.all), indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
