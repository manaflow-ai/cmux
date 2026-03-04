import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class WorkspaceDirectorySettingsTests: XCTestCase {
    func testCurrentReturnsDefaultWhenUnset() {
        let defaults = isolatedDefaults()
        XCTAssertEqual(
            WorkspaceDirectorySettings.current(defaults: defaults),
            WorkspaceDirectorySettings.defaultMode
        )
    }

    func testCurrentReturnsStoredMode() {
        let defaults = isolatedDefaults()
        defaults.set(NewWorkspaceDirectoryMode.customPath.rawValue, forKey: WorkspaceDirectorySettings.modeKey)

        XCTAssertEqual(
            WorkspaceDirectorySettings.current(defaults: defaults),
            .customPath
        )
    }

    func testCurrentFallsBackToDefaultForInvalidStoredValue() {
        let defaults = isolatedDefaults()
        defaults.set("invalid-mode", forKey: WorkspaceDirectorySettings.modeKey)

        XCTAssertEqual(
            WorkspaceDirectorySettings.current(defaults: defaults),
            WorkspaceDirectorySettings.defaultMode
        )
    }

    func testDefaultWorkingDirectoryInheritUsesInheritedDirectory() {
        let resolved = WorkspaceDirectorySettings.defaultWorkingDirectory(
            mode: .inheritCurrent,
            inheritedDirectory: "/tmp/project",
            customDirectory: "/Users/tester/Developer"
        )
        XCTAssertEqual(resolved, "/tmp/project")
    }

    func testDefaultWorkingDirectoryInheritCanBeNil() {
        let resolved = WorkspaceDirectorySettings.defaultWorkingDirectory(
            mode: .inheritCurrent,
            inheritedDirectory: nil,
            customDirectory: "/Users/tester/Developer"
        )
        XCTAssertNil(resolved)
    }

    func testDefaultWorkingDirectoryCustomUsesCustomDirectory() {
        let resolved = WorkspaceDirectorySettings.defaultWorkingDirectory(
            mode: .customPath,
            inheritedDirectory: "/tmp/project",
            customDirectory: "/Users/tester/Developer"
        )
        XCTAssertEqual(resolved, "/Users/tester/Developer")
    }

    func testDefaultWorkingDirectoryCustomFallsBackToInheritedWhenCustomMissing() {
        let resolved = WorkspaceDirectorySettings.defaultWorkingDirectory(
            mode: .customPath,
            inheritedDirectory: "/tmp/project",
            customDirectory: nil
        )
        XCTAssertEqual(resolved, "/tmp/project")
    }

    func testCurrentCustomDirectoryReturnsNilWhenUnset() {
        let defaults = isolatedDefaults()
        XCTAssertNil(WorkspaceDirectorySettings.currentCustomDirectory(defaults: defaults))
    }

    func testCurrentCustomDirectoryResolvesRelativePathFromHome() {
        let defaults = isolatedDefaults()
        defaults.set(".", forKey: WorkspaceDirectorySettings.customPathKey)

        let resolved = WorkspaceDirectorySettings.currentCustomDirectory(defaults: defaults)
        XCTAssertEqual(resolved, FileManager.default.homeDirectoryForCurrentUser.path)
    }

    func testNormalizedCustomDirectoryExpandsTilde() {
        let resolved = WorkspaceDirectorySettings.normalizedCustomDirectory(
            "~/Developer",
            homeDirectory: "/Users/tester"
        )
        XCTAssertEqual(resolved, "/Users/tester/Developer")
    }

    func testNormalizedCustomDirectoryAcceptsFileURL() {
        let resolved = WorkspaceDirectorySettings.normalizedCustomDirectory(
            "file:///Users/tester/Developer",
            homeDirectory: "/Users/tester"
        )
        XCTAssertEqual(resolved, "/Users/tester/Developer")
    }

    func testValidateCustomDirectoryReturnsInvalidWhenPathMissing() {
        let missingPath = "/tmp/cmux-missing-\(UUID().uuidString)"
        let validation = WorkspaceDirectorySettings.validateCustomDirectory(
            missingPath,
            homeDirectory: "/Users/tester"
        )
        XCTAssertEqual(validation, .invalid(path: missingPath, reason: "Path does not exist."))
    }

    func testValidateCustomDirectoryReturnsInvalidWhenPathIsFile() throws {
        let tempFile = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cmux-file-\(UUID().uuidString)")
        XCTAssertTrue(
            FileManager.default.createFile(atPath: tempFile.path, contents: Data(), attributes: nil),
            "Temp file should be created so this test validates the file-vs-directory path."
        )
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let validation = WorkspaceDirectorySettings.validateCustomDirectory(
            tempFile.path,
            homeDirectory: "/Users/tester"
        )
        XCTAssertEqual(validation, .invalid(path: tempFile.path, reason: "Path is not a directory."))
    }

    func testCurrentCustomDirectoryReturnsNilWhenPathMissing() {
        let defaults = isolatedDefaults()
        defaults.set("/tmp/cmux-missing-\(UUID().uuidString)", forKey: WorkspaceDirectorySettings.customPathKey)
        XCTAssertNil(WorkspaceDirectorySettings.currentCustomDirectory(defaults: defaults))
    }

    private func isolatedDefaults() -> UserDefaults {
        let suiteName = "WorkspaceDirectorySettingsTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Failed to create UserDefaults suite \(suiteName)")
        }
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
