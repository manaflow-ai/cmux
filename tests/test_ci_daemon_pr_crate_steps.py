#!/usr/bin/env python3
"""The cmux_next_ daemon tests a pull request runs itself (ci/steps.toml `cmux-next-daemon-crates`).

The post-merge `cmux_next_ daemon tests` gate (step cmux-next-daemon-tests, cmux-tui-artifacts.yml) holds the
feat-cmux-next acpmux channel; its inputs are whole-directory globs, so a pull request does not run it. The step
`cmux-next-daemon-crates` runs that gate's tests of the small members on the pull request, routed by one-directory
globs (`--pr-scope` routes a step only by those). This test keeps those globs whole and the step's targets right:

1. every tracked file of each member the step tests, and of each member it depends on by path (transitively), is
   matched by one of the step's named inputs, so a pull request that changes any of them runs the step;
2. every source file of those members that names a cmux_next_ test is in a target the step's cargo runs;
3. every member the gate tests is either in the step or listed below, with why its tests stay post-merge.

Run: python3 -I tests/test_ci_daemon_pr_crate_steps.py
"""

from __future__ import annotations

import re
import subprocess
import sys
import tomllib
import unittest
from pathlib import Path, PurePosixPath

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
import ci_steps  # noqa: E402

STEP = "cmux-next-daemon-crates"
# Gate members whose cmux_next_ tests the step does not run, and why. A member that gains a cmux_next_ test is
# added to the step (when its compile is small) or here.
POST_MERGE = {
    "acpmux": "its lib and test targets compile most of the workspace; step cmux-next-acpmux (its own files)",
    "cmux-tui-core": "its lib tests compile ghostty-vt with Zig and most of the workspace; step cmux-next-tui-core",
    "cmux-tui": "its test targets build the daemon binary over cmux-tui-core; step cmux-next-tui",
    "cmux-config": "its published_keys test is the settings-published-keys step's (named settings files)",
    "cmux-vmd": "no test name of it matches cmux_next_ (the filter runs none of its tests)",
}
# Files outside the members that can break their build: the workspace manifest, its lock and the toolchain.
WORKSPACE_INPUTS = ("cmux-tui/Cargo.toml", "cmux-tui/Cargo.lock", "cmux-tui/rust-toolchain.toml")
TEST_NAME = re.compile(r"\b(?:fn|mod) [a-z0-9_]*cmux_next_")


def tracked(*paths: str) -> list[str]:
    out = subprocess.run(["git", "ls-files", "-z", "--", *paths], cwd=ROOT, check=True,
                         capture_output=True, text=True).stdout
    return [p for p in out.split("\0") if p]


def members() -> dict[str, str]:
    """Workspace member name -> its directory (repository-relative)."""
    out: dict[str, str] = {}
    for manifest in tracked("cmux-tui/*Cargo.toml"):
        try:
            package = tomllib.loads((ROOT / manifest).read_text(encoding="utf-8")).get("package")
        except tomllib.TOMLDecodeError:
            continue
        if package and isinstance(package.get("name"), str):
            out[package["name"]] = str(PurePosixPath(manifest).parent)
    return out


def path_deps(crate_dir: str, workspace_paths: dict[str, str]) -> set[str]:
    manifest = tomllib.loads((ROOT / crate_dir / "Cargo.toml").read_text(encoding="utf-8"))
    tables = [manifest.get(k, {}) for k in ("dependencies", "dev-dependencies", "build-dependencies")]
    for target in manifest.get("target", {}).values():
        tables += [target.get(k, {}) for k in ("dependencies", "dev-dependencies", "build-dependencies")]
    out: set[str] = set()
    for table in tables:
        for name, spec in table.items():
            if not isinstance(spec, dict):
                continue
            if isinstance(spec.get("path"), str):
                out.add(str(PurePosixPath(*(Path(crate_dir) / spec["path"]).resolve().relative_to(ROOT).parts)))
            elif spec.get("workspace") and name in workspace_paths:
                out.add(workspace_paths[name])
    return out


