#!/usr/bin/env python3
"""scripts/ci/warnings_policy.py: warnings never fail a pull request's compile (Leo, 2026-11-19), and every
other run keeps them errors.

The detector half (WorkflowsRouteWarningsThroughThePolicy) reads every pull request workflow: a command there
that turns warnings into errors (`-D warnings`, `-warnings-as-errors`, `--deny-warnings`, `--max-warnings`)
runs through warnings_policy.py, and the workflow sets CI_WARNINGS for pull requests only. A new
`cargo clippy -- -D warnings` step in a pull request workflow is red here, not on the first PR it fails.
"""
from __future__ import annotations

import importlib.util
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
POLICY = ROOT / "scripts/ci/warnings_policy.py"
spec = importlib.util.spec_from_file_location("warnings_policy", POLICY)
policy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(policy)

SOFT_ENV_LINE = "CI_WARNINGS: ${{ github.event_name == 'pull_request' && 'soft' || 'deny' }}"
DENY_FLAG = re.compile(r"(?<![\w-])(?:-D ?warnings|-Dwarnings|-warnings-as-errors|--deny-warnings|--max-warnings)\b")
# Pull request workflows whose warnings-as-errors flags are in a script the workflow calls, which routes them
# through the policy itself (the test below checks the script), or whose flag is not a compile's.
SCRIPTS = {
    ".github/scripts/cmux-tui-clippy-changed.py": "cmux-tui-spec.yml's clippy job",
    ".github/scripts/rust-workspaces.py": "rust-workspaces.yml",
}


class Args(unittest.TestCase):
    def test_soft_drops_each_spelling(self):
        self.assertEqual(policy.soft_args(["cargo", "clippy", "--all-targets", "--", "-D", "warnings"]),
                         ["cargo", "clippy", "--all-targets", "--"])
        self.assertEqual(policy.soft_args(["cargo", "clippy", "--", "-Dwarnings", "-D", "clippy::expect_used"]),
                         ["cargo", "clippy", "--", "-D", "clippy::expect_used"])
        self.assertEqual(policy.soft_args(["swift", "test", "-Xswiftc", "-warnings-as-errors", "--parallel"]),
                         ["swift", "test", "--parallel"])
        self.assertEqual(policy.soft_args(["oxlint", ".", "--deny-warnings"]), ["oxlint", "."])
        self.assertEqual(policy.soft_args(["eslint", ".", "--max-warnings", "0", "--fix"]), ["eslint", ".", "--fix"])
        self.assertEqual(policy.soft_args(["eslint", ".", "--max-warnings=0"]), ["eslint", "."])

    def test_explicit_lint_denies_stay(self):
        argv = ["cargo", "clippy", "--", "-D", "clippy::indexing_slicing", "-W", "warnings", "-D", "unsafe_code"]
        self.assertEqual(policy.soft_args(argv), argv)

    def test_soft_env_strips_rust_flag_envs(self):
        env = policy.soft_env({"RUSTDOCFLAGS": "-D warnings", "RUSTFLAGS": "-C embed-bitcode=no -Dwarnings",
                               "CARGO_ENCODED_RUSTFLAGS": "-D\x1fwarnings\x1f-Ctarget-cpu=native", "PATH": "/bin"})
        self.assertEqual(env["RUSTDOCFLAGS"], "")
        self.assertEqual(env["RUSTFLAGS"], "-C embed-bitcode=no")
        self.assertEqual(env["CARGO_ENCODED_RUSTFLAGS"], "-Ctarget-cpu=native")
        self.assertEqual(env["PATH"], "/bin")

    def test_mode_is_deny_unless_soft(self):
        self.assertEqual(policy.mode({}), "deny")
        self.assertEqual(policy.mode({"CI_WARNINGS": "deny"}), "deny")
        self.assertEqual(policy.mode({"CI_WARNINGS": "anything"}), "deny")
        self.assertEqual(policy.mode({"CI_WARNINGS": "soft"}), "soft")

    def test_wrap_only_when_soft(self):
        command = ["cargo", "clippy", "--", "-D", "warnings"]
        self.assertEqual(policy.wrap(command, {}), command)
        wrapped = policy.wrap(command, {"CI_WARNINGS": "soft"})
        self.assertEqual(wrapped[2:4], ["run", "--"])
        self.assertEqual(wrapped[4:], command)


RUSTC = """\
   Compiling demo v0.1.0 (/w/demo)
warning: unused variable: `x`
 --> src/lib.rs:2:9
  |
2 |     let x = 1;
  |         ^ help: if this is intentional, prefix it with an underscore: `_x`
  |
  = note: `#[warn(unused_variables)]` on by default

warning: `demo` (lib) generated 1 warning
error[E0308]: mismatched types
 --> src/lib.rs:3:5

Sources/App/A.swift:4:9: warning: initialization of immutable value 'y' was never used
"""


class Warnings(unittest.TestCase):
    def test_finds_diagnostics_not_tallies(self):
        found = policy.warnings_in(RUSTC.splitlines(keepends=True))
        self.assertEqual(len(found), 2, found)
        self.assertTrue(found[0].startswith("warning: unused variable: `x`"))
        self.assertIn("--> src/lib.rs:2:9", found[0])
        self.assertIn("A.swift:4:9: warning: initialization", found[1])


