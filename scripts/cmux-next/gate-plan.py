#!/usr/bin/env python3
"""Print the smallest landing-gate steps file for a feat-cmux-next lane.

Agents wrote gate steps by hand and picked the heavy ones by habit: in the 5
days to 2026-10-18, 1,259 gate receipts spent 189 step-hours, mostly on the
Release compile (about 12 min, 78 runs), the full cmux-tui suite (about 70 min,
9 runs) and whole-package CmuxNext builds. This script picks the steps from the
change instead, with the same rules CI uses:

  CmuxNext Swift  scripts/ci/cmux_next_route.py (the SwiftPM target graph): only
                  the test targets the change reaches, as one cmux-ci
                  package-test-lane `suite` step (one build, one filter each);
                  more steps only when the filters pass cmux-ci's arg limits.
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
Commit first: the plan is for HEAD, and gate-run refuses a dirty tree. When it
prints `first:` (a cmux-ci step needs the SHA on origin), run that side push
before gate-run: a cmux-ci --ref step waits for a commit origin does not have.
"""

from __future__ import annotations

import argparse
import fnmatch
import json
import os
import re
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
# The cmux-ci controller's ci-step limits (hq build-fleet/cmd/controller/ci_step.go): at most
# ciStepMaxArgs args per step and ciStepMaxArgLen bytes per arg. A longer arg is refused with
# HTTP 400 before anything runs (a 1,275-suite list was one 26 KB arg on 2026-10-22).
CI_STEP_MAX_ARGS = 16
CI_STEP_MAX_ARG_LEN = 2048


def suite_args(names: list[str]) -> list[list[str]]:
    """The suite filters as package-test-lane `suite` steps the controller accepts: each step's
    args are "suite", the package dir and comma lists of at most CI_STEP_MAX_ARG_LEN bytes, at
    most CI_STEP_MAX_ARGS in all. Order is kept; a name is never split."""
    per_step = CI_STEP_MAX_ARGS - 2
    lists: list[str] = []
    for name in dict.fromkeys(names):
        if len(name) > CI_STEP_MAX_ARG_LEN:
            raise SystemExit(f"gate-plan: suite name longer than {CI_STEP_MAX_ARG_LEN} bytes: {name[:80]}...")
        if lists and len(lists[-1]) + 1 + len(name) <= CI_STEP_MAX_ARG_LEN:
            lists[-1] += "," + name
        else:
            lists.append(name)
    return [["suite", CMUXNEXT_DIR, *lists[i:i + per_step]] for i in range(0, len(lists), per_step)]


def suite_steps(names: list[str], head: str, lane: str) -> list[str]:
    """One cmux-ci step per suite_args() group; a second group gets its own idempotency key."""
    groups = suite_args(names)
    steps = []
    for index, group in enumerate(groups):
        key = f"{lane}-gate-{head[:12]}" if len(groups) == 1 else f"{lane}-gate{index}-{head[:12]}"
        steps.append(CMUX_CI + " " + shlex.join(["run", "--class", "light", "--script", "scripts/ci/package-test-lane.sh",
                                                 "--ref", head, "--key", key, *[f"--arg={a}" for a in group],
                                                 "--env", f"CMUX_CI_XCODE_APP={XCODE_APP}"]))
    return steps


def git(*args: str) -> str:
    return subprocess.run(["git", "-C", str(ROOT), *args], check=True, capture_output=True, text=True).stdout.strip()


# A test target with more test files than this runs only the suites the change names: a whole
# CmuxNextAppTests run (271 files) passed the 900 s per-filter limit of package-test-lane.sh.
BIG_TARGET_FILES = 40
DECLARED = re.compile(r"^\s*(?:(?:@\w+(?:\([^)\n]*\))?|public|package|internal|private|fileprivate|final|nonisolated|open|indirect)\s+)*"
                      r"(?:struct|class|enum|actor|protocol|extension)\s+([A-Z]\w+)", re.M)
