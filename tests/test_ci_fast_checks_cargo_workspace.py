#!/usr/bin/env python3
"""fast-checks.yml refuses `cargo ... -p CRATE` run from a workspace that excludes CRATE.

2026-11-16, run 43881963559 (cmux#44508): `cargo test -p cmux-rd-host` in directory cmux-tui. cmux-tui/Cargo.toml
lists crates/cmux-rd-host under [workspace] exclude, and the crate is its own workspace with its own Cargo.lock;
the only edge to it is a cfg(target_os = "macos") dependency. On Linux cargo 1.95 panicked (exit 101) with
"did not find features for (PackageId { name: \"cmux-rd-host\" ... }, NormalOrDev) within activated_features"
(cargo/core/resolver/features.rs), and the lane spent an hour on it. The Run fast checks step now runs
scripts/ci/cargo_package_workspace_check.py, from the workflow's own commit, before the command: such a request is
refused with exit 2 and the exact directory and command to run instead.
"""

from __future__ import annotations

import importlib.util
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest
from contextlib import redirect_stderr
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "fast-checks.yml"
SCRIPT = ROOT / "scripts" / "ci" / "cargo_package_workspace_check.py"


def load():
    spec = importlib.util.spec_from_file_location("cargo_package_workspace_check", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def step(name: str) -> str:
    match = re.search(rf"^      - name: {re.escape(name)}\n(.*?)(?=^      - |\Z)",
                      WORKFLOW.read_text(encoding="utf-8"), re.S | re.M)
    if not match:
        raise AssertionError(f"no step named {name!r}")
    return match.group(1)


def write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def fixture(root: Path) -> None:
    """A checkout with cmux-tui's shape: a workspace with one member crate and one excluded crate that is its own
    workspace, plus a crate that is outside every workspace member list but excluded by a glob-free path."""
    write(root / "tui" / "Cargo.toml",
          '[workspace]\nresolver = "2"\nmembers = ["crates/*"]\nexclude = ["crates/rd-host", "vendor/old"]\n')
    write(root / "tui" / "crates" / "app" / "Cargo.toml",
          '[package]\nname = "tui-app"\nversion = "0.1.0"\n\n'
          '[target.\'cfg(target_os = "macos")\'.dependencies]\nrd-host = { path = "../rd-host" }\n')
    write(root / "tui" / "crates" / "rd-host" / "Cargo.toml",
          '[package]\nname = "rd-host"\nversion = "0.1.0"\n\n[workspace]\n')
    write(root / "tui" / "vendor" / "old" / "Cargo.toml", '[package]\nname = "old-dep"\nversion = "0.1.0"\n')
    # A build output tree holds copies of manifests; it is never read as the crate.
    write(root / "tui" / "target" / "package" / "tui-app-0.1.0" / "Cargo.toml",
          '[package]\nname = "tui-app"\nversion = "0.1.0"\n[workspace]\n')


class CheckTests(unittest.TestCase):
    def setUp(self) -> None:
        self.check = load()
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        fixture(self.root)

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def run_check(self, command: str, directory: str = "tui") -> tuple[int, str]:
        err = io.StringIO()
        with redirect_stderr(err):
            code = self.check.main(["--command", command, "--directory", directory, "--root", str(self.root)])
        return code, err.getvalue()

    def test_an_excluded_crate_that_is_its_own_workspace_is_refused_with_the_next_step(self) -> None:
        code, err = self.run_check("cargo test -p rd-host --lib -- --nocapture")
        self.assertEqual(code, 2, err)
        self.assertIn("rd-host is not a member of the workspace at tui", err)
        self.assertIn("run it in the crate's own workspace: directory=tui/crates/rd-host, "
                      "command: cargo test --lib -- --nocapture", err)
        self.assertIn("activated_features", err)  # names the panic it saves the reader from

    def test_every_spelling_of_the_package_flag_is_read(self) -> None:
        for command in ("cargo test --package rd-host", "cargo test --package=rd-host", "cargo test -prd-host",
                        "cargo +1.95 clippy -p rd-host@0.1.0", "env RUST_LOG=1 cargo test -p rd-host",
                        "cargo build -p tui-app && cargo test -p rd-host", "cd crates && cargo test -p rd-host",
                        "bash -c 'cargo test -p rd-host'"):
            with self.subTest(command=command):
                code, err = self.run_check(command)
                self.assertEqual(code, 2, err)
                self.assertIn("directory=tui/crates/rd-host", err)

    def test_an_excluded_crate_without_its_own_workspace_is_refused(self) -> None:
        code, err = self.run_check("cargo test -p old-dep")
        self.assertEqual(code, 2, err)
        self.assertIn("directory=tui/vendor/old, command: cargo test", err)

    def test_a_member_crate_passes(self) -> None:
        self.assertEqual(self.run_check("cargo test -p tui-app"), (0, ""))
        self.assertEqual(self.run_check("cargo test -p tui-app", directory="tui/crates/app"), (0, ""))

    def test_a_command_without_a_package_flag_passes(self) -> None:
        for command in ("cargo test", "cargo test --workspace", "cargo test --lib -- -p rd-host", "bun test",
                        "echo cargo test -p rd-host"):
            with self.subTest(command=command):
                self.assertEqual(self.run_check(command), (0, ""))

    def test_a_crate_run_in_its_own_workspace_passes(self) -> None:
        self.assertEqual(self.run_check("cargo test -p rd-host", directory="tui/crates/rd-host"), (0, ""))

    def test_an_unknown_package_or_no_workspace_is_left_to_cargo(self) -> None:
        self.assertEqual(self.run_check("cargo test -p nope"), (0, ""))
        self.assertEqual(self.run_check("cargo test -p rd-host", directory="."), (0, ""))

    def test_commands_cargo_runs_correctly_are_not_refused(self) -> None:
        # Review cases on #44616: each of these does what it says in cargo, so refusing it would be a false red.
        for command, directory in (
                ("cargo update -p rd-host", "tui"),  # update -p names lockfile packages, not members
                ("cargo tree -p rd-host", "tui"),
                ("cargo test --manifest-path crates/rd-host/Cargo.toml -p rd-host", "tui"),
                ("(cd crates/rd-host && cargo test -p rd-host)", "tui"),
                ("cargo test -p old-dep", "tui/vendor/old"),  # cargo runs the excluded package standalone there
                ("# the comment\ncd crates/rd-host\ncargo test -p rd-host", "tui")):
            with self.subTest(command=command):
                self.assertEqual(self.run_check(command, directory=directory), (0, ""))

    def test_a_comment_line_does_not_hide_the_next_command(self) -> None:
        code, err = self.run_check("# run tests\ncargo test -p rd-host")
        self.assertEqual(code, 2, err)

    def test_a_subshell_cd_does_not_leak_out(self) -> None:
        code, err = self.run_check("(cd crates/rd-host && cargo build) && cargo test -p rd-host")
        self.assertEqual(code, 2, err)
        code, err = self.run_check("{ cd crates/rd-host; cargo test -p rd-host; }")
        self.assertEqual(code, 0, err)

    def test_a_literal_member_wins_over_an_exclude(self) -> None:
        write(self.root / "w" / "Cargo.toml", '[workspace]\nmembers = ["crates/app"]\nexclude = ["crates"]\n')
        write(self.root / "w" / "crates" / "app" / "Cargo.toml", '[package]\nname = "w-app"\nversion = "0.1.0"\n')
        self.assertEqual(self.run_check("cargo test -p w-app", directory="w"), (0, ""))

    def test_the_next_step_drops_every_package_flag_and_names_the_others(self) -> None:
        code, err = self.run_check("cargo test -p rd-host -p tui-app")
        self.assertEqual(code, 2, err)
        self.assertIn("directory=tui/crates/rd-host, command: cargo test (", err)
        self.assertIn("run the other packages (tui-app) apart, in tui", err)

    def test_a_command_shlex_cannot_read_is_left_alone(self) -> None:
        self.assertEqual(self.run_check("cargo test -p 'rd-host"), (0, ""))


class WorkflowTests(unittest.TestCase):
    def test_the_check_comes_from_the_workflow_commit_for_cargo_commands(self) -> None:
        # The source snapshot is untrusted (and a feat-cmux-next snapshot lacks main's scripts).
        body = step("Check out the cargo workspace check")
        self.assertIn("if: contains(inputs.command, 'cargo')", body)
        self.assertIn("ref: ${{ github.sha }}", body)
        self.assertIn("path: .fast-checks-cargo-tools", body)
        self.assertIn("persist-credentials: false", body)
        self.assertIn("sparse-checkout: scripts/ci/cargo_package_workspace_check.py", body)

    def test_the_run_step_refuses_before_the_command_and_writes_a_receipt(self) -> None:
        text = WORKFLOW.read_text(encoding="utf-8")
        self.assertLess(text.index("- name: Check out the cargo workspace check\n"),
                        text.index("- name: Run fast checks\n"))
        body = step("Run fast checks")
        self.assertIn("'.fast-checks-cargo-tools', 'scripts', 'ci', 'cargo_package_workspace_check.py'", body)
        self.assertLess(body.index("cargo_package_workspace_check.py"), body.index("command = subprocess.Popen("))
        self.assertIn("refused='cargo-package-workspace'", body)

    def run_step(self, command: str) -> tuple[subprocess.CompletedProcess[str], dict | None, bool]:
        """The Run fast checks step's script, in a git checkout of the fixture, with a fake cargo on PATH (no real
        cargo ever runs here): (its result, its receipt, whether the fake cargo ran)."""
        body = WORKFLOW.read_text(encoding="utf-8").split("      - name: Run fast checks\n", 1)[1]
        script = textwrap.dedent(body.split("          python3 - <<'PY'\n", 1)[1].split("\n          PY", 1)[0])
        with tempfile.TemporaryDirectory() as temp:
            temp_path = Path(temp)
            checkout, workspace, bin_dir, runner = (temp_path / n for n in ("checkout", "ws", "bin", "runner"))
            fixture(checkout)
            tools = workspace / ".fast-checks-cargo-tools" / "scripts" / "ci"
            tools.mkdir(parents=True)
            shutil.copy(SCRIPT, tools / SCRIPT.name)
            bin_dir.mkdir()
            runner.mkdir()
            ran = temp_path / "cargo-ran"
            write(bin_dir / "cargo", f"#!/bin/sh\ntouch '{ran}'\n")
            (bin_dir / "cargo").chmod(0o755)
            git = ["git", "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null"]
            subprocess.run(["git", "init", "-q", str(checkout)], check=True)
            subprocess.run([*git, "-C", str(checkout), "add", "-A"], check=True)
            subprocess.run([*git, "-C", str(checkout), "commit", "-qm", "fixture"], check=True)
            head = subprocess.check_output(["git", "-C", str(checkout), "rev-parse", "HEAD"], text=True).strip()
            env = {**os.environ, "PATH": f"{bin_dir}:{os.environ['PATH']}", "FAST_CHECKS_COMMAND": command,
                   "FAST_CHECKS_DIRECTORY": "tui", "FAST_CHECKS_SOURCE": head, "FAST_CHECKS_TIMEOUT": "30",
                   "RUNNER_TEMP": str(runner), "GITHUB_RUN_ID": "test-run", "GITHUB_WORKSPACE": str(workspace)}
            result = subprocess.run([sys.executable, "-c", script], cwd=checkout, env=env, capture_output=True,
                                    text=True)
            receipt_path = runner / "fast-checks.json"
            receipt = json.loads(receipt_path.read_text()) if receipt_path.exists() else None
            return result, receipt, ran.exists()

    def test_the_step_refuses_an_excluded_crate_with_a_receipt_and_runs_a_member(self) -> None:
        result, receipt, ran = self.run_step("cargo test -p rd-host")
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertFalse(ran)
        self.assertEqual((receipt or {}).get("exit_code"), 2)
        self.assertEqual((receipt or {}).get("refused"), "cargo-package-workspace")
        self.assertIn("directory=tui/crates/rd-host, command: cargo test", result.stderr)
        result, receipt, ran = self.run_step("cargo test -p tui-app")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(ran)
        self.assertEqual((receipt or {}).get("exit_code"), 0)


if __name__ == "__main__":
    unittest.main()
