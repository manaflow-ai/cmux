#!/usr/bin/env python3
"""The claude wrapper names the Claude process `claude`, not its version.

The native installer links `claude` to `versions/<version>`, and the kernel
names a process after the resolved file, so Activity Monitor and `ps` showed
every Claude Code session as "2.1.283". The wrapper execs a hardlink named
after the agent instead.
"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WRAPPER = ROOT / "Resources" / "bin" / "cmux-claude-wrapper"
# The trailing `:` keeps bash from replacing itself with `ps`, so `$$` stays
# the launched process.
PROCESS_NAME_COMMAND = "ps -o ucomm= -p $$; :"
# macOS names a process after the executed file with symlinks resolved; Linux
# uses the path passed to exec, which is the `claude` symlink here.
UNLABELED_NAME = "9.9.9" if sys.platform == "darwin" else "claude"


class Fixture:
    def __init__(self, root: Path) -> None:
        self.root = root
        self.home = root / "home"
        self.bundle_bin = root / "cmux.app" / "Contents" / "Resources" / "bin"
        self.user_bin = self.home / ".local" / "bin"
        self.versions = self.home / ".local" / "share" / "claude" / "versions"
        self.cache = self.home / "cache" / "agent-process-names"
        for directory in (self.bundle_bin, self.user_bin, self.versions):
            directory.mkdir(parents=True, exist_ok=True)
        self.wrapper = self.bundle_bin / "cmux-claude-wrapper"
        self.wrapper.write_bytes(WRAPPER.read_bytes())
        self.wrapper.chmod(0o755)

    def install_native(self, version: str) -> Path:
        # A copied bash stands in for the native Claude executable: a real
        # Mach-O/ELF file that can report its own kernel process name.
        bash = shutil.which("bash")
        assert bash, "bash is required"
        binary = self.versions / version
        shutil.copyfile(os.path.realpath(bash), binary)
        binary.chmod(0o755)
        link = self.user_bin / "claude"
        if link.is_symlink() or link.exists():
            link.unlink()
        link.symlink_to(binary)
        return binary

    def env(self, **extra: str) -> dict[str, str]:
        env = {
            "HOME": str(self.home),
            "PATH": f"{self.bundle_bin}:{self.user_bin}:/usr/bin:/bin",
            "TMPDIR": str(self.root),
            "CMUX_AGENT_PROCESS_NAME_DIR": str(self.cache),
        }
        env.update(extra)
        return env

    def run(self, env: dict[str, str]) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [str(self.wrapper), "-c", PROCESS_NAME_COMMAND],
            env=env,
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )


def expect_process_name(
    failures: list[str],
    label: str,
    result: subprocess.CompletedProcess[str],
    expected: str,
) -> None:
    if result.returncode != 0:
        failures.append(f"{label}: exit {result.returncode}: {result.stderr.strip()}")
        return
    actual = result.stdout.strip()
    if actual != expected:
        failures.append(f"{label}: process name {actual!r}, expected {expected!r}")


def test_versioned_native_claude_runs_as_claude(failures: list[str]) -> None:
    with tempfile.TemporaryDirectory(prefix="cmux-claude-process-name-") as td:
        fixture = Fixture(Path(td))
        binary = fixture.install_native("9.9.9")
        expect_process_name(failures, "first launch", fixture.run(fixture.env()), "claude")
        expect_process_name(failures, "second launch", fixture.run(fixture.env()), "claude")

        links = list(fixture.cache.glob("claude/*/claude"))
        if len(links) != 1:
            failures.append(f"expected one labeled link, found {links}")
        elif not os.path.samefile(links[0], binary):
            failures.append("labeled link is not a hardlink of the versioned binary")


def test_setting_off_keeps_the_version_name(failures: list[str]) -> None:
    with tempfile.TemporaryDirectory(prefix="cmux-claude-process-name-off-") as td:
        fixture = Fixture(Path(td))
        fixture.install_native("9.9.9")
        result = fixture.run(fixture.env(CMUX_AGENT_PROCESS_NAMES_DISABLED="1"))
        expect_process_name(failures, "disabled", result, UNLABELED_NAME)
        if fixture.cache.exists():
            failures.append("disabled launch created the process-name cache")


def test_unwritable_cache_falls_back_to_the_original(failures: list[str]) -> None:
    if os.geteuid() == 0:
        return
    with tempfile.TemporaryDirectory(prefix="cmux-claude-process-name-ro-") as td:
        fixture = Fixture(Path(td))
        fixture.install_native("9.9.9")
        fixture.cache.mkdir(parents=True)
        fixture.cache.chmod(0o500)
        try:
            result = fixture.run(fixture.env())
        finally:
            fixture.cache.chmod(0o700)
        expect_process_name(failures, "unwritable cache", result, UNLABELED_NAME)


def test_script_claude_is_not_linked(failures: list[str]) -> None:
    with tempfile.TemporaryDirectory(prefix="cmux-claude-process-name-script-") as td:
        fixture = Fixture(Path(td))
        script = fixture.versions / "1.0.0"
        script.write_text("#!/bin/sh\necho script-claude\n", encoding="utf-8")
        script.chmod(0o755)
        (fixture.user_bin / "claude").symlink_to(script)
        result = fixture.run(fixture.env())
        if result.returncode != 0 or result.stdout.strip() != "script-claude":
            failures.append(f"script claude: {result.returncode} {result.stdout!r} {result.stderr!r}")
        if list(fixture.cache.glob("claude/*/claude")):
            failures.append("script claude was linked")


def test_new_version_prunes_unused_links_to_removed_versions(failures: list[str]) -> None:
    with tempfile.TemporaryDirectory(prefix="cmux-claude-process-name-prune-") as td:
        fixture = Fixture(Path(td))
        old = fixture.install_native("9.9.8")
        expect_process_name(failures, "old version", fixture.run(fixture.env()), "claude")
        recent = fixture.install_native("9.9.7")
        expect_process_name(failures, "recent version", fixture.run(fixture.env()), "claude")

        entries = {path.parent.name: path.parent for path in fixture.cache.glob("claude/*/claude")}
        old_entry = next((entry for key, entry in entries.items() if key.endswith("9.9.8")), None)
        recent_entry = next((entry for key, entry in entries.items() if key.endswith("9.9.7")), None)
        if old_entry is None or recent_entry is None:
            failures.append(f"expected links for both versions, found {sorted(entries)}")
            return
        # The updater removed both versions. Only the old one has gone unused
        # for more than a week.
        old.unlink()
        recent.unlink()
        week_ago = time.time() - 8 * 24 * 60 * 60
        os.utime(old_entry / "used", (week_ago, week_ago))

        fixture.install_native("9.9.9")
        expect_process_name(failures, "new version", fixture.run(fixture.env()), "claude")
        if old_entry.exists():
            failures.append("unused link to a removed version was not pruned")
        if not recent_entry.exists():
            failures.append("recently used link to a removed version was pruned")


def main() -> int:
    failures: list[str] = []
    test_versioned_native_claude_runs_as_claude(failures)
    test_setting_off_keeps_the_version_name(failures)
    test_unwritable_cache_falls_back_to_the_original(failures)
    test_script_claude_is_not_linked(failures)
    test_new_version_prunes_unused_links_to_removed_versions(failures)
    if failures:
        for failure in failures:
            print(f"FAIL: {failure}", file=sys.stderr)
        return 1
    print("PASS: claude wrapper process names")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