TOP_TYPE = re.compile(r"^\s*(?:\S.*?[\s)])?(?:struct|class|enum|actor) +(\w+)")


def suites_in(text: str) -> set[str]:
    """Test types, nested ones too (a filter matches a nested suite's name): named *Test(s), or
    marked @Suite on their line or the line above. Helper types match neither."""
    found = set()
    previous = ""
    extension = None  # the top-level `extension X` block this line is in
    for line in text.splitlines():
        match = TOP_TYPE.match(line)
        if match and (match.group(1).endswith(("Test", "Tests")) or "@Suite" in line
                      or (previous.lstrip().startswith("@Suite") and not TOP_TYPE.match(previous))):
            found.add(match.group(1))
        top = re.match(r"(?:@\w+\s+)*extension\s+(\w+)", line)
        if top:
            extension = top.group(1)
        elif line[:1] not in ("", " ", "\t", "}", "/"):
            extension = None
        if extension and (re.search(r"@Test\b", line)
                          or (extension.endswith("Tests") and re.search(r"func test\w*\(", line))):
            # Tests of a suite declared in another file (extension ThemeFileSaveTests { @Test ... }).
            found.add(extension)
        previous = line
    return found


CAMEL = re.compile(r"[A-Z][a-z0-9]+|[A-Z]+(?![a-z])")


def suite_filters(graph: dict, target: str, changed: list[str], every: bool = False) -> tuple[list[str], str]:
    """Suites (test type names) of a big test target that the change names, and why.

    A test file is picked when it changed, when it uses a type a changed source declares,
    or when its name starts with the first two words of a changed source file's name
    (SidebarDocDrag.swift -> SidebarDocMoveToTopTests.swift). No pick: the whole target."""
    files = sorted(Path(ROOT, graph["targets"][target]["path"]).rglob("*.swift"))
    if len(files) <= BIG_TARGET_FILES:
        return [target], "whole target"
    if every:
        # A change every test reads (Package.swift, the graph): each suite is its own filter, under the limit.
        suites = sorted(set().union(*(suites_in(f.read_text(encoding="utf-8", errors="replace")) for f in files)))
        return suites, f"every suite ({len(suites)}), each its own filter"
    names: set[str] = set()
    prefixes: set[str] = set()
    for path in changed:
        if path.endswith(".swift") and (ROOT / path).is_file() and "/Tests/" not in path:
            names |= set(DECLARED.findall((ROOT / path).read_text(encoding="utf-8", errors="replace")))
            words = CAMEL.findall(Path(path).stem.split("+")[0])
            if len(words) >= 2:
                prefixes.add("".join(words[:2]))
    picked = []
    for file in files:
        rel = file.relative_to(ROOT).as_posix()
        text = file.read_text(encoding="utf-8", errors="replace")
        if rel in changed or file.name.startswith(tuple(prefixes)) or (
                names and re.search(r"\b(" + "|".join(map(re.escape, sorted(names))) + r")\b", text)):
            picked.append(text)
    # Only suites: a filter that runs no test fails the step, so helper types are never filters.
    suites = sorted(set().union(*(suites_in(text) for text in picked)))
    if not suites:
        return [target], f"whole target: no test file of its {len(files)} names the change (may pass the 900 s limit)"
    total = len(set().union(*(suites_in(f.read_text(encoding="utf-8", errors="replace")) for f in files)))
    return suites, (f"{len(picked)} of {len(files)} test files name the change: {len(suites)} of {total} suites;"
                    " the other suites run in the feat-cmux-next push's CI")


