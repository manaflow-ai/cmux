import Combine
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// MARK: - JSON Decoding


// MARK: - Notification hooks
extension CmuxConfigDecodingTests {
    func testDecodeNotificationHook() throws {
        let json = """
        {
          "notifications": {
            "hooks": [{
              "id": "agent-filter",
              "command": "jq '.effects.desktop = false'",
              "timeoutSeconds": 12
            }]
          }
        }
        """
        let config = try decode(json)
        let hook = try XCTUnwrap(config.notifications?.hooks?.first)
        XCTAssertEqual(hook.id, "agent-filter")
        XCTAssertEqual(hook.command, "jq '.effects.desktop = false'")
        XCTAssertEqual(hook.timeoutSeconds, 12)
        XCTAssertTrue(hook.enabled)
    }

    func testDecodeNotificationHookRejectsBlankCommand() {
        let json = """
        {
          "notifications": {
            "hooks": [{
              "id": "agent-filter",
              "command": "   "
            }]
          }
        }
        """
        XCTAssertThrowsError(try decode(json))
    }

    @MainActor
    func testNotificationHooksAppendThroughConfigHierarchy() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-config-store-\(UUID().uuidString)",
            isDirectory: true
        )
        let globalDirectory = root.appendingPathComponent("global", isDirectory: true)
        let projectDirectory = root.appendingPathComponent("project", isDirectory: true)
        let parentConfigDirectory = projectDirectory.appendingPathComponent(".cmux", isDirectory: true)
        let childDirectory = projectDirectory.appendingPathComponent("child", isDirectory: true)
        let childConfigDirectory = childDirectory.appendingPathComponent(".cmux", isDirectory: true)
        try FileManager.default.createDirectory(at: globalDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: parentConfigDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: childConfigDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let globalConfigURL = globalDirectory.appendingPathComponent("cmux.json")
        let parentConfigURL = parentConfigDirectory.appendingPathComponent("cmux.json")
        let childConfigURL = childConfigDirectory.appendingPathComponent("cmux.json")
        try """
        {
          "notifications": {
            "hooks": [{ "id": "global", "command": "cat" }]
          }
        }
        """.write(to: globalConfigURL, atomically: true, encoding: .utf8)
        try """
        {
          "notifications": {
            "hooks": [{ "id": "parent", "command": "cat" }]
          }
        }
        """.write(to: parentConfigURL, atomically: true, encoding: .utf8)
        try """
        {
          "notifications": {
            "hooks": [{ "id": "child", "command": "cat", "enabled": false }, { "id": "nearest", "command": "cat" }]
          }
        }
        """.write(to: childConfigURL, atomically: true, encoding: .utf8)

        let store = CmuxConfigStore(
            globalConfigPath: globalConfigURL.path,
            localConfigPath: childConfigURL.path,
            startFileWatchers: false
        )
        store.loadAll()

        XCTAssertEqual(store.notificationHooks.map(\.id), ["global", "parent", "nearest"])
        XCTAssertNil(store.notificationHooks[0].trustDescriptor)
        XCTAssertEqual(store.notificationHooks[1].trustDescriptor?.kind, "notificationHook")
        XCTAssertEqual(store.notificationHooks[1].trustDescriptor?.command, "cat")
        XCTAssertEqual(store.notificationHooks[1].trustDescriptor?.configPath, parentConfigURL.path)
        XCTAssertEqual(store.notificationHooks[2].trustDescriptor?.kind, "notificationHook")
        XCTAssertEqual(store.notificationHooks[1].cwd, projectDirectory.path)
        XCTAssertEqual(store.notificationHooks[2].cwd, childDirectory.path)
        XCTAssertTrue(store.configurationIssues.isEmpty)
    }

    @MainActor
    func testNotificationHooksIncludeExplicitLocalConfigOutsideDiscoveredHierarchy() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-config-store-\(UUID().uuidString)",
            isDirectory: true
        )
        let globalDirectory = root.appendingPathComponent("global", isDirectory: true)
        let explicitDirectory = root.appendingPathComponent("explicit", isDirectory: true)
        try FileManager.default.createDirectory(at: globalDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: explicitDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let globalConfigURL = globalDirectory.appendingPathComponent("cmux.json")
        let explicitConfigURL = explicitDirectory.appendingPathComponent("custom-cmux.json")
        try """
        {
          "notifications": {
            "hooks": [{ "id": "global", "command": "cat" }]
          }
        }
        """.write(to: globalConfigURL, atomically: true, encoding: .utf8)
        try """
        {
          "notifications": {
            "hooks": [{ "id": "explicit", "command": "cat" }]
          }
        }
        """.write(to: explicitConfigURL, atomically: true, encoding: .utf8)

        let store = CmuxConfigStore(
            globalConfigPath: globalConfigURL.path,
            localConfigPath: explicitConfigURL.path,
            startFileWatchers: false
        )
        store.loadAll()

        XCTAssertEqual(store.notificationHooks.map(\.id), ["global", "explicit"])
        XCTAssertEqual(store.notificationHooks[1].sourcePath, explicitConfigURL.path)
    }

    @MainActor
    func testNotificationHooksReplaceInheritedHooks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-config-store-\(UUID().uuidString)",
            isDirectory: true
        )
        let globalDirectory = root.appendingPathComponent("global", isDirectory: true)
        let projectDirectory = root.appendingPathComponent("project", isDirectory: true)
        let childConfigDirectory = projectDirectory
            .appendingPathComponent("child", isDirectory: true)
            .appendingPathComponent(".cmux", isDirectory: true)
        try FileManager.default.createDirectory(at: globalDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: childConfigDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let globalConfigURL = globalDirectory.appendingPathComponent("cmux.json")
        let childConfigURL = childConfigDirectory.appendingPathComponent("cmux.json")
        try """
        {
          "notifications": {
            "hooks": [{ "id": "global", "command": "cat" }]
          }
        }
        """.write(to: globalConfigURL, atomically: true, encoding: .utf8)
        try """
        {
          "notifications": {
            "hooksMode": "replace",
            "hooks": [{ "id": "child", "command": "cat" }]
          }
        }
        """.write(to: childConfigURL, atomically: true, encoding: .utf8)

        let store = CmuxConfigStore(
            globalConfigPath: globalConfigURL.path,
            localConfigPath: childConfigURL.path,
            startFileWatchers: false
        )
        store.loadAll()

        XCTAssertEqual(store.notificationHooks.map(\.id), ["child"])
    }

    @MainActor
    func testNotificationHooksResolveFromExplicitWorkspaceDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-config-store-\(UUID().uuidString)",
            isDirectory: true
        )
        let globalDirectory = root.appendingPathComponent("global", isDirectory: true)
        let projectDirectory = root.appendingPathComponent("project", isDirectory: true)
        let childDirectory = projectDirectory.appendingPathComponent("child", isDirectory: true)
        let childConfigDirectory = childDirectory.appendingPathComponent(".cmux", isDirectory: true)
        try FileManager.default.createDirectory(at: globalDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: childConfigDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let globalConfigURL = globalDirectory.appendingPathComponent("cmux.json")
        let childConfigURL = childConfigDirectory.appendingPathComponent("cmux.json")
        try """
        {
          "notifications": {
            "hooks": [{ "id": "global", "command": "cat" }]
          }
        }
        """.write(to: globalConfigURL, atomically: true, encoding: .utf8)
        try """
        {
          "notifications": {
            "hooks": [{ "id": "child", "command": "cat" }]
          }
        }
        """.write(to: childConfigURL, atomically: true, encoding: .utf8)

        let store = CmuxConfigStore(
            globalConfigPath: globalConfigURL.path,
            startFileWatchers: false
        )

        XCTAssertEqual(
            store.notificationHooks(startingFrom: childDirectory.path).map(\.id),
            ["global", "child"]
        )
    }

}