def closure(crate_dirs: set[str]) -> set[str]:
    ws = tomllib.loads((ROOT / "cmux-tui/Cargo.toml").read_text(encoding="utf-8"))["workspace"]["dependencies"]
    workspace_paths = {n: f"cmux-tui/{s['path']}" for n, s in ws.items() if isinstance(s, dict) and "path" in s}
    seen: set[str] = set()
    todo = sorted(crate_dirs)
    while todo:
        d = todo.pop()
        if d not in seen:
            seen.add(d)
            todo += sorted(path_deps(d, workspace_paths) - seen)
    return seen


def step_cargo_runs(step: ci_steps.Step) -> list[tuple[str, set[str]]]:
    """(package, targets) for each `cargo test ... -p NAME TARGETS cmux_next_` line of the step."""
    runs = []
    for line in step.run.splitlines():
        if "cargo test" not in line:
            continue
        args = line.split()
        pkg = args[args.index("-p") + 1]
        targets = {f"--test {args[i + 1]}" for i, a in enumerate(args) if a == "--test"}
        targets |= {a for a in args if a in ("--lib", "--bins")}
        runs.append((pkg, targets))
    return runs


def gate_members(by_dir: dict[str, str]) -> set[str]:
    """The members cmux-next-daemon-test-packages.sh names: those with a .rs file that says cmux_next_."""
    out = subprocess.run(["git", "grep", "-l", "cmux_next_", "--", "cmux-tui/*.rs"], cwd=ROOT,
                         capture_output=True, text=True).stdout.split()
    names = set()
    for f in out:
        d = PurePosixPath(f).parent
        while str(d) not in by_dir and str(d) != ".":
            d = d.parent
        if str(d) in by_dir:
            names.add(by_dir[str(d)])
    return names


class DaemonPrCrateStep(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.step = ci_steps.load().steps[STEP]
        cls.members = members()
        cls.runs = step_cargo_runs(cls.step)
        cls.named = [ci_steps.glob_pattern(g) for g in cls.step.inputs if ci_steps.named_input(g)]

    def test_the_step_routes_on_the_pull_request(self) -> None:
        self.assertEqual(self.step.job, "linux")
        self.assertTrue(self.step.pr_scope)
        self.assertEqual([g for g in self.step.inputs if not ci_steps.named_input(g)], [],
                         "a `**` input would leave the step to the post-merge batch")
        self.assertTrue(self.runs, "the step runs cargo test")

    def test_every_file_of_its_members_and_their_path_deps_routes_it(self) -> None:
        dirs = closure({self.members[p] for p, _ in self.runs})
        missed = [f for f in [*tracked(*sorted(dirs)), *WORKSPACE_INPUTS]
                  if not any(p.match(f) for p in self.named)]
        self.assertEqual(missed, [], f"add each file's directory as `DIR/*` to [step.{STEP}] inputs")

    def test_every_cmux_next_test_of_its_members_is_in_a_target_it_runs(self) -> None:
        by_pkg: dict[str, set[str]] = {}
        for pkg, targets in self.runs:
            by_pkg.setdefault(pkg, set()).update(targets)
        for pkg, targets in by_pkg.items():
            crate = self.members[pkg]
            for f in tracked(f"{crate}/*.rs"):
                if not TEST_NAME.search((ROOT / f).read_text(encoding="utf-8", errors="replace")):
                    continue
                rel = PurePosixPath(f).relative_to(crate)
                with self.subTest(file=f):
                    if rel.parts[0] == "src":
                        self.assertIn("--lib", targets)
                    else:
                        self.assertEqual(rel.parts[0], "tests")
                        self.assertIn(f"--test {PurePosixPath(rel.parts[1]).stem}", targets)

    def test_every_gate_member_is_in_the_step_or_named_post_merge(self) -> None:
        by_dir = {d: n for n, d in self.members.items()}
        stepped = {p for p, _ in self.runs}
        self.assertEqual(gate_members(by_dir) - stepped - set(POST_MERGE), set(),
                         f"a member the gate tests: add it to [step.{STEP}] or to POST_MERGE with why")
        self.assertEqual(stepped & set(POST_MERGE), set())


if __name__ == "__main__":
    unittest.main()
