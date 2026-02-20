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
        // Walk up from the test bundle to find the project root (contains GhosttyTabs.xcodeproj).
        var dir = URL(fileURLWithPath: #file).deletingLastPathComponent().deletingLastPathComponent()
        for _ in 0..<10 {
            let marker = dir.appendingPathComponent("GhosttyTabs.xcodeproj")
            if FileManager.default.fileExists(atPath: marker.path) {
                return dir
            }
            dir = dir.deletingLastPathComponent()
        }
        // Fallback: assume CWD is project root.
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }
}

/// Regression test: ensure WKWebView can load HTTP development URLs (e.g. *.localtest.me).
final class AppTransportSecurityTests: XCTestCase {
    func testInfoPlistAllowsArbitraryLoadsInWebContent() throws {
        let projectRoot = findProjectRoot()
        let infoPlistURL = projectRoot.appendingPathComponent("Resources/Info.plist")
        let data = try Data(contentsOf: infoPlistURL)
        var format = PropertyListSerialization.PropertyListFormat.xml
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, options: [], format: &format) as? [String: Any]
        )
        let ats = try XCTUnwrap(plist["NSAppTransportSecurity"] as? [String: Any])
        XCTAssertEqual(
            ats["NSAllowsArbitraryLoadsInWebContent"] as? Bool,
            true,
            "Resources/Info.plist must allow HTTP loads in WKWebView for local dev hostnames."
        )
    }

    private func findProjectRoot() -> URL {
        var dir = URL(fileURLWithPath: #file).deletingLastPathComponent().deletingLastPathComponent()
        for _ in 0..<10 {
            let marker = dir.appendingPathComponent("GhosttyTabs.xcodeproj")
            if FileManager.default.fileExists(atPath: marker.path) {
                return dir
            }
            dir = dir.deletingLastPathComponent()
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }
}
