#!/usr/bin/env python3
"""Print the smallest landing-gate steps file for a feat-cmux-next lane.

Agents wrote gate steps by hand and picked the heavy ones by habit: in the 5
days to 2026-10-18, 1,259 gate receipts spent 189 step-hours, mostly on the
Release compile (about 12 min, 78 runs), the full cmux-tui suite (about 70 min,
9 runs) and whole-package CmuxNext builds. This script picks the steps from the
change instead, with the same rules CI uses:

  CmuxNext Swift  scripts/ci/cmux_next_route.py (the SwiftPM target graph): only
                  the test targets the change reaches, as one cmux-ci
                  package-test-lane `suite` step (one build, one filter each).
  Release compile only when the route's native tier runs and the change is not
                  a small Sources-only diff (CI's canary rule). The push to
                  feat-cmux-next still runs every tier as the backstop.
  Rust, webviews, other Swift packages
                  $HQ_ROOT/scripts/cmux-next-affected.py selects the units and
                  $HQ_ROOT/scripts/cmux-next-receipts.py drops the ones with a
                  green receipt for the same inputs; its `plan` lines are the
                  steps (rbx, Freestyle, cmux-ci).
  Web bundles     the verified Freestyle build when a bundle input changed.

Every chosen step and every heavy step it leaves out is printed with its reason.
It runs nothing remote: it reads git, the target graph and the receipt store.

Usage: scripts/cmux-next/gate-plan.py [--base REF] [--lane NAME] [--out FILE]
Then:  $HQ_ROOT/.cmux-scratch/nx-worker/gate-run.sh --head $(git rev-parse HEAD) \\
         --out /tmp/gates/<lane>-<sha8>.json --steps FILE
Commit first: the plan is for HEAD, and gate-run refuses a dirty tree.
"""

from __future__ import annotations

import argparse
import fnmatch
import json
import os
import shlex
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
import cmux_next_route as route_mod  # noqa: E402

CMUX_CI = "~/.local/bin/cmux-ci"  # unquoted in the step line, so bash expands ~
XCODE_APP = "/Applications/Xcode_26.6.app"
CMUXNEXT_DIR = "Packages/macOS/CmuxNext"
RUST_WORKSPACE_FILES = ("cmux-tui/Cargo.toml", "cmux-tui/Cargo.lock", "cmux-tui/rust-toolchain.toml")


def git(*args: str) -> str:
    return subprocess.run(["git", "-C", str(ROOT), *args], check=True, capture_output=True, text=True).stdout.strip()


def pushed(head: str) -> bool:
    """HEAD is in the lane's upstream or in feat-cmux-next (local refs; no network)."""
    refs = ["origin/feat-cmux-next"]
    upstream = subprocess.run(["git", "-C", str(ROOT), "rev-parse", "--abbrev-ref", "@{upstream}"],
                              capture_output=True, text=True).stdout.strip()
    if upstream:
        refs.append(upstream)
    return any(subprocess.run(["git", "-C", str(ROOT), "merge-base", "--is-ancestor", head, ref]).returncode == 0
               for ref in refs)


def hq_root() -> Path:
    if os.environ.get("HQ_ROOT"):
        return Path(os.environ["HQ_ROOT"])
    # A task worktree lives at $HQ_ROOT/worktrees/<slug>.
    for parent in ROOT.parents:
        if (parent / "scripts" / "cmux-next-receipts.py").is_file():
            return parent
    raise SystemExit("gate-plan: set HQ_ROOT (the hq checkout with scripts/cmux-next-receipts.py)")


def nx_worker(hq: Path, name: str) -> Path:
    """A lane tool in .cmux-scratch/nx-worker/, which exists only in the primary hq checkout."""
    for base in (hq, *ROOT.parents):
        if (base / ".cmux-scratch" / "nx-worker" / name).is_file():
            return base / ".cmux-scratch" / "nx-worker" / name
    return hq / ".cmux-scratch" / "nx-worker" / name


