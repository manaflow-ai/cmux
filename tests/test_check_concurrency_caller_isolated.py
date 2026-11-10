"""check-concurrency.sh's caller-isolated blocking rule (scripts/cmux-next/caller_isolation.py).

Every CmuxNext target enables NonisolatedNonsendingByDefault, so an async function that is not `@concurrent`
and not an actor's runs on its caller's actor: awaited from the main actor, its blocking calls block the main
thread. ProcessRunner.run (`public static func ... async` in a plain struct) wrote a child's stdin there and
the NIGHTLY main thread waited in write(2) for 391 s (2026-11-09)."""
import json
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
RULE = "blocking call in a caller-isolated async function"
# ProcessRunner's shape before the fix: nonisolated async in a plain struct, a header over several lines
# with a default closure argument (SSHRunner's), the write before launch on the caller's thread.
CALLER = """import Foundation

public struct Runner {
    public static func run(
        _ handle: FileHandle,
        stdin: Data,
        stop: @escaping @Sendable () -> Void = { print("stop") }
    ) async throws {
        try handle.write(contentsOf: stdin)
    }
}
"""
CONCURRENT = CALLER.replace("public static func", "@concurrent public static func")
ACTOR = """import Foundation

actor Runner {
    func run(_ handle: FileHandle, stdin: Data) async throws {
        try handle.write(contentsOf: stdin)
    }
}
"""
SYNC = """import Foundation

struct Runner {
    func run(_ handle: FileHandle, stdin: Data) throws {
        try handle.write(contentsOf: stdin)
    }
}
"""
OFF_THE_CALLER = """import Foundation

struct Runner {
    func run(_ handle: FileHandle, stdin: Data, work: BackgroundWork) async throws {
        try await work.run(.userVisible, mayBlock: .files) { try handle.write(contentsOf: stdin) }
        Task.detached { try? handle.write(contentsOf: stdin) }
        // concurrency-allow: an awaited Backoff wait suspends, it never blocks
        try await backoff.wait(owner: "retry")
    }
}
"""
INLINE_CLOSURE = """import Foundation

struct Runner {
    func run(_ process: Process) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            if true {
                do { try process.run() } catch { continuation.resume(throwing: error) }
            }
        }
    }
}
"""
SEAM = """import CmuxNextCompat
import Foundation

struct Runner {
    func run(_ handle: FileHandle, stdin: Data) async throws {
        try handle.blockingWrite(contentsOf: stdin)
    }
}
"""
ESCAPED = CALLER.replace("        try handle.write", "        // caller-isolation-allow: only ever awaited from the install actor\n        try handle.write")
ONLY_CONCURRENCY_ALLOW = CALLER.replace("        try handle.write", "        // concurrency-allow: never on the main thread\n        try handle.write")
UI = """import Foundation

final class Loader {
    func load(_ handle: FileHandle) async throws -> Data? {
        try handle.read(upToCount: 64)
    }
}
"""


def run(files, pending=None):
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary) / "Package"
        root.mkdir(parents=True)
        (root / "Package.swift").write_text(MANIFEST)
        for name, text in files.items():
            (root / "Sources" / name).parent.mkdir(parents=True, exist_ok=True)
            (root / "Sources" / name).write_text(text)
        env = {key: value for key, value in os.environ.items() if key != "CHECK_CONCURRENCY_ONLY"}
        listed = Path(temporary) / "pending.json"
        listed.write_text(json.dumps({"files": pending or {}}))
        env["CHECK_CONCURRENCY_CALLER_PENDING"] = str(listed)
        return subprocess.run(["bash", str(SCRIPT), str(root)], env=env, text=True, capture_output=True, timeout=60)


class CallerIsolatedBlockingRule(unittest.TestCase):
    def red(self, files, line, pending=None):
        result = run(files, pending)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        name = next(iter(files))
        self.assertIn(f"{name}:{line}: {RULE}", result.stdout)
        self.assertIn("@concurrent", result.stdout)
        return result

    def green(self, files, pending=None):
        result = run(files, pending)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn(RULE, result.stdout)
        return result

    def test_a_blocking_call_in_a_nonsending_async_function_is_red(self):
        self.red({"FixtureCore/Runner.swift": CALLER}, 9)

    def test_concurrent_is_green(self):
        self.green({"FixtureCore/Runner.swift": CONCURRENT})

    def test_an_actor_method_is_green(self):
        self.green({"FixtureCore/Runner.swift": ACTOR})

    def test_an_actor_static_method_runs_on_the_caller(self):
        self.red({"FixtureCore/Runner.swift": ACTOR.replace("    func run", "    static func run")}, 5)

    def test_a_sync_function_is_green(self):
        self.green({"FixtureCore/Runner.swift": SYNC})

    def test_work_handed_off_the_caller_and_an_awaited_wait_are_green(self):
        self.green({"FixtureCore/Runner.swift": OFF_THE_CALLER})

    def test_an_inline_closure_keeps_the_caller(self):
        self.red({"FixtureCore/Runner.swift": INLINE_CLOSURE}, 7)

    def test_a_checked_seam_is_red_too(self):
        self.red({"FixtureCore/Runner.swift": SEAM}, 6)

    def test_an_unannotated_async_function_in_a_ui_target_is_main_actor(self):
        self.red({"FixtureUI/Loader.swift": UI}, 5)

    def test_the_rule_escape_is_green(self):
        self.green({"FixtureCore/Runner.swift": ESCAPED})

    def test_a_concurrency_allow_alone_does_not_escape_it(self):
        # That comment says the call is safe off the main thread; this rule is about that assumption.
        self.red({"FixtureCore/Runner.swift": ONLY_CONCURRENCY_ALLOW}, 10)

    def test_a_pending_file_keeps_its_count(self):
        self.green({"FixtureCore/Runner.swift": CALLER}, pending={"FixtureCore/Runner.swift": 1})

    def test_a_pending_file_with_more_hits_is_red(self):
        twice = CALLER.replace("        try handle.write(contentsOf: stdin)\n",
                               "        try handle.write(contentsOf: stdin)\n        try handle.write(contentsOf: stdin)\n")
        result = self.red({"FixtureCore/Runner.swift": twice}, 9, pending={"FixtureCore/Runner.swift": 1})
        self.assertIn("is pending with 1; it now has 2", result.stdout)

    def test_a_pending_file_fixed_elsewhere_is_a_note_not_a_failure(self):
        result = self.green({"FixtureCore/Runner.swift": CONCURRENT}, pending={"FixtureCore/Runner.swift": 1})
        self.assertIn("note: FixtureCore/Runner.swift has 0 caller-isolated blocking call(s), pending lists 1",
                      result.stdout)


if __name__ == "__main__":
    unittest.main()
