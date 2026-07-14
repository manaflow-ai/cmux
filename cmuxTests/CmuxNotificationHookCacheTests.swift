import XCTest
@testable import cmux

final class CmuxNotificationHookCacheTests: XCTestCase {
    func testCachesLayeredHooksAndInvalidatesChangedAndNewConfigFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-notification-hook-cache-\(UUID().uuidString)",
            isDirectory: true
        )
        let globalDirectory = root.appendingPathComponent("global", isDirectory: true)
        let projectDirectory = root.appendingPathComponent("project", isDirectory: true)
        let childDirectory = projectDirectory.appendingPathComponent("child", isDirectory: true)
        let childConfigDirectory = childDirectory.appendingPathComponent(".cmux", isDirectory: true)
        try FileManager.default.createDirectory(at: globalDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: childConfigDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let globalConfig = globalDirectory.appendingPathComponent("cmux.json")
        let projectConfig = projectDirectory.appendingPathComponent("cmux.json")
        let childConfig = childConfigDirectory.appendingPathComponent("cmux.json")
        try writeHook(id: "global", to: globalConfig)
        try writeHook(id: "child", to: childConfig)

        let cache = CmuxNotificationHookCache()
        let first = await cache.hooks(
            startingFrom: childDirectory.path,
            globalConfigPath: globalConfig.path
        )
        let afterFirst = await cache.statistics()
        let repeated = await cache.hooks(
            startingFrom: childDirectory.path,
            globalConfigPath: globalConfig.path
        )
        let afterRepeated = await cache.statistics()

        XCTAssertEqual(first.map(\.id), ["global", "child"])
        XCTAssertEqual(repeated, first)
        XCTAssertEqual(afterRepeated.parseCount, afterFirst.parseCount)
        XCTAssertEqual(afterRepeated.hitCount, afterFirst.hitCount + 1)

        try writeHook(id: "child-updated-longer", to: childConfig)
        let changed = await cache.hooks(
            startingFrom: childDirectory.path,
            globalConfigPath: globalConfig.path
        )
        XCTAssertEqual(changed.map(\.id), ["global", "child-updated-longer"])

        try writeHook(id: "project", to: projectConfig)
        let added = await cache.hooks(
            startingFrom: childDirectory.path,
            globalConfigPath: globalConfig.path
        )
        XCTAssertEqual(added.map(\.id), ["global", "project", "child-updated-longer"])
    }

    private func writeHook(id: String, to url: URL) throws {
        try """
        {
          // JSONC is supported by cmux config files.
          "notifications": {
            "hooks": [{ "id": "\(id)", "command": "cat" }],
          },
        }
        """.write(to: url, atomically: true, encoding: .utf8)
    }
}
