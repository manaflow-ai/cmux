"""Rules of scripts/cmux-next/check-no-swift-cli-spawn.py (the NO-SWIFT-CLI-SPAWN ratchet)."""

from __future__ import annotations

import importlib.util
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest

SOURCE = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = SOURCE / "scripts/cmux-next/check-no-swift-cli-spawn.py"
PKG = "Packages/macOS/CmuxNext"

MANIFEST = """
let package = Package(name: "CmuxNext", targets: [
    .target(name: "CmuxNextApp", swiftSettings: uiSwiftSettings),
    .target(name: "CmuxNextCloud"),
])
"""


def load():
    spec = importlib.util.spec_from_file_location("check_no_swift_cli_spawn", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class Rules(unittest.TestCase):
    def setUp(self):
        self.root = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.root)
        (self.root / "scripts/cmux-next").mkdir(parents=True)
        for name in ("check-no-swift-cli-spawn.py", "check-main-actor-work.py"):
            shutil.copy(SOURCE / "scripts/cmux-next" / name, self.root / "scripts/cmux-next" / name)
        (self.root / PKG).mkdir(parents=True)
        (self.root / PKG / "Package.swift").write_text(MANIFEST)

    def write(self, rel, text):
        path = self.root / PKG / "Sources" / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def baseline(self, rows):
        (self.root / "scripts/cmux-next/swift-cli-spawn-baseline.tsv").write_text(
            "# path\tkind\tcount\towner\n" + "".join(f"{PKG}/Sources/{p}\t{k}\t{n}\tlane:x\n" for p, k, n in rows))

    def run_check(self):
        return subprocess.run([sys.executable, "-I", str(self.root / "scripts/cmux-next/check-no-swift-cli-spawn.py"),
                               str(self.root)], capture_output=True, text=True)

    def test_a_new_cli_spawn_on_the_main_actor_fails_as_both_kinds(self):
        self.write("CmuxNextApp/Warm.swift", "struct Warm {\n    func go() async { _ = try? await cli.startChatWarmSpare(x) }\n}\n")
        self.baseline([])
        result = self.run_check()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("cmux-cli", result.stderr)
        self.assertIn("main-actor", result.stderr)

    def test_a_new_process_runner_site_off_the_main_actor_still_fails(self):
        self.write("CmuxNextCloud/Run.swift", "func go() async throws {\n    _ = try await ProcessRunner.run(executable: x)\n}\n")
        self.baseline([])
        result = self.run_check()
        self.assertEqual(result.returncode, 1)
        self.assertIn("process", result.stderr)
        self.assertNotIn("main-actor", result.stderr)

    def test_ssh_and_phone_runners_count_as_processes(self):
        text = "func go() async {\n    _ = try? await SSHProcessRunner.run(a)\n    let r = PhoneProcessRunner()\n}\n"
        hits = load().scan_text(text, False, load()._main_actor_module())
        self.assertEqual([kind for _, kind, _ in hits], ["process", "process"])

    def test_a_site_inside_the_baseline_passes_and_a_lower_count_is_a_note(self):
        self.write("CmuxNextCloud/Run.swift", "func go() async throws {\n    _ = try await ProcessRunner.run(executable: x)\n}\n")
        self.baseline([("CmuxNextCloud/Run.swift", "process", 2)])
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("lower the row", result.stdout)

    def test_comments_strings_and_nonisolated_code_are_read_right(self):
        text = ('// ProcessRunner.run(executable: x)\n'
                'let s = "cli.startChatPlan("\n'
                '@MainActor struct A {\n'
                '    nonisolated func off() async { _ = try? await ProcessRunner.run(executable: x) }\n'
                '}\n')
        hits = load().scan_text(text, False, load()._main_actor_module())
        self.assertEqual([(line, kind) for line, kind, _ in hits], [(4, "process")])

    def test_the_tree_matches_its_baseline(self):
        result = subprocess.run([sys.executable, "-I", str(SCRIPT), str(SOURCE)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("warning", result.stderr)


if __name__ == "__main__":
    unittest.main()