def hq_tool(hq: Path, name: str, *args: str) -> subprocess.CompletedProcess:
    return subprocess.run([sys.executable, "-I", str(hq / "scripts" / name), *args],
                          cwd=ROOT, capture_output=True, text=True)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--base", default="origin/feat-cmux-next", help="branch the lane lands on (default: %(default)s)")
    parser.add_argument("--lane", default=ROOT.name, help="lane label for rbx and Freestyle (default: worktree name)")
    parser.add_argument("--out", help="write the steps file here (default: stdout)")
    args = parser.parse_args(argv)

    if git("status", "--porcelain", "--untracked-files=no"):
        print("gate-plan: tracked changes are not committed; the plan covers HEAD only", file=sys.stderr)
    head = git("rev-parse", "HEAD")
    base = git("merge-base", args.base, "HEAD")
    changed = [p for p in git("diff", "--name-only", "--no-renames", base, "HEAD").splitlines() if p]
    if not changed:
        raise SystemExit(f"gate-plan: HEAD has no change against {args.base}")

    hq = hq_root()
    for tool in ("scripts/cmux-next-affected.py", "scripts/cmux-next-receipts.py"):
        stale = subprocess.run(["git", "-C", str(hq), "diff", "--quiet", "HEAD", "origin/main", "--", tool]).returncode
        if stale == 1:
            print(f"gate-plan: {hq}/{tool} differs from hq origin/main (stale checkout?); set HQ_ROOT to a current hq"
                  " checkout if it fails", file=sys.stderr)
    steps: list[str] = []      # parallel members, each run as "& <step>"
    after: list[str] = []      # plain lines, run alone after the group
    notes: list[str] = [f"# gate plan for {head} ({len(changed)} files against {args.base} {base[:12]})"]
    left_out: list[str] = []

    result = route_mod.route(ROOT, "pull_request", changed, set())
    for reason in dict.fromkeys(result.reasons):
        notes.append(f"#   route: {reason}")

    # Units for Rust, webviews and the other Swift packages (CmuxNext goes by test target below).
    with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as handle:
        handle.write("\n".join(changed) + "\n")
        files = handle.name
    affected = hq_tool(hq, "cmux-next-affected.py", "--root", str(ROOT), "--files", files, "--json")
    os.unlink(files)
    if affected.returncode != 0:
        raise SystemExit(f"gate-plan: cmux-next-affected.py failed:\n{affected.stderr}")
    plan = json.loads(affected.stdout)
    packages = [p["name"] for p in plan["swift"]["packages"]]
    other_packages = [name for name in packages if name != "CmuxNext"]
    crates = plan["rust"]["crates"]
    web = plan["webviews"]
    unit_args: list[str] = []
    for name in other_packages:
        unit_args += ["--package", name]
    rust_wide = plan["rust"]["workspace_wide"] or any(p in RUST_WORKSPACE_FILES or p.startswith("cmux-tui/spec/") for p in changed)
    for crate in [] if rust_wide else crates:  # the whole-workspace check below covers every crate
        unit_args += ["--crate", crate]
    for test_file in web["tests"]:
        unit_args += ["--webview", test_file]
    if web["widen_to_full_suite"]:
        notes.append("#   webviews: " + ", ".join(web["broad"]) + " reach every test file: run the full suite once at"
                     " handoff with scripts/ci/run-webviews-tests.sh on Freestyle (not in this gate)")

    if unit_args:
        receipts = hq_tool(hq, "cmux-next-receipts.py", "plan", "--root", str(ROOT), *unit_args)
        if receipts.returncode != 0:
            raise SystemExit(f"gate-plan: cmux-next-receipts.py plan failed:\n{receipts.stderr}")
        for line in receipts.stderr.splitlines():
            if line.startswith("# skip"):
                notes.append(f"#   green receipt, skipped: {line[len('# skip '):]}")
        for line in receipts.stdout.splitlines():
            if not line or line.startswith("#"):
                continue
            # The side-branch push is written below, with the primary checkout's safe-push.sh.
            if not line.startswith("SAFE_PUSH_NEW_BRANCH_BASE="):
                steps.append(line)
        if crates and not rust_wide and not any("cargo test" in s for s in steps):
            # Every crate is green, but safe-push wants a Rust compile step for a push with Rust files.
            steps.append(shlex.join([str(hq / "build-fleet" / "rust-builder" / "rbx"), "--lane", args.lane, "--", "cargo", "check", "--locked", "--all-targets",
                                     *[a for c in crates for a in ("-p", c)]]))
            notes.append("#   every crate has a green receipt: one cargo check stands in for safe-push's compile rule")

    if rust_wide:
        steps.append(CMUX_CI + " " + shlex.join(["run", "--class", "isolated", "--script", "scripts/ci/cmux-tui-rust-check.sh",
                                                 "--ref", head, "--key", f"{args.lane}-rust-{head[:12]}"]))
        notes.append("#   Rust workspace file or spec changed: the whole-workspace check (bindings and SDK tests too)")
    else:
        left_out.append("full cmux-tui suite (verify-cmux-tui-hosted.sh --full, cmux-tui-rust-check.sh): no Cargo.toml,"
                        " Cargo.lock, toolchain or spec change; the affected crates and their dependents cover it")

    # CmuxNext: the test targets the route reaches, one build, one filter each.
    graph = route_mod.load_graph(ROOT)
    every_test = sorted(n for n, t in graph["targets"].items() if t["kind"] == "test")
    targets: list[str] = []
    if "CmuxNext" in packages or result.tests or result.full or result.swift:
        if result.full or (result.swift and not result.tests):
            # CI's swift tier with an empty filter runs every target (a swift job script changed).
            targets = every_test
            notes.append("#   CmuxNext: the route selects every test target")
        else:
            targets = sorted(result.tests)
        if targets:
            # The controller allows no regex characters in an arg; a target name matches its own tests by substring.
            filters = ",".join(targets)
            steps.append(CMUX_CI + " " + shlex.join(["run", "--class", "light", "--script", "scripts/ci/package-test-lane.sh",
                                     "--ref", head, "--key", f"{args.lane}-gate-{head[:12]}", "--arg=suite",
                                     f"--arg={CMUXNEXT_DIR}", f"--arg={filters}", "--env", f"CMUX_CI_XCODE_APP={XCODE_APP}"]))
            notes.append(f"#   CmuxNext test targets: {' '.join(targets)}")

    if result.daemon:
        left_out.append("live-daemon suites with the same-tree cmux-tui (CI's daemon tier): the feat-cmux-next push runs"
                        " them; the crates above cover the Rust side")
    # A Release build compiles no test target, so CmuxNext Tests/ files do not change its result, and the
    # suite step compiles every target its tests depend on. A changed target outside that closure keeps Release.
    covered = route_mod.closure(graph, set(targets)) if targets else set()
    changed_targets = {route_mod.owning_target(graph, p) for p in changed if p.startswith(CMUXNEXT_DIR + "/")} - {None}
    release_neutral = not (changed_targets - covered) and all(route_mod.canary_swift_path(p) or (p.startswith(CMUXNEXT_DIR + "/Tests/") and p.endswith(".swift"))
                          for p in changed)
    # Files no app build reads: CI scripts, repo tests, docs and web-only sources (the route's fast classes).
    native_inputs = [p for p in changed if not (p.startswith(("tests/", "docs/")) or route_mod.ci_only(p) or route_mod.web_fast(p))
                     or p in route_mod.CI_SELF]
    if result.native and not result.full and not native_inputs:
        left_out.append("Release compile: only CI scripts, repo tests, docs or web sources changed")
    elif result.native and not result.full and release_neutral:
        left_out.append("Release compile: only CmuxNext Sources/ and Tests/ Swift files changed; the suite step"
                        " compiles them and the feat-cmux-next push runs Release")
    elif result.native:
        steps.append(CMUX_CI + " " + shlex.join(["run", "--class", "isolated", "--script", "scripts/cmux-next/check-release-compile.sh",
                                 "--ref", head, "--key", f"{args.lane}-rc-{head[:12]}", "--arg=.build/release-compile"]))
        notes.append("#   Release compile: the route's native tier runs and a changed file is outside CmuxNext Sources/ and Tests/")
    else:
        left_out.append("Release compile: the change reaches no native tier")

    if any(fnmatch.fnmatch(p, pattern) for p in changed for pattern in route_mod.BUNDLE_INPUTS):
        steps.append(shlex.join([str(hq / "scripts" / "freestyle-run.sh"), "--label", args.lane, "--snapshot", "webviews", "--sync", ".",
                                 "--", "./scripts/cmux-next/build-web-bundles.sh", "--force"]))
        notes.append("#   web bundles: a bundle input changed (safe-push needs this build in the receipt)")

    if any("--ref" in s for s in steps) and not pushed(head):
        # A cmux-ci step checks out the SHA from origin: push it to a side branch first.
        notes.append(f"SAFE_PUSH_NEW_BRANCH_BASE=feat-cmux-next {shlex.quote(str(nx_worker(hq, 'safe-push.sh')))}"
                     f" cmux-next-gate-{head[:12]}")
    for test in sorted(p for p in changed if p.startswith("tests/") and Path(p).name.startswith("test_") and p.endswith(".py")
                       and (ROOT / p).is_file()):
        after.append(f"python3 {shlex.quote(test)}")
        notes.append(f"#   repo test changed: {test} (a short local check)")
    after.append("bash scripts/cmux-next/check-no-godfiles.sh")
    # A syntax check of the changed scripts (also the compile step safe-push wants when nothing else runs).
    for path in reversed(changed):
        if (ROOT / path).is_file() and path.endswith(".py"):
            after.insert(0, f"python3 -m py_compile {shlex.quote(path)}")
        elif (ROOT / path).is_file() and path.endswith(".sh"):
            after.insert(0, f"bash -n {shlex.quote(path)}")
    if not steps:
        notes.append("#   no build or test unit: the change reaches only the Linux checks (CI covers them)")

    lines = notes + [f"# not selected: {item}" for item in left_out] + [""] + [f"& {s}" for s in steps] + after
    text = "\n".join(lines) + "\n"
    if args.out:
        Path(args.out).write_text(text, encoding="utf-8")
        print(f"wrote {args.out}: {len(steps)} parallel steps + {len(after)} after", file=sys.stderr)
        print(f"next: {nx_worker(hq, 'gate-run.sh')} --head {head} --out /tmp/gates/{args.lane}-{head[:8]}.json"
              f" --steps {args.out}", file=sys.stderr)
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
