"""check-concurrency.sh's pipe-read rule: no `availableData` inside a `readabilityHandler` closure.
A failed read(2) there (EBADF, EIO: a descriptor closed under a live handler) raises an Objective-C
exception Swift cannot catch, which aborts the app (cmuxterm-hq#4753). `handle.readReady()` reads
the same bytes and ends the stream on a failed read instead."""
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
# The shape #26746 and this rule's first sweep replaced (ChildProcess's stdout reader).
HANDLER = """import Foundation

func start(_ pipe: Pipe, yield: @escaping @Sendable (Data) -> Void) {
    pipe.fileHandleForReading.readabilityHandler = { handle in
        // concurrency-allow: readabilityHandler runs on Foundation's pipe queue, never main; data is ready.
        let data = handle.availableData
        if data.isEmpty { handle.readabilityHandler = nil; return }
        yield(data)
    }
}
"""
# AgentPaneLineReader's one-line shape.
ONE_LINE = """import Foundation

func start(_ handle: FileHandle, receive: @escaping @Sendable (Data) -> Void) {
    handle.readabilityHandler = { handle in receive(handle.availableData) }
}
"""
FIXED = """import CmuxNextCompat
import Foundation

func start(_ pipe: Pipe, yield: @escaping @Sendable (Data) -> Void) {
    pipe.fileHandleForReading.readabilityHandler = { handle in
        switch handle.readReady() {
        case .bytes(let data): yield(data)
        case .retry: return
        case .end: handle.readabilityHandler = nil
        }
    }
}
"""
# Nested braces inside the handler keep it open; one in a string literal doesn't close it.
NESTED = """import Foundation

func start(_ pipe: Pipe, state: Box) {
    pipe.fileHandleForReading.readabilityHandler = { handle in
        let marker = "}"
        state.withLock { state in
            if state.open { state.log(marker) }
        }
        state.append(handle.availableData)
    }
}
"""
# The blocking seam's shape: not a readability handler, and after one closes is outside it.
OUTSIDE = """import Foundation

extension FileHandle {
    func blockingAvailableData() -> Data {
        return availableData // concurrency-allow: the checked seam
    }
}

func start(_ pipe: Pipe) -> Data {
    pipe.fileHandleForReading.readabilityHandler = { handle in
        _ = handle.readReady()
    }
    return pipe.fileHandleForReading.availableData // concurrency-allow: a test helper off main
}
"""
COMMENT = """import Foundation

func start(_ pipe: Pipe) {
    pipe.fileHandleForReading.readabilityHandler = { handle in
        // One read of ready bytes; unlike `availableData` a failure returns -1.
        _ = handle.readReady()
    }
}
"""
# The closure's brace on the line after `readabilityHandler =`.
NEXT_LINE_BRACE = """import Foundation

func start(_ pipe: Pipe, yield: @escaping @Sendable (Data) -> Void) {
    pipe.fileHandleForReading.readabilityHandler =
        { handle in
            yield(handle.availableData)
        }
}
"""
# The name in a string literal or after code in a trailing comment is text, not a read.
TEXT = """import Foundation

func start(_ pipe: Pipe, log: @escaping @Sendable (String) -> Void) {
    pipe.fileHandleForReading.readabilityHandler = { handle in
        log("no availableData here")
        log("x") // availableData is not read here either
        _ = handle.readReady()
    }
}
"""
# A read inside a string interpolation is code.
INTERPOLATED = """import Foundation

func start(_ pipe: Pipe, log: @escaping @Sendable (String) -> Void) {
    pipe.fileHandleForReading.readabilityHandler = { handle in
        log("bytes: \\(handle.availableData.count)")
    }
}
"""
# A `}` in a block comment doesn't end the handler before its read.
BLOCK_COMMENT = """import Foundation

func start(_ pipe: Pipe, yield: @escaping @Sendable (Data) -> Void) {
    pipe.fileHandleForReading.readabilityHandler = { handle in
        /* the payload ends with } */
        yield(handle.availableData)
    }
}
"""
# The name in a multiline literal, a raw literal or a block comment is text.
LITERAL_TEXT = """import Foundation

func start(_ pipe: Pipe, log: @escaping @Sendable (String) -> Void) {
    pipe.fileHandleForReading.readabilityHandler = { handle in
        log(\"\"\"
            availableData } is text here
            \"\"\")
        log(#"availableData "quoted" too"#)
        /* availableData
           still a comment } */
        _ = handle.readReady()
    }
}
"""
ALLOWED = """import Foundation

func start(_ pipe: Pipe, yield: @escaping @Sendable (Data) -> Void) {
    pipe.fileHandleForReading.readabilityHandler = { handle in
        // pipe-read-allow: a regular file, whose read never fails with EBADF while we hold it.
        let data = handle.availableData
        yield(data)
    }
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
        env = dict(os.environ, CHECK_CONCURRENCY_ONLY="crash-class")
        return subprocess.run(["bash", str(SCRIPT), str(root)], env=env, text=True, capture_output=True, timeout=60)


class PipeReadRule(unittest.TestCase):
    def assert_red(self, result, line):
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn(f"FixtureCore/Reader.swift:{line}: availableData in a readabilityHandler", result.stdout)
        self.assertIn("1 violation", result.stdout)

    def test_available_data_in_a_handler_is_red_even_with_a_concurrency_allow(self):
        self.assert_red(run({"FixtureCore/Reader.swift": HANDLER}), 6)

    def test_the_one_line_handler_is_red(self):
        self.assert_red(run({"FixtureCore/Reader.swift": ONE_LINE}), 4)

    def test_it_applies_in_a_ui_target_too(self):
        result = run({"FixtureUI/Reader.swift": HANDLER})
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("FixtureUI/Reader.swift:6: availableData in a readabilityHandler", result.stdout)

    def test_read_ready_is_green(self):
        result = run({"FixtureCore/Reader.swift": FIXED})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_nested_braces_and_a_brace_in_a_string_keep_the_handler_open(self):
        self.assert_red(run({"FixtureCore/Reader.swift": NESTED}), 9)

    def test_outside_a_handler_is_out_of_scope(self):
        result = run({"FixtureCore/Reader.swift": OUTSIDE})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_a_comment_naming_it_is_green(self):
        result = run({"FixtureCore/Reader.swift": COMMENT})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_a_brace_on_the_next_line_still_opens_the_handler(self):
        self.assert_red(run({"FixtureCore/Reader.swift": NEXT_LINE_BRACE}), 6)

    def test_the_name_in_a_string_or_a_trailing_comment_is_green(self):
        result = run({"FixtureCore/Reader.swift": TEXT})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_a_read_in_a_string_interpolation_is_red(self):
        self.assert_red(run({"FixtureCore/Reader.swift": INTERPOLATED}), 5)

    def test_a_brace_in_a_block_comment_does_not_close_the_handler(self):
        self.assert_red(run({"FixtureCore/Reader.swift": BLOCK_COMMENT}), 6)

    def test_the_name_in_multiline_and_raw_literals_and_block_comments_is_green(self):
        result = run({"FixtureCore/Reader.swift": LITERAL_TEXT})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_a_reviewed_escape_is_green(self):
        result = run({"FixtureCore/Reader.swift": ALLOWED})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
