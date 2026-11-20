"""scripts/cmux-next/check-dev-build-state.py: a new path that every build shares (NIGHTLY, stable and each dev build)
fails unless its file's row in dev-build-state-baseline.tsv reviews it (AGENTS.md "Dev builds are separate")."""
from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CHECK = ROOT / "scripts/cmux-next/check-dev-build-state.py"
SWIFT = "Packages/macOS/CmuxNext/Sources/CmuxNextThing/Thing.swift"
RUST = "cmux-tui/crates/cmux-thing/src/lib.rs"


def run(files: dict[str, str], baseline: str = "# path\tcount\treason\n") -> tuple[int, str]:
    with tempfile.TemporaryDirectory() as tmp:
        for rel, text in files.items():
            path = Path(tmp) / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text, encoding="utf-8")
        rows = Path(tmp) / "baseline.tsv"
        rows.write_text(baseline, encoding="utf-8")
        done = subprocess.run([sys.executable, "-I", str(CHECK), tmp, "--baseline", str(rows)], capture_output=True, text=True)
        return done.returncode, done.stdout


class CheckDevBuildStateTests(unittest.TestCase):
    def test_a_new_shared_config_path_fails(self) -> None:
        code, out = run({SWIFT: 'let url = home.appending(path: ".config/cmux/new-state.json")\n'})
        self.assertEqual(code, 1)
        self.assertIn(f"{SWIFT}:1:", out)
        self.assertIn("~/.config/cmux", out)

    def test_each_shared_kind_is_found(self) -> None:
        for line in ['let s = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!',
                     'let c = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]',
                     'let d = UserDefaults(suiteName: "com.cmuxterm.shared")',
                     'let q = [kSecAttrService as String: "cmux-shared"]',
                     'static let service = "cmux-shared"',
                     'let h = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cmux/state")']:
            with self.subTest(line=line):
                self.assertEqual(run({SWIFT: line + "\n"})[0], 1)
        self.assertEqual(run({RUST: 'let p = home.join(".config/cmux/state.json");\n'})[0], 1)

    def test_a_reviewed_site_passes_and_a_rise_fails(self) -> None:
        text = 'let url = home.appending(path: ".config/cmux/input")\n'
        row = f"# path\tcount\treason\n{SWIFT}\t1\tan input of this Mac\n"
        self.assertEqual(run({SWIFT: text}, row), (0, ""))
        self.assertEqual(run({SWIFT: text * 2}, row)[0], 1)

    def test_comments_tests_and_per_build_paths_do_not_count(self) -> None:
        files = {
            SWIFT: '/// `~/.config/cmux/cmux-next.json`\n// .config/cmux\nlet p = paths.settingsFile\n',
            "Packages/macOS/CmuxNext/Sources/CmuxNextThing/ThingTests.swift": 'let p = ".config/cmux/x"\n',
            "cmux-tui/crates/cmux-thing/src/thing_tests.rs": 'let p = ".config/cmux/x";\n',
            "cmux-tui/crates/cmux-thing/tests/it.rs": 'let p = ".config/cmux/x";\n',
        }
        self.assertEqual(run(files), (0, ""))

    def test_a_bad_baseline_row_is_refused(self) -> None:
        code = subprocess.run([sys.executable, "-I", str(CHECK), "/nonexistent", "--baseline", "/dev/null"],
                              capture_output=True, text=True).returncode
        self.assertEqual(code, 0)
        self.assertNotEqual(run({}, f"{SWIFT}\tx\treason\n")[0], 0)
        self.assertNotEqual(run({}, f"{SWIFT}\t1\t\n")[0], 0)

    def test_the_repository_passes(self) -> None:
        done = subprocess.run([sys.executable, "-I", str(CHECK), str(ROOT)], capture_output=True, text=True)
        self.assertEqual(done.returncode, 0, done.stdout)


if __name__ == "__main__":
    unittest.main()
