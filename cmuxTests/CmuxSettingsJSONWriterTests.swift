import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

private final class FailingSecurityAttributeFileManager: FileManager, @unchecked Sendable {
    private let lock = NSLock()
    private var _setAttributesCount = 0

    var setAttributesCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _setAttributesCount
    }

    override func setAttributes(_ attributes: [FileAttributeKey: Any], ofItemAtPath path: String) throws {
        lock.lock()
        _setAttributesCount += 1
        lock.unlock()
        throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: path])
    }
}

final class CmuxSettingsJSONWriterTests: XCTestCase {
    func testWriteBackReportsWroteChangesWhenSecurityAttributeRestoreFails() async throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let primaryURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "sidebarAppearance": {
                "matchTerminalBackground": true
              }
            }
            """,
            to: primaryURL
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: primaryURL.path)

        let fileManager = FailingSecurityAttributeFileManager()
        let plan = ManagedSettingsWriteBackPlan(
            changesBySourcePath: [
                primaryURL.path: [
                    "sidebarAppearance.matchTerminalBackground": false
                ]
            ]
        )

        let outcome = try await plan.write(fileManager: fileManager)

        XCTAssertEqual(outcome, .wroteChanges)
        XCTAssertGreaterThan(fileManager.setAttributesCount, 0)
        XCTAssertEqual(
            try boolSetting(in: primaryURL, section: "sidebarAppearance", key: "matchTerminalBackground"),
            false
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-settings-json-writer-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeSettingsFile(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func boolSetting(in url: URL, section: String, key: String) throws -> Bool? {
        let data = try Data(contentsOf: url)
        let sanitized = try JSONCParser.preprocess(data: data)
        let object = try JSONSerialization.jsonObject(with: sanitized, options: []) as? [String: Any]
        let settingsSection = object?[section] as? [String: Any]
        return settingsSection?[key] as? Bool
    }
}
