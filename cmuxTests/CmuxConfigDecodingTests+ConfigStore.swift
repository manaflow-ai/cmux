import Combine
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// MARK: - JSON Decoding


// MARK: - Config store loading and watching
extension CmuxConfigDecodingTests {
    @MainActor
    func testInvalidConfigExposesSchemaIssueAndClearsAfterFix() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-config-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let configURL = root.appendingPathComponent("cmux.json")
        let invalidJSON = """
        {
          "actions": {
            "bad": {
              "type": "command",
              "command": "echo bad",
              "icon": "sparkles"
            }
          }
        }
        """
        try invalidJSON.write(to: configURL, atomically: true, encoding: .utf8)

        let store = CmuxConfigStore(
            globalConfigPath: root.appendingPathComponent("missing-global.json").path,
            localConfigPath: configURL.path,
            startFileWatchers: false
        )
        store.loadAll()

        let issue = try XCTUnwrap(store.configurationIssues.first)
        XCTAssertEqual(issue.kind, .schemaError)
        XCTAssertEqual(issue.sourcePath, configURL.path)
        XCTAssertTrue(issue.message?.contains("actions.bad.icon") ?? false)
        XCTAssertNil(store.resolvedAction(id: "bad"))

        let validJSON = """
        {
          "actions": {
            "bad": {
              "type": "command",
              "command": "echo bad",
              "icon": { "type": "symbol", "name": "sparkles" }
            }
          }
        }
        """
        try validJSON.write(to: configURL, atomically: true, encoding: .utf8)
        store.loadAll()

        XCTAssertTrue(store.configurationIssues.isEmpty)
        XCTAssertNotNil(store.resolvedAction(id: "bad"))
    }

    @MainActor
    func testConfigChangesRequireExplicitLoadByDefault() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-config-store-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let configURL = root.appendingPathComponent("cmux.json")
        try """
        {
          "actions": {
            "first": { "type": "command", "command": "echo first" }
          }
        }
        """.write(to: configURL, atomically: true, encoding: .utf8)

        let store = CmuxConfigStore(globalConfigPath: configURL.path)
        store.loadAll()
        XCTAssertNotNil(store.resolvedAction(id: "first"))
        XCTAssertNil(store.resolvedAction(id: "second"))

        let didAutoReload = expectation(description: "cmux.json should not hot reload")
        didAutoReload.isInverted = true
        var cancellable: AnyCancellable?
        cancellable = store.$loadedActions.dropFirst().sink { actions in
            if actions.contains(where: { $0.id == "second" }) {
                didAutoReload.fulfill()
            }
        }

        try """
        {
          "actions": {
            "second": { "type": "command", "command": "echo second" }
          }
        }
        """.write(to: configURL, atomically: true, encoding: .utf8)

        await fulfillment(of: [didAutoReload], timeout: 0.25)
        XCTAssertNotNil(store.resolvedAction(id: "first"))
        XCTAssertNil(store.resolvedAction(id: "second"))

        store.loadAll()
        XCTAssertNil(store.resolvedAction(id: "first"))
        XCTAssertNotNil(store.resolvedAction(id: "second"))
        cancellable?.cancel()
    }

    @MainActor
    func testConfigStoreParsesGlobalCmuxJSONCSettingsAndActionSections() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-config-store-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let configURL = root.appendingPathComponent("cmux.json")
        let data = """
        {
          // cmux-owned app settings share the global cmux.json file.
          "app": {
            "appearance": "dark",
          },
          "actions": {
            "first": {
              "type": "workspaceCommand",
              "commandName": "Dev",
            },
          },
          "ui": { "newWorkspace": { "action": "first" } },
          "commands": [{ "name": "Dev", "workspace": { "name": "Dev" } }],
        }
        """.data(using: .utf16LittleEndian)!
        try data.write(to: configURL)

        let store = CmuxConfigStore(globalConfigPath: configURL.path, startFileWatchers: false)
        store.loadAll()

        XCTAssertTrue(store.configurationIssues.isEmpty)
        XCTAssertNotNil(store.resolvedAction(id: "first"))
        XCTAssertEqual(store.newWorkspaceActionID, "first")
        XCTAssertEqual(store.loadedCommands.map(\.name), ["Dev"])
    }

    @MainActor
    func testConfigStoreReportsJSONCPreprocessingErrors() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-config-store-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let configURL = root.appendingPathComponent("cmux.json")
        try "{\n/* missing close\n\"actions\": {}\n}".write(to: configURL, atomically: true, encoding: .utf8)

        let store = CmuxConfigStore(globalConfigPath: configURL.path, startFileWatchers: false)
        store.loadAll()

        let issue = try XCTUnwrap(store.configurationIssues.first)
        XCTAssertEqual(issue.kind, .schemaError)
        XCTAssertEqual(issue.message, "JSONC preprocessing failed: unterminated block comment")
    }

    @MainActor
    func testLocalWatcherDetectsFirstCanonicalConfigAfterDirectoryCreation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-config-store-\(UUID().uuidString)",
            isDirectory: true
        )
        let projectDirectory = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let configDirectory = projectDirectory.appendingPathComponent(".cmux", isDirectory: true)
        let configURL = configDirectory.appendingPathComponent("cmux.json", isDirectory: false)
        let store = CmuxConfigStore(
            globalConfigPath: root.appendingPathComponent("missing-global.json").path,
            localConfigPath: configURL.path,
            startFileWatchers: true
        )
        store.loadAll()
        XCTAssertNil(store.resolvedAction(id: "created"))

        let loaded = expectation(description: "created local cmux config is loaded")
        loaded.assertForOverFulfill = false
        var cancellable: AnyCancellable?
        cancellable = store.$loadedActions.dropFirst().sink { actions in
            if actions.contains(where: { $0.id == "created" }) {
                loaded.fulfill()
            }
        }

        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        try """
        {
          "actions": {
            "created": { "type": "command", "command": "echo created" }
          }
        }
        """.write(to: configURL, atomically: true, encoding: .utf8)

        await fulfillment(of: [loaded], timeout: 3)
        cancellable?.cancel()
    }

    @MainActor
    func testLocalWatcherDetectsFirstLegacyConfigWhenCmuxDirectoryExists() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-config-store-\(UUID().uuidString)",
            isDirectory: true
        )
        let projectDirectory = root.appendingPathComponent("project", isDirectory: true)
        let configDirectory = projectDirectory.appendingPathComponent(".cmux", isDirectory: true)
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let canonicalConfigURL = configDirectory.appendingPathComponent("cmux.json", isDirectory: false)
        let legacyConfigURL = projectDirectory.appendingPathComponent("cmux.json", isDirectory: false)
        let store = CmuxConfigStore(
            globalConfigPath: root.appendingPathComponent("missing-global.json").path,
            localConfigPath: canonicalConfigURL.path,
            startFileWatchers: true
        )
        store.loadAll()
        XCTAssertNil(store.resolvedAction(id: "legacy-created"))

        let loaded = expectation(description: "created legacy cmux config is loaded")
        loaded.assertForOverFulfill = false
        var cancellable: AnyCancellable?
        cancellable = store.$loadedActions.dropFirst().sink { actions in
            if actions.contains(where: { $0.id == "legacy-created" }) {
                loaded.fulfill()
            }
        }

        try """
        {
          "actions": {
            "legacy-created": { "type": "command", "command": "echo created" }
          }
        }
        """.write(to: legacyConfigURL, atomically: true, encoding: .utf8)

        await fulfillment(of: [loaded], timeout: 3)
        cancellable?.cancel()
    }

}
