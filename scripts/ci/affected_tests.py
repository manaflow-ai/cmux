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
import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path, PurePosixPath

# focused_tests caps its selection for a car's guard; a lane's own run takes all of it, whatever
# cap the caller's environment holds (a capped Swift selection comes back empty).
os.environ["FOCUSED_WEB_CAP"] = "100000"
os.environ["FOCUSED_SWIFT_CAP"] = "100000"
sys.path.insert(0, str(Path(__file__).resolve().parent))
import cargo_affected  # noqa: E402
import focused_tests  # noqa: E402

RUST_SCRIPT = "scripts/ci/cmux-tui-rust-check.sh"
SWIFT_SCRIPT = "scripts/ci/package-test-lane.sh"
WEB_SCRIPT = "scripts/ci/run-webviews-tests.sh"
PYTHON_RUNNER = "scripts/ci/run_python_test_lane.py"
GUARDS_SCRIPT = "scripts/ci/guards-local.sh"
LINUX_PYTHON_LANE = "linux-guard"
NATIVE_MODES = {"Native/OptChat/optchat-chief/Cargo.toml": "optchat-chief"}
# A change to what decides or runs the selection selects everything.
SELF_INPUTS = (
    "scripts/ci/affected_tests.py", "scripts/ci/focused_tests.py", "scripts/ci/cargo_affected.py",
    "scripts/ci/cmux_next_route.py", "scripts/ci/select_package_tests.py", "scripts/ci/focused-tests-extra.json",
    RUST_SCRIPT, SWIFT_SCRIPT, WEB_SCRIPT, PYTHON_RUNNER, GUARDS_SCRIPT,
)
MAX_FILES = 400
# The controller takes at most 64 CMUX_WEB_TEST_FILES per step, each `(src|test)/....test.<ext>`
# (ci_step.go validCIStepWebTestFiles). A larger or other selection runs as one whole-lane step.
WEB_FILES_PER_STEP = 64
WEB_LISTED_MAX = 4 * WEB_FILES_PER_STEP
WEB_FILE_OK = re.compile(r"^(src|test)/[A-Za-z0-9._/-]+\.test\.(ts|tsx|js|jsx|mjs)$")
# A test outside the lane registry runs in its own workflow's job, which sets up what it needs (Bun,
# a built CLI, a live socket, arguments); a fast check cannot reproduce that, so it lists them.
UNREGISTERED_WHY = "outside the lane registry: its own workflow runs it, with that job's setup"
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


def is_browser_test(root: Path, test: str) -> bool:
    """A test that launches a browser engine (requireBrowserLane, playwright) skips unless CMUX_BROWSER_TESTS=1."""
    path = root / focused_tests.WEB / test
    text = path.read_text(encoding="utf-8", errors="replace") if path.is_file() else ""
    return "requireBrowserLane" in text or "playwright" in text


def webviews_source_changed(files: list[str]) -> list[str]:
    """Non-test webviews paths a change touches, docs aside. Browser and gallery tests render the whole
    app through vite or read sources by path, so no import edge links them to what they load, and a
    build input (vite.config.ts, package.json, the lockfile) changes every test: any such change runs
    every webviews test (a replay of merged PRs found reds the import graph skipped)."""
    return [f for f in files if f.startswith(focused_tests.WEB) and not focused_tests.WEB_TEST.search(f)
            and not f.endswith(".md")]


def web_workflow_python_tests(root: Path) -> list[str]:
    """Python tests the webviews workflow (ci-web.yml) runs in its jobs: they go with every-web-test plans."""
    path = root / ".github/workflows/ci-web.yml"
    found = re.findall(r"python3 ((?:[\w.-]+/)*test_[\w-]+\.py)", path.read_text()) if path.is_file() else []
    return sorted({t for t in found if (root / t).is_file()})


