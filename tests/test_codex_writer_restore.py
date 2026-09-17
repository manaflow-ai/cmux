#!/usr/bin/env python3
"""Exercise the production CLI exec boundary, with synthetic homes and a fake agent.

No app, socket, real Codex session, or user lock is opened. CMUX_RESTORE_SOURCE_REF
selects a base revision to prove the same behavior assertions fail without the fix.
The exported source is a disposable package fixture, never a git worktree.
"""
import fcntl
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SESSION = "01a06e0d-8793-7f33-b044-2b49a10c2260"


class CodexWriterRestoreTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build_root = tempfile.TemporaryDirectory(prefix="cmux-writer-cli-build-")
        cls.addClassCleanup(cls.build_root.cleanup)
        build = Path(cls.build_root.name)
        source_ref = os.environ.get("CMUX_RESTORE_SOURCE_REF")
        source = ROOT
        if source_ref:
            source = build / "base"
            source.mkdir()
            archive = build / "source.tar"
            with archive.open("wb") as output:
                subprocess.run(["git", "archive", source_ref, "Packages/macOS/CMUXAgentLaunch", "CLI", "Sources"], cwd=ROOT, stdout=output, check=True)
            with tarfile.open(archive) as contents:
                contents.extractall(source, filter="data")
        target = build / "Sources" / "RestoreHarness"
        target.mkdir(parents=True)
        shutil.copy(ROOT / "tests/fixtures/codex_writer_restore/Harness.swift", target)
        for filename in ["CLI/CMUXCLI+RestoreExecution.swift", "CLI/CMUXCLI+CodexWriterRestore.swift", "Sources/CodexWriterRestoreMessage.swift"]:
            if (source / filename).exists():
                shutil.copy(source / filename, target)
        package = source / "Packages/macOS/CMUXAgentLaunch"
        (build / "Package.swift").write_text(f'''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "RestoreHarness", platforms: [.macOS(.v14)],
    dependencies: [.package(path: {json.dumps(str(package))})],
    targets: [.executableTarget(name: "RestoreHarness", dependencies: [
        .product(name: "CMUXAgentLaunch", package: "CMUXAgentLaunch")])])
''')
        compiled = subprocess.run(["swift", "build", "--package-path", str(build), "--jobs", "4"], capture_output=True, text=True)
        if compiled.returncode:
            raise RuntimeError(compiled.stdout + compiled.stderr)
        if "warning:" in compiled.stderr:
            raise RuntimeError(compiled.stderr)
        bin_path = subprocess.check_output(["swift", "build", "--package-path", str(build), "--show-bin-path"], text=True).strip()
        cls.harness = Path(bin_path) / "RestoreHarness"

    def setUp(self):
        self.fixture = tempfile.TemporaryDirectory(prefix="cmux-writer-cli-")
        self.addCleanup(self.fixture.cleanup)
        self.root = Path(self.fixture.name).resolve()
        self.home = self.root / "account"
        self.other = self.root / "other-account"
        self.cwd = self.root / "project with spaces"
        for path in [self.home / "thread-writer-locks", self.other, self.cwd]:
            path.mkdir(parents=True)
        self.lock = self.home / "thread-writer-locks" / f"{SESSION}.lock"
        self.agent = self.root / "codex"
        # An executable fixture records what actually reached execve.
        self.agent.write_text('''#!/usr/bin/python3
import json, os, sys
print(json.dumps({"argv": sys.argv, "cwd": os.getcwd(), "home": os.environ.get("CODEX_HOME"), "marker": os.environ.get("CMUX_TEST_MARKER")}))
''')
        self.agent.chmod(0o700)

    def hold_lock(self):
        handle = self.lock.open("w+")
        self.addCleanup(handle.close)
        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return handle

    def restore(self, mode="structured", saved_home=None, ambient_home=None):
        env = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": str(self.root), "SHELL": "/bin/sh",
               "CODEX_HOME": str(ambient_home or self.home), "SAVED_CODEX_HOME": str(saved_home or self.home),
               "CMUX_TEST_MARKER": "kept verbatim"}
        return subprocess.run([str(self.harness), mode, str(self.agent), str(self.cwd), SESSION],
                              env=env, text=True, capture_output=True, timeout=15)

    def test_locked_session_stops_before_agent_exec(self):
        handle = self.hold_lock()
        result = self.restore()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("active writer", result.stderr)
        self.assertNotIn(self.lock.name, result.stderr)
        self.assertNotIn(str(self.root), result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertTrue(self.lock.exists())
        # A second descriptor still cannot acquire our lock: no unlock/removal.
        with self.lock.open() as probe:
            with self.assertRaises(BlockingIOError):
                fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)
        self.assertFalse(handle.closed)

    def test_unlocked_and_released_files_allow_exact_launch(self):
        handle = self.hold_lock()
        fcntl.flock(handle, fcntl.LOCK_UN)
        result = self.restore()
        self.assertEqual(result.returncode, 0, result.stderr)
        launch = json.loads(result.stdout)
        self.assertEqual(launch["cwd"], str(self.cwd))
        self.assertEqual(Path(launch["home"]).resolve(), self.home)
        self.assertEqual(launch["marker"], "kept verbatim")
        self.assertIn("model with spaces", launch["argv"])
        self.assertIn("test='quoted value'", launch["argv"])
        self.assertIn(SESSION, launch["argv"])
        self.assertTrue(self.lock.exists())

    def test_saved_account_wins_over_ambient(self):
        self.hold_lock()
        blocked = self.restore(ambient_home=self.other)
        self.assertNotEqual(blocked.returncode, 0, blocked.stdout)
        allowed = self.restore(saved_home=self.other)
        self.assertEqual(allowed.returncode, 0, allowed.stderr)
        self.assertEqual(Path(json.loads(allowed.stdout)["home"]).resolve(), self.other)

    def test_remote_provider_does_not_consult_local_lock(self):
        self.hold_lock()
        result = self.restore(mode="remote")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--remote", json.loads(result.stdout)["argv"])

    def test_legacy_explicit_home_is_guarded(self):
        handle = self.hold_lock()
        blocked = self.restore(mode="legacy", ambient_home=self.other)
        self.assertNotEqual(blocked.returncode, 0, blocked.stdout)
        self.assertIn("active writer", blocked.stderr)
        fcntl.flock(handle, fcntl.LOCK_UN)
        allowed = self.restore(mode="legacy")
        self.assertEqual(allowed.returncode, 0, allowed.stderr)

    def test_legacy_noncanonical_record_is_still_guarded(self):
        handle = self.hold_lock()
        blocked = self.restore(mode="legacy-noncanonical")
        self.assertNotEqual(blocked.returncode, 0, blocked.stdout)
        self.assertIn("active writer", blocked.stderr)
        self.assertEqual(blocked.stdout, "")
        fcntl.flock(handle, fcntl.LOCK_UN)
        allowed = self.restore(mode="legacy-noncanonical")
        self.assertEqual(allowed.returncode, 0, allowed.stderr)

    def test_ambiguous_legacy_does_not_guess_account(self):
        result = self.restore(mode="ambiguous-legacy")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("older shell-only", result.stderr)


if __name__ == "__main__":
    unittest.main()
