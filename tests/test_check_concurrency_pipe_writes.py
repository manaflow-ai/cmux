"""check-concurrency.sh's pipe-write rule: no `fileHandleForWriting.write(` on the caller's thread.
A pipe write can wait however few the bytes (a child that never reads; a fresh pipe when the
kernel's pipe memory is used up): ProcessRunner's stdin write held the NIGHTLY main thread in
write(2) for 391 s (2026-11-09). CmuxNextCompat's PipeFeed writes on a queue of its own."""
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/cmux-next/check-concurrency.sh"
MANIFEST = """// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "Fixture", targets: [
    .target(name: "FixtureUI", swiftSettings: uiSwiftSettings),
    .target(name: "FixtureCore", swiftSettings: coreSwiftSettings),
])
"""
# ProcessRunner's shape before the fix: the stdin bytes written before launch, on the caller's thread.
DIRECT = """import Foundation

func feed(_ input: Pipe, _ stdin: Data) throws {
    try input.fileHandleForWriting.write(contentsOf: stdin)
    try input.fileHandleForWriting.close()
}
"""
FED = """import CmuxNextCompat
import Foundation

func feed(_ input: Pipe, _ stdin: Data) {
    let feed = PipeFeed(input.fileHandleForWriting)
    feed.write(stdin)
    feed.close()
}
"""
ALLOWED = """import Foundation

func feed(_ input: Pipe, _ stdin: Data) {
    // concurrency-allow: runs on the feed's own queue, never the caller's thread
    try? input.fileHandleForWriting.write(contentsOf: stdin)
}
"""


def run(files):
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary) / "Package"
        root.mkdir(parents=True)
        (root / "Package.swift").write_text(MANIFEST)
        for name, text in files.items():
            (root / "Sources" / name).parent.mkdir(parents=True, exist_ok=True)
            (root / "Sources" / name).write_text(text)
        env = {key: value for key, value in os.environ.items() if key != "CHECK_CONCURRENCY_ONLY"}
        return subprocess.run(["bash", str(SCRIPT), str(root)], env=env, text=True, capture_output=True, timeout=60)


class PipeWriteRule(unittest.TestCase):
    def test_a_direct_pipe_write_is_red_in_core_code(self):
        result = run({"FixtureCore/Feed.swift": DIRECT})
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("FixtureCore/Feed.swift:4: pipe write on the caller's thread (use PipeFeed)", result.stdout)

    def test_it_applies_in_a_ui_target_too(self):
        result = run({"FixtureUI/Feed.swift": DIRECT})
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("FixtureUI/Feed.swift:4: pipe write on the caller's thread (use PipeFeed)", result.stdout)

    def test_a_pipe_feed_is_green(self):
        result = run({"FixtureCore/Feed.swift": FED})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_a_reviewed_escape_is_green(self):
        result = run({"FixtureCore/Feed.swift": ALLOWED})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
