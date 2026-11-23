#!/usr/bin/env python3
"""`cmux-ci test --setup rust -- '... cargo nextest run ...'` must not cost a fleet run to fail.

cargo nextest is cmux-tui's test runner (cmux-tui/.config/nextest.toml's `ci` profile,
scripts/ci/cmux-tui-rust-check.sh's test mode, cmux-tui-testbox-warmup.yml), so an agent reaching
for it under --setup rust is making the obvious inference. The setup did not carry it: runs
45086122865 (175.9 s) and 45086659367 (109.4 s) each dispatched a full fleet run, waited, and died
on "error: no such command: `nextest`" -- ~285 s of fleet time for a missing binary.

This is the detector for that class. It fails when the fast-checks Rust setup stops carrying the
pinned cargo-nextest, when the .fast-checks-checkout gate and fast-checks.yml's own `uses:` path
drift apart (which would silently drop nextest again), when two CI paths pin different nextest
versions, or when an unpinned get.nexte.st/latest install comes back.
"""

from __future__ import annotations

import re
import subprocess
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
INSTALLER = ROOT / "scripts" / "ci" / "install-nextest.sh"
ACTION = ROOT / ".github" / "actions" / "setup-cmux-tui-rust" / "action.yml"
FAST_CHECKS = ROOT / ".github" / "workflows" / "fast-checks.yml"
WARMUP = ROOT / ".github" / "workflows" / "cmux-tui-testbox-warmup.yml"
RUST_CHECK = ROOT / "scripts" / "ci" / "cmux-tui-rust-check.sh"
# The one literal that ties the action's gate to the path fast-checks.yml checks the snapshot out at.
FAST_CHECKS_CHECKOUT = ".fast-checks-checkout"
# Every CI path that needs nextest shares the installer instead of carrying its own download.
SHARING_SCRIPTS = (
    RUST_CHECK,
    ROOT / "scripts" / "ci" / "acpmux-lib-under-load.sh",
    ROOT / "scripts" / "ci" / "affected_tests_measure.sh",
)


def pinned_version() -> str:
    done = subprocess.run(
        ["bash", str(INSTALLER), "--print-version"], capture_output=True, text=True, timeout=60
    )
    assert done.returncode == 0, done.stderr
    return done.stdout.strip()


def action_step() -> dict:
    document = yaml.safe_load(ACTION.read_text(encoding="utf-8")) or {}
    steps = document["runs"]["steps"]
    found = [step for step in steps if "install-nextest.sh" in (step.get("run") or "")]
    assert len(found) == 1, [step.get("name") for step in steps]
    return found[0]


class InstallerIsTheOnePin(unittest.TestCase):
    def test_installer_runs_and_names_its_pin(self) -> None:
        self.assertTrue(INSTALLER.is_file(), f"{INSTALLER} is the shared pinned cargo-nextest install")
        self.assertRegex(pinned_version(), r"^\d+\.\d+\.\d+$")

    def test_installer_pins_a_checksum_for_every_runner_platform(self) -> None:
        text = INSTALLER.read_text(encoding="utf-8")
        for platform in ("Darwin-*", "Linux-x86_64", "Linux-aarch64"):
            self.assertIn(platform, text, f"{INSTALLER.name} has no pinned asset for {platform}")
        self.assertEqual(
            3, len(re.findall(r"\bsha=[0-9a-f]{64}\b", text)), "each platform asset needs its sha256"
        )

    def test_the_gates_share_one_nextest_version(self) -> None:
        version = pinned_version()
        warmup = re.search(r"NEXTEST_VERSION:\s*(\S+)", WARMUP.read_text(encoding="utf-8"))
        assert warmup is not None, f"{WARMUP.name} no longer names NEXTEST_VERSION"
        self.assertEqual(
            version,
            warmup.group(1),
            f"{WARMUP.name} pins a different cargo-nextest than {INSTALLER.name}: bump them together",
        )

    def test_no_ci_path_installs_an_unpinned_nextest(self) -> None:
        # The unpinned installer (nextest's "latest" redirect) gave a check a different nextest
        # than the gates ran, and changed version under it without a commit. A comment may name
        # the host; a command may not fetch from it.
        host = "get." + "nexte.st"
        offenders = []
        for path in sorted((ROOT / "scripts" / "ci").rglob("*")):
            if not path.is_file():
                continue
            for number, line in enumerate(path.read_text(encoding="utf-8", errors="ignore").splitlines(), 1):
                if host in line and not line.lstrip().startswith("#"):
                    offenders.append(f"{path.relative_to(ROOT).as_posix()}:{number}")
        self.assertEqual([], offenders, "install nextest with scripts/ci/install-nextest.sh")

    def test_every_sharing_script_calls_the_installer(self) -> None:
        for path in SHARING_SCRIPTS:
            with self.subTest(script=path.name):
                self.assertIn("install-nextest.sh", path.read_text(encoding="utf-8"))


class FastChecksRustSetupCarriesNextest(unittest.TestCase):
    def test_the_rust_setup_runs_the_shared_installer(self) -> None:
        run = action_step()["run"]
        self.assertIn("GITHUB_PATH", run, "the installed nextest has to reach the command's PATH")
        self.assertIn(
            FAST_CHECKS_CHECKOUT,
            run,
            "the step must install nextest only for the fast-checks copy of this action",
        )

    def test_the_gate_matches_the_path_fast_checks_checks_out_at(self) -> None:
        # If fast-checks.yml renames the snapshot checkout, the gate stops matching and nextest
        # silently disappears from the setup -- back to a 175 s run that dies on a missing binary.
        document = yaml.safe_load(FAST_CHECKS.read_text(encoding="utf-8")) or {}
        uses = [
            step["uses"]
            for job in document["jobs"].values()
            for step in (job.get("steps") or [])
            if "setup-cmux-tui-rust" in (step.get("uses") or "")
        ]
        self.assertTrue(uses, "fast-checks.yml no longer sets up the cmux-tui Rust toolchain")
        for path in uses:
            with self.subTest(uses=path):
                self.assertIn(
                    FAST_CHECKS_CHECKOUT,
                    path,
                    f"the action gates on {FAST_CHECKS_CHECKOUT}; this `uses:` would not match it",
                )

    def test_a_failed_install_never_reddens_a_setup_that_needs_no_nextest(self) -> None:
        run = action_step()["run"]
        self.assertIn("::warning::", run, "a download failure warns instead of failing the setup")
        self.assertNotIn("set -euo", run, "the step handles the installer's failure itself")


if __name__ == "__main__":
    unittest.main()