def tests_naming(root: Path, paths: list[str]) -> tuple[dict[str, list[str]], list[str], list[str]]:
    """Swift test targets, webviews tests and lane Python tests whose source names one of `paths` (a
    docs or plans file a test reads by path, such as plans/cmux-next/actions.md):
    ({package: [targets]}, [web tests], [Python tests])."""
    # Not a conventional name many directories share (AGENTS.md, README.md, SKILL.md, index.json).
    names = sorted({Path(p).name for p in paths if len(Path(p).name) >= 8 and Path(p).name not in focused_tests.COMMON
                    and not re.fullmatch(r"[A-Z0-9_-]+\.md", Path(p).name)})
    swift: dict[str, set[str]] = {}
    web: set[str] = set()
    python: set[str] = set()
    if not names:
        return {}, [], []
    args = ["grep", "-l", "-F"] + [x for n in names for x in ("-e", n)]
    out = subprocess.run(["git", "-C", str(root), *args, "--", "Packages/**/Tests/**/*.swift", focused_tests.WEB + "test", "tests"],
                         capture_output=True, text=True).stdout.split()
    for path in out:
        if path.startswith("tests/") and path.endswith(".py"):
            python.add(path)
        elif path.startswith(focused_tests.WEB):
            if focused_tests.WEB_TEST.search(path):
                web.add(path[len(focused_tests.WEB):])
        elif "/Tests/" in path:
            package, rest = path.split("/Tests/", 1)
            swift.setdefault(package, set()).add(rest.split("/", 1)[0])
    return {k: sorted(v) for k, v in swift.items()}, sorted(web), sorted(python)


def unregistered_python_tests(root: Path) -> list[str]:
    """test_*.py files the lane registry does not list (scripts/tests, scripts/cmux-next/tests,
    cmux-tui/scripts, ...): their own workflows run them, so the lane runner cannot."""
    registered = set(focused_tests.lanes(root))
    return sorted(p for p in focused_tests.tracked(root, ".") if Path(p).name.startswith("test_") and p.endswith(".py")
                  and p not in registered
                  and "/node_modules/" not in p and not p.startswith(DEVICE_ONLY) and (root / p).is_file())


def area(path: str) -> str:
    return "/".join(path.split("/")[:2])


def python_lane_tests(root: Path) -> dict[str, str]:
    return {path: lane for path, (lane, _serial) in focused_tests.lanes(root).items()}


def guard_tests(root: Path) -> set[str]:
    """The test files the guards unit runs: every tests/ path a ci-guards.yml step names."""
    path = root / ".github/workflows/ci-guards.yml"
    return set(re.findall(r"tests/test_[\w-]+\.(?:py|sh)", path.read_text())) if path.is_file() else set()


