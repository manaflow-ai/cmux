"""check-concurrency.sh's self-ending-handle rule: in a uiSwiftSettings target (main actor by
default) a class that stores an OwnedTask or a MainDirectoryWatch declares `nonisolated deinit`.
The handles stop on the thread that releases them; behind the class's implicit deinit, which is
isolated there, the release hops to the main actor (swift_task_deinitOnExecutor), the cx-t7hu trap
inside an action's task-local scope."""
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
# The shape this slice had: the owner's deinit was deleted, the handle stayed.
NO_DEINIT = """import CmuxNextCompat

public final class TabSearchLiveUpdates {
    private var task: OwnedTask?

    public init() {}
}
"""
FIXED = """import CmuxNextCompat

public final class TabSearchLiveUpdates {
    private var task: OwnedTask?

    public init() {}

    nonisolated deinit {}
}
"""
WATCH_NO_DEINIT = """import CmuxNextWakeups

@MainActor
public final class SocketTasksSource {
    private var directoryWatch: MainDirectoryWatch?
}
"""
# A nonisolated class has a nonisolated implicit deinit: nothing to declare.
NONISOLATED_CLASS = """import CmuxNextCompat

nonisolated final class Holder {
    private var task: OwnedTask?
}
"""
# A raw Task handle is not a self-ending handle (nothing stops it on release).
RAW_TASK = """final class Watcher {
    private var task: Task<Void, Never>?
}
"""


def run(files):
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary) / "Package"
        (root / "Package.swift").parent.mkdir(parents=True)
        (root / "Package.swift").write_text(MANIFEST)
        for name, text in files.items():
            (root / "Sources" / name).parent.mkdir(parents=True, exist_ok=True)
            (root / "Sources" / name).write_text(text)
        return subprocess.run(["bash", str(SCRIPT), str(root)], text=True, capture_output=True, timeout=60)


class SelfEndingHandleRule(unittest.TestCase):
    def test_an_owned_task_without_a_nonisolated_deinit_is_red(self):
        result = run({"FixtureUI/TabSearchLiveUpdates.swift": NO_DEINIT})
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("FixtureUI/TabSearchLiveUpdates.swift:3: main-actor class stores an OwnedTask", result.stdout)

    def test_a_directory_watch_without_a_nonisolated_deinit_is_red(self):
        result = run({"FixtureUI/SocketTasksSource.swift": WATCH_NO_DEINIT})
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("FixtureUI/SocketTasksSource.swift:4:", result.stdout)

    def test_a_nonisolated_deinit_is_green(self):
        result = run({"FixtureUI/TabSearchLiveUpdates.swift": FIXED})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_a_non_ui_target_is_out_of_scope(self):
        result = run({"FixtureCore/TabSearchLiveUpdates.swift": NO_DEINIT})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_a_nonisolated_class_is_out_of_scope(self):
        result = run({"FixtureUI/Holder.swift": NONISOLATED_CLASS})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_a_raw_task_handle_is_out_of_scope(self):
        result = run({"FixtureUI/Watcher.swift": RAW_TASK})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