class Run(unittest.TestCase):
    """The policy around a fake compiler that prints a warning and records its argv."""

    def run_policy(self, mode: str, exit_code: int = 0):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            fake = tmp / "fakecc"
            fake.write_text("#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$ARGV_OUT\"\nprintf '%s' \"$RUSTDOCFLAGS\" > "
                            "\"$ARGV_OUT.env\"\necho 'warning: unused import: `std::fmt`' >&2\n"
                            "echo ' --> src/a.rs:1:5' >&2\necho >&2\necho ok\nexit " + str(exit_code) + "\n")
            fake.chmod(0o755)
            summary = tmp / "summary.md"
            env = {**os.environ, "CI_WARNINGS": mode, "ARGV_OUT": str(tmp / "argv"), "RUNNER_TEMP": str(tmp),
                   "GITHUB_STEP_SUMMARY": str(summary), "RUSTDOCFLAGS": "-D warnings"}
            env.pop("CI_WARNINGS_LOG", None)
            done = subprocess.run([sys.executable, str(POLICY), "run", "--", str(fake), "clippy", "--", "-D",
                                   "warnings"], env=env, capture_output=True, text=True, stdin=subprocess.DEVNULL)
            argv = (tmp / "argv").read_text().split()
            flags = (tmp / "argv.env").read_text()
            kept = (tmp / "ci-warnings.log").read_text() if (tmp / "ci-warnings.log").exists() else ""
            return done, argv, flags, kept, summary.read_text() if summary.exists() else ""

    def test_deny_runs_the_command_as_written(self):
        done, argv, flags, kept, summary = self.run_policy("deny")
        self.assertEqual(argv, ["clippy", "--", "-D", "warnings"])
        self.assertEqual(flags, "-D warnings")
        self.assertEqual(kept, "")
        self.assertNotIn("CI_OOPS=", done.stdout)

    def test_soft_drops_the_flags_and_keeps_the_warnings(self):
        done, argv, flags, kept, summary = self.run_policy("soft")
        self.assertEqual(done.returncode, 0)
        self.assertEqual(argv, ["clippy", "--"])
        self.assertEqual(flags, "")
        self.assertIn("ok", done.stdout)
        self.assertIn("warning: unused import", done.stderr)
        self.assertIn("::warning title=warnings (soft)::1 warning(s)", done.stdout)
        line = next(line for line in done.stdout.splitlines() if line.startswith("CI_OOPS="))
        verdict = json.loads(line[len("CI_OOPS="):])
        self.assertEqual((verdict["class"], verdict["rule"], verdict["outcome"], verdict["count"]),
                         ("soft", "soft.warnings_as_errors", "soft_failed", 1))
        self.assertIn("unused import", kept)
        self.assertIn("1 warning(s), soft", summary)

    def test_soft_keeps_a_real_error_red(self):
        done, *_ = self.run_policy("soft", exit_code=101)
        self.assertEqual(done.returncode, 101)


def commands(text: str):
    """(line number, command) for each shell command line of a workflow, `\\` continuations joined."""
    lines = text.splitlines()
    i = 0
    while i < len(lines):
        start, parts = i + 1, [lines[i]]
        while parts[-1].rstrip().endswith("\\") and i + 1 < len(lines):
            i += 1
            parts.append(lines[i])
        i += 1
        joined = " ".join(part.strip().rstrip("\\") for part in parts)
        if joined.lstrip().startswith("#"):
            continue
        yield start, joined


def pull_request_workflows():
    for path in sorted((ROOT / ".github/workflows").glob("*.y*ml")):
        text = path.read_text(encoding="utf-8")
        if re.search(r"^  pull_request:", text, re.M) or re.search(r"^on:.*\bpull_request\b", text, re.M):
            yield path, text


class WorkflowsRouteWarningsThroughThePolicy(unittest.TestCase):
    def test_every_deny_flag_in_a_pull_request_workflow_goes_through_the_policy(self):
        bad = []
        for path, text in pull_request_workflows():
            uses = False
            for number, command in commands(text):
                if not DENY_FLAG.search(command):
                    continue
                uses = True
                if not re.search(r"warnings_policy\.py\"? run --", command):
                    bad.append(f"{path.relative_to(ROOT)}:{number}: {command.strip()[:160]}")
            if uses and SOFT_ENV_LINE not in text:
                bad.append(f"{path.relative_to(ROOT)}: runs warnings_policy.py but does not set `{SOFT_ENV_LINE}`")
        self.assertEqual(bad, [], "a pull request compile turns warnings into errors outside "
                                  "scripts/ci/warnings_policy.py (run it as `python3 \"$GITHUB_WORKSPACE/scripts/ci/"
                                  "warnings_policy.py\" run -- CMD`):\n" + "\n".join(bad))

    def test_scripts_route_clippy_through_the_policy(self):
        for script, caller in SCRIPTS.items():
            text = (ROOT / script).read_text(encoding="utf-8")
            self.assertIn("def warnings_soft(", text, f"{script} ({caller})")
            self.assertIn("warnings_soft(command, repo)", text, f"{script} ({caller})")
        workflows = {"cmux-tui-spec.yml", "rust-workspaces.yml"}
        for name in workflows:
            self.assertIn(SOFT_ENV_LINE, (ROOT / ".github/workflows" / name).read_text(encoding="utf-8"), name)

    def test_nightly_and_release_never_go_soft(self):
        for path in sorted((ROOT / ".github/workflows").glob("*.y*ml")):
            if not re.search(r"nightly|release|promote|notariz|appcast", path.name):
                continue
            text = path.read_text(encoding="utf-8")
            self.assertNotRegex(text, r"CI_WARNINGS:\s*['\"]?soft", path.name)


if __name__ == "__main__":
    unittest.main()