class Planner:
    def __init__(self, root: Path, base: str, head: str, shards: int):
        self.root, self.base, self.head, self.shards = root, base, head, shards
        self.units: list[dict] = []
        self.not_run: list[dict] = []

    def key(self, name: str, what: object) -> str:
        """Per head, unit and exact request: a rerun with another base, shard count or selection is
        never answered from an earlier step's result."""
        digest = hashlib.sha256(json.dumps([self.base, what], sort_keys=True).encode()).hexdigest()[:8]
        return f"affected-{self.head[:12]}-{name}-{digest}"

    def run_step(self, name: str, kind: str, why: str, script: str, cls: str, args: list[str],
                 env: dict[str, str] | None = None, extra: list[str] | None = None) -> None:
        key = self.key(name, [script, cls, args, env or {}, extra or []])
        argv = ["run", "--class", cls, "--script", script, "--ref", self.head, "--key", key]
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

    def web(self, files: list[str] | None) -> None:
        """Webviews test files in steps of at most 64 (the controller's bound), browser tests in
        CMUX_BROWSER_TESTS=1 steps. None, a selection over WEB_LISTED_MAX or a file the controller's
        pattern refuses runs every webviews test in one step with the browser lane on."""
        chosen = sorted(set(files or []))
        if files is None or len(chosen) > WEB_LISTED_MAX or not all(WEB_FILE_OK.match(f) for f in chosen):
            self.run_step("web", "web", "every webviews test, browser lane included (one step)", WEB_SCRIPT, "light", [],
                          env={"CMUX_BROWSER_TESTS": "1"})
            return
        browser = [f for f in chosen if is_browser_test(self.root, f)]
        plain = [f for f in chosen if f not in browser]
        for label, picked, env in (("web", plain, {}), ("web-browser", browser, {"CMUX_BROWSER_TESTS": "1"})):
            if not picked:
                continue
            n = max(min(self.shards, len(picked)), -(-len(picked) // WEB_FILES_PER_STEP))
            parts = split(picked, n)
            for i, part in enumerate(parts, 1):
                name = label + (f"-{i}of{len(parts)}" if len(parts) > 1 else "")
                self.run_step(name, "web", f"{len(picked)} webviews test files", WEB_SCRIPT, "light", [],
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
                elif lane:  # plan() lists an unregistered one as run by its own workflow
                    self.not_run.append({"what": path, "why": f"Python lane {lane!r} does not run on Linux fast checks"})
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

    def guards(self) -> None:
        """Every guard step of ci-guards.yml (the "CI fast guards" runner). Most guards read the whole
        tree (ratchets, "every macOS job names its class"), so any change can turn one red and no path
        map can say which: they always run, in about a minute."""
        self.units.append({"name": "guards", "kind": "guards", "why": "every ci-guards.yml guard (they read the whole tree)",
                           "argv": ["test", "--setup", "none", "--", "bash", GUARDS_SCRIPT, "--all", "--keep-going", "--no-stamp"]})

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


def rust_references(root: Path) -> set[str]:
    """Repo paths outside cmux-tui/ that a cmux-tui crate reads: a "../" literal in its Rust sources
    (cargo_affected.py's crate_references; resolved against every folder up to cmux-tui/, since the
    anchor is the file's folder or its crate's) and the tree inputs (cmux-tui-tree-inputs.txt)."""
    refs = set(cargo_affected.tree_inputs(root, cargo_affected.WORKSPACE))
    out = subprocess.run(["git", "-C", str(root), "grep", "-l", "-F", '"../', "--", f"{cargo_affected.WORKSPACE}/**/*.rs"],
                         capture_output=True, text=True).stdout
    found = [(path, literal.lstrip("/")) for path in out.split()
             for literal in cargo_affected.RELATIVE_REF.findall((root / path).read_text(encoding="utf-8", errors="replace"))]
    for path, literal in found:
        folder = PurePosixPath(path).parent
        while folder != PurePosixPath(".") and folder.as_posix() != cargo_affected.WORKSPACE:
            target = os.path.normpath(os.path.join(folder.as_posix(), literal))
            if not target.startswith(("..", cargo_affected.WORKSPACE + "/")) and (root / target).exists():
                refs.add(target)
            folder = folder.parent
    return refs


def rust_may_read(root: Path, files: list[str]) -> bool:
    """A changed path the Rust step may need: anything outside the webviews, Swift packages, Native
    workspaces, plans/ and docs/, or a path in those that a crate reads (an include_str! target, a
    fixture a Rust test compares with). The step's own cargo_affected.py says which crates."""
    skipped = (focused_tests.WEB, "Packages/", "Native/", "plans/", "docs/")
    if any(not f.startswith(skipped) for f in files):
        return True
    refs = rust_references(root)
    # "." is a test that walks the whole tree (cmux-tui-core's mux matrix): every path reaches it.
    return bool(files) and "." in refs or any(f == ref or f.startswith(ref + "/") for f in files for ref in refs)


def everything_reasons(files: list[str], focused: dict) -> list[str]:
    reasons = []
    if len(files) > MAX_FILES:
        reasons.append(f"{len(files)} changed paths (over {MAX_FILES})")
    reasons += [f"{p}: decides or runs the selection" for p in files if p in SELF_INPUTS]
    # An unmapped webviews path (a fixture, a baseline, a build script) runs every webviews test instead.
    reasons += [f"{p}: no rule maps it to tests" for p in focused.get("unmapped", []) if not p.startswith(focused_tests.WEB)]
    return reasons


def plan(root: Path, base: str, head: str, files: list[str] | None, shards: int, everything: bool) -> dict:
    if files is None:
        files = sorted({line for line in git(root, "diff", "--name-only", "--no-renames", f"{base}...{head}").splitlines() if line})
    focused = focused_tests.plan(root, files)
    reasons = ["--all"] if everything else everything_reasons(files, focused)
    p = Planner(root, base, head, shards)
    if files or reasons:
        p.guards()  # docs too: guards read docs (plans/*.md ratchets) as much as code
    if reasons:
        p.rust(everything=True)
        p.swift({pkg: swift_test_targets(root, pkg) for pkg in swift_packages(root)}, "every Swift package test target")
        p.web(None)
        p.python(None)
        unregistered = unregistered_python_tests(root)
        if unregistered:
            p.not_run.append({"what": f"{len(unregistered)} Python tests outside the lane registry", "why": UNREGISTERED_WHY})
        p.native(sorted({focused_tests.native_manifest(root, m.as_posix()) or "" for m in root.glob("Native/**/Cargo.lock")} - {""}))
    else:
        if focused["cargo"]["changed"] or rust_may_read(root, files):
            p.rust(everything=False)
        targets: dict[str, list[str]] = {}
        for item in focused["swift"]:
            targets.setdefault(item["package"], []).append(item["filter"])
        if focused["swift_deferred"]:
            # focused_tests drops its whole Swift selection when it defers, dependents of a changed
            # package included, so no subset is known to hold the dependent closure: every Swift
            # package's every test target, as the everything plan runs them.
            targets = {pkg: swift_test_targets(root, pkg) for pkg in swift_packages(root)}
        web_python: list[str] = []
        named_swift, named_web, named_python = tests_naming(root, focused.get("docs", []))
        for pkg, names in named_swift.items():
            targets.setdefault(pkg, []).extend(names)
        p.swift({k: sorted(set(v)) for k, v in targets.items() if v}, focused["swift_deferred"] or "test targets that import a changed target")
        if webviews_source_changed(files) or any(f.startswith(focused_tests.WEB) for f in focused.get("unmapped", [])):
            p.web(None)
            web_python = web_workflow_python_tests(root)
        elif focused["web"] or named_web:
            p.web([f["path"] for f in focused["web"]] + named_web)
        lanes = python_lane_tests(root)
        lane_paths = [item["path"] for item in focused["python"]]
        if any(focused_tests.REGISTRY_FRAGMENT.fullmatch(f) for f in files):
            # A registry change moves tests between lanes or changes how they run: the whole Linux lane.
            lane_paths = None
        if lane_paths is not None:
            lane_paths += [t for t in web_python if lanes.get(t) == LINUX_PYTHON_LANE and t not in lane_paths]
            lane_paths += [t for t in named_python if t not in lane_paths]  # p.python lists off-lane ones as not run
        p.python(lane_paths)
        extra = extra_python(root, files)
        extra += [t for t in web_python + (lane_paths or []) if t not in lanes and t not in extra]
        for test in extra:
            p.not_run.append({"what": test, "why": UNREGISTERED_WHY})
        p.native([item["manifest"] for item in focused["native"]])
    return {"base": base, "head": head, "all": bool(reasons), "reasons": reasons, "files": files,
            "units": p.units, "not_run": p.not_run, "docs": focused.get("docs", [])}


def resolve(root: Path, ref: str) -> str:
    return git(root, "rev-parse", "--verify", f"{ref}^{{commit}}")


def refresh_base(root, ref: str) -> str:
    """Fetch REF (origin/feat-cmux-next) before this branch's own change is measured from where HEAD meets it: a clone's
    copy older than a base the branch merged counts that base's files as the branch's own. One shared fetch
    (scripts/cmux-next/push_range.py refresh_base, the pre-push gate's); a failed fetch is said on stderr."""
    import importlib.util
    push_range = Path(__file__).resolve().parents[1] / "cmux-next" / "push_range.py"
    spec = importlib.util.spec_from_file_location("cmux_next_push_range_fresh", push_range)
    module = sys.modules.get(spec.name)
    if module is None:
        module = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = module
        spec.loader.exec_module(module)
    note = module.refresh_base(Path(root), ref)
    if note:
        print(f"affected_tests: {note.lstrip('; ')}", file=sys.stderr)
    return note


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
    files = sorted(set(args.files)) if args.files is not None else None
    if not args.base:
        refresh_base(root, "origin/feat-cmux-next")
    try:
        base = resolve(root, args.base or git(root, "merge-base", head, "origin/feat-cmux-next"))
    except subprocess.CalledProcessError:
        # No merge base (or an unknown --base): nothing says what changed, so every suite runs.
        result = plan(root, head, head, files or [], args.shards, True)
        result["reasons"] = [f"no merge base with {args.base or 'origin/feat-cmux-next'}"]
        print(json.dumps(result, indent=2))
        return 0
    try:
        result = plan(root, base, head, files, args.shards, args.all)
    except subprocess.CalledProcessError:
        # --base resolves but shares no history with HEAD: the diff is unknown, so every suite runs.
        result = plan(root, head, head, files or [], args.shards, True)
        result["reasons"] = [f"no diff between {base[:12]} and {head[:12]}"]
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
