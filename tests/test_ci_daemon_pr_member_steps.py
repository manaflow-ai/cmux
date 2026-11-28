#!/usr/bin/env python3
"""The big members' cmux_next_ daemon tests on the pull request (ci/steps.toml cmux-next-acpmux, cmux-next-tui-core,
cmux-next-tui).

The post-merge `cmux_next_ daemon tests` gate (step cmux-next-daemon-tests) has `**` inputs, so a pull request does not
run it. These steps run its tests of one big member each, routed by that member's own files (one-directory globs:
`--pr-scope` routes a step only by those) and the fixture files its cmux_next_ tests read from outside it. This test
keeps that whole:

1. each step is a linux, `alone` step with named inputs only, and runs scripts/ci/cmux-next-member-tests.sh on its member;
2. every tracked file of the member, and of every fixture directory or file its cmux_next_ tests name outside it
   (include_str!/include_bytes! paths and CARGO_MANIFEST_DIR-relative paths), is matched by one of the step's inputs;
3. the member's targets (cmux-next-daemon-test-packages.sh MEMBER_DIR) are `-p MEMBER` and a part of the gate's;
4. cmux-next-idle-wakeups, the gate's idle daemon tests, is a land_gate step: it runs on a landing head whose change
   reaches the daemon's idle paths (cmux#47027's cmux-tui-core-only change among them), on a target of the gate's.

Run: python3 -I tests/test_ci_daemon_pr_member_steps.py
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
import unittest
from pathlib import Path, PurePosixPath

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
import ci_steps  # noqa: E402

# step -> (package, member directory under cmux-tui/)
STEPS = {
    "cmux-next-acpmux": ("acpmux", "crates/acpmux"),
    "cmux-next-tui-core": ("cmux-tui-core", "crates/cmux-tui-core"),
    "cmux-next-tui": ("cmux-tui", "crates/cmux-tui"),
}
RUNNER = "scripts/ci/cmux-next-member-tests.sh"
PACKAGES = "scripts/ci/cmux-next-daemon-test-packages.sh"
WORKSPACE_INPUTS = ("cmux-tui/Cargo.toml", "cmux-tui/Cargo.lock", "cmux-tui/rust-toolchain.toml")
SCRIPT_INPUTS = (RUNNER, PACKAGES, "scripts/ci/cmux-tui-test-target.sh", "tests/test_ci_daemon_pr_member_steps.py")
INCLUDE = re.compile(r'include_(?:str|bytes)!\(\s*"([^"]+)"\s*\)')
MANIFEST_REL = re.compile(r'env!\("CARGO_MANIFEST_DIR"\)\s*,\s*"/([^"]+)"')


def tracked(*paths: str) -> list[str]:
    out = subprocess.run(["git", "ls-files", "-z", "--", *paths], cwd=ROOT, check=True,
                         capture_output=True, text=True).stdout
    return [p for p in out.split("\0") if p]


def repo_rel(path: Path) -> str:
    return PurePosixPath(os.path.relpath(os.path.normpath(path), ROOT)).as_posix()


def fixtures(member_dir: str) -> set[str]:
    """Repository paths outside the member that its cmux_next_ test files read."""
    out: set[str] = set()
    for f in tracked(f"{member_dir}/*.rs"):
        text = (ROOT / f).read_text(encoding="utf-8", errors="replace")
        if "cmux_next_" not in text:
            continue
        refs = [ROOT / PurePosixPath(f).parent / r for r in INCLUDE.findall(text)]
        refs += [ROOT / member_dir / r for r in MANIFEST_REL.findall(text)]
        for ref in refs:
            rel = repo_rel(ref)
            if not rel.startswith(member_dir + "/") and not rel.startswith(".."):
                out.add(rel)
    return out


def targets(member_dir: str = "") -> list[str]:
    cmd = [str(ROOT / PACKAGES)] + ([member_dir] if member_dir else [])
    return subprocess.run(cmd, cwd=ROOT, check=True, capture_output=True, text=True).stdout.split()


def pairs(args: list[str]) -> set[str]:
    out, i = set(), 0
    while i < len(args):
        if args[i] in ("-p", "--test"):
            out.add(f"{args[i]} {args[i + 1]}")
            i += 2
        else:
            out.add(args[i])
            i += 1
    return out


class DaemonPrMemberSteps(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.steps = ci_steps.load().steps
        cls.gate = pairs(targets())

    def test_each_step_routes_on_the_pull_request_alone(self) -> None:
        for name, (_, member) in STEPS.items():
            step = self.steps[name]
            with self.subTest(step=name):
                self.assertEqual(step.job, "linux")
                self.assertTrue(step.alone, "a 10+ minute cargo build would raise the shared wave bound")
                self.assertTrue(step.pr_scope)
                self.assertEqual([g for g in step.inputs if not ci_steps.named_input(g)], [],
                                 "a `**` input would leave the step to the post-merge batch")
                self.assertIn(f"{RUNNER} {member}", step.run)
                self.assertEqual(set(step.needs), {"rust", "zig"})

    def test_every_file_of_the_member_and_its_fixtures_routes_it(self) -> None:
        for name, (_, member) in STEPS.items():
            step = self.steps[name]
            named = [ci_steps.glob_pattern(g) for g in step.inputs]
            member_dir = f"cmux-tui/{member}"
            found = fixtures(member_dir)
            files = [*tracked(member_dir, *sorted(found)), *WORKSPACE_INPUTS, *SCRIPT_INPUTS]
            with self.subTest(step=name):
                self.assertTrue(tracked(member_dir))
                missed = [f for f in files if not any(p.match(f) for p in named)]
                self.assertEqual(missed, [], f"add each file's directory as `DIR/*` to [step.{name}] inputs")

    def test_the_fixture_scan_finds_the_known_reads(self) -> None:
        self.assertIn("cmux-tui/persisted-formats/agent-host-record", fixtures("cmux-tui/crates/acpmux"))
        self.assertIn("cmux-tui/spec/sdk-schema.json", fixtures("cmux-tui/crates/cmux-tui-core"))

    def test_each_member_runs_its_part_of_the_gate(self) -> None:
        for name, (package, member) in STEPS.items():
            with self.subTest(step=name):
                mine = pairs(targets(member))
                self.assertEqual({a for a in mine if a.startswith("-p ")}, {f"-p {package}"})
                self.assertTrue(any(a == "--lib" or a.startswith("--test ") for a in mine))
                self.assertLessEqual(mine, self.gate)


IDLE_STEP = "cmux-next-idle-wakeups"
IDLE_FILE = "cmux-tui/crates/cmux-tui/tests/idle_wakeups.rs"
# cmux#47027's files: a cmux-tui-core-only change that broke the idle tests and merged with none of them run.
CULPRIT_47027 = [
    "cmux-tui/crates/cmux-tui-core/src/mux/presentation.rs",
    "cmux-tui/crates/cmux-tui-core/src/mux/presentation/git_heads.rs",
    "cmux-tui/crates/cmux-tui-core/src/server/cmd_workspaces.rs",
]


class IdleWakeupsLandGate(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.table = ci_steps.load()
        cls.step = cls.table.steps[IDLE_STEP]

    def test_it_is_a_blocking_land_gate_step(self) -> None:
        step = self.step
        self.assertEqual(step.job, "linux")
        self.assertTrue(step.land_gate and step.blocks and step.alone)
        self.assertEqual(set(step.needs), {"rust", "zig"})
        self.assertIn(f"{RUNNER} crates/cmux-tui it idle_wakeups::cmux_next_", step.run)

    def test_a_landing_head_that_reaches_the_daemon_runs_it(self) -> None:
        gates = lambda paths: ci_steps.nightly_gate_steps(self.table, paths, ["linux"])  # noqa: E731
        self.assertIn(IDLE_STEP, gates(CULPRIT_47027))
        self.assertIn(IDLE_STEP, gates([IDLE_FILE]))
        self.assertIn(IDLE_STEP, gates(["cmux-tui/Cargo.lock"]))
        self.assertNotIn(IDLE_STEP, gates(["docs/x.md"]))
        self.assertNotIn(IDLE_STEP, gates(["cmux-tui/crates/cmux-tui-core/README.md"]))
        self.assertNotIn(IDLE_STEP, gates(["cmux-tui/crates/acpmux/src/lib.rs"]))

    def test_it_runs_the_gates_own_idle_tests(self) -> None:
        self.assertIn("--test it", pairs(targets("crates/cmux-tui")))
        text = (ROOT / IDLE_FILE).read_text(encoding="utf-8")
        self.assertRegex(text, r"fn cmux_next_daemon_idle_has_no_periodic_wakeups\(")
        for script_input in (*WORKSPACE_INPUTS, *SCRIPT_INPUTS):
            self.assertIn(script_input, self.step.inputs)


if __name__ == "__main__":
    unittest.main()