def pushed(head: str) -> bool:
    """HEAD is in the lane's upstream, its gate side branch or feat-cmux-next (local refs; no network)."""
    refs = ["origin/feat-cmux-next", f"origin/cmux-next-gate-{head[:12]}"]
    upstream = subprocess.run(["git", "-C", str(ROOT), "rev-parse", "--abbrev-ref", "@{upstream}"],
                              capture_output=True, text=True).stdout.strip()
    if upstream:
        refs.append(upstream)
    # A ref that does not exist (no gate side branch yet) is not an error.
    return any(subprocess.run(["git", "-C", str(ROOT), "merge-base", "--is-ancestor", head, ref],
                              stderr=subprocess.DEVNULL).returncode == 0
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
                                                 "--ref", head, "--os", "linux", "--arg", "all",
                                                 "--key", f"{args.lane}-rust-{head[:12]}"]))
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
            # The controller allows no regex characters in an arg: plain target or suite names, matched by substring.
            names: list[str] = []
            for target in targets:
                picked, why = suite_filters(graph, target, changed, every=result.full)
                names += picked
                notes.append(f"#   {target}: {why}")
            # One step while the filters fit the controller's arg limits; more steps (each its own build) past them.
            suite_group = suite_steps(names, head, args.lane)
            steps += suite_group
            if len(suite_group) > 1:
                notes.append(f"#   CmuxNext suites: {len(dict.fromkeys(names))} filters in {len(suite_group)} steps"
                             f" (cmux-ci allows {CI_STEP_MAX_ARGS} args of {CI_STEP_MAX_ARG_LEN} bytes per step)")
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
                                 "--ref", head, "--key", f"{args.lane}-rc-{head[:12]}"]))
        notes.append("#   Release compile: the route's native tier runs and a changed file is outside CmuxNext Sources/ and Tests/")
    else:
        left_out.append("Release compile: the change reaches no native tier")

    if any(fnmatch.fnmatch(p, pattern) for p in changed for pattern in route_mod.BUNDLE_INPUTS):
        steps.append(shlex.join([str(hq / "scripts" / "freestyle-run.sh"), "--label", args.lane, "--snapshot", "webviews", "--sync", ".",
                                 "--", "./scripts/cmux-next/build-web-bundles.sh", "--force"]))
        notes.append("#   web bundles: a bundle input changed (safe-push needs this build in the receipt)")

    side_push = None
    if any("--ref" in s for s in steps) and not pushed(head):
        # A cmux-ci step checks out the SHA from origin: push it to a side branch first. A comment, so
        # gate-run never runs it (as a plain line it would run after the parallel group, too late).
        side_push = (f"SAFE_PUSH_NEW_BRANCH_BASE=feat-cmux-next {shlex.quote(str(nx_worker(hq, 'safe-push.sh')))}"
                     f" cmux-next-gate-{head[:12]}")
        notes.append(f"#   push first: {side_push}")
    for test in sorted(p for p in changed if p.startswith("tests/") and Path(p).name.startswith("test_") and p.endswith(".py")
                       and (ROOT / p).is_file()):
        after.append(f"python3 {shlex.quote(test)}")
        notes.append(f"#   repo test changed: {test} (a short local check)")
    # The god-file check of the changed files only, against the base: the whole scan took 22 min on the
    # laptop (2026-10-19) and fails on other lanes' files whenever the base is red.
    code = [p for p in changed if p.endswith((".swift", ".rs")) and (ROOT / p).is_file()]
    if code:
        after.append(shlex.join(["bash", "scripts/cmux-next/check-no-godfiles.sh", "--base", base,
                                 *[a for p in code for a in ("--file", p)]]))
    if not steps and not after:
        # gate-run refuses a steps file without steps. A docs-only push needs no receipt; anything else
        # still needs a compile step that fits it (safe-push names it).
        after.append(shlex.join(["git", "diff", "--check", base, "HEAD"]))
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
        if side_push:
            print(f"first: {side_push}", file=sys.stderr)
        print(f"next: {nx_worker(hq, 'gate-run.sh')} --head {head} --out /tmp/gates/{args.lane}-{head[:8]}.json"
              f" --steps {args.out}", file=sys.stderr)
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
