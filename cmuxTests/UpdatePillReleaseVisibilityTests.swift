import XCTest
import Foundation

/// Regression test: ensures UpdatePill is never gated behind #if DEBUG in production code paths.
/// This prevents accidentally hiding the update UI in Release builds.
final class UpdatePillReleaseVisibilityTests: XCTestCase {

    /// Source files that must show UpdatePill without #if DEBUG guards.
    private let filesToCheck = [
        "Sources/Update/UpdateTitlebarAccessory.swift",
        "Sources/ContentView.swift",
    ]

    func testUpdatePillNotGatedBehindDebug() throws {
        let projectRoot = findProjectRoot()

        for relativePath in filesToCheck {
            let url = projectRoot.appendingPathComponent(relativePath)
            let source = try String(contentsOf: url, encoding: .utf8)
            let lines = source.components(separatedBy: .newlines)

            // Track #if DEBUG nesting depth.
            var debugDepth = 0

            for (index, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)

                if trimmed == "#if DEBUG" || trimmed.hasPrefix("#if DEBUG ") {
                    debugDepth += 1
                } else if trimmed == "#endif" && debugDepth > 0 {
                    debugDepth -= 1
                } else if trimmed == "#else" && debugDepth > 0 {
                    // #else inside #if DEBUG means we're in the non-debug branch — that's fine.
                    // But UpdatePill in the #if DEBUG branch (before #else) is the problem.
                    // We handle this by only flagging UpdatePill when debugDepth > 0 and we haven't
                    // hit #else yet. For simplicity, treat #else as flipping out of the guarded section.
                    debugDepth -= 1
                }

                if debugDepth > 0 && trimmed.contains("UpdatePill") {
                    XCTFail(
                        """
                        \(relativePath):\(index + 1) — UpdatePill is inside #if DEBUG. \
                        This hides the update UI in Release builds. Remove the #if DEBUG guard \
                        or move UpdatePill to the #else branch.
                        """
                    )
                }
            }
        }
    }

    private func findProjectRoot() -> URL {
        // Walk up from the test bundle to find the project root.
        // Prefer the canonical project name, then any *.xcodeproj marker.
        var dir = URL(fileURLWithPath: #file).deletingLastPathComponent().deletingLastPathComponent()
        for _ in 0..<10 {
            let newMarker = dir.appendingPathComponent("cmux.xcodeproj")
            if FileManager.default.fileExists(atPath: newMarker.path) {
                return dir
            }

            if let entries = try? FileManager.default.contentsOfDirectory(atPath: dir.path),
               entries.contains(where: { $0.hasSuffix(".xcodeproj") }) {
                return dir
            }

            dir = dir.deletingLastPathComponent()
        }

        // Fallback: assume CWD is project root.
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }
}
